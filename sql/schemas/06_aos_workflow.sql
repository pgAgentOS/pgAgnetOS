-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_workflow (Workflow Engine - LangGraph-inspired)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_workflow;

-- ----------------------------------------------------------------------------
-- Table: workflow_graph
-- Purpose: Graph definitions (like LangGraph StateGraph)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_workflow.workflow_graph (
    graph_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Identity
    name text NOT NULL,
    display_name text,
    description text,
    version text NOT NULL DEFAULT '1.0',
    
    -- Configuration
    config jsonb DEFAULT '{}'::jsonb,                -- e.g., {"max_steps": 100, "timeout_ms": 300000}
    
    -- Entry/Exit points
    entry_node text NOT NULL DEFAULT '__start__',
    exit_nodes text[] DEFAULT ARRAY['__end__']::text[],
    
    -- Metadata
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    created_by uuid REFERENCES aos_auth.principal(principal_id),
    
    UNIQUE (tenant_id, name, version)
);

CREATE INDEX idx_workflow_graph_tenant ON aos_workflow.workflow_graph(tenant_id);
CREATE INDEX idx_workflow_graph_name ON aos_workflow.workflow_graph(name);
CREATE INDEX idx_workflow_graph_active ON aos_workflow.workflow_graph(is_active) WHERE is_active = true;

-- Add FK from aos_core.run to workflow_graph
ALTER TABLE aos_core.run 
    ADD CONSTRAINT fk_run_graph 
    FOREIGN KEY (graph_id) REFERENCES aos_workflow.workflow_graph(graph_id);

-- ----------------------------------------------------------------------------
-- Table: workflow_graph_node
-- Purpose: Nodes in the graph (skill, llm, router, function, human, gateway)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_workflow.workflow_graph_node (
    node_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    graph_id uuid NOT NULL REFERENCES aos_workflow.workflow_graph(graph_id) ON DELETE CASCADE,
    
    -- Node identity
    node_name text NOT NULL,
    node_type text NOT NULL CHECK (node_type IN (
        'skill',      -- Execute a skill
        'llm',        -- LLM call with specific prompt
        'router',     -- Conditional branching
        'function',   -- Execute a PL/pgSQL function
        'human',      -- Human-in-the-loop checkpoint
        'gateway',    -- Entry/exit points
        'parallel',   -- Parallel execution branch
        'subgraph'    -- Nested graph execution
    )),
    
    -- Execution config
    skill_key text REFERENCES aos_skills.skill(skill_key),
    function_name regproc,                           -- PL/pgSQL function to call
    subgraph_id uuid REFERENCES aos_workflow.workflow_graph(graph_id),
    
    -- LLM-specific config
    persona_id uuid REFERENCES aos_persona.persona(persona_id),
    prompt_template text,
    llm_override_params jsonb DEFAULT '{}'::jsonb,
    
    -- Interrupt config (human-in-the-loop)
    interrupt_before bool DEFAULT false,
    interrupt_after bool DEFAULT false,
    interrupt_condition text,                        -- SQL expression
    
    -- Node config
    config jsonb DEFAULT '{}'::jsonb,                -- e.g., {"retry_count": 3, "timeout_ms": 30000}
    
    -- Metadata
    description text,
    position jsonb,                                  -- For visualization: {"x": 100, "y": 200}
    
    UNIQUE (graph_id, node_name)
);

CREATE INDEX idx_workflow_node_graph ON aos_workflow.workflow_graph_node(graph_id);
CREATE INDEX idx_workflow_node_type ON aos_workflow.workflow_graph_node(node_type);
CREATE INDEX idx_workflow_node_skill ON aos_workflow.workflow_graph_node(skill_key) WHERE skill_key IS NOT NULL;

-- ----------------------------------------------------------------------------
-- Table: workflow_graph_edge
-- Purpose: Edges connecting nodes (with optional conditions)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_workflow.workflow_graph_edge (
    edge_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    graph_id uuid NOT NULL REFERENCES aos_workflow.workflow_graph(graph_id) ON DELETE CASCADE,
    
    -- Connection
    from_node text NOT NULL,
    to_node text NOT NULL,
    
    -- Conditional routing
    is_conditional bool DEFAULT false,
    condition_function regproc,                      -- Returns bool
    condition_expression text,                       -- SQL expression (if no function)
    condition_value jsonb,                           -- Match against state value
    
    -- Metadata
    label text,                                      -- e.g., 'success', 'failure', 'continue'
    priority int DEFAULT 0,                          -- Higher = evaluated first for conditionals
    description text,
    
    UNIQUE (graph_id, from_node, to_node, label)
);

CREATE INDEX idx_workflow_edge_graph ON aos_workflow.workflow_graph_edge(graph_id);
CREATE INDEX idx_workflow_edge_from ON aos_workflow.workflow_graph_edge(from_node);
CREATE INDEX idx_workflow_edge_to ON aos_workflow.workflow_graph_edge(to_node);
CREATE INDEX idx_workflow_edge_priority ON aos_workflow.workflow_graph_edge(priority DESC);

