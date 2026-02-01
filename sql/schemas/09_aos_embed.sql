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
COMMENT ON TABLE aos_embed.embedding IS 'Vector embeddings with HNSW index';
COMMENT ON FUNCTION aos_embed.similarity_search IS 'Vector similarity search';
