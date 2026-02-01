-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_policy (Policy Hooks)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_policy;

-- ----------------------------------------------------------------------------
-- Table: hooks
-- Purpose: Policy hook registry
-- ----------------------------------------------------------------------------
CREATE TABLE aos_policy.hooks (
    hook_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Hook type
    hook_type text NOT NULL CHECK (hook_type IN (
        'pre_skill',     -- Before skill execution
        'post_skill',    -- After skill execution
        'pre_egress',    -- Before external API call
        'post_egress',   -- After external API call
        'pre_retrieve',  -- Before RAG retrieval
        'post_retrieve', -- After RAG retrieval
        'pre_node',      -- Before workflow node execution
        'post_node',     -- After workflow node execution
        'pre_run',       -- Before run starts
        'post_run',      -- After run completes
        'on_error',      -- On error
        'on_interrupt'   -- When interrupt is triggered
    )),
    
    -- Hook implementation
    function_name regproc NOT NULL,
    
    -- Configuration
    priority int DEFAULT 0,                          -- Higher = executed first
    enabled bool DEFAULT true,
    
    -- Filtering
    skill_filter text[],                             -- Only apply to these skills
    node_filter text[],                              -- Only apply to these nodes
    graph_filter uuid[],                             -- Only apply to these graphs
    
    -- Metadata
    name text,
    description text,
    config jsonb DEFAULT '{}'::jsonb,
    
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid REFERENCES aos_auth.principal(principal_id)
);

CREATE INDEX idx_policy_hooks_type ON aos_policy.hooks(hook_type);
CREATE INDEX idx_policy_hooks_tenant ON aos_policy.hooks(tenant_id);
CREATE INDEX idx_policy_hooks_enabled ON aos_policy.hooks(enabled) WHERE enabled = true;
CREATE INDEX idx_policy_hooks_priority ON aos_policy.hooks(hook_type, priority DESC);

-- ----------------------------------------------------------------------------
-- Table: policy_rule
-- Purpose: Declarative policy rules
-- ----------------------------------------------------------------------------
CREATE TABLE aos_policy.policy_rule (
    rule_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Rule definition
    name text NOT NULL,
    description text,
    rule_type text NOT NULL CHECK (rule_type IN (
        'allow',    -- Explicitly allow
        'deny',     -- Explicitly deny
        'require',  -- Require condition
        'transform' -- Transform data
    )),
    
    -- Scope
    scope text NOT NULL CHECK (scope IN (
        'skill',
        'egress',
        'node',
        'run',
        'persona'
    )),
    
    -- Condition (SQL expression that returns bool)
    condition_expression text,
    
    -- Action
    action_type text DEFAULT 'block' CHECK (action_type IN (
        'block',     -- Block the operation
        'allow',     -- Allow the operation
        'log',       -- Log only
        'transform', -- Transform the data
        'escalate'   -- Escalate for approval
    )),
    action_config jsonb DEFAULT '{}'::jsonb,
    
    -- Metadata
    priority int DEFAULT 0,
    enabled bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_policy_rule_tenant ON aos_policy.policy_rule(tenant_id);
CREATE INDEX idx_policy_rule_scope ON aos_policy.policy_rule(scope);
CREATE INDEX idx_policy_rule_enabled ON aos_policy.policy_rule(enabled) WHERE enabled = true;

-- ----------------------------------------------------------------------------
-- Function: get_hooks
-- Purpose: Get applicable hooks for a given context
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_policy.get_hooks(
    p_hook_type text,
    p_tenant_id uuid DEFAULT NULL,
    p_skill_key text DEFAULT NULL,
    p_node_name text DEFAULT NULL,
    p_graph_id uuid DEFAULT NULL
)
RETURNS TABLE (
    hook_id uuid,
    function_name regproc,
    config jsonb,
    priority int
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_tenant_id uuid;
BEGIN
    v_tenant_id := COALESCE(p_tenant_id, aos_auth.current_tenant());
    
    RETURN QUERY
    SELECT 
        h.hook_id,
        h.function_name,
        h.config,
        h.priority
    FROM aos_policy.hooks h
    WHERE h.hook_type = p_hook_type
      AND h.enabled = true
      AND (h.tenant_id IS NULL OR h.tenant_id = v_tenant_id)
      AND (h.skill_filter IS NULL OR p_skill_key = ANY(h.skill_filter))
      AND (h.node_filter IS NULL OR p_node_name = ANY(h.node_filter))
      AND (h.graph_filter IS NULL OR p_graph_id = ANY(h.graph_filter))
    ORDER BY h.priority DESC;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: execute_hooks
-- Purpose: Execute all applicable hooks
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_policy.execute_hooks(
    p_hook_type text,
    p_context jsonb,
    p_tenant_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_hook record;
    v_result jsonb := p_context;
    v_hook_result jsonb;
BEGIN
    FOR v_hook IN
        SELECT * FROM aos_policy.get_hooks(p_hook_type, p_tenant_id)
    LOOP
        -- Execute each hook function
        -- Hook functions should accept (context jsonb) and return jsonb
        EXECUTE format('SELECT %s($1)', v_hook.function_name)
        INTO v_hook_result
        USING v_result;
        
        -- Merge result
        IF v_hook_result IS NOT NULL THEN
            v_result := v_result || v_hook_result;
        END IF;
        
        -- Check for abort signal
        IF (v_result->>'_abort')::bool = true THEN
            EXIT;
        END IF;
    END LOOP;
    
    RETURN v_result;
END;
$$;

COMMENT ON SCHEMA aos_policy IS 'pgAgentOS: Policy hooks and rules';
COMMENT ON TABLE aos_policy.hooks IS 'Policy hook registry';
COMMENT ON TABLE aos_policy.policy_rule IS 'Declarative policy rules';
