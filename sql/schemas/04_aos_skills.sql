-- ============================================================================
-- pgAgentOS: Skills Schema
-- Purpose: Tool/capability registry
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_skills;

-- ----------------------------------------------------------------------------
-- Table: skill
-- Purpose: Tool definition
-- ----------------------------------------------------------------------------
CREATE TABLE aos_skills.skill (
    skill_key text PRIMARY KEY,
    name text NOT NULL,
    description text,
    category text,                                   -- 'retrieval', 'generation', 'tool'
    
    -- Schema (JSON Schema format)
    input_schema jsonb,
    output_schema jsonb,
    
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_skill_category ON aos_skills.skill(category);
CREATE INDEX idx_skill_active ON aos_skills.skill(is_active) WHERE is_active = true;

-- ----------------------------------------------------------------------------
-- Table: impl
-- Purpose: Skill implementation
-- ----------------------------------------------------------------------------
CREATE TABLE aos_skills.impl (
    skill_key text NOT NULL REFERENCES aos_skills.skill(skill_key) ON DELETE CASCADE,
    version text NOT NULL DEFAULT '1.0',
    
    impl_type text NOT NULL CHECK (impl_type IN ('function', 'http', 'plpgsql')),
    impl_ref text NOT NULL,                          -- Function name or URL
    
    -- Config
    config jsonb DEFAULT '{}'::jsonb,
    
    enabled bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    
    PRIMARY KEY (skill_key, version)
);

CREATE INDEX idx_impl_enabled ON aos_skills.impl(enabled) WHERE enabled = true;

-- ----------------------------------------------------------------------------
-- Function: get_skill
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_skills.get_skill(p_skill_key text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'skill_key', s.skill_key,
        'name', s.name,
        'description', s.description,
        'input_schema', s.input_schema,
        'impl_type', i.impl_type,
        'impl_ref', i.impl_ref,
        'config', i.config
    ) INTO v_result
    FROM aos_skills.skill s
    LEFT JOIN aos_skills.impl i ON i.skill_key = s.skill_key AND i.enabled
    WHERE s.skill_key = p_skill_key AND s.is_active;
    
    RETURN v_result;
END;
$$;

-- ----------------------------------------------------------------------------
-- Default skills
-- ----------------------------------------------------------------------------
INSERT INTO aos_skills.skill (skill_key, name, description, category) VALUES
('llm_chat', 'LLM Chat', 'Send chat completion request', 'generation'),
('rag_search', 'RAG Search', 'Search documents with hybrid retrieval', 'retrieval'),
('memory_store', 'Memory Store', 'Store in session memory', 'memory'),
('memory_recall', 'Memory Recall', 'Recall from session memory', 'memory');

INSERT INTO aos_skills.impl (skill_key, impl_type, impl_ref) VALUES
('llm_chat', 'function', 'external'),
('rag_search', 'plpgsql', 'aos_rag.search'),
('memory_store', 'plpgsql', 'aos_agent.store_memory'),
('memory_recall', 'plpgsql', 'aos_agent.recall_memory');

COMMENT ON SCHEMA aos_skills IS 'pgAgentOS: Tool registry';
COMMENT ON TABLE aos_skills.skill IS 'Tool definitions';
COMMENT ON TABLE aos_skills.impl IS 'Tool implementations';
