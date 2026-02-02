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
