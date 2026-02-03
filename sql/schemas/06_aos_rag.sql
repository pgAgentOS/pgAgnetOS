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
