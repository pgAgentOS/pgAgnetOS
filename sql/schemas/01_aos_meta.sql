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
