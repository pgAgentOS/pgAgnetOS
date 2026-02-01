-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_skills (Skill Registry)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_skills;

-- ----------------------------------------------------------------------------
-- Table: skill
-- Purpose: Skill definitions (capabilities that agents can use)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_skills.skill (
    skill_key text PRIMARY KEY,                      -- e.g., 'web_search', 'code_execute'
    name text NOT NULL,
    description text,
    category text,                                    -- e.g., 'retrieval', 'generation', 'tool'
    input_schema jsonb,                              -- JSON Schema for input validation
    output_schema jsonb,                             -- JSON Schema for output validation
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz
);

CREATE INDEX idx_skill_category ON aos_skills.skill(category);
CREATE INDEX idx_skill_active ON aos_skills.skill(is_active) WHERE is_active = true;

-- ----------------------------------------------------------------------------
-- Table: skill_impl
-- Purpose: Skill implementation details (how to execute)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_skills.skill_impl (
    skill_key text NOT NULL REFERENCES aos_skills.skill(skill_key) ON DELETE CASCADE,
    version text NOT NULL DEFAULT '1.0',
    impl_type text NOT NULL CHECK (impl_type IN ('function', 'http', 'plpgsql', 'external', 'llm')),
    impl_ref text NOT NULL,                          -- Function name, URL, or external identifier
    
    -- HTTP-specific config
    http_method text DEFAULT 'POST',
    http_headers jsonb DEFAULT '{}'::jsonb,
    http_timeout_ms int DEFAULT 30000,
    
    -- Retry config
    retry_count int DEFAULT 3,
    retry_delay_ms int DEFAULT 1000,
    
    -- LLM-specific config (for impl_type='llm')
    model_id uuid REFERENCES aos_meta.llm_model_registry(model_id),
    prompt_template text,
    
    enabled bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    
    PRIMARY KEY (skill_key, version)
);

CREATE INDEX idx_skill_impl_type ON aos_skills.skill_impl(impl_type);
CREATE INDEX idx_skill_impl_enabled ON aos_skills.skill_impl(enabled) WHERE enabled = true;

-- ----------------------------------------------------------------------------
-- Table: role_skill
-- Purpose: Role-based skill permissions
-- ----------------------------------------------------------------------------
CREATE TABLE aos_skills.role_skill (
    role_key text NOT NULL,                          -- e.g., 'admin', 'developer', 'agent'
    skill_key text NOT NULL REFERENCES aos_skills.skill(skill_key) ON DELETE CASCADE,
    allowed_params jsonb DEFAULT '{}'::jsonb,        -- Parameter restrictions
    denied_params jsonb DEFAULT '{}'::jsonb,         -- Explicitly denied parameters
    priority int DEFAULT 0,                          -- Higher = evaluated first
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    
    PRIMARY KEY (role_key, skill_key)
);

CREATE INDEX idx_role_skill_role ON aos_skills.role_skill(role_key);
CREATE INDEX idx_role_skill_priority ON aos_skills.role_skill(priority DESC);

-- ----------------------------------------------------------------------------
-- Insert default skills
-- ----------------------------------------------------------------------------
INSERT INTO aos_skills.skill (skill_key, name, description, category) VALUES
('llm_chat', 'LLM Chat', 'Send a chat completion request to an LLM', 'generation'),
('llm_embed', 'LLM Embed', 'Generate embeddings for text', 'embedding'),
('rag_retrieve', 'RAG Retrieve', 'Retrieve relevant documents using hybrid search', 'retrieval'),
('web_search', 'Web Search', 'Search the web for information', 'retrieval'),
('code_execute', 'Code Execute', 'Execute code in a sandboxed environment', 'tool'),
('http_request', 'HTTP Request', 'Make an HTTP request to an external API', 'tool'),
('file_read', 'File Read', 'Read contents of a file', 'tool'),
('file_write', 'File Write', 'Write contents to a file', 'tool'),
('memory_store', 'Memory Store', 'Store information in session memory', 'memory'),
('memory_recall', 'Memory Recall', 'Recall information from session memory', 'memory');

