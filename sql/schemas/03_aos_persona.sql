-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_persona (Agent Personas)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_persona;

-- ----------------------------------------------------------------------------
-- Table: persona
-- Purpose: AI agent persona definitions with LLM defaults
-- ----------------------------------------------------------------------------
CREATE TABLE aos_persona.persona (
    persona_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    principal_id uuid REFERENCES aos_auth.principal(principal_id) ON DELETE SET NULL,
    
    -- Identity
    name text NOT NULL,
    display_name text,
    description text,
    
    -- System prompt and behavior
    system_prompt text NOT NULL,
    traits jsonb DEFAULT '{}'::jsonb,                -- e.g., {"helpful": true, "verbose": false}
    rules jsonb[] DEFAULT ARRAY[]::jsonb[],          -- e.g., [{"rule": "always confirm before action"}]
    
    -- Model selection (FK to registry)
    model_id uuid REFERENCES aos_meta.llm_model_registry(model_id),
    
    -- Override params (merged with model defaults at runtime)
    override_params jsonb DEFAULT '{}'::jsonb,       -- e.g., {"temperature": 0.3} for coding tasks
    
    -- Limits
    max_tokens_per_request int,
    max_requests_per_minute int,
    
    -- Metadata
    version text DEFAULT '1.0',
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    
    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_persona_tenant ON aos_persona.persona(tenant_id);
CREATE INDEX idx_persona_principal ON aos_persona.persona(principal_id);
CREATE INDEX idx_persona_model ON aos_persona.persona(model_id);
CREATE INDEX idx_persona_active ON aos_persona.persona(is_active) WHERE is_active = true;
CREATE INDEX idx_persona_traits ON aos_persona.persona USING GIN (traits);

-- ----------------------------------------------------------------------------
-- Function: get_effective_params
-- Purpose: Merge model defaults with persona overrides
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_persona.get_effective_params(p_persona_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_model_defaults jsonb;
    v_persona_overrides jsonb;
    v_result jsonb;
BEGIN
    SELECT 
        COALESCE(m.default_params, '{}'::jsonb),
        COALESCE(p.override_params, '{}'::jsonb)
    INTO v_model_defaults, v_persona_overrides
    FROM aos_persona.persona p
    LEFT JOIN aos_meta.llm_model_registry m ON m.model_id = p.model_id
    WHERE p.persona_id = p_persona_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Persona not found: %', p_persona_id;
    END IF;
    
    -- Merge: persona overrides take precedence
    v_result := v_model_defaults || v_persona_overrides;
    
    RETURN v_result;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_persona_config
-- Purpose: Get full persona configuration including model info
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_persona.get_persona_config(p_persona_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'persona_id', p.persona_id,
        'name', p.name,
        'system_prompt', p.system_prompt,
        'traits', p.traits,
        'rules', p.rules,
        'model', jsonb_build_object(
            'provider', m.provider,
            'model_name', m.model_name,
            'context_window', m.context_window,
            'endpoint', m.endpoint_template
        ),
        'effective_params', aos_persona.get_effective_params(p.persona_id),
        'limits', jsonb_build_object(
            'max_tokens_per_request', p.max_tokens_per_request,
            'max_requests_per_minute', p.max_requests_per_minute
        )
    ) INTO v_result
    FROM aos_persona.persona p
    LEFT JOIN aos_meta.llm_model_registry m ON m.model_id = p.model_id
    WHERE p.persona_id = p_persona_id AND p.is_active = true;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Persona not found or inactive: %', p_persona_id;
    END IF;
    
    RETURN v_result;
END;
$$;

COMMENT ON SCHEMA aos_persona IS 'pgAgentOS: AI agent persona definitions';
COMMENT ON TABLE aos_persona.persona IS 'Agent personas with system prompts and LLM configurations';
COMMENT ON FUNCTION aos_persona.get_effective_params IS 'Merge model defaults with persona overrides';
COMMENT ON FUNCTION aos_persona.get_persona_config IS 'Get full persona configuration for runtime use';
