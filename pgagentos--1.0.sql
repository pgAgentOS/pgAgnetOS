-- pgAgentOS v1.0 - AI Agent Operating System for PostgreSQL
-- Generated on Mon Feb  2 15:12:26 UTC 2026

-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: Extensions & Dependencies
-- ============================================================================

-- Required extensions are declared in pgagentos.control (vector/pgcrypto).

-- Verify minimum PostgreSQL version
DO $$
BEGIN
    IF current_setting('server_version_num')::int < 140000 THEN
        RAISE EXCEPTION 'pgAgentOS requires PostgreSQL 14 or higher';
    END IF;
END $$;
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_meta (Metadata & Versioning)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_meta;

-- ----------------------------------------------------------------------------
-- Table: installed_version (Singleton)
-- Purpose: Track extension installation and version info
-- ----------------------------------------------------------------------------
CREATE TABLE aos_meta.installed_version (
    version text PRIMARY KEY,
    installed_at timestamptz NOT NULL DEFAULT now(),
    pg_version text NOT NULL DEFAULT current_setting('server_version'),
    pgvector_version text NOT NULL,
    schema_version text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb
);

-- Ensure singleton
CREATE UNIQUE INDEX idx_installed_version_singleton 
    ON aos_meta.installed_version ((true));

-- ----------------------------------------------------------------------------
-- Table: llm_model_registry
-- Purpose: LLM model driver specs and presets (System Defaults)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_meta.llm_model_registry (
    model_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider text NOT NULL,                          -- e.g., 'openai', 'anthropic', 'ollama'
    model_name text NOT NULL,                        -- e.g., 'gpt-4o', 'claude-3-5-sonnet'
    display_name text,                               -- Human-readable name
    context_window int NOT NULL DEFAULT 8192,        -- Max context tokens
    max_output_tokens int DEFAULT 4096,              -- Max output tokens
    supports_vision bool DEFAULT false,
    supports_function_calling bool DEFAULT true,
    supports_streaming bool DEFAULT true,
    default_params jsonb NOT NULL DEFAULT '{
        "temperature": 0.7,
        "top_p": 0.9,
        "frequency_penalty": 0,
        "presence_penalty": 0
    }'::jsonb,
    endpoint_template text,                          -- e.g., 'https://api.openai.com/v1/chat/completions'
    api_key_env_var text,                            -- e.g., 'OPENAI_API_KEY'
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    notes text,
    UNIQUE (provider, model_name)
);

-- Index for common lookups
CREATE INDEX idx_llm_model_registry_provider ON aos_meta.llm_model_registry(provider);
CREATE INDEX idx_llm_model_registry_active ON aos_meta.llm_model_registry(is_active) WHERE is_active = true;

