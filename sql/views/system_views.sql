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
