-- pgAgentOS v1.0 - AI Agent Operating System for PostgreSQL
-- Generated on Tue Feb  3 23:24:19 KST 2026

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
-- pgAgentOS: Core Schema
-- Purpose: Essential infrastructure (Models, Runs, Events, Jobs)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_core;

-- ----------------------------------------------------------------------------
-- Table: model
-- Purpose: LLM model registry (system defaults)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_core.model (
    model_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider text NOT NULL,                          -- 'openai', 'anthropic', 'google', 'ollama'
    name text NOT NULL,                              -- 'gpt-4o', 'claude-3-5-sonnet'
    display_name text,
    
    -- Capabilities
    context_window int NOT NULL DEFAULT 8192,
    max_output_tokens int DEFAULT 4096,
    supports_tools bool DEFAULT true,
    supports_vision bool DEFAULT false,
    
    -- Default parameters
    default_params jsonb NOT NULL DEFAULT '{
        "temperature": 0.7,
        "top_p": 0.9
    }'::jsonb,
    
    -- API config
    endpoint text,
    api_key_env text,                                -- e.g., 'OPENAI_API_KEY'
    
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    
    UNIQUE (provider, name)
);

CREATE INDEX idx_model_provider ON aos_core.model(provider);
CREATE INDEX idx_model_active ON aos_core.model(is_active) WHERE is_active = true;

