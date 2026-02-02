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