-- ----------------------------------------------------------------------------
-- Insert default model presets
-- ----------------------------------------------------------------------------
INSERT INTO aos_meta.llm_model_registry (provider, model_name, display_name, context_window, max_output_tokens, supports_vision, default_params, endpoint_template, api_key_env_var) VALUES
-- OpenAI Models
('openai', 'gpt-4o', 'GPT-4o', 128000, 16384, true, 
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY'),
('openai', 'gpt-4o-mini', 'GPT-4o Mini', 128000, 16384, true,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY'),
('openai', 'o1', 'o1', 200000, 100000, true,
 '{"temperature": 1.0}'::jsonb,
 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY'),
('openai', 'o3-mini', 'o3-mini', 200000, 100000, false,
 '{"temperature": 1.0}'::jsonb,
 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY'),

-- Anthropic Models
('anthropic', 'claude-3-5-sonnet-20241022', 'Claude 3.5 Sonnet', 200000, 8192, true,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'https://api.anthropic.com/v1/messages', 'ANTHROPIC_API_KEY'),
('anthropic', 'claude-3-5-haiku-20241022', 'Claude 3.5 Haiku', 200000, 8192, true,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'https://api.anthropic.com/v1/messages', 'ANTHROPIC_API_KEY'),

-- Google Models
('google', 'gemini-2.0-flash', 'Gemini 2.0 Flash', 1048576, 8192, true,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'https://generativelanguage.googleapis.com/v1beta/models', 'GOOGLE_API_KEY'),
('google', 'gemini-2.0-flash-thinking-exp', 'Gemini 2.0 Flash Thinking', 1048576, 8192, true,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'https://generativelanguage.googleapis.com/v1beta/models', 'GOOGLE_API_KEY'),

-- Ollama (Local)
('ollama', 'llama3.3:70b', 'Llama 3.3 70B', 128000, 4096, false,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'http://localhost:11434/api/chat', NULL),
('ollama', 'qwen2.5:32b', 'Qwen 2.5 32B', 131072, 8192, false,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'http://localhost:11434/api/chat', NULL),
('ollama', 'deepseek-r1:32b', 'DeepSeek R1 32B', 131072, 8192, false,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'http://localhost:11434/api/chat', NULL);

-- Insert version info
INSERT INTO aos_meta.installed_version (version, pgvector_version, schema_version)
SELECT '1.0', extversion, '1.0'
FROM pg_extension WHERE extname = 'vector';

COMMENT ON SCHEMA aos_meta IS 'pgAgentOS: System metadata and versioning';
COMMENT ON TABLE aos_meta.installed_version IS 'Extension installation info (singleton)';
COMMENT ON TABLE aos_meta.llm_model_registry IS 'LLM model driver specs and default parameters';
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_auth (Authentication & Authorization)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_auth;

-- ----------------------------------------------------------------------------
-- Table: tenant
-- Purpose: Multi-tenancy isolation unit
-- ----------------------------------------------------------------------------
CREATE TABLE aos_auth.tenant (
    tenant_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL UNIQUE,
    display_name text,
    is_active bool DEFAULT true,
    settings jsonb DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz
);

CREATE INDEX idx_tenant_active ON aos_auth.tenant(is_active) WHERE is_active = true;

-- ----------------------------------------------------------------------------
-- Table: principal
-- Purpose: User/Agent principal entity
-- ----------------------------------------------------------------------------
CREATE TABLE aos_auth.principal (
    principal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    principal_type text NOT NULL DEFAULT 'user' CHECK (principal_type IN ('user', 'agent', 'service')),
    db_role_name text UNIQUE,                        -- PostgreSQL role name for RLS
    display_name text,
    email text,
    is_active bool DEFAULT true,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz
);

CREATE INDEX idx_principal_tenant ON aos_auth.principal(tenant_id);
CREATE INDEX idx_principal_type ON aos_auth.principal(principal_type);
CREATE INDEX idx_principal_db_role ON aos_auth.principal(db_role_name) WHERE db_role_name IS NOT NULL;

-- ----------------------------------------------------------------------------
-- Table: role_grant
-- Purpose: Role assignment to principals (admin, developer, auditor)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_auth.role_grant (
    grant_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    principal_id uuid NOT NULL REFERENCES aos_auth.principal(principal_id) ON DELETE CASCADE,
    role_key text NOT NULL CHECK (role_key IN ('admin', 'developer', 'auditor', 'agent', 'viewer')),
    granted_at timestamptz NOT NULL DEFAULT now(),
    granted_by uuid REFERENCES aos_auth.principal(principal_id),
    expires_at timestamptz,                          -- NULL means never expires
    is_active bool DEFAULT true,
    metadata jsonb DEFAULT '{}'::jsonb,
    UNIQUE (principal_id, role_key)
);

CREATE INDEX idx_role_grant_principal ON aos_auth.role_grant(principal_id);
CREATE INDEX idx_role_grant_role ON aos_auth.role_grant(role_key);
CREATE INDEX idx_role_grant_active ON aos_auth.role_grant(is_active, expires_at);

-- ----------------------------------------------------------------------------
-- Function: set_tenant
-- Purpose: Set current tenant context for RLS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.set_tenant(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Verify tenant exists and is active
    IF NOT EXISTS (
        SELECT 1 FROM aos_auth.tenant 
        WHERE tenant_id = p_tenant_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
    END IF;
    
    PERFORM set_config('aos.tenant_id', p_tenant_id::text, false);
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: current_tenant
-- Purpose: Get current tenant ID from session
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.current_tenant()
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_tenant_id text;
BEGIN
    v_tenant_id := current_setting('aos.tenant_id', true);
    IF v_tenant_id IS NULL OR v_tenant_id = '' THEN
        RETURN NULL;
    END IF;
    RETURN v_tenant_id::uuid;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: current_principal
-- Purpose: Get current principal ID from session
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.current_principal()
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_principal_id text;
BEGIN
    v_principal_id := current_setting('aos.principal_id', true);
    IF v_principal_id IS NULL OR v_principal_id = '' THEN
        RETURN NULL;
    END IF;
    RETURN v_principal_id::uuid;
END;
$$;

COMMENT ON SCHEMA aos_auth IS 'pgAgentOS: Authentication and authorization';
COMMENT ON TABLE aos_auth.tenant IS 'Multi-tenancy isolation units';
COMMENT ON TABLE aos_auth.principal IS 'Users, agents, and service principals';
COMMENT ON TABLE aos_auth.role_grant IS 'Role assignments to principals';
COMMENT ON FUNCTION aos_auth.set_tenant IS 'Set current tenant context for RLS';
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
    risk_level text DEFAULT 'low',                   -- e.g., 'low', 'medium', 'high', 'critical'
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
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_egress (External API Control)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_egress;

-- ----------------------------------------------------------------------------
-- Table: request
-- Purpose: External API request queue with approval flow
-- ----------------------------------------------------------------------------
CREATE TABLE aos_egress.request (
    request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id uuid REFERENCES aos_core.run(run_id) ON DELETE CASCADE,
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Target
    target_type text NOT NULL CHECK (target_type IN ('api', 'db', 'file', 'webhook', 'email')),
    target text NOT NULL,                            -- URL, connection string, file path, etc.
    method text DEFAULT 'POST',                      -- HTTP method
    
    -- Request data
    headers jsonb DEFAULT '{}'::jsonb,
    payload jsonb NOT NULL,
    
    -- Risk assessment
    risk_level text DEFAULT 'low' CHECK (risk_level IN ('low', 'medium', 'high', 'critical')),
    risk_factors jsonb DEFAULT '[]'::jsonb,
    
    -- Approval flow
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'executed', 'rejected', 'failed', 'timeout')),
    requires_approval bool DEFAULT false,
    approval_notes text,
    approved_by uuid REFERENCES aos_auth.principal(principal_id),
    
    -- Response
    response_status int,
    response_headers jsonb,
    response_body jsonb,
    error_message text,
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    approved_at timestamptz,
    executed_at timestamptz,
    duration_ms bigint
);

CREATE INDEX idx_egress_request_run ON aos_egress.request(run_id);
CREATE INDEX idx_egress_request_tenant ON aos_egress.request(tenant_id);
CREATE INDEX idx_egress_request_status ON aos_egress.request(status);
CREATE INDEX idx_egress_request_pending ON aos_egress.request(status, created_at) 
    WHERE status = 'pending';

-- ----------------------------------------------------------------------------
-- Table: allowlist
-- Purpose: Pre-approved external endpoints
-- ----------------------------------------------------------------------------
CREATE TABLE aos_egress.allowlist (
    allowlist_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Pattern matching
    target_pattern text NOT NULL,                    -- Regex pattern for URL/endpoint
    target_type text NOT NULL CHECK (target_type IN ('api', 'db', 'file', 'webhook', 'email')),
    
    -- Permissions
    allowed_methods text[] DEFAULT ARRAY['GET', 'POST']::text[],
    max_payload_bytes int DEFAULT 1048576,           -- 1MB default
    rate_limit_per_minute int DEFAULT 60,
    
    -- Metadata
    description text,
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid REFERENCES aos_auth.principal(principal_id)
);

CREATE INDEX idx_egress_allowlist_tenant ON aos_egress.allowlist(tenant_id);
CREATE INDEX idx_egress_allowlist_active ON aos_egress.allowlist(is_active) WHERE is_active = true;

-- ----------------------------------------------------------------------------
-- Function: check_allowlist
-- Purpose: Check if a request is pre-approved
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_egress.check_allowlist(
    p_tenant_id uuid,
    p_target_type text,
    p_target text,
    p_method text DEFAULT 'POST'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_match aos_egress.allowlist;
BEGIN
    SELECT * INTO v_match
    FROM aos_egress.allowlist
    WHERE tenant_id = p_tenant_id
      AND target_type = p_target_type
      AND is_active = true
      AND p_target ~ target_pattern
      AND p_method = ANY(allowed_methods)
    LIMIT 1;
    
    IF FOUND THEN
        RETURN jsonb_build_object(
            'allowed', true,
            'allowlist_id', v_match.allowlist_id,
            'rate_limit_per_minute', v_match.rate_limit_per_minute,
            'max_payload_bytes', v_match.max_payload_bytes
        );
    ELSE
        RETURN jsonb_build_object('allowed', false);
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: create_egress_request
-- Purpose: Create an egress request with automatic approval check
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_egress.create_egress_request(
    p_run_id uuid,
    p_target_type text,
    p_target text,
    p_payload jsonb,
    p_method text DEFAULT 'POST',
    p_headers jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_tenant_id uuid;
    v_request_id uuid;
    v_allowlist_check jsonb;
    v_requires_approval bool := true;
    v_status text := 'pending';
BEGIN
    -- Get tenant from run
    SELECT tenant_id INTO v_tenant_id
    FROM aos_core.run
    WHERE run_id = p_run_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Run not found: %', p_run_id;
    END IF;
    
    -- Check allowlist
    v_allowlist_check := aos_egress.check_allowlist(v_tenant_id, p_target_type, p_target, p_method);
    
    IF (v_allowlist_check->>'allowed')::bool THEN
        v_requires_approval := false;
        v_status := 'approved';
    END IF;
    
    -- Create request
    INSERT INTO aos_egress.request (
        run_id, tenant_id, target_type, target, method, headers, payload,
        requires_approval, status
    ) VALUES (
        p_run_id, v_tenant_id, p_target_type, p_target, p_method, p_headers, p_payload,
        v_requires_approval, v_status
    )
    RETURNING request_id INTO v_request_id;
    
    -- Log event
    PERFORM aos_core.log_event(
        p_run_id,
        'egress_request',
        jsonb_build_object(
            'request_id', v_request_id,
            'target', p_target,
            'requires_approval', v_requires_approval
        )
    );
    
    RETURN v_request_id;
END;
$$;

-- Insert default allowlists
INSERT INTO aos_egress.allowlist (tenant_id, target_pattern, target_type, description)
SELECT tenant_id, '^https://api\.openai\.com/', 'api', 'OpenAI API'
FROM aos_auth.tenant LIMIT 0;  -- Template only, no actual insert

COMMENT ON SCHEMA aos_egress IS 'pgAgentOS: External API request control';
COMMENT ON TABLE aos_egress.request IS 'External API request queue with approval flow';
COMMENT ON TABLE aos_egress.allowlist IS 'Pre-approved external endpoints';
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_kg (Knowledge Graph / Document Store)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_kg;

-- ----------------------------------------------------------------------------
-- Table: doc
-- Purpose: Document storage with full-text search support
-- ----------------------------------------------------------------------------
CREATE TABLE aos_kg.doc (
    doc_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    run_id uuid REFERENCES aos_core.run(run_id) ON DELETE SET NULL,
    
    -- Content
    content text NOT NULL,
    content_type text DEFAULT 'text/plain',          -- MIME type
    title text,
    
    -- Metadata
    source text,                                     -- e.g., 'web', 'file', 'api'
    source_url text,
    metadata jsonb DEFAULT '{}'::jsonb,
    
    -- Full-text search
    tsvector tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', content), 'B')
    ) STORED,
    
    -- Chunking info
    parent_doc_id uuid REFERENCES aos_kg.doc(doc_id) ON DELETE CASCADE,
    chunk_index int,
    chunk_start int,
    chunk_end int,
    
    -- Versioning
    version int DEFAULT 1,
    is_latest bool DEFAULT true,
    
    -- Timestamps
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    expires_at timestamptz
);

CREATE INDEX idx_kg_doc_tenant ON aos_kg.doc(tenant_id);
CREATE INDEX idx_kg_doc_run ON aos_kg.doc(run_id) WHERE run_id IS NOT NULL;
CREATE INDEX idx_kg_doc_tsvector ON aos_kg.doc USING GIN(tsvector);
CREATE INDEX idx_kg_doc_source ON aos_kg.doc(source);
CREATE INDEX idx_kg_doc_parent ON aos_kg.doc(parent_doc_id) WHERE parent_doc_id IS NOT NULL;
CREATE INDEX idx_kg_doc_metadata ON aos_kg.doc USING GIN(metadata);

-- ----------------------------------------------------------------------------
-- Table: doc_relationship
-- Purpose: Relationships between documents (knowledge graph edges)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_kg.doc_relationship (
    relationship_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    from_doc_id uuid NOT NULL REFERENCES aos_kg.doc(doc_id) ON DELETE CASCADE,
    to_doc_id uuid NOT NULL REFERENCES aos_kg.doc(doc_id) ON DELETE CASCADE,
    
    relationship_type text NOT NULL,                 -- e.g., 'references', 'similar_to', 'part_of'
    weight float DEFAULT 1.0,
    metadata jsonb DEFAULT '{}'::jsonb,
    
    created_at timestamptz NOT NULL DEFAULT now(),
    
    UNIQUE (from_doc_id, to_doc_id, relationship_type)
);

CREATE INDEX idx_kg_relationship_from ON aos_kg.doc_relationship(from_doc_id);
CREATE INDEX idx_kg_relationship_to ON aos_kg.doc_relationship(to_doc_id);
CREATE INDEX idx_kg_relationship_type ON aos_kg.doc_relationship(relationship_type);

-- ----------------------------------------------------------------------------
-- Function: search_docs
-- Purpose: Full-text search with ranking
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_kg.search_docs(
    p_query text,
    p_tenant_id uuid DEFAULT NULL,
    p_limit int DEFAULT 10,
    p_source text DEFAULT NULL
)
RETURNS TABLE (
    doc_id uuid,
    title text,
    content text,
    source text,
    rank float,
    headline text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_tsquery tsquery;
    v_tenant_id uuid;
BEGIN
    v_tsquery := websearch_to_tsquery('english', p_query);
    v_tenant_id := COALESCE(p_tenant_id, aos_auth.current_tenant());
    
    RETURN QUERY
    SELECT 
        d.doc_id,
        d.title,
        d.content,
        d.source,
        ts_rank(d.tsvector, v_tsquery)::float as rank,
        ts_headline('english', d.content, v_tsquery, 
            'MaxWords=50, MinWords=20, StartSel=**, StopSel=**') as headline
    FROM aos_kg.doc d
    WHERE d.tsvector @@ v_tsquery
      AND (v_tenant_id IS NULL OR d.tenant_id = v_tenant_id)
      AND (p_source IS NULL OR d.source = p_source)
      AND d.is_latest = true
    ORDER BY rank DESC
    LIMIT p_limit;
END;
$$;

COMMENT ON SCHEMA aos_kg IS 'pgAgentOS: Knowledge graph and document store';
COMMENT ON TABLE aos_kg.doc IS 'Document storage with full-text search';
COMMENT ON TABLE aos_kg.doc_relationship IS 'Knowledge graph edges between documents';
COMMENT ON FUNCTION aos_kg.search_docs IS 'Full-text search with ranking';
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_embed (Embedding Management with pgvector)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_embed;

-- ----------------------------------------------------------------------------
-- Table: job
-- Purpose: Embedding generation job queue
-- ----------------------------------------------------------------------------
CREATE TABLE aos_embed.job (
    job_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    doc_id uuid NOT NULL REFERENCES aos_kg.doc(doc_id) ON DELETE CASCADE,
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    run_id uuid REFERENCES aos_core.run(run_id) ON DELETE SET NULL,
    
    -- Job config
    model_id uuid REFERENCES aos_meta.llm_model_registry(model_id),
    model_name text DEFAULT 'text-embedding-3-small',
    chunk_size int DEFAULT 512,
    chunk_overlap int DEFAULT 50,
    
    -- Status
    status text NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued', 'processing', 'completed', 'failed', 'cancelled')),
    priority int DEFAULT 5 CHECK (priority BETWEEN 1 AND 10),
    attempts int DEFAULT 0,
    max_attempts int DEFAULT 3,
    error_message text,
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz
);

CREATE INDEX idx_embed_job_doc ON aos_embed.job(doc_id);
CREATE INDEX idx_embed_job_tenant ON aos_embed.job(tenant_id);
CREATE INDEX idx_embed_job_status ON aos_embed.job(status);
CREATE INDEX idx_embed_job_queue ON aos_embed.job(status, priority DESC, created_at)
    WHERE status = 'queued';

-- ----------------------------------------------------------------------------
-- Table: embedding_settings
-- Purpose: Control background embedding enqueue behavior
-- ----------------------------------------------------------------------------
CREATE TABLE aos_embed.embedding_settings (
    tenant_id uuid PRIMARY KEY REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    auto_enqueue bool NOT NULL DEFAULT true,
    enqueue_interval interval NOT NULL DEFAULT interval '15 minutes',
    max_queue_size int NOT NULL DEFAULT 1000,
    enabled bool NOT NULL DEFAULT true,
    last_enqueued_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz
);

-- ----------------------------------------------------------------------------
-- Table: embedding
-- Purpose: Vector embeddings with HNSW index
-- ----------------------------------------------------------------------------
CREATE TABLE aos_embed.embedding (
    doc_id uuid NOT NULL REFERENCES aos_kg.doc(doc_id) ON DELETE CASCADE,
    chunk_index int NOT NULL,
    
    -- Vector (1536 for OpenAI ada-002/text-embedding-3-small)
    embedding vector(1536),
    
    -- Metadata
    model_name text NOT NULL,
    chunk_text text,                                 -- Original text of chunk
    chunk_tokens int,
    
    created_at timestamptz NOT NULL DEFAULT now(),
    
    PRIMARY KEY (doc_id, chunk_index)
);

-- HNSW index for fast similarity search
CREATE INDEX idx_embed_embedding_hnsw ON aos_embed.embedding 
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- ----------------------------------------------------------------------------
-- Function: ensure_embedding_settings
-- Purpose: Ensure tenant has embedding settings row
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_embed.ensure_embedding_settings(
    p_tenant_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO aos_embed.embedding_settings (tenant_id)
    VALUES (p_tenant_id)
    ON CONFLICT (tenant_id) DO NOTHING;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: set_embedding_settings
-- Purpose: Update tenant embedding settings
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_embed.set_embedding_settings(
    p_tenant_id uuid,
    p_auto_enqueue bool DEFAULT NULL,
    p_enqueue_interval interval DEFAULT NULL,
    p_max_queue_size int DEFAULT NULL,
    p_enabled bool DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    PERFORM aos_embed.ensure_embedding_settings(p_tenant_id);

    UPDATE aos_embed.embedding_settings
    SET auto_enqueue = COALESCE(p_auto_enqueue, auto_enqueue),
        enqueue_interval = COALESCE(p_enqueue_interval, enqueue_interval),
        max_queue_size = COALESCE(p_max_queue_size, max_queue_size),
        enabled = COALESCE(p_enabled, enabled),
        updated_at = now()
    WHERE tenant_id = p_tenant_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: enqueue_missing_embeddings
-- Purpose: Queue embedding jobs for docs missing embeddings
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_embed.enqueue_missing_embeddings(
    p_tenant_id uuid DEFAULT NULL,
    p_limit int DEFAULT 100,
    p_force bool DEFAULT false
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_tenant_id uuid;
    v_settings aos_embed.embedding_settings%ROWTYPE;
    v_enqueued int := 0;
BEGIN
    v_tenant_id := COALESCE(p_tenant_id, aos_auth.current_tenant());
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Tenant required for embedding enqueue';
    END IF;

    PERFORM aos_embed.ensure_embedding_settings(v_tenant_id);
    SELECT * INTO v_settings
    FROM aos_embed.embedding_settings
    WHERE tenant_id = v_tenant_id;

    IF NOT v_settings.enabled THEN
        RETURN 0;
    END IF;

    IF NOT p_force AND v_settings.auto_enqueue = false THEN
        RETURN 0;
    END IF;

    IF NOT p_force
        AND v_settings.last_enqueued_at IS NOT NULL
        AND v_settings.last_enqueued_at + v_settings.enqueue_interval > now() THEN
        RETURN 0;
    END IF;

    WITH candidates AS (
        SELECT d.doc_id, d.tenant_id, d.run_id
        FROM aos_kg.doc d
        LEFT JOIN aos_embed.embedding e ON e.doc_id = d.doc_id
        LEFT JOIN aos_embed.job j
            ON j.doc_id = d.doc_id
           AND j.status IN ('queued', 'processing')
        WHERE d.tenant_id = v_tenant_id
          AND d.is_latest = true
          AND e.doc_id IS NULL
          AND j.doc_id IS NULL
        ORDER BY d.created_at DESC
        LIMIT p_limit
    ), inserted AS (
        INSERT INTO aos_embed.job (doc_id, tenant_id, run_id)
        SELECT doc_id, tenant_id, run_id
        FROM candidates
        RETURNING 1
    )
    SELECT count(*) INTO v_enqueued FROM inserted;

    UPDATE aos_embed.embedding_settings
    SET last_enqueued_at = now(),
        updated_at = now()
    WHERE tenant_id = v_tenant_id;

    RETURN v_enqueued;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: run_embedding_maintenance
-- Purpose: Scheduler entrypoint to enqueue missing embeddings
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_embed.run_embedding_maintenance(
    p_tenant_id uuid DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN aos_embed.enqueue_missing_embeddings(p_tenant_id, 100, false);
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: similarity_search
-- Purpose: Vector similarity search
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_embed.similarity_search(
    p_query_embedding vector(1536),
    p_tenant_id uuid DEFAULT NULL,
    p_limit int DEFAULT 10,
    p_min_similarity float DEFAULT 0.7
)
RETURNS TABLE (
    doc_id uuid,
    chunk_index int,
    chunk_text text,
    similarity float
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
        e.doc_id,
        e.chunk_index,
        e.chunk_text,
        (1 - (e.embedding <=> p_query_embedding))::float as similarity
    FROM aos_embed.embedding e
    JOIN aos_kg.doc d ON d.doc_id = e.doc_id
    WHERE (v_tenant_id IS NULL OR d.tenant_id = v_tenant_id)
      AND (1 - (e.embedding <=> p_query_embedding)) >= p_min_similarity
    ORDER BY e.embedding <=> p_query_embedding
    LIMIT p_limit;
END;
$$;

COMMENT ON SCHEMA aos_embed IS 'pgAgentOS: Embedding management with pgvector';
COMMENT ON TABLE aos_embed.job IS 'Embedding generation job queue';
COMMENT ON TABLE aos_embed.embedding_settings IS 'Embedding queue settings and controls';
COMMENT ON TABLE aos_embed.embedding IS 'Vector embeddings with HNSW index';
COMMENT ON FUNCTION aos_embed.ensure_embedding_settings IS 'Ensure embedding settings exist for a tenant';
COMMENT ON FUNCTION aos_embed.set_embedding_settings IS 'Update embedding settings for a tenant';
COMMENT ON FUNCTION aos_embed.enqueue_missing_embeddings IS 'Queue embedding jobs for docs missing embeddings';
COMMENT ON FUNCTION aos_embed.run_embedding_maintenance IS 'Scheduler entrypoint to enqueue embeddings';
COMMENT ON FUNCTION aos_embed.similarity_search IS 'Vector similarity search';
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_collab (Collaboration & Task Management)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_collab;

-- ----------------------------------------------------------------------------
-- Table: task
-- Purpose: Task/issue tracking for agent work
-- ----------------------------------------------------------------------------
CREATE TABLE aos_collab.task (
    task_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Task details
    title text NOT NULL,
    description text,
    task_type text DEFAULT 'task' CHECK (task_type IN ('task', 'bug', 'feature', 'research', 'review')),
    
    -- Status
    status text NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'in_progress', 'blocked', 'review', 'done', 'cancelled')),
    priority int DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    
    -- Assignment
    assignee_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    reporter_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    
    -- Hierarchy
    parent_task_id uuid REFERENCES aos_collab.task(task_id),
    
    -- Metadata
    labels text[] DEFAULT ARRAY[]::text[],
    metadata jsonb DEFAULT '{}'::jsonb,
    
    -- Timing
    due_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    completed_at timestamptz
);

CREATE INDEX idx_collab_task_tenant ON aos_collab.task(tenant_id);
CREATE INDEX idx_collab_task_status ON aos_collab.task(status);
CREATE INDEX idx_collab_task_assignee ON aos_collab.task(assignee_principal_id);
CREATE INDEX idx_collab_task_parent ON aos_collab.task(parent_task_id) WHERE parent_task_id IS NOT NULL;
CREATE INDEX idx_collab_task_labels ON aos_collab.task USING GIN(labels);

-- ----------------------------------------------------------------------------
-- Table: run_link
-- Purpose: Link runs to tasks
-- ----------------------------------------------------------------------------
CREATE TABLE aos_collab.run_link (
    run_id uuid NOT NULL REFERENCES aos_core.run(run_id) ON DELETE CASCADE,
    task_id uuid NOT NULL REFERENCES aos_collab.task(task_id) ON DELETE CASCADE,
    
    link_type text NOT NULL DEFAULT 'works_on'
        CHECK (link_type IN ('works_on', 'generated_by', 'reviews', 'blocks', 'relates_to')),
    
    metadata jsonb DEFAULT '{}'::jsonb,
    linked_at timestamptz NOT NULL DEFAULT now(),
    linked_by uuid REFERENCES aos_auth.principal(principal_id),
    
    PRIMARY KEY (run_id, task_id, link_type)
);

CREATE INDEX idx_collab_run_link_task ON aos_collab.run_link(task_id);
CREATE INDEX idx_collab_run_link_type ON aos_collab.run_link(link_type);

-- ----------------------------------------------------------------------------
-- Table: comment
-- Purpose: Comments on tasks
-- ----------------------------------------------------------------------------
CREATE TABLE aos_collab.comment (
    comment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id uuid NOT NULL REFERENCES aos_collab.task(task_id) ON DELETE CASCADE,
    
    content text NOT NULL,
    author_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    
    -- For threaded comments
    parent_comment_id uuid REFERENCES aos_collab.comment(comment_id),
    
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    is_edited bool DEFAULT false
);

CREATE INDEX idx_collab_comment_task ON aos_collab.comment(task_id);
CREATE INDEX idx_collab_comment_author ON aos_collab.comment(author_principal_id);

COMMENT ON SCHEMA aos_collab IS 'pgAgentOS: Collaboration and task management';
COMMENT ON TABLE aos_collab.task IS 'Task/issue tracking';
COMMENT ON TABLE aos_collab.run_link IS 'Links between runs and tasks';
COMMENT ON TABLE aos_collab.comment IS 'Comments on tasks';
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
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_agent (Simplified Agent Loop Architecture)
-- 
-- New Design Philosophy:
-- - "Conversation → Turn → Step" structure instead of graphs
-- - All steps are transparently observable
-- - Admin can intervene at any time
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_agent;

-- ============================================================================
-- CORE: Agent Definition
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: agent
-- Purpose: Agent Definition (Persona + Tools + Config)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.agent (
    agent_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Basic Info
    name text NOT NULL,
    display_name text,
    description text,
    avatar_url text,
    
    -- Persona Link
    persona_id uuid REFERENCES aos_persona.persona(persona_id),
    
    -- Available Tools (Skill Key Array)
    tools text[] DEFAULT ARRAY[]::text[],
    
    -- Behavior Config
    config jsonb DEFAULT '{
        "max_iterations": 10,
        "max_tokens_per_turn": 4096,
        "thinking_visible": true,
        "auto_approve_tools": false,
        "pause_before_tool": false,
        "pause_after_tool": false
    }'::jsonb,
    
    -- Meta
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    
    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_agent_tenant ON aos_agent.agent(tenant_id);
CREATE INDEX idx_agent_active ON aos_agent.agent(is_active) WHERE is_active = true;

-- ============================================================================
-- CORE: Conversation
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: conversation
-- Purpose: Conversation session between user and agent
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.conversation (
    conversation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    agent_id uuid NOT NULL REFERENCES aos_agent.agent(agent_id) ON DELETE CASCADE,
    
    -- Participants
    user_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    
    -- Status
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'paused', 'completed', 'archived')),
    
    -- Context
    title text,                                      -- Auto-generated or user-defined
    summary text,                                    -- AI generated summary
    context jsonb DEFAULT '{}'::jsonb,               -- Additional context
    
    -- Stats
    total_turns int DEFAULT 0,
    total_tokens int DEFAULT 0,
    total_cost_usd numeric(10,6) DEFAULT 0,
    
    -- Timing
    started_at timestamptz NOT NULL DEFAULT now(),
    last_activity_at timestamptz DEFAULT now(),
    completed_at timestamptz
);

CREATE INDEX idx_conversation_tenant ON aos_agent.conversation(tenant_id);
CREATE INDEX idx_conversation_agent ON aos_agent.conversation(agent_id);
CREATE INDEX idx_conversation_user ON aos_agent.conversation(user_principal_id);
CREATE INDEX idx_conversation_status ON aos_agent.conversation(status);
CREATE INDEX idx_conversation_recent ON aos_agent.conversation(last_activity_at DESC);

-- ============================================================================
-- CORE: Turn
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: turn
-- Purpose: Each turn in conversation (User Input → Agent Response)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.turn (
    turn_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES aos_agent.conversation(conversation_id) ON DELETE CASCADE,
    
    -- Sequence
    turn_number int NOT NULL,
    
    -- User Input
    user_message text NOT NULL,
    user_attachments jsonb DEFAULT '[]'::jsonb,      -- files, images, etc.
    
    -- Agent Response
    assistant_message text,
    assistant_attachments jsonb DEFAULT '[]'::jsonb,
    
    -- Status
    status text NOT NULL DEFAULT 'processing'
        CHECK (status IN (
            'processing',     -- processing
            'waiting_tool',   -- waiting for tool approval
            'waiting_human',  -- waiting for human input
            'completed',      -- completed
            'failed',         -- failed
            'cancelled'       -- cancelled
        )),
    
    -- Error Info
    error_message text,
    error_details jsonb,
    
    -- Stats
    iteration_count int DEFAULT 0,
    tokens_used int DEFAULT 0,
    cost_usd numeric(10,6) DEFAULT 0,
    
    -- Timing
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    duration_ms bigint,
    
    UNIQUE (conversation_id, turn_number)
);

CREATE INDEX idx_turn_conversation ON aos_agent.turn(conversation_id);
CREATE INDEX idx_turn_status ON aos_agent.turn(status);
CREATE INDEX idx_turn_order ON aos_agent.turn(conversation_id, turn_number);

-- ============================================================================
-- CORE: Step (Observable Step)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: step
-- Purpose: Each step within a turn (Granular execution log)
-- 
-- Types:
--   think     : Chain of Thought
--   tool_call : Request tool execution
--   tool_result: Result of tool execution
--   respond   : Generate response
--   pause     : Paused (waiting approval)
--   error     : Error occurred
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.step (
    step_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    turn_id uuid NOT NULL REFERENCES aos_agent.turn(turn_id) ON DELETE CASCADE,
    
    -- Step Sequence
    step_number int NOT NULL,
    
    -- Type
    step_type text NOT NULL CHECK (step_type IN (
        'think',
        'tool_call',
        'tool_result',
        'respond',
        'pause',
        'error'
    )),
    
    -- Content (Schema varies by type)
    content jsonb NOT NULL DEFAULT '{}'::jsonb,
    /*
    think:       {"reasoning": "...", "next_action": "..."}
    tool_call:   {"tool": "web_search", "input": {...}, "requires_approval": true}
    tool_result: {"tool": "web_search", "output": {...}, "success": true}
    respond:     {"message": "...", "confidence": 0.95}
    pause:       {"reason": "tool_approval", "awaiting": "admin"}
    error:       {"type": "rate_limit", "message": "...", "recoverable": true}
    */
    
    -- Status
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled', 'approved', 'rejected')),
    
    -- Admin Feedback
    admin_feedback jsonb,                            -- {"action": "approve", "note": "OK", "by": "..."}
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    duration_ms bigint,
    
    UNIQUE (turn_id, step_number)
);

CREATE INDEX idx_step_turn ON aos_agent.step(turn_id);
CREATE INDEX idx_step_type ON aos_agent.step(step_type);
CREATE INDEX idx_step_status ON aos_agent.step(status);
CREATE INDEX idx_step_order ON aos_agent.step(turn_id, step_number);
CREATE INDEX idx_step_pending ON aos_agent.step(status) WHERE status IN ('pending', 'running');

-- ============================================================================
-- CORE: Memory (Conversation Memory)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: memory
-- Purpose: Agent's Long/Short-term memory
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.memory (
    memory_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid REFERENCES aos_agent.conversation(conversation_id) ON DELETE CASCADE,
    agent_id uuid REFERENCES aos_agent.agent(agent_id) ON DELETE CASCADE,
    
    -- Memory Type
    memory_type text NOT NULL CHECK (memory_type IN (
        'conversation',   -- Conversation History
        'working',        -- Working Memory
        'episodic',       -- Episodic Memory
        'semantic',       -- Semantic Memory (Facts)
        'procedural'      -- Procedural Memory (Methods)
    )),
    
    -- Content
    key text NOT NULL,
    value jsonb NOT NULL,
    
    -- Importance & Access
    importance float DEFAULT 0.5,
    access_count int DEFAULT 0,
    last_accessed_at timestamptz DEFAULT now(),
    
    -- Expiry
    expires_at timestamptz,
    
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_memory_conversation ON aos_agent.memory(conversation_id);
CREATE INDEX idx_memory_agent ON aos_agent.memory(agent_id);
CREATE INDEX idx_memory_type ON aos_agent.memory(memory_type);
CREATE INDEX idx_memory_key ON aos_agent.memory(key);

-- ============================================================================
-- ADMIN: Observation & Intervention
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: observation
-- Purpose: Admin observations and feedback
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.observation (
    observation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Target (Set only one)
    conversation_id uuid REFERENCES aos_agent.conversation(conversation_id),
    turn_id uuid REFERENCES aos_agent.turn(turn_id),
    step_id uuid REFERENCES aos_agent.step(step_id),
    
    -- content
    observer_id uuid REFERENCES aos_auth.principal(principal_id),
    observation_type text NOT NULL CHECK (observation_type IN (
        'note',           -- Note
        'flag',           -- Issue Flag
        'correction',     -- Correction Proposal
        'approval',       -- Approval
        'rejection',      -- Rejection
        'rating'          -- Rating
    )),
    
    content jsonb NOT NULL,
    /*
    note:       {"text": "Good"}
    flag:       {"severity": "warning", "reason": "Cost too high"}
    correction: {"original": "...", "corrected": "...", "reason": "..."}
    approval:   {"approved": true, "note": "OK"}
    rejection:  {"reason": "Unsafe", "alternative": "..."}
    rating:     {"score": 4, "aspects": {"accuracy": 5, "speed": 3}}
    */
    
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_observation_conversation ON aos_agent.observation(conversation_id);
CREATE INDEX idx_observation_turn ON aos_agent.observation(turn_id);
CREATE INDEX idx_observation_step ON aos_agent.observation(step_id);
CREATE INDEX idx_observation_type ON aos_agent.observation(observation_type);

-- ============================================================================
-- FUNCTIONS: Core Agent Functions
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: create_agent
-- Purpose: Create new agent
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.create_agent(
    p_tenant_id uuid,
    p_name text,
    p_persona_id uuid DEFAULT NULL,
    p_tools text[] DEFAULT ARRAY[]::text[],
    p_config jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_agent_id uuid;
    v_default_config jsonb := '{
        "max_iterations": 10,
        "max_tokens_per_turn": 4096,
        "thinking_visible": true,
        "auto_approve_tools": false,
        "pause_before_tool": false,
        "pause_after_tool": false
    }'::jsonb;
BEGIN
    INSERT INTO aos_agent.agent (tenant_id, name, persona_id, tools, config)
    VALUES (p_tenant_id, p_name, p_persona_id, p_tools, v_default_config || p_config)
    RETURNING agent_id INTO v_agent_id;
    
    RETURN v_agent_id;
END;
$$;


-- ----------------------------------------------------------------------------
-- Function: start_conversation
-- Purpose: Start conversation
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.start_conversation(
    p_agent_id uuid,
    p_user_principal_id uuid DEFAULT NULL,
    p_context jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_agent aos_agent.agent;
    v_conversation_id uuid;
BEGIN
    SELECT * INTO v_agent FROM aos_agent.agent WHERE agent_id = p_agent_id AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Agent not found or inactive: %', p_agent_id;
    END IF;
    
    INSERT INTO aos_agent.conversation (tenant_id, agent_id, user_principal_id, context)
    VALUES (v_agent.tenant_id, p_agent_id, p_user_principal_id, p_context)
    RETURNING conversation_id INTO v_conversation_id;
    
    RETURN v_conversation_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: send_message
-- Purpose: Send user message → Start new turn
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.send_message(
    p_conversation_id uuid,
    p_message text,
    p_attachments jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_conversation aos_agent.conversation;
    v_turn_number int;
    v_turn_id uuid;
BEGIN
    -- Check conversation
    SELECT * INTO v_conversation 
    FROM aos_agent.conversation 
    WHERE conversation_id = p_conversation_id AND status = 'active';
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Conversation not found or not active: %', p_conversation_id;
    END IF;
    
    -- Next turn number
    SELECT COALESCE(MAX(turn_number), 0) + 1 INTO v_turn_number
    FROM aos_agent.turn WHERE conversation_id = p_conversation_id;
    
    -- Create turn
    INSERT INTO aos_agent.turn (conversation_id, turn_number, user_message, user_attachments)
    VALUES (p_conversation_id, v_turn_number, p_message, p_attachments)
    RETURNING turn_id INTO v_turn_id;
    
    -- Update conversation stats
    UPDATE aos_agent.conversation
    SET total_turns = total_turns + 1,
        last_activity_at = now()
    WHERE conversation_id = p_conversation_id;
    
    -- Create first step (think)
    INSERT INTO aos_agent.step (turn_id, step_number, step_type, status, content)
    VALUES (v_turn_id, 1, 'think', 'pending', 
            jsonb_build_object('input', p_message, 'reasoning', NULL));
    
    RETURN v_turn_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: record_step
-- Purpose: Record step (called by external execution engine)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.record_step(
    p_turn_id uuid,
    p_step_type text,
    p_content jsonb,
    p_status text DEFAULT 'completed'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_step_number int;
    v_step_id uuid;
BEGIN
    -- Next step number
    SELECT COALESCE(MAX(step_number), 0) + 1 INTO v_step_number
    FROM aos_agent.step WHERE turn_id = p_turn_id;
    
    -- Create step
    INSERT INTO aos_agent.step (turn_id, step_number, step_type, content, status, completed_at)
    VALUES (p_turn_id, v_step_number, p_step_type, p_content, p_status,
            CASE WHEN p_status = 'completed' THEN now() ELSE NULL END)
    RETURNING step_id INTO v_step_id;
    
    RETURN v_step_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: approve_step
-- Purpose: Admin approves/rejects pending step
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.approve_step(
    p_step_id uuid,
    p_approved bool,
    p_admin_id uuid,
    p_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE aos_agent.step
    SET status = CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END,
        admin_feedback = jsonb_build_object(
            'action', CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END,
            'by', p_admin_id,
            'note', p_note,
            'at', now()
        ),
        completed_at = now()
    WHERE step_id = p_step_id AND status IN ('pending', 'running');
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Step not found or not in pending/running state: %', p_step_id;
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: complete_turn
-- Purpose: Complete turn (set response)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.complete_turn(
    p_turn_id uuid,
    p_assistant_message text,
    p_tokens_used int DEFAULT 0,
    p_cost_usd numeric DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_conversation_id uuid;
    v_duration_ms bigint;
BEGIN
    -- Update turn
    UPDATE aos_agent.turn
    SET assistant_message = p_assistant_message,
        status = 'completed',
        tokens_used = p_tokens_used,
        cost_usd = p_cost_usd,
        completed_at = now(),
        duration_ms = EXTRACT(EPOCH FROM (now() - started_at)) * 1000
    WHERE turn_id = p_turn_id
    RETURNING conversation_id, duration_ms INTO v_conversation_id, v_duration_ms;
    
    -- Update conversation stats
    UPDATE aos_agent.conversation
    SET total_tokens = total_tokens + p_tokens_used,
        total_cost_usd = total_cost_usd + p_cost_usd,
        last_activity_at = now()
    WHERE conversation_id = v_conversation_id;
    
    -- Record response step
    PERFORM aos_agent.record_step(p_turn_id, 'respond', 
        jsonb_build_object('message', p_assistant_message));
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: add_observation
-- Purpose: Add Admin observation
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.add_observation(
    p_observer_id uuid,
    p_observation_type text,
    p_content jsonb,
    p_conversation_id uuid DEFAULT NULL,
    p_turn_id uuid DEFAULT NULL,
    p_step_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_observation_id uuid;
BEGIN
    INSERT INTO aos_agent.observation (
        observer_id, observation_type, content,
        conversation_id, turn_id, step_id
    ) VALUES (
        p_observer_id, p_observation_type, p_content,
        p_conversation_id, p_turn_id, p_step_id
    )
    RETURNING observation_id INTO v_observation_id;
    
    RETURN v_observation_id;
END;
$$;

-- ============================================================================
-- VIEWS: Admin Dashboard Views
-- ============================================================================

-- ----------------------------------------------------------------------------
-- View: live_activity
-- Purpose: Real-time agent activity monitoring
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.live_activity AS
SELECT 
    c.conversation_id,
    a.name as agent_name,
    c.status as conversation_status,
    t.turn_id,
    t.turn_number,
    t.user_message,
    t.status as turn_status,
    s.step_id,
    s.step_number,
    s.step_type,
    s.content,
    s.status as step_status,
    s.created_at as step_started_at,
    EXTRACT(EPOCH FROM (now() - s.created_at))::int as seconds_ago
FROM aos_agent.conversation c
JOIN aos_agent.agent a ON a.agent_id = c.agent_id
LEFT JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id
LEFT JOIN aos_agent.step s ON s.turn_id = t.turn_id
WHERE c.status = 'active'
  AND (t.status IN ('processing', 'waiting_tool', 'waiting_human') OR t.status IS NULL)
ORDER BY s.created_at DESC;

-- ----------------------------------------------------------------------------
-- View: pending_approvals
-- Purpose: Steps awaiting approval
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.pending_approvals AS
SELECT 
    s.step_id,
    a.name as agent_name,
    c.conversation_id,
    t.turn_number,
    t.user_message,
    s.step_number,
    s.step_type,
    s.content,
    s.created_at,
    EXTRACT(EPOCH FROM (now() - s.created_at))::int as waiting_seconds
FROM aos_agent.step s
JOIN aos_agent.turn t ON t.turn_id = s.turn_id
JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
JOIN aos_agent.agent a ON a.agent_id = c.agent_id
WHERE s.status = 'pending' 
  AND s.step_type IN ('tool_call', 'pause')
ORDER BY s.created_at;

-- ----------------------------------------------------------------------------
-- View: conversation_timeline
-- Purpose: Conversation timeline (chronological steps)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.conversation_timeline AS
SELECT 
    c.conversation_id,
    t.turn_id,
    t.turn_number,
    'user' as actor,
    t.user_message as content,
    NULL as step_type,
    t.started_at as timestamp
FROM aos_agent.conversation c
JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id

UNION ALL

SELECT 
    c.conversation_id,
    t.turn_id,
    t.turn_number,
    'agent' as actor,
    s.content::text as content,
    s.step_type,
    s.created_at as timestamp
FROM aos_agent.conversation c
JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id
JOIN aos_agent.step s ON s.turn_id = t.turn_id

ORDER BY conversation_id, timestamp;

-- ----------------------------------------------------------------------------
-- View: agent_stats
-- Purpose: Agent Statistics
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.agent_stats AS
SELECT 
    a.agent_id,
    a.name,
    a.display_name,
    count(DISTINCT c.conversation_id) as total_conversations,
    count(DISTINCT t.turn_id) as total_turns,
    sum(t.tokens_used) as total_tokens,
    sum(t.cost_usd) as total_cost,
    avg(t.duration_ms)::int as avg_turn_duration_ms,
    count(*) FILTER (WHERE t.status = 'completed') as successful_turns,
    count(*) FILTER (WHERE t.status = 'failed') as failed_turns,
    max(c.last_activity_at) as last_activity
FROM aos_agent.agent a
LEFT JOIN aos_agent.conversation c ON c.agent_id = a.agent_id
LEFT JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id
GROUP BY a.agent_id, a.name, a.display_name;

COMMENT ON SCHEMA aos_agent IS 'pgAgentOS: Simplified Agent Loop Architecture';
COMMENT ON TABLE aos_agent.agent IS 'Agent Definition';
COMMENT ON TABLE aos_agent.conversation IS 'Conversation Session';
COMMENT ON TABLE aos_agent.turn IS 'Conversation Turn';
COMMENT ON TABLE aos_agent.step IS 'Observable Step';
COMMENT ON TABLE aos_agent.memory IS 'Agent Memory';
COMMENT ON TABLE aos_agent.observation IS 'Admin Observation & Feedback';
-- ============================================================================
-- pgAgentOS: Multi-Agent Collaboration System
-- Schema: aos_multi_agent
-- 
-- Core Philosophy:
-- - PostgreSQL acts as the "Central Bus" for inter-agent communication
-- - All agent-to-agent messages are recorded for audit/debugging
-- - Supports collaboration patterns like debate, voting, consensus, etc.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_multi_agent;

-- ============================================================================
-- CORE: Team & Membership
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: team
-- Purpose: Agent Team (Collaboration Group)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.team (
    team_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Basic Info
    name text NOT NULL,
    display_name text,
    description text,
    
    -- Team Type
    team_type text NOT NULL DEFAULT 'collaborative'
        CHECK (team_type IN (
            'collaborative',    -- Collaborative (Work together)
            'hierarchical',     -- Hierarchical (Leader + Members)
            'debate',           -- Debate (Pro/Con)
            'review',           -- Review (Author + Reviewer)
            'swarm'            -- Swarm (Dynamic)
        )),
    
    -- Config
    config jsonb DEFAULT '{
        "max_members": 10,
        "require_consensus": false,
        "consensus_threshold": 0.6,
        "allow_delegation": true,
        "timeout_seconds": 300
    }'::jsonb,
    
    -- Meta
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid REFERENCES aos_auth.principal(principal_id),
    
    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_team_tenant ON aos_multi_agent.team(tenant_id);
CREATE INDEX idx_team_type ON aos_multi_agent.team(team_type);

-- ----------------------------------------------------------------------------
-- Table: team_member
-- Purpose: Team Member (Agent or Human)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.team_member (
    member_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id uuid NOT NULL REFERENCES aos_multi_agent.team(team_id) ON DELETE CASCADE,
    
    -- Member (Set only one)
    agent_id uuid REFERENCES aos_agent.agent(agent_id) ON DELETE CASCADE,
    principal_id uuid REFERENCES aos_auth.principal(principal_id) ON DELETE CASCADE,
    
    -- Role
    role text NOT NULL DEFAULT 'member'
        CHECK (role IN (
            'leader',       -- Leader (Decision Maker)
            'coordinator',  -- Coordinator
            'member',       -- Member
            'observer',     -- Observer (Read-only)
            'critic',       -- Critic (Debate)
            'advocate'      -- Advocate (Debate)
        )),
    
    -- Permissions
    can_initiate bool DEFAULT true,      -- Can start discussion
    can_respond bool DEFAULT true,       -- Can respond
    can_vote bool DEFAULT true,          -- Can vote
    can_delegate bool DEFAULT false,     -- Can delegate
    
    -- Meta
    joined_at timestamptz NOT NULL DEFAULT now(),
    is_active bool DEFAULT true,
    
    CHECK (
        (agent_id IS NOT NULL AND principal_id IS NULL) OR
        (agent_id IS NULL AND principal_id IS NOT NULL)
    )
);

CREATE INDEX idx_team_member_team ON aos_multi_agent.team_member(team_id);
CREATE INDEX idx_team_member_agent ON aos_multi_agent.team_member(agent_id);
CREATE INDEX idx_team_member_principal ON aos_multi_agent.team_member(principal_id);

-- ============================================================================
-- CORE: Discussion
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: discussion
-- Purpose: Inter-agent Discussion/Collaboration Session
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.discussion (
    discussion_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    team_id uuid REFERENCES aos_multi_agent.team(team_id) ON DELETE SET NULL,
    
    -- Discussion Info
    topic text NOT NULL,                          -- Topic
    goal text,                                    -- Goal
    context jsonb DEFAULT '{}'::jsonb,            -- Context
    
    -- Discussion Type
    discussion_type text NOT NULL DEFAULT 'open'
        CHECK (discussion_type IN (
            'open',           -- Free discussion
            'structured',     -- Structured (Sequential)
            'debate',         -- Debate
            'brainstorm',     -- Brainstorming
            'review',         -- Review/Feedback
            'decision'        -- Decision Making
        )),
    
    -- Status
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN (
            'draft',          -- Draft
            'active',         -- Active
            'voting',         -- Voting
            'concluded',      -- Concluded
            'stalled',        -- Stalled
            'cancelled'       -- Cancelled
        )),
    
    -- Conclusion
    conclusion text,                              -- Final Conclusion
    conclusion_rationale text,                    -- Rationale
    concluded_by uuid,                            -- Concluded By
    concluded_at timestamptz,
    
    -- Config
    config jsonb DEFAULT '{
        "max_rounds": 10,
        "max_messages_per_round": 5,
        "require_all_participate": false,
        "allow_abstain": true
    }'::jsonb,
    
    -- Stats
    total_messages int DEFAULT 0,
    participating_agents int DEFAULT 0,
    
    -- Timing
    started_at timestamptz NOT NULL DEFAULT now(),
    deadline_at timestamptz,
    updated_at timestamptz DEFAULT now()
);

CREATE INDEX idx_discussion_tenant ON aos_multi_agent.discussion(tenant_id);
CREATE INDEX idx_discussion_team ON aos_multi_agent.discussion(team_id);
CREATE INDEX idx_discussion_status ON aos_multi_agent.discussion(status);

-- ============================================================================
-- CORE: Message
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: agent_message
-- Purpose: Inter-agent Message (Communication Protocol)
-- 
-- CORE: All agent communications are recorded here.
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.agent_message (
    message_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    discussion_id uuid NOT NULL REFERENCES aos_multi_agent.discussion(discussion_id) ON DELETE CASCADE,
    
    -- Sender/Recipient
    sender_agent_id uuid REFERENCES aos_agent.agent(agent_id),
    sender_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    recipient_agent_ids uuid[] DEFAULT ARRAY[]::uuid[],     -- Specific recipients (Empty = Broadcast)
    
    -- Message Type
    message_type text NOT NULL DEFAULT 'statement'
        CHECK (message_type IN (
            'statement',      -- Statement/Opinion
            'question',       -- Question
            'answer',         -- Answer
            'proposal',       -- Proposal
            'objection',      -- Objection
            'support',        -- Support
            'clarification',  -- Clarification Request
            'summary',        -- Summary
            'vote',           -- Vote
            'delegate',       -- Delegate
            'system'          -- System Message
        )),
    
    -- Content
    content text NOT NULL,
    attachments jsonb DEFAULT '[]'::jsonb,
    
    -- Metadata
    metadata jsonb DEFAULT '{}'::jsonb,
    /*
    {
        "confidence": 0.85,
        "sources": ["doc_1", "doc_2"],
        "reasoning_trace": "...",
        "in_reply_to": "message_uuid",
        "vote_value": "agree|disagree|abstain",
        "proposal_id": "...",
        "delegation_to": "agent_uuid"
    }
    */
    
    -- Sequence
    round_number int,                             -- Round Number
    sequence_number int NOT NULL,                 -- Sequence in Discussion
    
    -- Reactions
    reactions jsonb DEFAULT '{}'::jsonb,
    /*
    {
        "agent_1_uuid": {"type": "agree", "strength": 0.8},
        "agent_2_uuid": {"type": "disagree", "strength": 0.6}
    }
    */
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    
    -- Turn Link
    source_turn_id uuid REFERENCES aos_agent.turn(turn_id),
    
    CHECK (
        (sender_agent_id IS NOT NULL AND sender_principal_id IS NULL) OR
        (sender_agent_id IS NULL AND sender_principal_id IS NOT NULL)
    )
);

CREATE INDEX idx_agent_message_discussion ON aos_multi_agent.agent_message(discussion_id);
CREATE INDEX idx_agent_message_sender ON aos_multi_agent.agent_message(sender_agent_id);
CREATE INDEX idx_agent_message_type ON aos_multi_agent.agent_message(message_type);
CREATE INDEX idx_agent_message_order ON aos_multi_agent.agent_message(discussion_id, sequence_number);

-- ============================================================================
-- CORE: Proposal & Voting
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: proposal
-- Purpose: Proposal in discussion (Voting Target)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.proposal (
    proposal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    discussion_id uuid NOT NULL REFERENCES aos_multi_agent.discussion(discussion_id) ON DELETE CASCADE,
    
    -- Proposal Info
    title text NOT NULL,
    description text NOT NULL,
    proposed_by uuid REFERENCES aos_agent.agent(agent_id),
    
    -- Status
    status text NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'voting', 'accepted', 'rejected', 'withdrawn')),
    
    -- Vote Results
    votes_for int DEFAULT 0,
    votes_against int DEFAULT 0,
    votes_abstain int DEFAULT 0,
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    voting_deadline timestamptz,
    resolved_at timestamptz
);

CREATE INDEX idx_proposal_discussion ON aos_multi_agent.proposal(discussion_id);
CREATE INDEX idx_proposal_status ON aos_multi_agent.proposal(status);

-- ----------------------------------------------------------------------------
-- Table: vote
-- Purpose: Vote Record
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.vote (
    vote_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    proposal_id uuid NOT NULL REFERENCES aos_multi_agent.proposal(proposal_id) ON DELETE CASCADE,
    
    -- Voter
    voter_agent_id uuid REFERENCES aos_agent.agent(agent_id),
    voter_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    
    -- Vote
    vote_value text NOT NULL CHECK (vote_value IN ('for', 'against', 'abstain')),
    weight float DEFAULT 1.0,                     -- Weighted Voting
    rationale text,                               -- Rationale
    
    -- Timing
    voted_at timestamptz NOT NULL DEFAULT now(),
    
    -- One vote per proposal per voter
    UNIQUE (proposal_id, voter_agent_id),
    UNIQUE (proposal_id, voter_principal_id),
    
    CHECK (
        (voter_agent_id IS NOT NULL AND voter_principal_id IS NULL) OR
        (voter_agent_id IS NULL AND voter_principal_id IS NOT NULL)
    )
);

CREATE INDEX idx_vote_proposal ON aos_multi_agent.vote(proposal_id);

-- ============================================================================
-- CORE: Shared Workspace
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: shared_artifact
-- Purpose: Shared Artifacts (Docs, Code, etc.)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.shared_artifact (
    artifact_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    discussion_id uuid REFERENCES aos_multi_agent.discussion(discussion_id) ON DELETE SET NULL,
    team_id uuid REFERENCES aos_multi_agent.team(team_id) ON DELETE SET NULL,
    
    -- Artifact Info
    artifact_type text NOT NULL CHECK (artifact_type IN (
        'document', 'code', 'plan', 'diagram', 'data', 'other'
    )),
    name text NOT NULL,
    description text,
    
    -- Content
    content text,
    content_format text DEFAULT 'text',           -- 'text', 'markdown', 'json', 'code'
    metadata jsonb DEFAULT '{}'::jsonb,
    
    -- Versioning
    version int NOT NULL DEFAULT 1,
    parent_version_id uuid REFERENCES aos_multi_agent.shared_artifact(artifact_id),
    
    -- Contributors
    created_by uuid,                              -- agent_id or principal_id
    created_by_type text CHECK (created_by_type IN ('agent', 'human')),
    
    -- Status
    status text DEFAULT 'draft' CHECK (status IN ('draft', 'review', 'approved', 'archived')),
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

CREATE INDEX idx_shared_artifact_discussion ON aos_multi_agent.shared_artifact(discussion_id);
CREATE INDEX idx_shared_artifact_team ON aos_multi_agent.shared_artifact(team_id);

-- ============================================================================
-- FUNCTIONS: Team Management
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: create_team
-- Purpose: Create Team
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.create_team(
    p_tenant_id uuid,
    p_name text,
    p_team_type text DEFAULT 'collaborative',
    p_agent_ids uuid[] DEFAULT ARRAY[]::uuid[],
    p_config jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_team_id uuid;
    v_agent_id uuid;
    v_default_config jsonb := '{
        "max_members": 10,
        "require_consensus": false,
        "consensus_threshold": 0.6,
        "allow_delegation": true,
        "timeout_seconds": 300
    }'::jsonb;
BEGIN
    -- Create Team
    INSERT INTO aos_multi_agent.team (tenant_id, name, team_type, config)
    VALUES (p_tenant_id, p_name, p_team_type, v_default_config || p_config)
    RETURNING team_id INTO v_team_id;
    
    -- Add Members
    FOREACH v_agent_id IN ARRAY p_agent_ids
    LOOP
        INSERT INTO aos_multi_agent.team_member (team_id, agent_id, role)
        VALUES (v_team_id, v_agent_id, 
                CASE WHEN v_agent_id = p_agent_ids[1] THEN 'leader' ELSE 'member' END);
    END LOOP;
    
    RETURN v_team_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: add_team_member
-- Purpose: Add member to team
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.add_team_member(
    p_team_id uuid,
    p_agent_id uuid DEFAULT NULL,
    p_principal_id uuid DEFAULT NULL,
    p_role text DEFAULT 'member'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_member_id uuid;
BEGIN
    INSERT INTO aos_multi_agent.team_member (team_id, agent_id, principal_id, role)
    VALUES (p_team_id, p_agent_id, p_principal_id, p_role)
    RETURNING member_id INTO v_member_id;
    
    RETURN v_member_id;
END;
$$;

-- ============================================================================
-- FUNCTIONS: Discussion Management
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: start_discussion
-- Purpose: Start Discussion
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.start_discussion(
    p_tenant_id uuid,
    p_topic text,
    p_team_id uuid DEFAULT NULL,
    p_discussion_type text DEFAULT 'open',
    p_goal text DEFAULT NULL,
    p_context jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_discussion_id uuid;
BEGIN
    INSERT INTO aos_multi_agent.discussion (
        tenant_id, team_id, topic, goal, context, discussion_type
    ) VALUES (
        p_tenant_id, p_team_id, p_topic, p_goal, p_context, p_discussion_type
    )
    RETURNING discussion_id INTO v_discussion_id;
    
    -- System Notification
    INSERT INTO aos_multi_agent.agent_message (
        discussion_id, sender_principal_id, message_type, content, sequence_number
    ) VALUES (
        v_discussion_id, 
        NULL,  -- System
        'system',
        format('Discussion started: %s', p_topic),
        1
    );
    
    RETURN v_discussion_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: send_agent_message
-- Purpose: Send Message between Agents (CORE!)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.send_agent_message(
    p_discussion_id uuid,
    p_sender_agent_id uuid,
    p_message_type text,
    p_content text,
    p_recipient_agent_ids uuid[] DEFAULT ARRAY[]::uuid[],
    p_metadata jsonb DEFAULT '{}'::jsonb,
    p_source_turn_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_message_id uuid;
    v_sequence int;
    v_round int;
BEGIN
    -- Next Sequence
    SELECT COALESCE(MAX(sequence_number), 0) + 1 INTO v_sequence
    FROM aos_multi_agent.agent_message WHERE discussion_id = p_discussion_id;
    
    -- Current Round
    SELECT COALESCE(MAX(round_number), 1) INTO v_round
    FROM aos_multi_agent.agent_message WHERE discussion_id = p_discussion_id;
    
    -- Insert Message
    INSERT INTO aos_multi_agent.agent_message (
        discussion_id, sender_agent_id, message_type, content,
        recipient_agent_ids, metadata, sequence_number, round_number,
        source_turn_id
    ) VALUES (
        p_discussion_id, p_sender_agent_id, p_message_type, p_content,
        p_recipient_agent_ids, p_metadata, v_sequence, v_round,
        p_source_turn_id
    )
    RETURNING message_id INTO v_message_id;
    
    -- Update Discussion Stats
    UPDATE aos_multi_agent.discussion
    SET total_messages = total_messages + 1,
        updated_at = now()
    WHERE discussion_id = p_discussion_id;
    
    -- Log to Event Log
    INSERT INTO aos_core.event_log (
        run_id, event_type, actor_type, actor_id, event_name, payload
    )
    SELECT 
        NULL,  -- Need to fix this to handle run_id eventually
        'agent_communication',
        'agent',
        p_sender_agent_id,
        'message_sent',
        jsonb_build_object(
            'discussion_id', p_discussion_id,
            'message_id', v_message_id,
            'message_type', p_message_type,
            'recipients', p_recipient_agent_ids
        );
    
    RETURN v_message_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: react_to_message
-- Purpose: React to a message
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.react_to_message(
    p_message_id uuid,
    p_reactor_agent_id uuid,
    p_reaction_type text,  -- 'agree', 'disagree', 'neutral', 'clarify'
    p_strength float DEFAULT 1.0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE aos_multi_agent.agent_message
    SET reactions = reactions || jsonb_build_object(
        p_reactor_agent_id::text,
        jsonb_build_object('type', p_reaction_type, 'strength', p_strength, 'at', now())
    )
    WHERE message_id = p_message_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: create_proposal
-- Purpose: Create Proposal
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.create_proposal(
    p_discussion_id uuid,
    p_title text,
    p_description text,
    p_proposed_by uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_proposal_id uuid;
BEGIN
    INSERT INTO aos_multi_agent.proposal (
        discussion_id, title, description, proposed_by
    ) VALUES (
        p_discussion_id, p_title, p_description, p_proposed_by
    )
    RETURNING proposal_id INTO v_proposal_id;
    
    -- Auto-generate Proposal Message
    PERFORM aos_multi_agent.send_agent_message(
        p_discussion_id,
        p_proposed_by,
        'proposal',
        format('**Proposal:** %s\n\n%s', p_title, p_description),
        ARRAY[]::uuid[],
        jsonb_build_object('proposal_id', v_proposal_id)
    );
    
    RETURN v_proposal_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: cast_vote
-- Purpose: Cast Vote
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.cast_vote(
    p_proposal_id uuid,
    p_voter_agent_id uuid,
    p_vote_value text,
    p_rationale text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_discussion_id uuid;
BEGIN
    -- Record Vote
    INSERT INTO aos_multi_agent.vote (
        proposal_id, voter_agent_id, vote_value, rationale
    ) VALUES (
        p_proposal_id, p_voter_agent_id, p_vote_value, p_rationale
    )
    ON CONFLICT (proposal_id, voter_agent_id) DO UPDATE
    SET vote_value = EXCLUDED.vote_value,
        rationale = EXCLUDED.rationale,
        voted_at = now();
    
    -- Update Count
    UPDATE aos_multi_agent.proposal p
    SET votes_for = (SELECT count(*) FROM aos_multi_agent.vote v WHERE v.proposal_id = p.proposal_id AND v.vote_value = 'for'),
        votes_against = (SELECT count(*) FROM aos_multi_agent.vote v WHERE v.proposal_id = p.proposal_id AND v.vote_value = 'against'),
        votes_abstain = (SELECT count(*) FROM aos_multi_agent.vote v WHERE v.proposal_id = p.proposal_id AND v.vote_value = 'abstain')
    WHERE p.proposal_id = p_proposal_id;
    
    -- Create Vote Message
    SELECT discussion_id INTO v_discussion_id
    FROM aos_multi_agent.proposal WHERE proposal_id = p_proposal_id;
    
    PERFORM aos_multi_agent.send_agent_message(
        v_discussion_id,
        p_voter_agent_id,
        'vote',
        COALESCE(p_rationale, format('Vote: %s', p_vote_value)),
        ARRAY[]::uuid[],
        jsonb_build_object(
            'proposal_id', p_proposal_id,
            'vote_value', p_vote_value
        )
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: conclude_discussion
-- Purpose: Conclude discussion
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.conclude_discussion(
    p_discussion_id uuid,
    p_conclusion text,
    p_rationale text DEFAULT NULL,
    p_concluded_by uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE aos_multi_agent.discussion
    SET status = 'concluded',
        conclusion = p_conclusion,
        conclusion_rationale = p_rationale,
        concluded_by = p_concluded_by,
        concluded_at = now(),
        updated_at = now()
    WHERE discussion_id = p_discussion_id;
    
    -- Conclusion Message
    INSERT INTO aos_multi_agent.agent_message (
        discussion_id, message_type, content, sequence_number
    )
    SELECT 
        p_discussion_id,
        'system',
        format('**Conclusion:** %s', p_conclusion),
        COALESCE(MAX(sequence_number), 0) + 1
    FROM aos_multi_agent.agent_message
    WHERE discussion_id = p_discussion_id;
END;
$$;

-- ============================================================================
-- FUNCTIONS: Message Queries
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: get_discussion_messages
-- Purpose: Get discussion messages (context for agent)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.get_discussion_messages(
    p_discussion_id uuid,
    p_limit int DEFAULT 50,
    p_since_sequence int DEFAULT 0
)
RETURNS TABLE (
    message_id uuid,
    sender_agent_id uuid,
    sender_name text,
    message_type text,
    content text,
    metadata jsonb,
    reactions jsonb,
    sequence_number int,
    created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        m.message_id,
        m.sender_agent_id,
        COALESCE(a.display_name, a.name, 'System') as sender_name,
        m.message_type,
        m.content,
        m.metadata,
        m.reactions,
        m.sequence_number,
        m.created_at
    FROM aos_multi_agent.agent_message m
    LEFT JOIN aos_agent.agent a ON a.agent_id = m.sender_agent_id
    WHERE m.discussion_id = p_discussion_id
      AND m.sequence_number > p_since_sequence
    ORDER BY m.sequence_number
    LIMIT p_limit;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_pending_messages_for_agent
-- Purpose: Get messages requiring response
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.get_pending_messages_for_agent(
    p_agent_id uuid
)
RETURNS TABLE (
    discussion_id uuid,
    discussion_topic text,
    message_id uuid,
    sender_name text,
    message_type text,
    content text,
    created_at timestamptz,
    needs_response bool
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        d.discussion_id,
        d.topic as discussion_topic,
        m.message_id,
        COALESCE(a.display_name, a.name) as sender_name,
        m.message_type,
        m.content,
        m.created_at,
        -- Needs Response? (Question or Direct Mention)
        (m.message_type = 'question' OR p_agent_id = ANY(m.recipient_agent_ids)) as needs_response
    FROM aos_multi_agent.discussion d
    JOIN aos_multi_agent.agent_message m ON m.discussion_id = d.discussion_id
    LEFT JOIN aos_agent.agent a ON a.agent_id = m.sender_agent_id
    WHERE d.status = 'active'
      AND m.sender_agent_id != p_agent_id
      AND (
          p_agent_id = ANY(m.recipient_agent_ids)  -- Direct Recipient
          OR array_length(m.recipient_agent_ids, 1) IS NULL  -- Broadcast
      )
      AND NOT EXISTS (  -- Not yet replied
          SELECT 1 FROM aos_multi_agent.agent_message reply
          WHERE reply.discussion_id = d.discussion_id
            AND reply.sender_agent_id = p_agent_id
            AND reply.sequence_number > m.sequence_number
            AND reply.metadata->>'in_reply_to' = m.message_id::text
      )
    ORDER BY m.created_at DESC;
END;
$$;

-- ============================================================================
-- VIEWS: Monitoring
-- ============================================================================

-- ----------------------------------------------------------------------------
-- View: active_discussions
-- Purpose: Active Discussions
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_multi_agent.active_discussions AS
SELECT 
    d.discussion_id,
    d.topic,
    d.discussion_type,
    d.status,
    t.name as team_name,
    d.total_messages,
    d.participating_agents,
    d.started_at,
    d.updated_at,
    EXTRACT(EPOCH FROM (now() - d.updated_at))::int as seconds_since_activity
FROM aos_multi_agent.discussion d
LEFT JOIN aos_multi_agent.team t ON t.team_id = d.team_id
WHERE d.status IN ('active', 'voting')
ORDER BY d.updated_at DESC;

-- ----------------------------------------------------------------------------
-- View: discussion_summary
-- Purpose: Discussion Summary
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_multi_agent.discussion_summary AS
SELECT 
    d.discussion_id,
    d.topic,
    d.status,
    d.conclusion,
    d.total_messages,
    array_agg(DISTINCT a.name) as participants,
    (SELECT count(DISTINCT message_type) FROM aos_multi_agent.agent_message m 
     WHERE m.discussion_id = d.discussion_id) as message_type_diversity,
    (SELECT count(*) FROM aos_multi_agent.proposal p 
     WHERE p.discussion_id = d.discussion_id) as proposals_count,
    (SELECT count(*) FROM aos_multi_agent.proposal p 
     WHERE p.discussion_id = d.discussion_id AND p.status = 'accepted') as accepted_proposals
FROM aos_multi_agent.discussion d
LEFT JOIN aos_multi_agent.agent_message m ON m.discussion_id = d.discussion_id
LEFT JOIN aos_agent.agent a ON a.agent_id = m.sender_agent_id
GROUP BY d.discussion_id, d.topic, d.status, d.conclusion, d.total_messages;

COMMENT ON SCHEMA aos_multi_agent IS 'pgAgentOS: Multi-Agent Collaboration System';
COMMENT ON TABLE aos_multi_agent.team IS 'Agent Team';
COMMENT ON TABLE aos_multi_agent.team_member IS 'Team Member';
COMMENT ON TABLE aos_multi_agent.discussion IS 'Discussion Session';
COMMENT ON TABLE aos_multi_agent.agent_message IS 'Agent Message (Core Protocol)';
COMMENT ON TABLE aos_multi_agent.proposal IS 'Proposal in Discussion';
COMMENT ON TABLE aos_multi_agent.vote IS 'Vote Record';
COMMENT ON TABLE aos_multi_agent.shared_artifact IS 'Shared Artifact';

COMMENT ON FUNCTION aos_multi_agent.send_agent_message IS 'Send agent message (Multi-agent communication)';
COMMENT ON FUNCTION aos_multi_agent.get_pending_messages_for_agent IS 'Get messages requiring agent response';
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Triggers: Immutability Enforcement
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Trigger Function: prevent_modification
-- Purpose: Prevent UPDATE/DELETE on immutable records
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.prevent_modification()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Cannot update immutable record in %.%: %', 
            TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD;
    ELSIF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Cannot delete immutable record in %.%: %',
            TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD;
    END IF;
    RETURN NULL;
END;
$$;

-- ----------------------------------------------------------------------------
-- Trigger: Immutable event_log
-- Purpose: Prevent any modification to event_log entries
-- ----------------------------------------------------------------------------
CREATE TRIGGER trg_event_log_immutable
    BEFORE UPDATE OR DELETE ON aos_core.event_log
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.prevent_modification();

-- ----------------------------------------------------------------------------
-- Trigger Function: prevent_final_state_modification
-- Purpose: Prevent modification of finalized state checkpoints
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.prevent_final_state_modification()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.is_final = true THEN
            RAISE EXCEPTION 'Cannot update finalized state checkpoint: %', OLD.state_id;
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        IF OLD.is_final = true THEN
            RAISE EXCEPTION 'Cannot delete finalized state checkpoint: %', OLD.state_id;
        END IF;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

-- ----------------------------------------------------------------------------
-- Trigger: Protect finalized state checkpoints
-- ----------------------------------------------------------------------------
CREATE TRIGGER trg_workflow_state_immutable
    BEFORE UPDATE OR DELETE ON aos_workflow.workflow_state
    FOR EACH ROW
    EXECUTE FUNCTION aos_workflow.prevent_final_state_modification();

-- ----------------------------------------------------------------------------
-- Trigger Function: auto_update_timestamp
-- Purpose: Automatically update updated_at timestamp
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.auto_update_timestamp()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- Apply auto_update_timestamp to tables with updated_at column
CREATE TRIGGER trg_tenant_updated
    BEFORE UPDATE ON aos_auth.tenant
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_principal_updated
    BEFORE UPDATE ON aos_auth.principal
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_persona_updated
    BEFORE UPDATE ON aos_persona.persona
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_skill_updated
    BEFORE UPDATE ON aos_skills.skill
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_workflow_graph_updated
    BEFORE UPDATE ON aos_workflow.workflow_graph
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_doc_updated
    BEFORE UPDATE ON aos_kg.doc
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_task_updated
    BEFORE UPDATE ON aos_collab.task
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_model_registry_updated
    BEFORE UPDATE ON aos_meta.llm_model_registry
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_agent_updated
    BEFORE UPDATE ON aos_agent.agent
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_conversation_updated
    BEFORE UPDATE ON aos_agent.conversation
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_team_updated
    BEFORE UPDATE ON aos_multi_agent.team
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_discussion_updated
    BEFORE UPDATE ON aos_multi_agent.discussion
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_shared_artifact_updated
    BEFORE UPDATE ON aos_multi_agent.shared_artifact
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

-- ----------------------------------------------------------------------------
-- Trigger Function: log_graph_changes
-- Purpose: Audit log for graph modifications
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.log_graph_changes()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Log creation
        INSERT INTO aos_core.event_log (run_id, event_type, event_subtype, payload)
        SELECT 
            r.run_id,
            'graph_modified',
            'node_added',
            jsonb_build_object(
                'graph_id', NEW.graph_id,
                'node_name', NEW.node_name,
                'node_type', NEW.node_type
            )
        FROM aos_core.run r
        WHERE r.graph_id = NEW.graph_id AND r.status = 'running'
        LIMIT 1;
        
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        -- Log update
        INSERT INTO aos_core.event_log (run_id, event_type, event_subtype, payload)
        SELECT 
            r.run_id,
            'graph_modified',
            'node_updated',
            jsonb_build_object(
                'graph_id', NEW.graph_id,
                'node_name', NEW.node_name,
                'changes', jsonb_build_object(
                    'old', row_to_json(OLD),
                    'new', row_to_json(NEW)
                )
            )
        FROM aos_core.run r
        WHERE r.graph_id = NEW.graph_id AND r.status = 'running'
        LIMIT 1;
        
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        -- Log deletion
        INSERT INTO aos_core.event_log (run_id, event_type, event_subtype, payload)
        SELECT 
            r.run_id,
            'graph_modified',
            'node_deleted',
            jsonb_build_object(
                'graph_id', OLD.graph_id,
                'node_name', OLD.node_name
            )
        FROM aos_core.run r
        WHERE r.graph_id = OLD.graph_id AND r.status = 'running'
        LIMIT 1;
        
        RETURN OLD;
    END IF;
    
    RETURN NULL;
END;
$$;

-- Apply graph change logging (optional - can be enabled per-tenant)
-- CREATE TRIGGER trg_workflow_node_audit
--     AFTER INSERT OR UPDATE OR DELETE ON aos_workflow.workflow_graph_node
--     FOR EACH ROW
--     EXECUTE FUNCTION aos_workflow.log_graph_changes();

-- ----------------------------------------------------------------------------
-- Trigger Function: validate_run_status_transition
-- Purpose: Ensure valid status transitions for runs
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.validate_run_status_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_valid_transitions jsonb := '{
        "pending": ["running", "cancelled"],
        "running": ["completed", "failed", "interrupted", "cancelled"],
        "interrupted": ["running", "cancelled", "failed"],
        "completed": [],
        "failed": [],
        "cancelled": []
    }'::jsonb;
    v_allowed_next text[];
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    
    SELECT array_agg(value::text) INTO v_allowed_next
    FROM jsonb_array_elements_text(v_valid_transitions->OLD.status);
    
    IF NEW.status = ANY(v_allowed_next) THEN
        RETURN NEW;
    ELSE
        RAISE EXCEPTION 'Invalid status transition from % to %', OLD.status, NEW.status;
    END IF;
END;
$$;

CREATE TRIGGER trg_run_status_transition
    BEFORE UPDATE ON aos_core.run
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION aos_core.validate_run_status_transition();

COMMENT ON FUNCTION aos_core.prevent_modification IS 'Prevent UPDATE/DELETE on immutable records';
COMMENT ON FUNCTION aos_workflow.prevent_final_state_modification IS 'Protect finalized state checkpoints';
COMMENT ON FUNCTION aos_core.auto_update_timestamp IS 'Auto-update updated_at timestamp';
COMMENT ON FUNCTION aos_core.validate_run_status_transition IS 'Validate run status transitions';
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Functions: Utilities
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: generate_uuid
-- Purpose: Generate a new UUID (wrapper for gen_random_uuid)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.generate_uuid()
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT gen_random_uuid();
$$;

-- ----------------------------------------------------------------------------
-- Function: hash_params
-- Purpose: Generate SHA256 hash for input parameters (for caching/dedup)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.hash_params(p_params jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT encode(digest(p_params::text, 'sha256'), 'hex');
$$;

-- ----------------------------------------------------------------------------
-- Function: merge_jsonb
-- Purpose: Deep merge two JSONB objects
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.merge_jsonb(p_base jsonb, p_overlay jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_result jsonb;
    v_key text;
    v_value jsonb;
BEGIN
    v_result := p_base;
    
    FOR v_key, v_value IN SELECT * FROM jsonb_each(p_overlay)
    LOOP
        IF v_result ? v_key AND 
           jsonb_typeof(v_result->v_key) = 'object' AND 
           jsonb_typeof(v_value) = 'object' THEN
            -- Recursively merge objects
            v_result := jsonb_set(v_result, ARRAY[v_key], 
                aos_core.merge_jsonb(v_result->v_key, v_value));
        ELSE
            -- Overlay value
            v_result := jsonb_set(v_result, ARRAY[v_key], v_value);
        END IF;
    END LOOP;
    
    RETURN v_result;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: prune_expired_memory
-- Purpose: Remove expired session memory entries
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.prune_expired_memory()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_count int;
BEGIN
    DELETE FROM aos_core.session_memory
    WHERE expires_at IS NOT NULL AND expires_at < now();
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_run_summary
-- Purpose: Get a summary of a run including events and state
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.get_run_summary(p_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_run aos_core.run;
    v_latest_state aos_workflow.workflow_state;
    v_event_count int;
    v_skill_executions jsonb;
BEGIN
    -- Get run
    SELECT * INTO v_run FROM aos_core.run WHERE run_id = p_run_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Run not found: %', p_run_id;
    END IF;
    
    -- Get latest state
    SELECT * INTO v_latest_state
    FROM aos_workflow.workflow_state
    WHERE run_id = p_run_id
    ORDER BY checkpoint_version DESC
    LIMIT 1;
    
    -- Get event count
    SELECT count(*) INTO v_event_count
    FROM aos_core.event_log
    WHERE run_id = p_run_id;
    
    -- Get skill executions summary
    SELECT jsonb_agg(jsonb_build_object(
        'skill_key', skill_key,
        'status', status,
        'duration_ms', duration_ms
    )) INTO v_skill_executions
    FROM aos_core.skill_execution
    WHERE run_id = p_run_id;
    
    RETURN jsonb_build_object(
        'run_id', v_run.run_id,
        'graph_id', v_run.graph_id,
        'status', v_run.status,
        'started_at', v_run.started_at,
        'completed_at', v_run.completed_at,
        'total_steps', v_run.total_steps,
        'total_tokens_used', v_run.total_tokens_used,
        'total_cost_usd', v_run.total_cost_usd,
        'current_node', v_latest_state.current_node,
        'checkpoint_version', v_latest_state.checkpoint_version,
        'event_count', v_event_count,
        'skill_executions', v_skill_executions,
        'input_data', v_run.input_data,
        'output_data', v_run.output_data,
        'error_info', v_run.error_info
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: cleanup_old_runs
-- Purpose: Archive or delete old completed runs
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.cleanup_old_runs(
    p_tenant_id uuid,
    p_days_old int DEFAULT 30,
    p_delete bool DEFAULT false
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_count int;
    v_cutoff_date timestamptz;
BEGIN
    v_cutoff_date := now() - (p_days_old || ' days')::interval;
    
    IF p_delete THEN
        DELETE FROM aos_core.run
        WHERE tenant_id = p_tenant_id
          AND status IN ('completed', 'failed', 'cancelled')
          AND completed_at IS NOT NULL
          AND completed_at < v_cutoff_date;
    ELSE
        -- Just mark as archived in metadata
        UPDATE aos_core.run
        SET metadata = metadata || '{"archived": true}'::jsonb
        WHERE tenant_id = p_tenant_id
          AND status IN ('completed', 'failed', 'cancelled')
          AND completed_at IS NOT NULL
          AND completed_at < v_cutoff_date
          AND NOT (metadata ? 'archived');
    END IF;
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: format_duration
-- Purpose: Format milliseconds as human-readable duration
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.format_duration(p_ms bigint)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_ms < 1000 THEN p_ms || 'ms'
        WHEN p_ms < 60000 THEN round((p_ms / 1000.0)::numeric, 2) || 's'
        WHEN p_ms < 3600000 THEN round((p_ms / 60000.0)::numeric, 2) || 'm'
        ELSE round((p_ms / 3600000.0)::numeric, 2) || 'h'
    END;
$$;

COMMENT ON FUNCTION aos_core.generate_uuid IS 'Generate a new UUID';
COMMENT ON FUNCTION aos_core.hash_params IS 'Generate SHA256 hash for input parameters';
COMMENT ON FUNCTION aos_core.merge_jsonb IS 'Deep merge two JSONB objects';
COMMENT ON FUNCTION aos_core.prune_expired_memory IS 'Remove expired session memory entries';
COMMENT ON FUNCTION aos_core.get_run_summary IS 'Get a summary of a run';
COMMENT ON FUNCTION aos_core.cleanup_old_runs IS 'Archive or delete old completed runs';
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Functions: Workflow Engine (Core Execution Functions)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: create_graph
-- Purpose: Create a new workflow graph with nodes and edges
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.create_graph(
    p_tenant_id uuid,
    p_name text,
    p_version text DEFAULT '1.0',
    p_description text DEFAULT NULL,
    p_nodes jsonb[] DEFAULT ARRAY[]::jsonb[],
    p_edges jsonb[] DEFAULT ARRAY[]::jsonb[],
    p_config jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_graph_id uuid;
    v_node jsonb;
    v_edge jsonb;
    v_validation jsonb;
BEGIN
    -- Verify tenant exists
    IF NOT EXISTS (SELECT 1 FROM aos_auth.tenant WHERE tenant_id = p_tenant_id AND is_active = true) THEN
        RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
    END IF;
    
    -- Create graph
    INSERT INTO aos_workflow.workflow_graph (
        tenant_id, name, version, description, config
    ) VALUES (
        p_tenant_id, p_name, p_version, p_description, p_config
    )
    RETURNING graph_id INTO v_graph_id;
    
    -- Create gateway nodes for entry/exit
    INSERT INTO aos_workflow.workflow_graph_node (graph_id, node_name, node_type, description)
    VALUES 
        (v_graph_id, '__start__', 'gateway', 'Entry point'),
        (v_graph_id, '__end__', 'gateway', 'Exit point');
    
    -- Create nodes from JSON array
    FOREACH v_node IN ARRAY p_nodes
    LOOP
        INSERT INTO aos_workflow.workflow_graph_node (
            graph_id,
            node_name,
            node_type,
            skill_key,
            function_name,
            persona_id,
            prompt_template,
            llm_override_params,
            interrupt_before,
            interrupt_after,
            config,
            description,
            position
        ) VALUES (
            v_graph_id,
            v_node->>'node_name',
            COALESCE(v_node->>'node_type', 'skill'),
            v_node->>'skill_key',
            (v_node->>'function_name')::regproc,
            (v_node->>'persona_id')::uuid,
            v_node->>'prompt_template',
            COALESCE(v_node->'llm_override_params', '{}'::jsonb),
            COALESCE((v_node->>'interrupt_before')::bool, false),
            COALESCE((v_node->>'interrupt_after')::bool, false),
            COALESCE(v_node->'config', '{}'::jsonb),
            v_node->>'description',
            v_node->'position'
        );
    END LOOP;
    
    -- Create edges from JSON array
    FOREACH v_edge IN ARRAY p_edges
    LOOP
        INSERT INTO aos_workflow.workflow_graph_edge (
            graph_id,
            from_node,
            to_node,
            is_conditional,
            condition_function,
            condition_expression,
            condition_value,
            label,
            priority,
            description
        ) VALUES (
            v_graph_id,
            v_edge->>'from_node',
            v_edge->>'to_node',
            COALESCE((v_edge->>'is_conditional')::bool, false),
            (v_edge->>'condition_function')::regproc,
            v_edge->>'condition_expression',
            v_edge->'condition_value',
            v_edge->>'label',
            COALESCE((v_edge->>'priority')::int, 0),
            v_edge->>'description'
        );
    END LOOP;
    
    -- Validate graph structure
    v_validation := aos_workflow.validate_graph(v_graph_id);
    IF NOT (v_validation->>'valid')::bool THEN
        RAISE EXCEPTION 'Invalid graph structure: %', v_validation->'errors';
    END IF;
    
    RETURN v_graph_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: start_graph_run
-- Purpose: Start a new workflow run
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.start_graph_run(
    p_graph_id uuid,
    p_initial_state jsonb DEFAULT '{}'::jsonb,
    p_principal_id uuid DEFAULT NULL,
    p_persona_id uuid DEFAULT NULL,
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_run_id uuid;
    v_graph aos_workflow.workflow_graph;
    v_state_id uuid;
BEGIN
    -- Get graph
    SELECT * INTO v_graph FROM aos_workflow.workflow_graph 
    WHERE graph_id = p_graph_id AND is_active = true;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Graph not found or inactive: %', p_graph_id;
    END IF;
    
    -- Create run
    INSERT INTO aos_core.run (
        tenant_id, principal_id, graph_id, persona_id, status, input_data, metadata
    ) VALUES (
        v_graph.tenant_id, p_principal_id, p_graph_id, p_persona_id, 'running', p_initial_state, p_metadata
    )
    RETURNING run_id INTO v_run_id;
    
    -- Create initial state checkpoint
    INSERT INTO aos_workflow.workflow_state (
        run_id, graph_id, checkpoint_version, current_node, state_data, messages
    ) VALUES (
        v_run_id, p_graph_id, 1, v_graph.entry_node, p_initial_state, ARRAY[]::jsonb[]
    )
    RETURNING state_id INTO v_state_id;
    
    -- Create session memory
    INSERT INTO aos_core.session_memory (
        run_id, tenant_id, principal_id, memory_type
    ) VALUES (
        v_run_id, v_graph.tenant_id, p_principal_id, 'working'
    );
    
    -- Log event
    PERFORM aos_core.log_event(
        v_run_id,
        'run_started',
        jsonb_build_object(
            'graph_id', p_graph_id,
            'graph_name', v_graph.name,
            'initial_state', p_initial_state
        )
    );
    
    RETURN v_run_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: step_graph
-- Purpose: Execute a single step in the workflow (Pregel-like)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.step_graph(p_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_run aos_core.run;
    v_state aos_workflow.workflow_state;
    v_node aos_workflow.workflow_graph_node;
    v_graph aos_workflow.workflow_graph;
    v_next_node text;
    v_new_state_data jsonb;
    v_new_messages jsonb[];
    v_new_checkpoint_version int;
    v_execution_result jsonb;
    v_edge record;
    v_start_time timestamptz;
    v_duration_ms bigint;
    v_should_interrupt bool := false;
    v_hooks_result jsonb;
BEGIN
    v_start_time := clock_timestamp();
    
    -- Get run
    SELECT * INTO v_run FROM aos_core.run WHERE run_id = p_run_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Run not found: %', p_run_id;
    END IF;
    
    IF v_run.status NOT IN ('running', 'pending') THEN
        RAISE EXCEPTION 'Run is not in a runnable state: %', v_run.status;
    END IF;
    
    -- Get current state (latest checkpoint)
    SELECT * INTO v_state
    FROM aos_workflow.workflow_state
    WHERE run_id = p_run_id
    ORDER BY checkpoint_version DESC
    LIMIT 1;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No state checkpoint found for run: %', p_run_id;
    END IF;
    
    -- Get graph
    SELECT * INTO v_graph FROM aos_workflow.workflow_graph WHERE graph_id = v_state.graph_id;
    
    -- Check if we've reached an exit node
    IF v_state.current_node = ANY(v_graph.exit_nodes) THEN
        -- Mark run as completed
        UPDATE aos_core.run
        SET status = 'completed', completed_at = now(), output_data = v_state.state_data
        WHERE run_id = p_run_id;
        
        PERFORM aos_core.log_event(p_run_id, 'run_completed', v_state.state_data);
        
        RETURN jsonb_build_object(
            'status', 'completed',
            'state', v_state.state_data,
            'checkpoint_version', v_state.checkpoint_version
        );
    END IF;
    
    -- Get current node
    SELECT * INTO v_node
    FROM aos_workflow.workflow_graph_node
    WHERE graph_id = v_state.graph_id AND node_name = v_state.current_node;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Node not found: %', v_state.current_node;
    END IF;
    
    -- Check interrupt_before
    IF v_node.interrupt_before THEN
        v_should_interrupt := true;
        
        -- Create interrupt
        INSERT INTO aos_workflow.workflow_interrupt (
            run_id, state_id, node_name, interrupt_type, request_message
        ) VALUES (
            p_run_id, v_state.state_id, v_node.node_name, 'approval',
            'Approval required before executing node: ' || v_node.node_name
        );
        
        UPDATE aos_core.run SET status = 'interrupted' WHERE run_id = p_run_id;
        
        PERFORM aos_core.log_event(p_run_id, 'interrupted', jsonb_build_object(
            'node', v_node.node_name,
            'reason', 'interrupt_before'
        ));
        
        RETURN jsonb_build_object(
            'status', 'interrupted',
            'reason', 'interrupt_before',
            'node', v_node.node_name,
            'checkpoint_version', v_state.checkpoint_version
        );
    END IF;
    
    -- Execute pre_node hooks
    v_hooks_result := aos_policy.execute_hooks(
        'pre_node',
        jsonb_build_object(
            'run_id', p_run_id,
            'node_name', v_node.node_name,
            'node_type', v_node.node_type,
            'state', v_state.state_data
        ),
        v_run.tenant_id
    );
    
    IF (v_hooks_result->>'_abort')::bool = true THEN
        PERFORM aos_core.log_event(p_run_id, 'node_aborted', v_hooks_result);
        RETURN jsonb_build_object(
            'status', 'aborted',
            'reason', v_hooks_result->>'_abort_reason'
        );
    END IF;
    
    -- Log node start
    PERFORM aos_core.log_event(p_run_id, 'node_start', jsonb_build_object(
        'node', v_node.node_name,
        'type', v_node.node_type
    ), v_node.node_name);
    
    -- Initialize new state
    v_new_state_data := v_state.state_data;
    v_new_messages := v_state.messages;
    
    -- Execute based on node type
    CASE v_node.node_type
        WHEN 'gateway' THEN
            -- Gateway nodes just pass through
            v_execution_result := jsonb_build_object('passed', true);
            
        WHEN 'skill' THEN
            -- Execute skill
            IF v_node.skill_key IS NOT NULL THEN
                -- This would call the actual skill implementation
                -- For now, record that we would execute the skill
                v_execution_result := jsonb_build_object(
                    'skill_key', v_node.skill_key,
                    'status', 'pending_external_execution'
                );
                
                INSERT INTO aos_core.skill_execution (
                    run_id, skill_key, input_params, status
                ) VALUES (
                    p_run_id, v_node.skill_key, v_new_state_data, 'pending'
                );
            END IF;
            
        WHEN 'llm' THEN
            -- LLM call would happen here
            v_execution_result := jsonb_build_object(
                'type', 'llm',
                'persona_id', v_node.persona_id,
                'prompt_template', v_node.prompt_template,
                'status', 'pending_external_execution'
            );
            
        WHEN 'function' THEN
            -- Execute PL/pgSQL function
            IF v_node.function_name IS NOT NULL THEN
                EXECUTE format('SELECT %s($1)', v_node.function_name)
                INTO v_execution_result
                USING v_new_state_data;
                
                -- Merge result into state
                IF v_execution_result IS NOT NULL THEN
                    v_new_state_data := v_new_state_data || v_execution_result;
                END IF;
            END IF;
            
        WHEN 'router' THEN
            -- Router just determines next node via conditional edges
            v_execution_result := jsonb_build_object('type', 'router');
            
        WHEN 'human' THEN
            -- Human-in-the-loop always interrupts
            v_should_interrupt := true;
            
            INSERT INTO aos_workflow.workflow_interrupt (
                run_id, state_id, node_name, interrupt_type, request_message
            ) VALUES (
                p_run_id, v_state.state_id, v_node.node_name, 'input',
                'Human input required at node: ' || v_node.node_name
            );
            
        ELSE
            RAISE EXCEPTION 'Unknown node type: %', v_node.node_type;
    END CASE;
    
    -- Check interrupt_after
    IF v_node.interrupt_after AND NOT v_should_interrupt THEN
        v_should_interrupt := true;
        
        INSERT INTO aos_workflow.workflow_interrupt (
            run_id, state_id, node_name, interrupt_type, request_message
        ) VALUES (
            p_run_id, v_state.state_id, v_node.node_name, 'review',
            'Review required after executing node: ' || v_node.node_name
        );
    END IF;
    
    -- If interrupted, update run status and return
    IF v_should_interrupt THEN
        UPDATE aos_core.run SET status = 'interrupted' WHERE run_id = p_run_id;
        
        PERFORM aos_core.log_event(p_run_id, 'interrupted', jsonb_build_object(
            'node', v_node.node_name,
            'reason', CASE WHEN v_node.node_type = 'human' THEN 'human_input' ELSE 'interrupt_after' END
        ));
        
        RETURN jsonb_build_object(
            'status', 'interrupted',
            'node', v_node.node_name,
            'checkpoint_version', v_state.checkpoint_version
        );
    END IF;
    
    -- Determine next node via edges
    v_next_node := NULL;
    
    FOR v_edge IN
        SELECT * FROM aos_workflow.workflow_graph_edge
        WHERE graph_id = v_state.graph_id AND from_node = v_state.current_node
        ORDER BY priority DESC
    LOOP
        IF v_edge.is_conditional THEN
            -- Evaluate condition
            IF v_edge.condition_function IS NOT NULL THEN
                EXECUTE format('SELECT %s($1)', v_edge.condition_function)
                INTO v_next_node
                USING v_new_state_data;
                
                IF v_next_node IS NOT NULL THEN
                    v_next_node := v_edge.to_node;
                    EXIT;
                END IF;
            ELSIF v_edge.condition_expression IS NOT NULL THEN
                -- Evaluate SQL expression
                EXECUTE format('SELECT CASE WHEN %s THEN $1 ELSE NULL END', v_edge.condition_expression)
                INTO v_next_node
                USING v_edge.to_node;
                
                IF v_next_node IS NOT NULL THEN
                    EXIT;
                END IF;
            ELSIF v_edge.condition_value IS NOT NULL THEN
                -- Match against state value
                IF v_new_state_data @> v_edge.condition_value THEN
                    v_next_node := v_edge.to_node;
                    EXIT;
                END IF;
            END IF;
        ELSE
            -- Non-conditional edge
            v_next_node := v_edge.to_node;
            EXIT;
        END IF;
    END LOOP;
    
    IF v_next_node IS NULL THEN
        -- No valid edge found, check if current node is an exit
        IF v_state.current_node = ANY(v_graph.exit_nodes) THEN
            v_next_node := v_state.current_node;
        ELSE
            RAISE EXCEPTION 'No valid edge from node: %', v_state.current_node;
        END IF;
    END IF;
    
    -- Execute post_node hooks
    v_hooks_result := aos_policy.execute_hooks(
        'post_node',
        jsonb_build_object(
            'run_id', p_run_id,
            'node_name', v_node.node_name,
            'next_node', v_next_node,
            'state', v_new_state_data,
            'result', v_execution_result
        ),
        v_run.tenant_id
    );
    
    -- Calculate duration
    v_duration_ms := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000;
    
    -- Log node end
    PERFORM aos_core.log_event(p_run_id, 'node_end', jsonb_build_object(
        'node', v_node.node_name,
        'next_node', v_next_node,
        'result', v_execution_result
    ), v_node.node_name, NULL, v_duration_ms);
    
    -- Create new checkpoint
    v_new_checkpoint_version := v_state.checkpoint_version + 1;
    
    INSERT INTO aos_workflow.workflow_state (
        run_id, graph_id, checkpoint_version, current_node, previous_node,
        state_data, messages, parent_state_id
    ) VALUES (
        p_run_id, v_state.graph_id, v_new_checkpoint_version, v_next_node, v_state.current_node,
        v_new_state_data, v_new_messages, v_state.state_id
    );
    
    -- Update run stats
    UPDATE aos_core.run
    SET total_steps = total_steps + 1
    WHERE run_id = p_run_id;
    
    RETURN jsonb_build_object(
        'status', 'stepped',
        'previous_node', v_state.current_node,
        'current_node', v_next_node,
        'checkpoint_version', v_new_checkpoint_version,
        'state', v_new_state_data,
        'duration_ms', v_duration_ms
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: resume_graph
-- Purpose: Resume a workflow after an interrupt
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.resume_graph(
    p_run_id uuid,
    p_from_checkpoint_version int DEFAULT NULL,
    p_state_patch jsonb DEFAULT NULL,
    p_resolved_by uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_run aos_core.run;
    v_state aos_workflow.workflow_state;
    v_interrupt aos_workflow.workflow_interrupt;
    v_new_state_data jsonb;
BEGIN
    -- Get run
    SELECT * INTO v_run FROM aos_core.run WHERE run_id = p_run_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Run not found: %', p_run_id;
    END IF;
    
    IF v_run.status != 'interrupted' THEN
        RAISE EXCEPTION 'Run is not interrupted: %', v_run.status;
    END IF;
    
    -- Resolve any pending interrupts
    UPDATE aos_workflow.workflow_interrupt
    SET status = 'resolved',
        resolved_by = p_resolved_by,
        resolved_at = now(),
        changes = p_state_patch
    WHERE run_id = p_run_id AND status = 'pending'
    RETURNING * INTO v_interrupt;
    
    -- Get state checkpoint (either specified or latest)
    IF p_from_checkpoint_version IS NOT NULL THEN
        SELECT * INTO v_state
        FROM aos_workflow.workflow_state
        WHERE run_id = p_run_id AND checkpoint_version = p_from_checkpoint_version;
    ELSE
        SELECT * INTO v_state
        FROM aos_workflow.workflow_state
        WHERE run_id = p_run_id
        ORDER BY checkpoint_version DESC
        LIMIT 1;
    END IF;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'State checkpoint not found';
    END IF;
    
    -- Apply state patch if provided
    IF p_state_patch IS NOT NULL THEN
        v_new_state_data := v_state.state_data || p_state_patch;
        
        -- Create new checkpoint with patched state
        INSERT INTO aos_workflow.workflow_state (
            run_id, graph_id, checkpoint_version, current_node, previous_node,
            state_data, messages, parent_state_id
        ) VALUES (
            p_run_id, v_state.graph_id, v_state.checkpoint_version + 1, v_state.current_node, v_state.previous_node,
            v_new_state_data, v_state.messages, v_state.state_id
        );
    END IF;
    
    -- Update run status
    UPDATE aos_core.run SET status = 'running' WHERE run_id = p_run_id;
    
    -- Log event
    PERFORM aos_core.log_event(p_run_id, 'resumed', jsonb_build_object(
        'from_checkpoint', COALESCE(p_from_checkpoint_version, v_state.checkpoint_version),
        'state_patched', p_state_patch IS NOT NULL,
        'resolved_by', p_resolved_by
    ));
    
    RETURN jsonb_build_object(
        'status', 'resumed',
        'run_id', p_run_id,
        'checkpoint_version', v_state.checkpoint_version + CASE WHEN p_state_patch IS NOT NULL THEN 1 ELSE 0 END
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_state_history
-- Purpose: Get checkpoint history for time-travel debugging
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.get_state_history(
    p_run_id uuid,
    p_limit int DEFAULT 10
)
RETURNS jsonb[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_result jsonb[];
BEGIN
    SELECT array_agg(
        jsonb_build_object(
            'checkpoint_version', checkpoint_version,
            'current_node', current_node,
            'previous_node', previous_node,
            'state_data', state_data,
            'messages', messages,
            'created_at', created_at,
            'is_final', is_final
        ) ORDER BY checkpoint_version DESC
    ) INTO v_result
    FROM aos_workflow.workflow_state
    WHERE run_id = p_run_id
    LIMIT p_limit;
    
    RETURN COALESCE(v_result, ARRAY[]::jsonb[]);
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: run_to_completion
-- Purpose: Run the workflow until completion or interrupt (with max steps)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.run_to_completion(
    p_run_id uuid,
    p_max_steps int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_step_result jsonb;
    v_step_count int := 0;
BEGIN
    LOOP
        v_step_result := aos_workflow.step_graph(p_run_id);
        v_step_count := v_step_count + 1;
        
        -- Check termination conditions
        IF v_step_result->>'status' IN ('completed', 'interrupted', 'aborted') THEN
            EXIT;
        END IF;
        
        IF v_step_count >= p_max_steps THEN
            -- Update run status
            UPDATE aos_core.run SET status = 'failed', 
                error_info = jsonb_build_object('error', 'Max steps exceeded')
            WHERE run_id = p_run_id;
            
            RETURN jsonb_build_object(
                'status', 'failed',
                'reason', 'max_steps_exceeded',
                'steps_executed', v_step_count
            );
        END IF;
    END LOOP;
    
    RETURN v_step_result || jsonb_build_object('steps_executed', v_step_count);
END;
$$;

COMMENT ON FUNCTION aos_workflow.create_graph IS 'Create a new workflow graph with nodes and edges';
COMMENT ON FUNCTION aos_workflow.start_graph_run IS 'Start a new workflow run';
COMMENT ON FUNCTION aos_workflow.step_graph IS 'Execute a single step in the workflow';
COMMENT ON FUNCTION aos_workflow.resume_graph IS 'Resume a workflow after an interrupt';
COMMENT ON FUNCTION aos_workflow.get_state_history IS 'Get checkpoint history for time-travel';
COMMENT ON FUNCTION aos_workflow.run_to_completion IS 'Run workflow until completion or interrupt';
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Functions: RAG Retrieval (Hybrid Search)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: retrieve
-- Purpose: Hybrid RAG retrieval (tsvector + vector similarity)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_kg.retrieve(
    p_query text,
    p_tenant_id uuid DEFAULT NULL,
    p_top_k int DEFAULT 5,
    p_hybrid_weight float DEFAULT 0.5,
    p_query_embedding vector(1536) DEFAULT NULL,
    p_min_similarity float DEFAULT 0.5,
    p_source_filter text DEFAULT NULL,
    p_metadata_filter jsonb DEFAULT NULL
)
RETURNS jsonb[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_tenant_id uuid;
    v_tsquery tsquery;
    v_results jsonb[];
    v_fts_results jsonb[];
    v_vector_results jsonb[];
    v_combined_scores jsonb := '{}'::jsonb;
    v_doc_id uuid;
    v_score float;
    v_rec record;
BEGIN
    v_tenant_id := COALESCE(p_tenant_id, aos_auth.current_tenant());
    v_tsquery := websearch_to_tsquery('english', p_query);
    
    -- Full-text search results
    SELECT array_agg(jsonb_build_object(
        'doc_id', doc_id,
        'title', title,
        'content', substring(content, 1, 500),
        'source', source,
        'fts_score', rank,
        'headline', headline
    )) INTO v_fts_results
    FROM (
        SELECT 
            d.doc_id,
            d.title,
            d.content,
            d.source,
            ts_rank_cd(d.tsvector, v_tsquery) as rank,
            ts_headline('english', d.content, v_tsquery, 
                'MaxWords=50, MinWords=20, StartSel=**, StopSel=**') as headline
        FROM aos_kg.doc d
        WHERE d.tsvector @@ v_tsquery
          AND (v_tenant_id IS NULL OR d.tenant_id = v_tenant_id)
          AND (p_source_filter IS NULL OR d.source = p_source_filter)
          AND (p_metadata_filter IS NULL OR d.metadata @> p_metadata_filter)
          AND d.is_latest = true
        ORDER BY rank DESC
        LIMIT p_top_k * 2  -- Get more for merging
    ) sub;
    
    -- Vector similarity search (if embedding provided)
    IF p_query_embedding IS NOT NULL THEN
        SELECT array_agg(jsonb_build_object(
            'doc_id', doc_id,
            'chunk_index', chunk_index,
            'chunk_text', chunk_text,
            'vector_score', similarity
        )) INTO v_vector_results
        FROM (
            SELECT 
                e.doc_id,
                e.chunk_index,
                e.chunk_text,
                (1 - (e.embedding <=> p_query_embedding))::float as similarity
            FROM aos_embed.embedding e
            JOIN aos_kg.doc d ON d.doc_id = e.doc_id
            WHERE (v_tenant_id IS NULL OR d.tenant_id = v_tenant_id)
              AND (p_source_filter IS NULL OR d.source = p_source_filter)
              AND (1 - (e.embedding <=> p_query_embedding)) >= p_min_similarity
            ORDER BY e.embedding <=> p_query_embedding
            LIMIT p_top_k * 2
        ) sub;
    END IF;
    
    -- Combine results using hybrid scoring
    -- Score = (1 - hybrid_weight) * normalized_fts_score + hybrid_weight * vector_score
    
    -- Process FTS results
    IF v_fts_results IS NOT NULL THEN
        FOR v_rec IN
            SELECT * FROM jsonb_array_elements(to_jsonb(v_fts_results))
        LOOP
            v_doc_id := (v_rec.value->>'doc_id')::uuid;
            v_score := (v_rec.value->>'fts_score')::float * (1 - p_hybrid_weight);
            
            v_combined_scores := v_combined_scores || jsonb_build_object(
                v_doc_id::text,
                jsonb_build_object(
                    'fts_score', v_rec.value->>'fts_score',
                    'combined_score', v_score,
                    'data', v_rec.value
                )
            );
        END LOOP;
    END IF;
    
    -- Process vector results and merge
    IF v_vector_results IS NOT NULL THEN
        FOR v_rec IN
            SELECT * FROM jsonb_array_elements(to_jsonb(v_vector_results))
        LOOP
            v_doc_id := (v_rec.value->>'doc_id')::uuid;
            v_score := (v_rec.value->>'vector_score')::float * p_hybrid_weight;
            
            IF v_combined_scores ? v_doc_id::text THEN
                -- Add vector score to existing entry
                v_combined_scores := jsonb_set(
                    v_combined_scores,
                    ARRAY[v_doc_id::text, 'vector_score'],
                    to_jsonb(v_rec.value->>'vector_score')
                );
                v_combined_scores := jsonb_set(
                    v_combined_scores,
                    ARRAY[v_doc_id::text, 'combined_score'],
                    to_jsonb(
                        (v_combined_scores->v_doc_id::text->>'combined_score')::float + v_score
                    )
                );
            ELSE
                v_combined_scores := v_combined_scores || jsonb_build_object(
                    v_doc_id::text,
                    jsonb_build_object(
                        'vector_score', v_rec.value->>'vector_score',
                        'combined_score', v_score,
                        'data', v_rec.value
                    )
                );
            END IF;
        END LOOP;
    END IF;
    
    -- Sort by combined score and return top_k
    SELECT array_agg(value ORDER BY (value->>'combined_score')::float DESC)
    INTO v_results
    FROM jsonb_each(v_combined_scores)
    LIMIT p_top_k;
    
    RETURN COALESCE(v_results, ARRAY[]::jsonb[]);
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: retrieve_with_context
-- Purpose: Retrieve documents with surrounding context for RAG
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_kg.retrieve_with_context(
    p_query text,
    p_tenant_id uuid DEFAULT NULL,
    p_top_k int DEFAULT 3,
    p_context_window int DEFAULT 1,  -- Number of surrounding chunks to include
    p_query_embedding vector(1536) DEFAULT NULL
)
RETURNS jsonb[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_results jsonb[];
    v_retrieval_results jsonb[];
    v_rec record;
    v_context_chunks text[];
    v_doc_id uuid;
    v_chunk_index int;
BEGIN
    -- Get initial retrieval results
    v_retrieval_results := aos_kg.retrieve(
        p_query, p_tenant_id, p_top_k, 0.5, p_query_embedding
    );
    
    -- Expand each result with context
    FOR v_rec IN
        SELECT * FROM jsonb_array_elements(to_jsonb(v_retrieval_results))
    LOOP
        v_doc_id := (v_rec.value->'data'->>'doc_id')::uuid;
        v_chunk_index := COALESCE((v_rec.value->'data'->>'chunk_index')::int, 0);
        
        -- Get surrounding chunks
        SELECT array_agg(chunk_text ORDER BY chunk_index)
        INTO v_context_chunks
        FROM aos_embed.embedding
        WHERE doc_id = v_doc_id
          AND chunk_index BETWEEN (v_chunk_index - p_context_window) AND (v_chunk_index + p_context_window);
        
        v_results := array_append(v_results, v_rec.value || jsonb_build_object(
            'context_chunks', v_context_chunks,
            'full_context', array_to_string(v_context_chunks, ' ')
        ));
    END LOOP;
    
    RETURN COALESCE(v_results, ARRAY[]::jsonb[]);
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: add_document
-- Purpose: Add a document and queue for embedding
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_kg.add_document(
    p_content text,
    p_tenant_id uuid DEFAULT NULL,
    p_title text DEFAULT NULL,
    p_source text DEFAULT NULL,
    p_source_url text DEFAULT NULL,
    p_metadata jsonb DEFAULT '{}'::jsonb,
    p_run_id uuid DEFAULT NULL,
    p_auto_embed bool DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_tenant_id uuid;
    v_doc_id uuid;
BEGIN
    v_tenant_id := COALESCE(p_tenant_id, aos_auth.current_tenant());
    
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Tenant ID is required';
    END IF;
    
    -- Insert document
    INSERT INTO aos_kg.doc (
        tenant_id, run_id, content, title, source, source_url, metadata
    ) VALUES (
        v_tenant_id, p_run_id, p_content, p_title, p_source, p_source_url, p_metadata
    )
    RETURNING doc_id INTO v_doc_id;
    
    -- Queue for embedding if requested
    IF p_auto_embed THEN
        INSERT INTO aos_embed.job (doc_id, tenant_id, run_id)
        VALUES (v_doc_id, v_tenant_id, p_run_id);
    END IF;
    
    RETURN v_doc_id;
END;
$$;

COMMENT ON FUNCTION aos_kg.retrieve IS 'Hybrid RAG retrieval combining full-text search and vector similarity';
COMMENT ON FUNCTION aos_kg.retrieve_with_context IS 'Retrieve documents with surrounding context chunks';
COMMENT ON FUNCTION aos_kg.add_document IS 'Add a document and optionally queue for embedding';
-- ============================================================================
-- pgAgentOS: Agent Loop Engine
-- Core functions for interacting with external execution engine
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: run_turn
-- Purpose: Execute Turn (Agent Loop: Think → Tool → Observe → Repeat)
-- 
-- This function is called by the runtime that interfaces with the external LLM.
-- PostgreSQL manages only state and recording.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.run_turn(p_turn_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_turn aos_agent.turn;
    v_conversation aos_agent.conversation;
    v_agent aos_agent.agent;
    v_persona aos_persona.persona;
    v_messages jsonb[];
    v_tools jsonb[];
    v_system_prompt text;
    v_effective_params jsonb;
BEGIN
    -- Get Turn Info
    SELECT * INTO v_turn FROM aos_agent.turn WHERE turn_id = p_turn_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Turn not found: %', p_turn_id;
    END IF;
    
    -- Conversation Info
    SELECT * INTO v_conversation 
    FROM aos_agent.conversation WHERE conversation_id = v_turn.conversation_id;
    
    -- Agent Info
    SELECT * INTO v_agent FROM aos_agent.agent WHERE agent_id = v_conversation.agent_id;
    
    -- Persona Info
    IF v_agent.persona_id IS NOT NULL THEN
        SELECT * INTO v_persona FROM aos_persona.persona WHERE persona_id = v_agent.persona_id;
        v_system_prompt := v_persona.system_prompt;
        v_effective_params := aos_persona.get_effective_params(v_agent.persona_id);
    ELSE
        v_system_prompt := 'You are a helpful assistant.';
        v_effective_params := '{}'::jsonb;
    END IF;
    
    -- Assemble Chat History
    SELECT array_agg(
        CASE 
            WHEN row_number() OVER (ORDER BY turn_number) % 2 = 1 THEN
                jsonb_build_object('role', 'user', 'content', user_message)
            ELSE
                jsonb_build_object('role', 'assistant', 'content', assistant_message)
        END
    ) INTO v_messages
    FROM aos_agent.turn
    WHERE conversation_id = v_turn.conversation_id
      AND turn_number <= v_turn.turn_number
      AND (assistant_message IS NOT NULL OR turn_number = v_turn.turn_number);
    
    -- Generate Tool Schema
    SELECT array_agg(
        jsonb_build_object(
            'type', 'function',
            'function', jsonb_build_object(
                'name', s.skill_key,
                'description', s.description,
                'parameters', si.input_schema
            )
        )
    ) INTO v_tools
    FROM unnest(v_agent.tools) AS tool_key
    JOIN aos_skills.skill s ON s.skill_key = tool_key
    LEFT JOIN aos_skills.skill_impl si ON si.skill_key = s.skill_key AND si.enabled = true;
    
    -- Return execution info (for external runtime to call LLM)
    RETURN jsonb_build_object(
        'turn_id', p_turn_id,
        'conversation_id', v_turn.conversation_id,
        'agent', jsonb_build_object(
            'agent_id', v_agent.agent_id,
            'name', v_agent.name,
            'config', v_agent.config
        ),
        'system_prompt', v_system_prompt,
        'messages', v_messages,
        'tools', COALESCE(v_tools, ARRAY[]::jsonb[]),
        'parameters', v_effective_params,
        'current_iteration', v_turn.iteration_count
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: process_tool_call
-- Purpose: Process tool call (Wait if approval needed)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.process_tool_call(
    p_turn_id uuid,
    p_tool_name text,
    p_tool_input jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_agent aos_agent.agent;
    v_conversation aos_agent.conversation;
    v_step_id uuid;
    v_requires_approval bool;
    v_skill aos_skills.skill;
BEGIN
    -- Check Agent Config
    SELECT a.* INTO v_agent
    FROM aos_agent.turn t
    JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
    JOIN aos_agent.agent a ON a.agent_id = c.agent_id
    WHERE t.turn_id = p_turn_id;
    
    -- Check Skill
    SELECT * INTO v_skill FROM aos_skills.skill WHERE skill_key = p_tool_name;
    
    -- Determine Approval Requirement
    v_requires_approval := 
        (v_agent.config->>'auto_approve_tools')::bool = false
        OR (v_skill.risk_level IN ('high', 'critical'));
    
    -- Record Tool Call Step
    v_step_id := aos_agent.record_step(
        p_turn_id,
        'tool_call',
        jsonb_build_object(
            'tool', p_tool_name,
            'input', p_tool_input,
            'requires_approval', v_requires_approval
        ),
        CASE WHEN v_requires_approval THEN 'pending' ELSE 'completed' END
    );
    
    -- Update Turn Status if Approval Needed
    IF v_requires_approval THEN
        UPDATE aos_agent.turn
        SET status = 'waiting_tool'
        WHERE turn_id = p_turn_id;
        
        RETURN jsonb_build_object(
            'status', 'awaiting_approval',
            'step_id', v_step_id,
            'tool', p_tool_name
        );
    END IF;
    
    -- Ready to Execute if No Approval Needed
    RETURN jsonb_build_object(
        'status', 'approved',
        'step_id', v_step_id,
        'tool', p_tool_name,
        'input', p_tool_input
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: record_tool_result
-- Purpose: Record Tool Execution Result
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.record_tool_result(
    p_turn_id uuid,
    p_tool_name text,
    p_output jsonb,
    p_success bool DEFAULT true,
    p_error_message text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_step_id uuid;
BEGIN
    v_step_id := aos_agent.record_step(
        p_turn_id,
        'tool_result',
        jsonb_build_object(
            'tool', p_tool_name,
            'output', p_output,
            'success', p_success,
            'error', p_error_message
        ),
        CASE WHEN p_success THEN 'completed' ELSE 'failed' END
    );
    
    -- Return to Processing State (Next Thought Step)
    UPDATE aos_agent.turn
    SET status = 'processing',
        iteration_count = iteration_count + 1
    WHERE turn_id = p_turn_id;
    
    RETURN v_step_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: record_thinking
-- Purpose: Record Agent Thinking Process (Chain of Thought)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.record_thinking(
    p_turn_id uuid,
    p_reasoning text,
    p_next_action text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN aos_agent.record_step(
        p_turn_id,
        'think',
        jsonb_build_object(
            'reasoning', p_reasoning,
            'next_action', p_next_action
        )
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_turn_state
-- Purpose: Get Current Turn State (For Debugging/Monitoring)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.get_turn_state(p_turn_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_turn aos_agent.turn;
    v_steps jsonb[];
    v_pending_approval uuid;
BEGIN
    SELECT * INTO v_turn FROM aos_agent.turn WHERE turn_id = p_turn_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Turn not found: %', p_turn_id;
    END IF;
    
    -- Get All Steps
    SELECT array_agg(jsonb_build_object(
        'step_id', step_id,
        'step_number', step_number,
        'step_type', step_type,
        'content', content,
        'status', status,
        'created_at', created_at,
        'duration_ms', duration_ms
    ) ORDER BY step_number) INTO v_steps
    FROM aos_agent.step WHERE turn_id = p_turn_id;
    
    -- Find Step Pending Approval
    SELECT step_id INTO v_pending_approval
    FROM aos_agent.step
    WHERE turn_id = p_turn_id AND status = 'pending'
    ORDER BY step_number
    LIMIT 1;
    
    RETURN jsonb_build_object(
        'turn_id', v_turn.turn_id,
        'turn_number', v_turn.turn_number,
        'status', v_turn.status,
        'user_message', v_turn.user_message,
        'assistant_message', v_turn.assistant_message,
        'iteration_count', v_turn.iteration_count,
        'steps', COALESCE(v_steps, ARRAY[]::jsonb[]),
        'step_count', array_length(v_steps, 1),
        'pending_approval_step', v_pending_approval,
        'started_at', v_turn.started_at,
        'duration_ms', EXTRACT(EPOCH FROM (COALESCE(v_turn.completed_at, now()) - v_turn.started_at)) * 1000
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_conversation_history
-- Purpose: Get Full Conversation History
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.get_conversation_history(
    p_conversation_id uuid,
    p_include_steps bool DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_conversation aos_agent.conversation;
    v_turns jsonb[];
BEGIN
    SELECT * INTO v_conversation 
    FROM aos_agent.conversation WHERE conversation_id = p_conversation_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Conversation not found: %', p_conversation_id;
    END IF;
    
    IF p_include_steps THEN
        SELECT array_agg(aos_agent.get_turn_state(turn_id) ORDER BY turn_number)
        INTO v_turns
        FROM aos_agent.turn WHERE conversation_id = p_conversation_id;
    ELSE
        SELECT array_agg(jsonb_build_object(
            'turn_number', turn_number,
            'user_message', user_message,
            'assistant_message', assistant_message,
            'status', status
        ) ORDER BY turn_number) INTO v_turns
        FROM aos_agent.turn WHERE conversation_id = p_conversation_id;
    END IF;
    
    RETURN jsonb_build_object(
        'conversation_id', v_conversation.conversation_id,
        'agent_id', v_conversation.agent_id,
        'status', v_conversation.status,
        'total_turns', v_conversation.total_turns,
        'total_tokens', v_conversation.total_tokens,
        'total_cost_usd', v_conversation.total_cost_usd,
        'turns', COALESCE(v_turns, ARRAY[]::jsonb[]),
        'started_at', v_conversation.started_at,
        'last_activity_at', v_conversation.last_activity_at
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: pause_conversation
-- Purpose: Pause Conversation (Admin Intervention)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.pause_conversation(
    p_conversation_id uuid,
    p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE aos_agent.conversation
    SET status = 'paused'
    WHERE conversation_id = p_conversation_id;
    
    -- Pause processing turn
    UPDATE aos_agent.turn
    SET status = 'waiting_human'
    WHERE conversation_id = p_conversation_id AND status = 'processing';
    
    IF p_reason IS NOT NULL THEN
        PERFORM aos_agent.record_step(
            (SELECT turn_id FROM aos_agent.turn 
             WHERE conversation_id = p_conversation_id 
             ORDER BY turn_number DESC LIMIT 1),
            'pause',
            jsonb_build_object('reason', p_reason, 'paused_by', 'admin')
        );
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: resume_conversation
-- Purpose: Resume Conversation
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.resume_conversation(p_conversation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE aos_agent.conversation
    SET status = 'active'
    WHERE conversation_id = p_conversation_id AND status = 'paused';
    
    -- Resume waiting turn
    UPDATE aos_agent.turn
    SET status = 'processing'
    WHERE conversation_id = p_conversation_id AND status = 'waiting_human';
END;
$$;

COMMENT ON FUNCTION aos_agent.run_turn IS 'Returns info for turn execution (for external LLM runtime)';
COMMENT ON FUNCTION aos_agent.process_tool_call IS 'Process tool call (includes approval flow)';
COMMENT ON FUNCTION aos_agent.record_tool_result IS 'Record tool execution result';
COMMENT ON FUNCTION aos_agent.record_thinking IS 'Record agent thinking process';
COMMENT ON FUNCTION aos_agent.get_turn_state IS 'Get turn state';
COMMENT ON FUNCTION aos_agent.get_conversation_history IS 'Get conversation history';
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Views: System Views for Monitoring and Debugging
-- ============================================================================

-- ----------------------------------------------------------------------------
-- View: agent_permissions_view
-- Purpose: Show principals with their roles and skill permissions
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_auth.agent_permissions_view AS
SELECT 
    p.principal_id,
    p.tenant_id,
    t.name as tenant_name,
    p.principal_type,
    p.display_name as principal_name,
    p.db_role_name,
    p.is_active as principal_active,
    array_agg(DISTINCT rg.role_key) FILTER (WHERE rg.role_key IS NOT NULL) as roles,
    array_agg(DISTINCT rs.skill_key) FILTER (WHERE rs.skill_key IS NOT NULL) as allowed_skills
FROM aos_auth.principal p
JOIN aos_auth.tenant t ON t.tenant_id = p.tenant_id
LEFT JOIN aos_auth.role_grant rg ON rg.principal_id = p.principal_id 
    AND rg.is_active = true 
    AND (rg.expires_at IS NULL OR rg.expires_at > now())
LEFT JOIN aos_skills.role_skill rs ON rs.role_key = rg.role_key
    AND rs.is_active = true
GROUP BY p.principal_id, p.tenant_id, t.name, p.principal_type, p.display_name, p.db_role_name, p.is_active;

COMMENT ON VIEW aos_auth.agent_permissions_view IS 'Principals with their roles and skill permissions';

-- ----------------------------------------------------------------------------
-- View: active_graph_runs_view
-- Purpose: Show currently running workflow executions
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_workflow.active_graph_runs_view AS
SELECT 
    r.run_id,
    r.tenant_id,
    t.name as tenant_name,
    r.graph_id,
    g.name as graph_name,
    g.version as graph_version,
    r.status,
    r.started_at,
    EXTRACT(EPOCH FROM (now() - r.started_at))::int as runtime_seconds,
    r.total_steps,
    ws.current_node,
    ws.checkpoint_version,
    r.metadata,
    p.display_name as principal_name,
    per.name as persona_name
FROM aos_core.run r
JOIN aos_auth.tenant t ON t.tenant_id = r.tenant_id
LEFT JOIN aos_workflow.workflow_graph g ON g.graph_id = r.graph_id
LEFT JOIN aos_auth.principal p ON p.principal_id = r.principal_id
LEFT JOIN aos_persona.persona per ON per.persona_id = r.persona_id
LEFT JOIN LATERAL (
    SELECT current_node, checkpoint_version
    FROM aos_workflow.workflow_state
    WHERE run_id = r.run_id
    ORDER BY checkpoint_version DESC
    LIMIT 1
) ws ON true
WHERE r.status IN ('running', 'pending', 'interrupted');

COMMENT ON VIEW aos_workflow.active_graph_runs_view IS 'Currently running workflow executions';

-- ----------------------------------------------------------------------------
-- View: state_history_view
-- Purpose: Time-travel view for workflow state checkpoints
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_workflow.state_history_view AS
SELECT 
    ws.state_id,
    ws.run_id,
    r.graph_id,
    g.name as graph_name,
    ws.checkpoint_version,
    ws.current_node,
    ws.previous_node,
    ws.state_data,
    ws.messages,
    ws.created_at,
    ws.is_final,
    LAG(ws.current_node) OVER (PARTITION BY ws.run_id ORDER BY ws.checkpoint_version) as came_from,
    LEAD(ws.current_node) OVER (PARTITION BY ws.run_id ORDER BY ws.checkpoint_version) as went_to
FROM aos_workflow.workflow_state ws
JOIN aos_core.run r ON r.run_id = ws.run_id
LEFT JOIN aos_workflow.workflow_graph g ON g.graph_id = ws.graph_id
ORDER BY ws.run_id, ws.checkpoint_version;

COMMENT ON VIEW aos_workflow.state_history_view IS 'Time-travel view for workflow state checkpoints';

-- ----------------------------------------------------------------------------
-- View: pending_interrupts_view
-- Purpose: Show pending human-in-the-loop interrupts
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_workflow.pending_interrupts_view AS
SELECT 
    wi.interrupt_id,
    wi.run_id,
    r.tenant_id,
    t.name as tenant_name,
    g.name as graph_name,
    wi.node_name,
    wi.interrupt_type,
    wi.status,
    wi.request_message,
    wi.request_data,
    wi.created_at,
    EXTRACT(EPOCH FROM (now() - wi.created_at))::int as waiting_seconds,
    wi.expires_at,
    CASE WHEN wi.expires_at IS NOT NULL AND wi.expires_at < now() THEN true ELSE false END as is_expired,
    p.display_name as requested_by_name
FROM aos_workflow.workflow_interrupt wi
JOIN aos_core.run r ON r.run_id = wi.run_id
JOIN aos_auth.tenant t ON t.tenant_id = r.tenant_id
LEFT JOIN aos_workflow.workflow_graph g ON g.graph_id = r.graph_id
LEFT JOIN aos_auth.principal p ON p.principal_id = wi.requested_by
WHERE wi.status = 'pending';

COMMENT ON VIEW aos_workflow.pending_interrupts_view IS 'Pending human-in-the-loop interrupts';

-- ----------------------------------------------------------------------------
-- View: recent_events_view
-- Purpose: Show recent events across all runs
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_core.recent_events_view AS
SELECT 
    el.event_id,
    el.run_id,
    r.tenant_id,
    el.event_type,
    el.event_subtype,
    el.node_name,
    el.payload,
    el.created_at,
    el.duration_ms,
    aos_core.format_duration(el.duration_ms) as duration_formatted
FROM aos_core.event_log el
JOIN aos_core.run r ON r.run_id = el.run_id
ORDER BY el.created_at DESC;

COMMENT ON VIEW aos_core.recent_events_view IS 'Recent events across all runs';

-- ----------------------------------------------------------------------------
-- View: skill_usage_stats_view
-- Purpose: Show skill usage statistics
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_skills.skill_usage_stats_view AS
SELECT 
    se.skill_key,
    s.name as skill_name,
    s.category,
    count(*) as total_executions,
    count(*) FILTER (WHERE se.status = 'success') as successful,
    count(*) FILTER (WHERE se.status = 'failure') as failed,
    round((100.0 * count(*) FILTER (WHERE se.status = 'success') / NULLIF(count(*), 0))::numeric, 2) as success_rate,
    round(avg(se.duration_ms)::numeric, 2) as avg_duration_ms,
    round(percentile_cont(0.95) WITHIN GROUP (ORDER BY se.duration_ms)::numeric, 2) as p95_duration_ms,
    sum(se.tokens_used) as total_tokens,
    sum(se.cost_usd) as total_cost_usd,
    max(se.completed_at) as last_used_at
FROM aos_core.skill_execution se
JOIN aos_skills.skill s ON s.skill_key = se.skill_key
GROUP BY se.skill_key, s.name, s.category
ORDER BY total_executions DESC;

COMMENT ON VIEW aos_skills.skill_usage_stats_view IS 'Skill usage statistics';

-- ----------------------------------------------------------------------------
-- View: embedding_queue_view
-- Purpose: Show embedding job queue status
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_embed.embedding_queue_view AS
SELECT 
    j.job_id,
    j.doc_id,
    d.title as doc_title,
    j.tenant_id,
    t.name as tenant_name,
    j.status,
    j.priority,
    j.attempts,
    j.max_attempts,
    j.model_name,
    j.created_at,
    j.started_at,
    j.completed_at,
    CASE 
        WHEN j.status = 'processing' THEN 
            EXTRACT(EPOCH FROM (now() - j.started_at))::int
        ELSE NULL
    END as processing_seconds,
    j.error_message
FROM aos_embed.job j
JOIN aos_kg.doc d ON d.doc_id = j.doc_id
JOIN aos_auth.tenant t ON t.tenant_id = j.tenant_id
ORDER BY 
    CASE j.status 
        WHEN 'processing' THEN 1 
        WHEN 'queued' THEN 2 
        ELSE 3 
    END,
    j.priority DESC,
    j.created_at;

COMMENT ON VIEW aos_embed.embedding_queue_view IS 'Embedding job queue status';

-- ----------------------------------------------------------------------------
-- View: model_registry_view
-- Purpose: Show available LLM models with their configurations
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_meta.model_registry_view AS
SELECT 
    m.model_id,
    m.provider,
    m.model_name,
    m.display_name,
    m.context_window,
    m.max_output_tokens,
    m.supports_vision,
    m.supports_function_calling,
    m.supports_streaming,
    m.default_params,
    m.is_active,
    count(DISTINCT p.persona_id) as personas_using,
    count(DISTINCT si.skill_key) as skills_using
FROM aos_meta.llm_model_registry m
LEFT JOIN aos_persona.persona p ON p.model_id = m.model_id AND p.is_active = true
LEFT JOIN aos_skills.skill_impl si ON si.model_id = m.model_id AND si.enabled = true
GROUP BY m.model_id
ORDER BY m.provider, m.model_name;

COMMENT ON VIEW aos_meta.model_registry_view IS 'Available LLM models with usage stats';

-- ----------------------------------------------------------------------------
-- View: egress_pending_approval_view
-- Purpose: Show egress requests pending approval
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_egress.pending_approval_view AS
SELECT 
    req.request_id,
    req.run_id,
    req.tenant_id,
    t.name as tenant_name,
    req.target_type,
    req.target,
    req.method,
    req.risk_level,
    req.risk_factors,
    req.created_at,
    EXTRACT(EPOCH FROM (now() - req.created_at))::int as waiting_seconds
FROM aos_egress.request req
JOIN aos_auth.tenant t ON t.tenant_id = req.tenant_id
WHERE req.status = 'pending' AND req.requires_approval = true
ORDER BY 
    CASE req.risk_level 
        WHEN 'critical' THEN 1 
        WHEN 'high' THEN 2 
        WHEN 'medium' THEN 3 
        ELSE 4 
    END,
    req.created_at;

COMMENT ON VIEW aos_egress.pending_approval_view IS 'Egress requests pending approval';
-- ============================================================================
-- pgAgentOS: Admin Dashboard Views & Functions
-- Views and functions for admin monitoring and intervention
-- ============================================================================

-- ============================================================================
-- REALTIME MONITORING VIEWS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- View: dashboard_overview
-- Purpose: Main Dashboard Overview
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.dashboard_overview AS
WITH stats AS (
    SELECT 
        a.tenant_id,
        count(DISTINCT a.agent_id) as total_agents,
        count(DISTINCT CASE WHEN c.status = 'active' THEN c.conversation_id END) as active_conversations,
        count(DISTINCT CASE WHEN t.status = 'processing' THEN t.turn_id END) as processing_turns,
        count(DISTINCT CASE WHEN t.status = 'waiting_tool' THEN t.turn_id END) as awaiting_approval,
        sum(t.tokens_used) as total_tokens_today,
        sum(t.cost_usd) as total_cost_today
    FROM aos_agent.agent a
    LEFT JOIN aos_agent.conversation c ON c.agent_id = a.agent_id
    LEFT JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id
        AND t.started_at > now() - interval '24 hours'
    GROUP BY a.tenant_id
)
SELECT 
    t.tenant_id,
    t.name as tenant_name,
    s.total_agents,
    s.active_conversations,
    s.processing_turns,
    s.awaiting_approval,
    s.total_tokens_today,
    s.total_cost_today
FROM aos_auth.tenant t
LEFT JOIN stats s ON s.tenant_id = t.tenant_id;

-- ----------------------------------------------------------------------------
-- View: realtime_steps
-- Purpose: Real-time Step Stream (Last 100)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.realtime_steps AS
SELECT 
    s.step_id,
    s.step_type,
    s.step_number,
    s.content,
    s.status,
    s.created_at,
    EXTRACT(EPOCH FROM (now() - s.created_at))::int as seconds_ago,
    t.turn_id,
    t.turn_number,
    SUBSTRING(t.user_message, 1, 100) as user_message_preview,
    c.conversation_id,
    a.agent_id,
    a.name as agent_name,
    a.display_name as agent_display_name,
    c.tenant_id
FROM aos_agent.step s
JOIN aos_agent.turn t ON t.turn_id = s.turn_id
JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
JOIN aos_agent.agent a ON a.agent_id = c.agent_id
ORDER BY s.created_at DESC
LIMIT 100;

-- ----------------------------------------------------------------------------
-- View: tool_call_queue
-- Purpose: Tool Call Approval Queue
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.tool_call_queue AS
SELECT 
    s.step_id,
    s.content->>'tool' as tool_name,
    s.content->'input' as tool_input,
    s.content->>'requires_approval' as requires_approval,
    s.created_at,
    EXTRACT(EPOCH FROM (now() - s.created_at))::int as waiting_seconds,
    t.user_message,
    a.name as agent_name,
    c.conversation_id,
    sk.risk_level,
    sk.description as tool_description
FROM aos_agent.step s
JOIN aos_agent.turn t ON t.turn_id = s.turn_id
JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
JOIN aos_agent.agent a ON a.agent_id = c.agent_id
LEFT JOIN aos_skills.skill sk ON sk.skill_key = s.content->>'tool'
WHERE s.step_type = 'tool_call' AND s.status = 'pending'
ORDER BY 
    CASE sk.risk_level 
        WHEN 'critical' THEN 1 
        WHEN 'high' THEN 2 
        WHEN 'medium' THEN 3 
        ELSE 4 
    END,
    s.created_at;

-- ----------------------------------------------------------------------------
-- View: thinking_trace
-- Purpose: Agent Thinking Process Trace
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.thinking_trace AS
SELECT 
    s.step_id,
    t.turn_id,
    t.turn_number,
    s.step_number,
    s.content->>'reasoning' as reasoning,
    s.content->>'next_action' as next_action,
    s.created_at,
    s.duration_ms,
    a.name as agent_name,
    c.conversation_id
FROM aos_agent.step s
JOIN aos_agent.turn t ON t.turn_id = s.turn_id
JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
JOIN aos_agent.agent a ON a.agent_id = c.agent_id
WHERE s.step_type = 'think'
ORDER BY c.conversation_id, t.turn_number, s.step_number;

-- ----------------------------------------------------------------------------
-- View: error_log
-- Purpose: Error Log
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.error_log AS
SELECT 
    s.step_id,
    s.content->>'type' as error_type,
    s.content->>'message' as error_message,
    (s.content->>'recoverable')::bool as is_recoverable,
    s.content->'details' as error_details,
    s.created_at,
    t.user_message,
    a.name as agent_name,
    c.conversation_id,
    c.tenant_id
FROM aos_agent.step s
JOIN aos_agent.turn t ON t.turn_id = s.turn_id
JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
JOIN aos_agent.agent a ON a.agent_id = c.agent_id
WHERE s.step_type = 'error'
ORDER BY s.created_at DESC;

-- ============================================================================
-- ADMIN INTERVENTION FUNCTIONS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: bulk_approve_tools
-- Purpose: Bulk approve tool calls
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.bulk_approve_tools(
    p_step_ids uuid[],
    p_admin_id uuid,
    p_note text DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_count int;
BEGIN
    UPDATE aos_agent.step
    SET status = 'approved',
        admin_feedback = jsonb_build_object(
            'action', 'approved',
            'by', p_admin_id,
            'note', p_note,
            'at', now(),
            'bulk', true
        ),
        completed_at = now()
    WHERE step_id = ANY(p_step_ids) 
      AND status = 'pending';
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    
    -- Update turn status
    UPDATE aos_agent.turn t
    SET status = 'processing'
    FROM aos_agent.step s
    WHERE s.step_id = ANY(p_step_ids)
      AND t.turn_id = s.turn_id
      AND t.status = 'waiting_tool';
    
    RETURN v_count;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: inject_message
-- Purpose: Admin injects message into conversation
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.inject_message(
    p_conversation_id uuid,
    p_message text,
    p_admin_id uuid,
    p_message_type text DEFAULT 'system'  -- 'system', 'context', 'override'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_turn_number int;
    v_step_id uuid;
    v_turn_id uuid;
BEGIN
    -- Find latest turn
    SELECT turn_id, turn_number INTO v_turn_id, v_turn_number
    FROM aos_agent.turn
    WHERE conversation_id = p_conversation_id
    ORDER BY turn_number DESC
    LIMIT 1;
    
    -- Record as System Message Step
    v_step_id := aos_agent.record_step(
        v_turn_id,
        'think',
        jsonb_build_object(
            'injected', true,
            'message_type', p_message_type,
            'content', p_message,
            'injected_by', p_admin_id
        )
    );
    
    -- Record Observation
    PERFORM aos_agent.add_observation(
        p_admin_id,
        'note',
        jsonb_build_object(
            'action', 'message_injected',
            'message', p_message,
            'type', p_message_type
        ),
        p_conversation_id => p_conversation_id,
        p_step_id => v_step_id
    );
    
    RETURN v_step_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: override_response
-- Purpose: Admin overrides agent response
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.override_response(
    p_turn_id uuid,
    p_new_response text,
    p_admin_id uuid,
    p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_old_response text;
BEGIN
    -- Save old response
    SELECT assistant_message INTO v_old_response
    FROM aos_agent.turn WHERE turn_id = p_turn_id;
    
    -- Update response
    UPDATE aos_agent.turn
    SET assistant_message = p_new_response
    WHERE turn_id = p_turn_id;
    
    -- Record Observation
    PERFORM aos_agent.add_observation(
        p_admin_id,
        'correction',
        jsonb_build_object(
            'original', v_old_response,
            'corrected', p_new_response,
            'reason', p_reason
        ),
        p_turn_id => p_turn_id
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: rate_turn
-- Purpose: Rate a turn
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.rate_turn(
    p_turn_id uuid,
    p_admin_id uuid,
    p_score int,  -- 1-5
    p_aspects jsonb DEFAULT NULL  -- {"accuracy": 5, "helpfulness": 4, ...}
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN aos_agent.add_observation(
        p_admin_id,
        'rating',
        jsonb_build_object(
            'score', p_score,
            'aspects', COALESCE(p_aspects, '{}'::jsonb)
        ),
        p_turn_id => p_turn_id
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: flag_issue
-- Purpose: Flag an issue
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.flag_issue(
    p_admin_id uuid,
    p_severity text,  -- 'info', 'warning', 'error', 'critical'
    p_reason text,
    p_step_id uuid DEFAULT NULL,
    p_turn_id uuid DEFAULT NULL,
    p_conversation_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN aos_agent.add_observation(
        p_admin_id,
        'flag',
        jsonb_build_object(
            'severity', p_severity,
            'reason', p_reason
        ),
        p_conversation_id => p_conversation_id,
        p_turn_id => p_turn_id,
        p_step_id => p_step_id
    );
END;
$$;

-- ============================================================================
-- ANALYTICS FUNCTIONS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: get_agent_analytics
-- Purpose: Get Agent Analytics
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.get_agent_analytics(
    p_agent_id uuid,
    p_days int DEFAULT 7
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
        'agent_id', p_agent_id,
        'period_days', p_days,
        'total_conversations', count(DISTINCT c.conversation_id),
        'total_turns', count(DISTINCT t.turn_id),
        'total_steps', count(DISTINCT s.step_id),
        'total_tokens', sum(t.tokens_used),
        'total_cost_usd', sum(t.cost_usd),
        'avg_turns_per_conversation', round(count(DISTINCT t.turn_id)::numeric / NULLIF(count(DISTINCT c.conversation_id), 0), 2),
        'avg_steps_per_turn', round(count(DISTINCT s.step_id)::numeric / NULLIF(count(DISTINCT t.turn_id), 0), 2),
        'avg_turn_duration_ms', round(avg(t.duration_ms)),
        'tool_usage', (
            SELECT jsonb_object_agg(tool_name, usage_count)
            FROM (
                SELECT s2.content->>'tool' as tool_name, count(*) as usage_count
                FROM aos_agent.step s2
                JOIN aos_agent.turn t2 ON t2.turn_id = s2.turn_id
                JOIN aos_agent.conversation c2 ON c2.conversation_id = t2.conversation_id
                WHERE c2.agent_id = p_agent_id
                  AND s2.step_type = 'tool_call'
                  AND s2.created_at > now() - (p_days || ' days')::interval
                GROUP BY s2.content->>'tool'
            ) sub
        ),
        'success_rate', round(
            (100.0 * count(*) FILTER (WHERE t.status = 'completed') / NULLIF(count(*), 0))::numeric, 2
        ),
        'ratings', (
            SELECT jsonb_build_object(
                'avg_score', round(avg((content->>'score')::numeric), 2),
                'count', count(*)
            )
            FROM aos_agent.observation o
            WHERE o.observation_type = 'rating'
              AND o.turn_id IN (
                  SELECT t3.turn_id FROM aos_agent.turn t3
                  JOIN aos_agent.conversation c3 ON c3.conversation_id = t3.conversation_id
                  WHERE c3.agent_id = p_agent_id
              )
          )
    ) INTO v_result
    FROM aos_agent.conversation c
    LEFT JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id
        AND t.started_at > now() - (p_days || ' days')::interval
    LEFT JOIN aos_agent.step s ON s.turn_id = t.turn_id
    WHERE c.agent_id = p_agent_id;
    
    RETURN v_result;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_hourly_activity
-- Purpose: Get hourly activity stats
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.get_hourly_activity(
    p_tenant_id uuid,
    p_days int DEFAULT 1
)
RETURNS TABLE (
    hour int,
    turn_count bigint,
    step_count bigint,
    token_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        EXTRACT(HOUR FROM t.started_at)::int as hour,
        count(DISTINCT t.turn_id) as turn_count,
        count(DISTINCT s.step_id) as step_count,
        sum(t.tokens_used) as token_count
    FROM aos_agent.turn t
    JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
    LEFT JOIN aos_agent.step s ON s.turn_id = t.turn_id
    WHERE c.tenant_id = p_tenant_id
      AND t.started_at > now() - (p_days || ' days')::interval
    GROUP BY EXTRACT(HOUR FROM t.started_at)
    ORDER BY hour;
END;
$$;

COMMENT ON VIEW aos_agent.dashboard_overview IS 'Main Dashboard Overview';
COMMENT ON VIEW aos_agent.realtime_steps IS 'Real-time Step Stream';
COMMENT ON VIEW aos_agent.tool_call_queue IS 'Tool Call Approval Queue';
COMMENT ON VIEW aos_agent.thinking_trace IS 'Agent Thinking Process Trace';
COMMENT ON FUNCTION aos_agent.bulk_approve_tools IS 'Bulk Approve Tool Calls';
COMMENT ON FUNCTION aos_agent.inject_message IS 'Inject Message into Conversation';
COMMENT ON FUNCTION aos_agent.override_response IS 'Override Agent Response';
COMMENT ON FUNCTION aos_agent.get_agent_analytics IS 'Get Agent Analytics';
-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- RLS: Row Level Security Policies
-- ============================================================================

-- Enable RLS on all tables
ALTER TABLE aos_auth.tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_auth.principal ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_auth.role_grant ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_persona.persona ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_skills.skill ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_skills.skill_impl ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_skills.role_skill ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.run ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.event_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.skill_execution ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.session_memory ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_workflow.workflow_graph ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_workflow.workflow_graph_node ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_workflow.workflow_graph_edge ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_workflow.workflow_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_workflow.workflow_interrupt ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_egress.request ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_egress.allowlist ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_kg.doc ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_kg.doc_relationship ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_embed.job ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_embed.embedding ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_collab.task ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_collab.run_link ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_collab.comment ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_policy.hooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_policy.policy_rule ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- Helper function: Check if current user is superuser or has admin role
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.is_admin()
RETURNS bool
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
BEGIN
    -- Superusers bypass RLS anyway, but let's be explicit
    IF current_setting('is_superuser', true) = 'on' THEN
        RETURN true;
    END IF;
    
    -- Check for admin role
    RETURN EXISTS (
        SELECT 1 FROM aos_auth.role_grant rg
        JOIN aos_auth.principal p ON p.principal_id = rg.principal_id
        WHERE p.db_role_name = current_user
          AND rg.role_key = 'admin'
          AND rg.is_active = true
          AND (rg.expires_at IS NULL OR rg.expires_at > now())
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Tenant Policies
-- ----------------------------------------------------------------------------
-- Tenants: visible to members of that tenant or admins
CREATE POLICY tenant_select_policy ON aos_auth.tenant
    FOR SELECT
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY tenant_modify_policy ON aos_auth.tenant
    FOR ALL
    USING (aos_auth.is_admin());

-- ----------------------------------------------------------------------------
-- Principal Policies
-- ----------------------------------------------------------------------------
CREATE POLICY principal_select_policy ON aos_auth.principal
    FOR SELECT
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY principal_modify_policy ON aos_auth.principal
    FOR ALL
    USING (aos_auth.is_admin());

-- ----------------------------------------------------------------------------
-- Role Grant Policies
-- ----------------------------------------------------------------------------
CREATE POLICY role_grant_policy ON aos_auth.role_grant
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_auth.principal p
            WHERE p.principal_id = role_grant.principal_id
              AND (p.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- ----------------------------------------------------------------------------
-- Persona Policies
-- ----------------------------------------------------------------------------
CREATE POLICY persona_policy ON aos_persona.persona
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Skill Policies (skills are global, but role_skill is tenant-scoped)
-- ----------------------------------------------------------------------------
CREATE POLICY skill_select_policy ON aos_skills.skill
    FOR SELECT
    USING (true);  -- Skills are globally visible

CREATE POLICY skill_modify_policy ON aos_skills.skill
    FOR ALL
    USING (aos_auth.is_admin());

CREATE POLICY skill_impl_policy ON aos_skills.skill_impl
    FOR ALL
    USING (true);  -- Implementations are global

CREATE POLICY role_skill_policy ON aos_skills.role_skill
    FOR ALL
    USING (true);  -- Role-skill mappings are global

-- ----------------------------------------------------------------------------
-- Run Policies
-- ----------------------------------------------------------------------------
CREATE POLICY run_policy ON aos_core.run
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Event Log Policies
-- ----------------------------------------------------------------------------
CREATE POLICY event_log_policy ON aos_core.event_log
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM aos_core.run r
            WHERE r.run_id = event_log.run_id
              AND (r.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- INSERT allowed for all (internal use)
CREATE POLICY event_log_insert_policy ON aos_core.event_log
    FOR INSERT
    WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- Skill Execution Policies
-- ----------------------------------------------------------------------------
CREATE POLICY skill_execution_policy ON aos_core.skill_execution
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_core.run r
            WHERE r.run_id = skill_execution.run_id
              AND (r.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- ----------------------------------------------------------------------------
-- Session Memory Policies
-- ----------------------------------------------------------------------------
CREATE POLICY session_memory_policy ON aos_core.session_memory
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Workflow Policies
-- ----------------------------------------------------------------------------
CREATE POLICY workflow_graph_policy ON aos_workflow.workflow_graph
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY workflow_node_policy ON aos_workflow.workflow_graph_node
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_workflow.workflow_graph g
            WHERE g.graph_id = workflow_graph_node.graph_id
              AND (g.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY workflow_edge_policy ON aos_workflow.workflow_graph_edge
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_workflow.workflow_graph g
            WHERE g.graph_id = workflow_graph_edge.graph_id
              AND (g.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY workflow_state_policy ON aos_workflow.workflow_state
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_core.run r
            WHERE r.run_id = workflow_state.run_id
              AND (r.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY workflow_interrupt_policy ON aos_workflow.workflow_interrupt
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_core.run r
            WHERE r.run_id = workflow_interrupt.run_id
              AND (r.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- ----------------------------------------------------------------------------
-- Egress Policies
-- ----------------------------------------------------------------------------
CREATE POLICY egress_request_policy ON aos_egress.request
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY egress_allowlist_policy ON aos_egress.allowlist
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Knowledge Graph Policies
-- ----------------------------------------------------------------------------
CREATE POLICY kg_doc_policy ON aos_kg.doc
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY kg_relationship_policy ON aos_kg.doc_relationship
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Embedding Policies
-- ----------------------------------------------------------------------------
CREATE POLICY embed_job_policy ON aos_embed.job
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY embed_embedding_policy ON aos_embed.embedding
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_kg.doc d
            WHERE d.doc_id = embedding.doc_id
              AND (d.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- ----------------------------------------------------------------------------
-- Collaboration Policies
-- ----------------------------------------------------------------------------
CREATE POLICY collab_task_policy ON aos_collab.task
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY collab_run_link_policy ON aos_collab.run_link
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_core.run r
            WHERE r.run_id = run_link.run_id
              AND (r.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY collab_comment_policy ON aos_collab.comment
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_collab.task t
            WHERE t.task_id = comment.task_id
              AND (t.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- ----------------------------------------------------------------------------
-- Policy Policies
-- ----------------------------------------------------------------------------
CREATE POLICY policy_hooks_global ON aos_policy.hooks
    FOR SELECT
    USING (tenant_id IS NULL);  -- Global hooks visible to all

CREATE POLICY policy_hooks_tenant ON aos_policy.hooks
    FOR ALL
    USING (
        tenant_id IS NULL OR tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY policy_rule_policy ON aos_policy.policy_rule
    FOR ALL
    USING (
        tenant_id IS NULL OR tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Grant execute on SECURITY DEFINER functions to bypass RLS
-- ----------------------------------------------------------------------------
-- Note: SECURITY DEFINER functions run as the function owner (typically superuser)
-- so they bypass RLS automatically. Regular users call these functions.

-- ============================================================================
-- aos_agent Policies (Agent Loop Architecture)
-- ============================================================================

ALTER TABLE aos_agent.agent ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.conversation ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.turn ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.step ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.memory ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.observation ENABLE ROW LEVEL SECURITY;

CREATE POLICY agent_policy ON aos_agent.agent
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY conversation_policy ON aos_agent.conversation
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY turn_policy ON aos_agent.turn
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_agent.conversation c
            WHERE c.conversation_id = turn.conversation_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY step_policy ON aos_agent.step
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_agent.turn t
            JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
            WHERE t.turn_id = step.turn_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY memory_policy ON aos_agent.memory
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_agent.agent a
            WHERE a.agent_id = memory.agent_id
              AND (a.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
        OR
        EXISTS (
            SELECT 1 FROM aos_agent.conversation c
            WHERE c.conversation_id = memory.conversation_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY observation_policy ON aos_agent.observation
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_agent.conversation c
            WHERE c.conversation_id = observation.conversation_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
        OR
        EXISTS (
            SELECT 1 FROM aos_agent.turn t
            JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
            WHERE t.turn_id = observation.turn_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
        OR
        EXISTS (
            SELECT 1 FROM aos_agent.step s
            JOIN aos_agent.turn t ON t.turn_id = s.turn_id
            JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
            WHERE s.step_id = observation.step_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

COMMENT ON FUNCTION aos_auth.is_admin IS 'Check if current user has admin privileges';

-- ============================================================================
-- aos_multi_agent Policies (Multi-Agent Collaboration)
-- ============================================================================

ALTER TABLE aos_multi_agent.team ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.team_member ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.discussion ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.agent_message ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.proposal ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.vote ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.shared_artifact ENABLE ROW LEVEL SECURITY;

CREATE POLICY team_policy ON aos_multi_agent.team
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY team_member_policy ON aos_multi_agent.team_member
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_multi_agent.team t
            WHERE t.team_id = team_member.team_id
              AND (t.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY discussion_policy ON aos_multi_agent.discussion
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY agent_message_policy ON aos_multi_agent.agent_message
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_multi_agent.discussion d
            WHERE d.discussion_id = agent_message.discussion_id
              AND (d.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY proposal_policy ON aos_multi_agent.proposal
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_multi_agent.discussion d
            WHERE d.discussion_id = proposal.discussion_id
              AND (d.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY vote_policy ON aos_multi_agent.vote
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_multi_agent.proposal p
            JOIN aos_multi_agent.discussion d ON d.discussion_id = p.discussion_id
            WHERE p.proposal_id = vote.proposal_id
              AND (d.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY shared_artifact_policy ON aos_multi_agent.shared_artifact
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_multi_agent.discussion d
            WHERE d.discussion_id = shared_artifact.discussion_id
              AND (d.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
        OR
        EXISTS (
            SELECT 1 FROM aos_multi_agent.team t
            WHERE t.team_id = shared_artifact.team_id
              AND (t.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

