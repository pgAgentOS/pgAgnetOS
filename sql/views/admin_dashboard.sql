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
        tenant_id,
        count(DISTINCT agent_id) as total_agents,
        count(DISTINCT CASE WHEN c.status = 'active' THEN c.conversation_id END) as active_conversations,
        count(DISTINCT CASE WHEN t.status = 'processing' THEN t.turn_id END) as processing_turns,
        count(DISTINCT CASE WHEN t.status = 'waiting_tool' THEN t.turn_id END) as awaiting_approval,
        sum(t.tokens_used) as total_tokens_today,
        sum(t.cost_usd) as total_cost_today
    FROM aos_agent.agent a
    LEFT JOIN aos_agent.conversation c ON c.agent_id = a.agent_id
    LEFT JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id
        AND t.started_at > now() - interval '24 hours'
    GROUP BY tenant_id
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
            100.0 * count(*) FILTER (WHERE t.status = 'completed') / NULLIF(count(*), 0), 2
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