-- Default implementations
INSERT INTO aos_skills.skill_impl (skill_key, version, impl_type, impl_ref) VALUES
('llm_chat', '1.0', 'llm', 'aos_skills.execute_llm_chat'),
('llm_embed', '1.0', 'llm', 'aos_skills.execute_llm_embed'),
('rag_retrieve', '1.0', 'plpgsql', 'aos_kg.retrieve'),
('memory_store', '1.0', 'plpgsql', 'aos_core.store_memory'),
('memory_recall', '1.0', 'plpgsql', 'aos_core.recall_memory');

-- Default role permissions
INSERT INTO aos_skills.role_skill (role_key, skill_key, priority) VALUES
('admin', 'llm_chat', 100),
('admin', 'llm_embed', 100),
('admin', 'rag_retrieve', 100),
('admin', 'web_search', 100),
('admin', 'code_execute', 100),
('admin', 'http_request', 100),
('admin', 'file_read', 100),
('admin', 'file_write', 100),
('admin', 'memory_store', 100),
('admin', 'memory_recall', 100),
('developer', 'llm_chat', 50),
('developer', 'llm_embed', 50),
('developer', 'rag_retrieve', 50),
('developer', 'code_execute', 50),
('developer', 'memory_store', 50),
('developer', 'memory_recall', 50),
('agent', 'llm_chat', 10),
('agent', 'llm_embed', 10),
('agent', 'rag_retrieve', 10),
('agent', 'memory_store', 10),
('agent', 'memory_recall', 10);

-- ----------------------------------------------------------------------------
-- Function: can_use_skill
-- Purpose: Check if a principal can use a skill
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_skills.can_use_skill(
    p_principal_id uuid,
    p_skill_key text
)
RETURNS bool
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_can_use bool := false;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM aos_auth.role_grant rg
        JOIN aos_skills.role_skill rs ON rs.role_key = rg.role_key
        WHERE rg.principal_id = p_principal_id
          AND rg.is_active = true
          AND (rg.expires_at IS NULL OR rg.expires_at > now())
          AND rs.skill_key = p_skill_key
          AND rs.is_active = true
    ) INTO v_can_use;
    
    RETURN v_can_use;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_skill_impl
-- Purpose: Get the implementation details for a skill
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_skills.get_skill_impl(
    p_skill_key text,
    p_version text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'skill_key', s.skill_key,
        'name', s.name,
        'category', s.category,
        'impl_type', si.impl_type,
        'impl_ref', si.impl_ref,
        'version', si.version,
        'config', jsonb_build_object(
            'http_method', si.http_method,
            'http_headers', si.http_headers,
            'http_timeout_ms', si.http_timeout_ms,
            'retry_count', si.retry_count,
            'retry_delay_ms', si.retry_delay_ms,
            'model_id', si.model_id,
            'prompt_template', si.prompt_template
        )
    ) INTO v_result
    FROM aos_skills.skill s
    JOIN aos_skills.skill_impl si ON si.skill_key = s.skill_key
    WHERE s.skill_key = p_skill_key
      AND s.is_active = true
      AND si.enabled = true
      AND (p_version IS NULL OR si.version = p_version)
    ORDER BY si.version DESC
    LIMIT 1;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Skill implementation not found: %', p_skill_key;
    END IF;
    
    RETURN v_result;
END;
$$;

COMMENT ON SCHEMA aos_skills IS 'pgAgentOS: Skill registry and permissions';
COMMENT ON TABLE aos_skills.skill IS 'Available agent skills/capabilities';
COMMENT ON TABLE aos_skills.skill_impl IS 'Skill implementation details';
COMMENT ON TABLE aos_skills.role_skill IS 'Role-based skill permissions';