-- ----------------------------------------------------------------------------
-- Table: workflow_state
-- Purpose: Checkpoint states (for time-travel and recovery)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_workflow.workflow_state (
    state_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id uuid NOT NULL REFERENCES aos_core.run(run_id) ON DELETE CASCADE,
    graph_id uuid NOT NULL REFERENCES aos_workflow.workflow_graph(graph_id),
    
    -- Checkpoint version (for time-travel)
    checkpoint_version int NOT NULL,
    
    -- Current position
    current_node text NOT NULL,
    previous_node text,
    
    -- State data
    state_data jsonb NOT NULL DEFAULT '{}'::jsonb,
    messages jsonb[] DEFAULT ARRAY[]::jsonb[],
    
    -- Lineage
    parent_state_id uuid REFERENCES aos_workflow.workflow_state(state_id),
    
    -- Metadata
    created_at timestamptz NOT NULL DEFAULT now(),
    is_final bool DEFAULT false,
    
    UNIQUE (run_id, checkpoint_version)
);

CREATE INDEX idx_workflow_state_run ON aos_workflow.workflow_state(run_id);
CREATE INDEX idx_workflow_state_checkpoint ON aos_workflow.workflow_state(run_id, checkpoint_version DESC);
CREATE INDEX idx_workflow_state_node ON aos_workflow.workflow_state(current_node);

-- ----------------------------------------------------------------------------
-- Table: workflow_interrupt
-- Purpose: Human-in-the-loop interrupts
-- ----------------------------------------------------------------------------
CREATE TABLE aos_workflow.workflow_interrupt (
    interrupt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id uuid NOT NULL REFERENCES aos_core.run(run_id) ON DELETE CASCADE,
    state_id uuid REFERENCES aos_workflow.workflow_state(state_id),
    
    -- Interrupt details
    node_name text NOT NULL,
    interrupt_type text NOT NULL DEFAULT 'approval'
        CHECK (interrupt_type IN ('approval', 'input', 'review', 'escalation')),
    
    -- Status
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'resolved', 'rejected', 'timeout', 'cancelled')),
    
    -- Request/Response
    request_message text,
    request_data jsonb DEFAULT '{}'::jsonb,
    response_data jsonb,
    changes jsonb,                                   -- State modifications made by human
    
    -- Who
    requested_by uuid REFERENCES aos_auth.principal(principal_id),
    resolved_by uuid REFERENCES aos_auth.principal(principal_id),
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    expires_at timestamptz                           -- Auto-reject after this time
);

CREATE INDEX idx_workflow_interrupt_run ON aos_workflow.workflow_interrupt(run_id);
CREATE INDEX idx_workflow_interrupt_status ON aos_workflow.workflow_interrupt(status);
CREATE INDEX idx_workflow_interrupt_pending ON aos_workflow.workflow_interrupt(status, created_at) 
    WHERE status = 'pending';

