-- ============================================================================
-- pgAgentOS: Persona Schema
-- Purpose: Agent identity and behavior configuration
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_persona;

-- ----------------------------------------------------------------------------
-- Table: persona
-- Purpose: Agent persona definition
-- ----------------------------------------------------------------------------
CREATE TABLE aos_persona.persona (
    persona_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Identity
    name text NOT NULL,
    description text,
    
    -- Current version pointer
    current_version_id uuid,
    
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    
    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_persona_tenant ON aos_persona.persona(tenant_id);

-- ----------------------------------------------------------------------------
-- Table: version
-- Purpose: Immutable persona configuration snapshot
-- ----------------------------------------------------------------------------
CREATE TABLE aos_persona.version (
    version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    persona_id uuid NOT NULL REFERENCES aos_persona.persona(persona_id) ON DELETE CASCADE,
    
    version_num int NOT NULL,
    
    -- Configuration
    system_prompt text NOT NULL,
    model_id uuid REFERENCES aos_core.model(model_id),
    params jsonb DEFAULT '{}'::jsonb,              -- Override model defaults
    
    -- Metadata
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid,
    
    UNIQUE (persona_id, version_num)
);

CREATE INDEX idx_version_persona ON aos_persona.version(persona_id);

-- Add FK back
ALTER TABLE aos_persona.persona
ADD CONSTRAINT fk_persona_current_version
FOREIGN KEY (current_version_id) REFERENCES aos_persona.version(version_id);

-- ----------------------------------------------------------------------------
-- Function: create_persona
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_persona.create_persona(
    p_tenant_id uuid,
    p_name text,
    p_system_prompt text,
    p_model_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_persona_id uuid;
    v_version_id uuid;
BEGIN
    INSERT INTO aos_persona.persona (tenant_id, name)
    VALUES (p_tenant_id, p_name)
    RETURNING persona_id INTO v_persona_id;
    
    INSERT INTO aos_persona.version (persona_id, version_num, system_prompt, model_id)
    VALUES (v_persona_id, 1, p_system_prompt, p_model_id)
    RETURNING version_id INTO v_version_id;
    
    UPDATE aos_persona.persona 
    SET current_version_id = v_version_id 
    WHERE persona_id = v_persona_id;
    
    RETURN v_persona_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_effective_params
-- Purpose: Merge model defaults with persona overrides
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_persona.get_effective_params(p_version_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_model_params jsonb;
    v_override_params jsonb;
BEGIN
    SELECT 
        COALESCE(m.default_params, '{}'::jsonb),
        COALESCE(v.params, '{}'::jsonb)
    INTO v_model_params, v_override_params
    FROM aos_persona.version v
    LEFT JOIN aos_core.model m ON m.model_id = v.model_id
    WHERE v.version_id = p_version_id;
    
    RETURN v_model_params || v_override_params;
END;
$$;

COMMENT ON SCHEMA aos_persona IS 'pgAgentOS: Agent persona definitions';
COMMENT ON TABLE aos_persona.persona IS 'Persona identity';
COMMENT ON TABLE aos_persona.version IS 'Immutable configuration snapshots';