-- ----------------------------------------------------------------------------
-- Table: run
-- Purpose: Execution tracking (atomic unit of work)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_core.run (
    run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    
    -- Context
    run_type text NOT NULL DEFAULT 'agent',          -- 'agent', 'job', 'tool'
    parent_run_id uuid REFERENCES aos_core.run(run_id),
    
    -- Status
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
    
    -- Input/Output
    input jsonb,
    output jsonb,
    error text,
    
    -- Timing
    started_at timestamptz,
    completed_at timestamptz,
    
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_run_tenant ON aos_core.run(tenant_id);
CREATE INDEX idx_run_status ON aos_core.run(status);
CREATE INDEX idx_run_parent ON aos_core.run(parent_run_id) WHERE parent_run_id IS NOT NULL;
CREATE INDEX idx_run_created ON aos_core.run(created_at DESC);

-- ----------------------------------------------------------------------------
-- Table: event
-- Purpose: Immutable event log (audit trail)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_core.event (
    event_id bigserial PRIMARY KEY,
    run_id uuid REFERENCES aos_core.run(run_id) ON DELETE CASCADE,
    tenant_id uuid NOT NULL,
    
    -- Event info
    event_type text NOT NULL,                        -- 'llm_call', 'tool_call', 'error', etc.
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    
    -- Immutable timestamp
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_event_run ON aos_core.event(run_id);
CREATE INDEX idx_event_tenant ON aos_core.event(tenant_id);
CREATE INDEX idx_event_type ON aos_core.event(event_type);
CREATE INDEX idx_event_created ON aos_core.event(created_at DESC);

-- ----------------------------------------------------------------------------
-- Table: job
-- Purpose: Async job queue (PostgreSQL-native)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_core.job (
    job_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    
    -- Job definition
    job_type text NOT NULL,                          -- 'embed', 'llm_call', 'webhook', etc.
    payload jsonb NOT NULL,
    priority int DEFAULT 0,
    
    -- Status
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'cancelled')),
    
    -- Execution
    attempts int DEFAULT 0,
    max_attempts int DEFAULT 3,
    result jsonb,
    error text,
    
    -- Worker
    locked_by text,
    locked_at timestamptz,
    
    -- Timing
    scheduled_at timestamptz DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_job_tenant ON aos_core.job(tenant_id);
CREATE INDEX idx_job_status ON aos_core.job(status);
CREATE INDEX idx_job_queue ON aos_core.job(status, priority DESC, scheduled_at)
    WHERE status = 'pending';

-- ----------------------------------------------------------------------------
-- Function: log_event
-- Purpose: Record event (simplified)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.log_event(
    p_run_id uuid,
    p_event_type text,
    p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_tenant_id uuid;
    v_event_id bigint;
BEGIN
    SELECT tenant_id INTO v_tenant_id FROM aos_core.run WHERE run_id = p_run_id;
    
    INSERT INTO aos_core.event (run_id, tenant_id, event_type, payload)
    VALUES (p_run_id, v_tenant_id, p_event_type, p_payload)
    RETURNING event_id INTO v_event_id;
    
    RETURN v_event_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: enqueue
-- Purpose: Add job to queue
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.enqueue(
    p_tenant_id uuid,
    p_job_type text,
    p_payload jsonb,
    p_priority int DEFAULT 0,
    p_scheduled_at timestamptz DEFAULT now()
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_job_id uuid;
BEGIN
    INSERT INTO aos_core.job (tenant_id, job_type, payload, priority, scheduled_at)
    VALUES (p_tenant_id, p_job_type, p_payload, p_priority, p_scheduled_at)
    RETURNING job_id INTO v_job_id;
    
    RETURN v_job_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: poll_job
-- Purpose: Get next job (with locking)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.poll_job(
    p_job_type text,
    p_worker_id text
)
RETURNS aos_core.job
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_job aos_core.job;
BEGIN
    SELECT * INTO v_job
    FROM aos_core.job
    WHERE job_type = p_job_type
      AND status = 'pending'
      AND scheduled_at <= now()
      AND (locked_at IS NULL OR locked_at < now() - interval '5 minutes')
    ORDER BY priority DESC, scheduled_at
    LIMIT 1
    FOR UPDATE SKIP LOCKED;
    
    IF FOUND THEN
        UPDATE aos_core.job
        SET status = 'processing',
            locked_by = p_worker_id,
            locked_at = now(),
            started_at = COALESCE(started_at, now()),
            attempts = attempts + 1
        WHERE job_id = v_job.job_id
        RETURNING * INTO v_job;
    END IF;
    
    RETURN v_job;
END;
$$;

-- ----------------------------------------------------------------------------
-- Insert default models
-- ----------------------------------------------------------------------------
INSERT INTO aos_core.model (provider, name, display_name, context_window, max_output_tokens, supports_vision, default_params, endpoint, api_key_env) VALUES
-- OpenAI
('openai', 'gpt-4o', 'GPT-4o', 128000, 16384, true, 
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY'),
('openai', 'gpt-4o-mini', 'GPT-4o Mini', 128000, 16384, true,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY'),
-- Anthropic
('anthropic', 'claude-3-5-sonnet-20241022', 'Claude 3.5 Sonnet', 200000, 8192, true,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'https://api.anthropic.com/v1/messages', 'ANTHROPIC_API_KEY'),
-- Google
('google', 'gemini-2.0-flash', 'Gemini 2.0 Flash', 1048576, 8192, true,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'https://generativelanguage.googleapis.com/v1beta/models', 'GOOGLE_API_KEY'),
-- Ollama (Local)
('ollama', 'llama3.3:70b', 'Llama 3.3 70B', 128000, 4096, false,
 '{"temperature": 0.7, "top_p": 0.9}'::jsonb,
 'http://localhost:11434/api/chat', NULL);

COMMENT ON SCHEMA aos_core IS 'pgAgentOS: Core execution infrastructure';
COMMENT ON TABLE aos_core.model IS 'LLM model registry';
COMMENT ON TABLE aos_core.run IS 'Execution tracking';
COMMENT ON TABLE aos_core.event IS 'Immutable event log';
COMMENT ON TABLE aos_core.job IS 'Async job queue';

-- ============================================================================
-- pgAgentOS: Authentication & Multi-tenancy
-- Purpose: Tenant isolation and principal identity
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
    settings jsonb DEFAULT '{}'::jsonb,
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_tenant_active ON aos_auth.tenant(is_active) WHERE is_active = true;

-- ----------------------------------------------------------------------------
-- Table: principal
-- Purpose: User or agent identity
-- ----------------------------------------------------------------------------
CREATE TABLE aos_auth.principal (
    principal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    principal_type text NOT NULL DEFAULT 'user' 
        CHECK (principal_type IN ('user', 'agent', 'service')),
    
    name text NOT NULL,
    email text,
    role text DEFAULT 'user' CHECK (role IN ('admin', 'user', 'agent')),
    
    is_active bool DEFAULT true,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    
    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_principal_tenant ON aos_auth.principal(tenant_id);
CREATE INDEX idx_principal_type ON aos_auth.principal(principal_type);

-- ----------------------------------------------------------------------------
-- Add FK to aos_core.run
-- ----------------------------------------------------------------------------
ALTER TABLE aos_core.run 
ADD CONSTRAINT fk_run_tenant 
FOREIGN KEY (tenant_id) REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE;

ALTER TABLE aos_core.event
ADD CONSTRAINT fk_event_tenant
FOREIGN KEY (tenant_id) REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE;

ALTER TABLE aos_core.job
ADD CONSTRAINT fk_job_tenant
FOREIGN KEY (tenant_id) REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE;

-- ----------------------------------------------------------------------------
-- Function: set_tenant (for RLS)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.set_tenant(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM aos_auth.tenant WHERE tenant_id = p_tenant_id AND is_active) THEN
        RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
    END IF;
    PERFORM set_config('aos.tenant_id', p_tenant_id::text, false);
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: current_tenant
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.current_tenant()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('aos.tenant_id', true), '')::uuid;
$$;

COMMENT ON SCHEMA aos_auth IS 'pgAgentOS: Authentication and multi-tenancy';
COMMENT ON TABLE aos_auth.tenant IS 'Tenant isolation units';
COMMENT ON TABLE aos_auth.principal IS 'Users and agents';

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

-- ============================================================================
-- pgAgentOS: Agent Schema
-- Purpose: Agent loop (conversation, turn, step, memory)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_agent;

-- ----------------------------------------------------------------------------
-- Table: agent
-- Purpose: Agent instance
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.agent (
    agent_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    name text NOT NULL,
    persona_id uuid REFERENCES aos_persona.persona(persona_id),
    
    -- Tools this agent can use
    tools text[] DEFAULT ARRAY[]::text[],
    
    config jsonb DEFAULT '{}'::jsonb,
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    
    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_agent_tenant ON aos_agent.agent(tenant_id);
CREATE INDEX idx_agent_persona ON aos_agent.agent(persona_id);

-- ----------------------------------------------------------------------------
-- Table: conversation
-- Purpose: Chat session
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.conversation (
    conversation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    agent_id uuid NOT NULL REFERENCES aos_agent.agent(agent_id) ON DELETE CASCADE,
    
    -- Snapshot of persona version at conversation start
    persona_version_id uuid REFERENCES aos_persona.version(version_id),
    
    -- Status
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'paused', 'completed')),
    
    -- Metadata
    title text,
    metadata jsonb DEFAULT '{}'::jsonb,
    
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz
);

CREATE INDEX idx_conversation_tenant ON aos_agent.conversation(tenant_id);
CREATE INDEX idx_conversation_agent ON aos_agent.conversation(agent_id);
CREATE INDEX idx_conversation_status ON aos_agent.conversation(status);

-- ----------------------------------------------------------------------------
-- Table: turn
-- Purpose: Single turn (user message → assistant response)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.turn (
    turn_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES aos_agent.conversation(conversation_id) ON DELETE CASCADE,
    run_id uuid REFERENCES aos_core.run(run_id),
    
    turn_number int NOT NULL,
    
    -- Messages
    user_message text NOT NULL,
    assistant_message text,
    
    -- Status
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'thinking', 'tool_use', 'completed', 'failed')),
    
    -- Timing
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    
    UNIQUE (conversation_id, turn_number)
);

CREATE INDEX idx_turn_conversation ON aos_agent.turn(conversation_id);
CREATE INDEX idx_turn_status ON aos_agent.turn(status);

-- ----------------------------------------------------------------------------
-- Table: step
-- Purpose: Tool execution within a turn
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.step (
    step_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    turn_id uuid NOT NULL REFERENCES aos_agent.turn(turn_id) ON DELETE CASCADE,
    
    step_number int NOT NULL,
    
    -- Tool call
    tool_name text NOT NULL,
    tool_input jsonb NOT NULL,
    tool_output jsonb,
    
    -- Status
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'running', 'completed', 'failed')),
    error text,
    
    -- Timing
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    
    UNIQUE (turn_id, step_number)
);