-- ----------------------------------------------------------------------------
-- Function: validate_graph
-- Purpose: Validate graph structure (no orphan nodes, valid edges, etc.)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.validate_graph(p_graph_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_errors text[] := ARRAY[]::text[];
    v_warnings text[] := ARRAY[]::text[];
    v_graph aos_workflow.workflow_graph;
    v_node record;
    v_edge record;
BEGIN
    -- Get graph
    SELECT * INTO v_graph FROM aos_workflow.workflow_graph WHERE graph_id = p_graph_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('valid', false, 'errors', ARRAY['Graph not found']);
    END IF;
    
    -- Check entry node exists
    IF NOT EXISTS (
        SELECT 1 FROM aos_workflow.workflow_graph_node 
        WHERE graph_id = p_graph_id AND node_name = v_graph.entry_node
    ) THEN
        v_errors := array_append(v_errors, 'Entry node not found: ' || v_graph.entry_node);
    END IF;
    
    -- Check for orphan nodes (no incoming edges except entry)
    FOR v_node IN
        SELECT n.node_name
        FROM aos_workflow.workflow_graph_node n
        WHERE n.graph_id = p_graph_id
          AND n.node_name != v_graph.entry_node
          AND NOT EXISTS (
              SELECT 1 FROM aos_workflow.workflow_graph_edge e
              WHERE e.graph_id = p_graph_id AND e.to_node = n.node_name
          )
    LOOP
        v_warnings := array_append(v_warnings, 'Orphan node (no incoming edges): ' || v_node.node_name);
    END LOOP;
    
    -- Check for dead-end nodes (no outgoing edges except exit)
    FOR v_node IN
        SELECT n.node_name
        FROM aos_workflow.workflow_graph_node n
        WHERE n.graph_id = p_graph_id
          AND n.node_name != ALL(v_graph.exit_nodes)
          AND NOT EXISTS (
              SELECT 1 FROM aos_workflow.workflow_graph_edge e
              WHERE e.graph_id = p_graph_id AND e.from_node = n.node_name
          )
    LOOP
        v_warnings := array_append(v_warnings, 'Dead-end node (no outgoing edges): ' || v_node.node_name);
    END LOOP;
    
    -- Check edges reference valid nodes
    FOR v_edge IN
        SELECT e.from_node, e.to_node
        FROM aos_workflow.workflow_graph_edge e
        WHERE e.graph_id = p_graph_id
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM aos_workflow.workflow_graph_node 
            WHERE graph_id = p_graph_id AND node_name = v_edge.from_node
        ) AND v_edge.from_node != v_graph.entry_node THEN
            v_errors := array_append(v_errors, 'Edge from non-existent node: ' || v_edge.from_node);
        END IF;
        
        IF NOT EXISTS (
            SELECT 1 FROM aos_workflow.workflow_graph_node 
            WHERE graph_id = p_graph_id AND node_name = v_edge.to_node
        ) AND v_edge.to_node != ALL(v_graph.exit_nodes) THEN
            v_errors := array_append(v_errors, 'Edge to non-existent node: ' || v_edge.to_node);
        END IF;
    END LOOP;
    
    RETURN jsonb_build_object(
        'valid', array_length(v_errors, 1) IS NULL,
        'errors', v_errors,
        'warnings', v_warnings
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_graph_visualization
-- Purpose: Generate DOT format for Graphviz visualization
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.get_graph_visualization(p_graph_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_graph aos_workflow.workflow_graph;
    v_dot text;
    v_node record;
    v_edge record;
BEGIN
    SELECT * INTO v_graph FROM aos_workflow.workflow_graph WHERE graph_id = p_graph_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Graph not found: %', p_graph_id;
    END IF;
    
    v_dot := 'digraph "' || v_graph.name || '" {' || E'\n';
    v_dot := v_dot || '  rankdir=TB;' || E'\n';
    v_dot := v_dot || '  node [shape=box, style=rounded];' || E'\n';
    
    -- Add nodes
    FOR v_node IN
        SELECT node_name, node_type, description
        FROM aos_workflow.workflow_graph_node
        WHERE graph_id = p_graph_id
    LOOP
        v_dot := v_dot || '  "' || v_node.node_name || '" [';
        v_dot := v_dot || 'label="' || v_node.node_name || '\n(' || v_node.node_type || ')"';
        
        -- Color by type
        CASE v_node.node_type
            WHEN 'gateway' THEN v_dot := v_dot || ', shape=diamond, fillcolor="#e8f5e9", style="filled,rounded"';
            WHEN 'human' THEN v_dot := v_dot || ', fillcolor="#fff3e0", style="filled,rounded"';
            WHEN 'router' THEN v_dot := v_dot || ', shape=diamond, fillcolor="#e3f2fd", style="filled,rounded"';
            WHEN 'llm' THEN v_dot := v_dot || ', fillcolor="#f3e5f5", style="filled,rounded"';
            WHEN 'skill' THEN v_dot := v_dot || ', fillcolor="#e0f7fa", style="filled,rounded"';
            ELSE v_dot := v_dot || '';
        END CASE;
        
        v_dot := v_dot || '];' || E'\n';
    END LOOP;
    
    -- Add edges
    FOR v_edge IN
        SELECT from_node, to_node, label, is_conditional
        FROM aos_workflow.workflow_graph_edge
        WHERE graph_id = p_graph_id
        ORDER BY priority DESC
    LOOP
        v_dot := v_dot || '  "' || v_edge.from_node || '" -> "' || v_edge.to_node || '"';
        IF v_edge.label IS NOT NULL OR v_edge.is_conditional THEN
            v_dot := v_dot || ' [';
            IF v_edge.label IS NOT NULL THEN
                v_dot := v_dot || 'label="' || v_edge.label || '"';
            END IF;
            IF v_edge.is_conditional THEN
                v_dot := v_dot || ', style=dashed';
            END IF;
            v_dot := v_dot || ']';
        END IF;
        v_dot := v_dot || ';' || E'\n';
    END LOOP;
    
    v_dot := v_dot || '}';
    
    RETURN v_dot;
END;
$$;

COMMENT ON SCHEMA aos_workflow IS 'pgAgentOS: LangGraph-inspired workflow engine';
COMMENT ON TABLE aos_workflow.workflow_graph IS 'Workflow graph definitions';
COMMENT ON TABLE aos_workflow.workflow_graph_node IS 'Nodes in workflow graphs';
COMMENT ON TABLE aos_workflow.workflow_graph_edge IS 'Edges connecting nodes';
COMMENT ON TABLE aos_workflow.workflow_state IS 'Checkpoint states for time-travel and recovery';
COMMENT ON TABLE aos_workflow.workflow_interrupt IS 'Human-in-the-loop interrupts';
COMMENT ON FUNCTION aos_workflow.validate_graph IS 'Validate graph structure';
COMMENT ON FUNCTION aos_workflow.get_graph_visualization IS 'Generate DOT format for Graphviz';
