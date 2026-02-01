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
