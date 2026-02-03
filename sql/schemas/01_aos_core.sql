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
