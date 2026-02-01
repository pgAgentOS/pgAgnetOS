-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_core (Core Execution Tracking)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_core;

-- ----------------------------------------------------------------------------
-- Table: run
-- Purpose: Workflow execution instances
-- ----------------------------------------------------------------------------
CREATE TABLE aos_core.run (
    run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    principal_id uuid REFERENCES aos_auth.principal(principal_id),
    graph_id uuid,                                   -- FK added after aos_workflow created
    persona_id uuid REFERENCES aos_persona.persona(persona_id),
    parent_run_id uuid REFERENCES aos_core.run(run_id),
    
    -- Status tracking
    status text NOT NULL DEFAULT 'pending' 
        CHECK (status IN ('pending', 'running', 'completed', 'failed', 'interrupted', 'cancelled')),
    
    -- Timing
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    
    -- Execution context
    input_data jsonb DEFAULT '{}'::jsonb,
    output_data jsonb,
    error_info jsonb,
    
    -- Metadata
    metadata jsonb DEFAULT '{}'::jsonb,              -- e.g., {"tags": ["test"], "priority": "high"}
    
    -- Stats
    total_steps int DEFAULT 0,
    total_tokens_used int DEFAULT 0,
    total_cost_usd numeric(10, 6) DEFAULT 0
);

CREATE INDEX idx_run_tenant ON aos_core.run(tenant_id);
CREATE INDEX idx_run_status ON aos_core.run(status);
CREATE INDEX idx_run_started ON aos_core.run(started_at DESC);
CREATE INDEX idx_run_tenant_status ON aos_core.run(tenant_id, status, started_at DESC);
CREATE INDEX idx_run_parent ON aos_core.run(parent_run_id) WHERE parent_run_id IS NOT NULL;
CREATE INDEX idx_run_graph ON aos_core.run(graph_id) WHERE graph_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- Table: event_log
-- Purpose: Immutable audit log for all events
-- ----------------------------------------------------------------------------
CREATE TABLE aos_core.event_log (
    event_id bigserial PRIMARY KEY,
    run_id uuid NOT NULL REFERENCES aos_core.run(run_id) ON DELETE CASCADE,
    
    -- Event details
    event_type text NOT NULL,                        -- e.g., 'node_start', 'node_end', 'decision', 'error'
    event_subtype text,                              -- More specific categorization
    node_name text,                                  -- Which node triggered this event
    
    -- Payload
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    duration_ms bigint                               -- If applicable
);

CREATE INDEX idx_event_log_run ON aos_core.event_log(run_id);
CREATE INDEX idx_event_log_type ON aos_core.event_log(event_type);
CREATE INDEX idx_event_log_created ON aos_core.event_log(created_at);
CREATE INDEX idx_event_log_run_created ON aos_core.event_log(run_id, created_at);

-- ----------------------------------------------------------------------------
-- Table: skill_execution
-- Purpose: Track individual skill executions
-- ----------------------------------------------------------------------------
CREATE TABLE aos_core.skill_execution (
    execution_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id uuid NOT NULL REFERENCES aos_core.run(run_id) ON DELETE CASCADE,
    skill_key text NOT NULL REFERENCES aos_skills.skill(skill_key),
    
    -- Input/Output
    input_params jsonb NOT NULL DEFAULT '{}'::jsonb,
    input_params_hash text,                          -- SHA256 for dedup/caching
    output_data jsonb,
    output_summary jsonb,                            -- Condensed version for display
    
    -- Status
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'running', 'success', 'failure', 'timeout', 'cancelled')),
    error_message text,
    
    -- Metrics
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    duration_ms bigint,
    tokens_used int,
    cost_usd numeric(10, 6)
);

CREATE INDEX idx_skill_execution_run ON aos_core.skill_execution(run_id);
CREATE INDEX idx_skill_execution_skill ON aos_core.skill_execution(skill_key);
CREATE INDEX idx_skill_execution_status ON aos_core.skill_execution(status);
CREATE INDEX idx_skill_execution_hash ON aos_core.skill_execution(input_params_hash) 
    WHERE input_params_hash IS NOT NULL;

-- ----------------------------------------------------------------------------
-- Table: session_memory
-- Purpose: Session-scoped memory for agents
-- ----------------------------------------------------------------------------
CREATE TABLE aos_core.session_memory (
    memory_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id uuid REFERENCES aos_core.run(run_id) ON DELETE CASCADE,
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    principal_id uuid REFERENCES aos_auth.principal(principal_id),
    
    -- Memory content
    memory_type text NOT NULL DEFAULT 'conversation'
        CHECK (memory_type IN ('conversation', 'working', 'scratch', 'context')),
    messages jsonb[] NOT NULL DEFAULT ARRAY[]::jsonb[],
    key_value_store jsonb DEFAULT '{}'::jsonb,
    
    -- TTL
    last_accessed timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz,
    
    -- Limits
    max_messages int DEFAULT 100,
    max_tokens int DEFAULT 100000
);

CREATE INDEX idx_session_memory_run ON aos_core.session_memory(run_id);
CREATE INDEX idx_session_memory_tenant ON aos_core.session_memory(tenant_id);
CREATE INDEX idx_session_memory_expires ON aos_core.session_memory(expires_at) 
    WHERE expires_at IS NOT NULL;
CREATE INDEX idx_session_memory_accessed ON aos_core.session_memory(last_accessed DESC);

-- ----------------------------------------------------------------------------
-- Function: store_memory
-- Purpose: Store key-value in session memory
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.store_memory(
    p_run_id uuid,
    p_key text,
    p_value jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE aos_core.session_memory
    SET key_value_store = key_value_store || jsonb_build_object(p_key, p_value),
        last_accessed = now()
    WHERE run_id = p_run_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Session memory not found for run: %', p_run_id;
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: recall_memory
-- Purpose: Recall value from session memory
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.recall_memory(
    p_run_id uuid,
    p_key text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_result jsonb;
BEGIN
    SELECT key_value_store -> p_key INTO v_result
    FROM aos_core.session_memory
    WHERE run_id = p_run_id;
    
    -- Update last accessed
    UPDATE aos_core.session_memory
    SET last_accessed = now()
    WHERE run_id = p_run_id;
    
    RETURN v_result;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: log_event
-- Purpose: Create an immutable event log entry
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.log_event(
    p_run_id uuid,
    p_event_type text,
    p_payload jsonb,
    p_node_name text DEFAULT NULL,
    p_event_subtype text DEFAULT NULL,
    p_duration_ms bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_event_id bigint;
BEGIN
    INSERT INTO aos_core.event_log (
        run_id, event_type, event_subtype, node_name, payload, duration_ms
    ) VALUES (
        p_run_id, p_event_type, p_event_subtype, p_node_name, p_payload, p_duration_ms
    )
    RETURNING event_id INTO v_event_id;
    
    RETURN v_event_id;
END;
$$;

COMMENT ON SCHEMA aos_core IS 'pgAgentOS: Core execution tracking';
COMMENT ON TABLE aos_core.run IS 'Workflow execution instances';
COMMENT ON TABLE aos_core.event_log IS 'Immutable audit log for all events';
COMMENT ON TABLE aos_core.skill_execution IS 'Individual skill execution records';
COMMENT ON TABLE aos_core.session_memory IS 'Session-scoped agent memory';
