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