CREATE INDEX idx_step_turn ON aos_agent.step(turn_id);

-- ----------------------------------------------------------------------------
-- Table: memory
-- Purpose: Session/conversation memory
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.memory (
    memory_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES aos_agent.conversation(conversation_id) ON DELETE CASCADE,
    
    key text NOT NULL,
    value jsonb NOT NULL,
    
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    
    UNIQUE (conversation_id, key)
);

CREATE INDEX idx_memory_conversation ON aos_agent.memory(conversation_id);

-- ----------------------------------------------------------------------------
-- Function: start_conversation
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.start_conversation(
    p_agent_id uuid,
    p_title text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_agent aos_agent.agent;
    v_persona aos_persona.persona;
    v_conv_id uuid;
BEGIN
    SELECT * INTO v_agent FROM aos_agent.agent WHERE agent_id = p_agent_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Agent not found: %', p_agent_id;
    END IF;
    
    -- Get current persona version
    SELECT * INTO v_persona 
    FROM aos_persona.persona WHERE persona_id = v_agent.persona_id;
    
    INSERT INTO aos_agent.conversation (
        tenant_id, agent_id, persona_version_id, title
    ) VALUES (
        v_agent.tenant_id, p_agent_id, v_persona.current_version_id, p_title
    ) RETURNING conversation_id INTO v_conv_id;
    
    RETURN v_conv_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: send_message
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.send_message(
    p_conversation_id uuid,
    p_message text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_conv aos_agent.conversation;
    v_turn_number int;
    v_turn_id uuid;
    v_run_id uuid;
BEGIN
    SELECT * INTO v_conv 
    FROM aos_agent.conversation WHERE conversation_id = p_conversation_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Conversation not found: %', p_conversation_id;
    END IF;
    
    -- Get next turn number
    SELECT COALESCE(MAX(turn_number), 0) + 1 INTO v_turn_number
    FROM aos_agent.turn WHERE conversation_id = p_conversation_id;
    
    -- Create run
    INSERT INTO aos_core.run (tenant_id, run_type, input)
    VALUES (v_conv.tenant_id, 'agent', jsonb_build_object('message', p_message))
    RETURNING run_id INTO v_run_id;
    
    -- Create turn
    INSERT INTO aos_agent.turn (conversation_id, run_id, turn_number, user_message)
    VALUES (p_conversation_id, v_run_id, v_turn_number, p_message)
    RETURNING turn_id INTO v_turn_id;
    
    -- Update conversation
    UPDATE aos_agent.conversation 
    SET updated_at = now() 
    WHERE conversation_id = p_conversation_id;
    
    RETURN v_turn_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: store_memory
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.store_memory(
    p_conversation_id uuid,
    p_key text,
    p_value jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO aos_agent.memory (conversation_id, key, value)
    VALUES (p_conversation_id, p_key, p_value)
    ON CONFLICT (conversation_id, key) DO UPDATE
    SET value = p_value, updated_at = now();
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: recall_memory
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.recall_memory(
    p_conversation_id uuid,
    p_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_key IS NOT NULL THEN
        RETURN (SELECT value FROM aos_agent.memory 
                WHERE conversation_id = p_conversation_id AND key = p_key);
    ELSE
        RETURN (SELECT jsonb_object_agg(key, value) 
                FROM aos_agent.memory 
                WHERE conversation_id = p_conversation_id);
    END IF;
END;
$$;

COMMENT ON SCHEMA aos_agent IS 'pgAgentOS: Agent loop';
COMMENT ON TABLE aos_agent.agent IS 'Agent instances';
COMMENT ON TABLE aos_agent.conversation IS 'Chat sessions';
COMMENT ON TABLE aos_agent.turn IS 'Conversation turns';
COMMENT ON TABLE aos_agent.step IS 'Tool execution steps';
COMMENT ON TABLE aos_agent.memory IS 'Session memory';

-- ============================================================================
-- pgAgentOS: RAG Schema
-- Purpose: Document storage, embeddings, and retrieval
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_rag;

-- ----------------------------------------------------------------------------
-- Table: collection
-- Purpose: Document collection/namespace
-- ----------------------------------------------------------------------------
CREATE TABLE aos_rag.collection (
    collection_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    name text NOT NULL,
    description text,
    
    -- Embedding config
    embedding_model text DEFAULT 'text-embedding-3-small',
    embedding_dims int DEFAULT 1536,
    
    created_at timestamptz NOT NULL DEFAULT now(),
    
    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_collection_tenant ON aos_rag.collection(tenant_id);

-- ----------------------------------------------------------------------------
-- Table: document
-- Purpose: Document storage with full-text search
-- ----------------------------------------------------------------------------
CREATE TABLE aos_rag.document (
    doc_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    collection_id uuid NOT NULL REFERENCES aos_rag.collection(collection_id) ON DELETE CASCADE,
    
    -- Content
    content text NOT NULL,
    title text,
    source text,                                     -- URL, file path, etc.
    
    -- Full-text search
    tsv tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', content), 'B')
    ) STORED,
    
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_document_collection ON aos_rag.document(collection_id);
CREATE INDEX idx_document_tsv ON aos_rag.document USING GIN(tsv);

-- ----------------------------------------------------------------------------
-- Table: chunk
-- Purpose: Document chunks with vector embeddings
-- ----------------------------------------------------------------------------
CREATE TABLE aos_rag.chunk (
    chunk_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    doc_id uuid NOT NULL REFERENCES aos_rag.document(doc_id) ON DELETE CASCADE,
    
    chunk_index int NOT NULL,
    content text NOT NULL,
    
    -- Vector embedding (pgvector)
    embedding vector(1536),
    
    -- Token info
    token_count int,
    
    created_at timestamptz NOT NULL DEFAULT now(),
    
    UNIQUE (doc_id, chunk_index)
);

CREATE INDEX idx_chunk_doc ON aos_rag.chunk(doc_id);
CREATE INDEX idx_chunk_embedding ON aos_rag.chunk USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

-- ----------------------------------------------------------------------------
-- Function: add_document
-- Purpose: Add document and queue for embedding
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_rag.add_document(
    p_collection_id uuid,
    p_content text,
    p_title text DEFAULT NULL,
    p_source text DEFAULT NULL,
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_doc_id uuid;
    v_tenant_id uuid;
BEGIN
    -- Get tenant
    SELECT tenant_id INTO v_tenant_id 
    FROM aos_rag.collection WHERE collection_id = p_collection_id;
    
    -- Insert document
    INSERT INTO aos_rag.document (collection_id, content, title, source, metadata)
    VALUES (p_collection_id, p_content, p_title, p_source, p_metadata)
    RETURNING doc_id INTO v_doc_id;
    
    -- Queue for embedding
    PERFORM aos_core.enqueue(
        v_tenant_id,
        'embed_document',
        jsonb_build_object('doc_id', v_doc_id)
    );
    
    RETURN v_doc_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: search
-- Purpose: Hybrid search (vector + full-text)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_rag.search(
    p_collection_id uuid,
    p_query text,
    p_query_embedding vector DEFAULT NULL,
    p_limit int DEFAULT 10
)
RETURNS TABLE (
    doc_id uuid,
    chunk_id uuid,
    content text,
    title text,
    score float
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_query_embedding IS NOT NULL THEN
        -- Vector search
        RETURN QUERY
        SELECT 
            d.doc_id,
            c.chunk_id,
            c.content,
            d.title,
            (1 - (c.embedding <=> p_query_embedding))::float as score
        FROM aos_rag.chunk c
        JOIN aos_rag.document d ON d.doc_id = c.doc_id
        WHERE d.collection_id = p_collection_id
        ORDER BY c.embedding <=> p_query_embedding
        LIMIT p_limit;
    ELSE
        -- Full-text search
        RETURN QUERY
        SELECT 
            d.doc_id,
            NULL::uuid as chunk_id,
            d.content,
            d.title,
            ts_rank(d.tsv, websearch_to_tsquery('english', p_query))::float as score
        FROM aos_rag.document d
        WHERE d.collection_id = p_collection_id
          AND d.tsv @@ websearch_to_tsquery('english', p_query)
        ORDER BY score DESC
        LIMIT p_limit;
    END IF;
END;
$$;

COMMENT ON SCHEMA aos_rag IS 'pgAgentOS: RAG and document retrieval';
COMMENT ON TABLE aos_rag.collection IS 'Document collections';
COMMENT ON TABLE aos_rag.document IS 'Documents with full-text search';
COMMENT ON TABLE aos_rag.chunk IS 'Document chunks with embeddings';

-- ============================================================================
-- pgAgentOS: Triggers (Simplified)
-- Purpose: Immutability and auto-update
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: immutable_record
-- Purpose: Prevent updates to immutable records
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.immutable_record()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Cannot update immutable record in %', TG_TABLE_NAME;
    RETURN NULL;
END;
$$;

-- ----------------------------------------------------------------------------
-- Event immutability
-- ----------------------------------------------------------------------------
CREATE TRIGGER trg_event_immutable
    BEFORE UPDATE ON aos_core.event
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.immutable_record();

-- ----------------------------------------------------------------------------
-- Persona version immutability
-- ----------------------------------------------------------------------------
CREATE TRIGGER trg_persona_version_immutable
    BEFORE UPDATE ON aos_persona.version
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.immutable_record();

-- ----------------------------------------------------------------------------
-- Function: auto_update_timestamp
-- Purpose: Auto-update updated_at column
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

-- Apply to tables with updated_at
CREATE TRIGGER trg_conversation_updated
    BEFORE UPDATE ON aos_agent.conversation
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_memory_updated
    BEFORE UPDATE ON aos_agent.memory
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_persona_updated
    BEFORE UPDATE ON aos_persona.persona
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

-- ============================================================================
-- pgAgentOS: System Views (Simplified)
-- Purpose: Essential observability
-- ============================================================================

-- ----------------------------------------------------------------------------
-- View: active_runs
-- Purpose: Show running executions
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_core.active_runs AS
SELECT 
    r.run_id,
    r.run_type,
    r.status,
    r.started_at,
    now() - r.started_at as duration,
    r.input
FROM aos_core.run r
WHERE r.status IN ('pending', 'running')
ORDER BY r.started_at DESC;

-- ----------------------------------------------------------------------------
-- View: pending_jobs
-- Purpose: Show job queue status
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_core.pending_jobs AS
SELECT 
    j.job_type,
    COUNT(*) as pending_count,
    MIN(j.scheduled_at) as oldest,
    MAX(j.priority) as max_priority
FROM aos_core.job j
WHERE j.status = 'pending'
GROUP BY j.job_type
ORDER BY pending_count DESC;

-- ----------------------------------------------------------------------------
-- View: conversation_summary
-- Purpose: Show conversation overview
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.conversation_summary AS
SELECT 
    c.conversation_id,
    a.name as agent_name,
    c.title,
    c.status,
    c.created_at,
    COUNT(t.turn_id) as turn_count
FROM aos_agent.conversation c
JOIN aos_agent.agent a ON a.agent_id = c.agent_id
LEFT JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id
GROUP BY c.conversation_id, a.name, c.title, c.status, c.created_at
ORDER BY c.created_at DESC;

COMMENT ON VIEW aos_core.active_runs IS 'Currently running executions';
COMMENT ON VIEW aos_core.pending_jobs IS 'Job queue status by type';
COMMENT ON VIEW aos_agent.conversation_summary IS 'Conversation overview';

-- ============================================================================
-- pgAgentOS: RLS Policies (Simplified)
-- Purpose: Row-level security for multi-tenancy
-- ============================================================================

-- ----------------------------------------------------------------------------
-- aos_core policies
-- ----------------------------------------------------------------------------
ALTER TABLE aos_core.run ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.event ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.job ENABLE ROW LEVEL SECURITY;

CREATE POLICY run_tenant_isolation ON aos_core.run
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY event_tenant_isolation ON aos_core.event
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY job_tenant_isolation ON aos_core.job
    USING (tenant_id = aos_auth.current_tenant());

-- ----------------------------------------------------------------------------
-- aos_auth policies
-- ----------------------------------------------------------------------------
ALTER TABLE aos_auth.tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_auth.principal ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON aos_auth.tenant
    USING (tenant_id = aos_auth.current_tenant() OR aos_auth.current_tenant() IS NULL);

CREATE POLICY principal_tenant_isolation ON aos_auth.principal
    USING (tenant_id = aos_auth.current_tenant());

-- ----------------------------------------------------------------------------
-- aos_persona policies
-- ----------------------------------------------------------------------------
ALTER TABLE aos_persona.persona ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_persona.version ENABLE ROW LEVEL SECURITY;

CREATE POLICY persona_tenant_isolation ON aos_persona.persona
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY version_tenant_isolation ON aos_persona.version
    USING (EXISTS (
        SELECT 1 FROM aos_persona.persona p 
        WHERE p.persona_id = version.persona_id 
          AND p.tenant_id = aos_auth.current_tenant()
    ));

-- ----------------------------------------------------------------------------
-- aos_agent policies
-- ----------------------------------------------------------------------------
ALTER TABLE aos_agent.agent ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.conversation ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.turn ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.step ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.memory ENABLE ROW LEVEL SECURITY;

CREATE POLICY agent_tenant_isolation ON aos_agent.agent
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY conversation_tenant_isolation ON aos_agent.conversation
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY turn_tenant_isolation ON aos_agent.turn
    USING (EXISTS (
        SELECT 1 FROM aos_agent.conversation c 
        WHERE c.conversation_id = turn.conversation_id 
          AND c.tenant_id = aos_auth.current_tenant()
    ));

CREATE POLICY step_tenant_isolation ON aos_agent.step
    USING (EXISTS (
        SELECT 1 FROM aos_agent.turn t
        JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
        WHERE t.turn_id = step.turn_id 
          AND c.tenant_id = aos_auth.current_tenant()
    ));

CREATE POLICY memory_tenant_isolation ON aos_agent.memory
    USING (EXISTS (
        SELECT 1 FROM aos_agent.conversation c 
        WHERE c.conversation_id = memory.conversation_id 
          AND c.tenant_id = aos_auth.current_tenant()
    ));

-- ----------------------------------------------------------------------------
-- aos_rag policies
-- ----------------------------------------------------------------------------
ALTER TABLE aos_rag.collection ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_rag.document ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_rag.chunk ENABLE ROW LEVEL SECURITY;

CREATE POLICY collection_tenant_isolation ON aos_rag.collection
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY document_tenant_isolation ON aos_rag.document
    USING (EXISTS (
        SELECT 1 FROM aos_rag.collection c 
        WHERE c.collection_id = document.collection_id 
          AND c.tenant_id = aos_auth.current_tenant()
    ));

CREATE POLICY chunk_tenant_isolation ON aos_rag.chunk
    USING (EXISTS (
        SELECT 1 FROM aos_rag.document d
        JOIN aos_rag.collection c ON c.collection_id = d.collection_id
        WHERE d.doc_id = chunk.doc_id 
          AND c.tenant_id = aos_auth.current_tenant()
    ));

