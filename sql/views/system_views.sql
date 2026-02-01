-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Views: System Views for Monitoring and Debugging
-- ============================================================================

-- ----------------------------------------------------------------------------
-- View: agent_permissions_view
-- Purpose: Show principals with their roles and skill permissions
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_auth.agent_permissions_view AS
SELECT 
    p.principal_id,
    p.tenant_id,
    t.name as tenant_name,
    p.principal_type,
    p.display_name as principal_name,
    p.db_role_name,
    p.is_active as principal_active,
    array_agg(DISTINCT rg.role_key) FILTER (WHERE rg.role_key IS NOT NULL) as roles,
    array_agg(DISTINCT rs.skill_key) FILTER (WHERE rs.skill_key IS NOT NULL) as allowed_skills
FROM aos_auth.principal p
JOIN aos_auth.tenant t ON t.tenant_id = p.tenant_id
LEFT JOIN aos_auth.role_grant rg ON rg.principal_id = p.principal_id 
    AND rg.is_active = true 
    AND (rg.expires_at IS NULL OR rg.expires_at > now())
LEFT JOIN aos_skills.role_skill rs ON rs.role_key = rg.role_key
    AND rs.is_active = true
GROUP BY p.principal_id, p.tenant_id, t.name, p.principal_type, p.display_name, p.db_role_name, p.is_active;

COMMENT ON VIEW aos_auth.agent_permissions_view IS 'Principals with their roles and skill permissions';

-- ----------------------------------------------------------------------------
-- View: active_graph_runs_view
-- Purpose: Show currently running workflow executions
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_workflow.active_graph_runs_view AS
SELECT 
    r.run_id,
    r.tenant_id,
    t.name as tenant_name,
    r.graph_id,
    g.name as graph_name,
    g.version as graph_version,
    r.status,
    r.started_at,
    EXTRACT(EPOCH FROM (now() - r.started_at))::int as runtime_seconds,
    r.total_steps,
    ws.current_node,
    ws.checkpoint_version,
    r.metadata,
    p.display_name as principal_name,
    per.name as persona_name
FROM aos_core.run r
JOIN aos_auth.tenant t ON t.tenant_id = r.tenant_id
LEFT JOIN aos_workflow.workflow_graph g ON g.graph_id = r.graph_id
LEFT JOIN aos_auth.principal p ON p.principal_id = r.principal_id
LEFT JOIN aos_persona.persona per ON per.persona_id = r.persona_id
LEFT JOIN LATERAL (
    SELECT current_node, checkpoint_version
    FROM aos_workflow.workflow_state
    WHERE run_id = r.run_id
    ORDER BY checkpoint_version DESC
    LIMIT 1
) ws ON true
WHERE r.status IN ('running', 'pending', 'interrupted');

COMMENT ON VIEW aos_workflow.active_graph_runs_view IS 'Currently running workflow executions';

-- ----------------------------------------------------------------------------
-- View: state_history_view
-- Purpose: Time-travel view for workflow state checkpoints
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_workflow.state_history_view AS
SELECT 
    ws.state_id,
    ws.run_id,
    r.graph_id,
    g.name as graph_name,
    ws.checkpoint_version,
    ws.current_node,
    ws.previous_node,
    ws.state_data,
    ws.messages,
    ws.created_at,
    ws.is_final,
    LAG(ws.current_node) OVER (PARTITION BY ws.run_id ORDER BY ws.checkpoint_version) as came_from,
    LEAD(ws.current_node) OVER (PARTITION BY ws.run_id ORDER BY ws.checkpoint_version) as went_to
FROM aos_workflow.workflow_state ws
JOIN aos_core.run r ON r.run_id = ws.run_id
LEFT JOIN aos_workflow.workflow_graph g ON g.graph_id = ws.graph_id
ORDER BY ws.run_id, ws.checkpoint_version;

COMMENT ON VIEW aos_workflow.state_history_view IS 'Time-travel view for workflow state checkpoints';

-- ----------------------------------------------------------------------------
-- View: pending_interrupts_view
-- Purpose: Show pending human-in-the-loop interrupts
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_workflow.pending_interrupts_view AS
SELECT 
    wi.interrupt_id,
    wi.run_id,
    r.tenant_id,
    t.name as tenant_name,
    g.name as graph_name,
    wi.node_name,
    wi.interrupt_type,
    wi.status,
    wi.request_message,
    wi.request_data,
    wi.created_at,
    EXTRACT(EPOCH FROM (now() - wi.created_at))::int as waiting_seconds,
    wi.expires_at,
    CASE WHEN wi.expires_at IS NOT NULL AND wi.expires_at < now() THEN true ELSE false END as is_expired,
    p.display_name as requested_by_name
FROM aos_workflow.workflow_interrupt wi
JOIN aos_core.run r ON r.run_id = wi.run_id
JOIN aos_auth.tenant t ON t.tenant_id = r.tenant_id
LEFT JOIN aos_workflow.workflow_graph g ON g.graph_id = r.graph_id
LEFT JOIN aos_auth.principal p ON p.principal_id = wi.requested_by
WHERE wi.status = 'pending';

COMMENT ON VIEW aos_workflow.pending_interrupts_view IS 'Pending human-in-the-loop interrupts';

-- ----------------------------------------------------------------------------
-- View: recent_events_view
-- Purpose: Show recent events across all runs
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_core.recent_events_view AS
SELECT 
    el.event_id,
    el.run_id,
    r.tenant_id,
    el.event_type,
    el.event_subtype,
    el.node_name,
    el.payload,
    el.created_at,
    el.duration_ms,
    aos_core.format_duration(el.duration_ms) as duration_formatted
FROM aos_core.event_log el
JOIN aos_core.run r ON r.run_id = el.run_id
ORDER BY el.created_at DESC;

COMMENT ON VIEW aos_core.recent_events_view IS 'Recent events across all runs';

-- ----------------------------------------------------------------------------
-- View: skill_usage_stats_view
-- Purpose: Show skill usage statistics
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_skills.skill_usage_stats_view AS
SELECT 
    se.skill_key,
    s.name as skill_name,
    s.category,
    count(*) as total_executions,
    count(*) FILTER (WHERE se.status = 'success') as successful,
    count(*) FILTER (WHERE se.status = 'failure') as failed,
    round(100.0 * count(*) FILTER (WHERE se.status = 'success') / NULLIF(count(*), 0), 2) as success_rate,
    round(avg(se.duration_ms), 2) as avg_duration_ms,
    round(percentile_cont(0.95) WITHIN GROUP (ORDER BY se.duration_ms), 2) as p95_duration_ms,
    sum(se.tokens_used) as total_tokens,
    sum(se.cost_usd) as total_cost_usd,
    max(se.completed_at) as last_used_at
FROM aos_core.skill_execution se
JOIN aos_skills.skill s ON s.skill_key = se.skill_key
GROUP BY se.skill_key, s.name, s.category
ORDER BY total_executions DESC;

COMMENT ON VIEW aos_skills.skill_usage_stats_view IS 'Skill usage statistics';

-- ----------------------------------------------------------------------------
-- View: embedding_queue_view
-- Purpose: Show embedding job queue status
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_embed.embedding_queue_view AS
SELECT 
    j.job_id,
    j.doc_id,
    d.title as doc_title,
    j.tenant_id,
    t.name as tenant_name,
    j.status,
    j.priority,
    j.attempts,
    j.max_attempts,
    j.model_name,
    j.created_at,
    j.started_at,
    j.completed_at,
    CASE 
        WHEN j.status = 'processing' THEN 
            EXTRACT(EPOCH FROM (now() - j.started_at))::int
        ELSE NULL
    END as processing_seconds,
    j.error_message
FROM aos_embed.job j
JOIN aos_kg.doc d ON d.doc_id = j.doc_id
JOIN aos_auth.tenant t ON t.tenant_id = j.tenant_id
ORDER BY 
    CASE j.status 
        WHEN 'processing' THEN 1 
        WHEN 'queued' THEN 2 
        ELSE 3 
    END,
    j.priority DESC,
    j.created_at;

COMMENT ON VIEW aos_embed.embedding_queue_view IS 'Embedding job queue status';

-- ----------------------------------------------------------------------------
-- View: model_registry_view
-- Purpose: Show available LLM models with their configurations
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_meta.model_registry_view AS
SELECT 
    m.model_id,
    m.provider,
    m.model_name,
    m.display_name,
    m.context_window,
    m.max_output_tokens,
    m.supports_vision,
    m.supports_function_calling,
    m.supports_streaming,
    m.default_params,
    m.is_active,
    count(DISTINCT p.persona_id) as personas_using,
    count(DISTINCT si.skill_key) as skills_using
FROM aos_meta.llm_model_registry m
LEFT JOIN aos_persona.persona p ON p.model_id = m.model_id AND p.is_active = true
LEFT JOIN aos_skills.skill_impl si ON si.model_id = m.model_id AND si.enabled = true
GROUP BY m.model_id
ORDER BY m.provider, m.model_name;

COMMENT ON VIEW aos_meta.model_registry_view IS 'Available LLM models with usage stats';

-- ----------------------------------------------------------------------------
-- View: egress_pending_approval_view
-- Purpose: Show egress requests pending approval
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_egress.pending_approval_view AS
SELECT 
    req.request_id,
    req.run_id,
    req.tenant_id,
    t.name as tenant_name,
    req.target_type,
    req.target,
    req.method,
    req.risk_level,
    req.risk_factors,
    req.created_at,
    EXTRACT(EPOCH FROM (now() - req.created_at))::int as waiting_seconds
FROM aos_egress.request req
JOIN aos_auth.tenant t ON t.tenant_id = req.tenant_id
WHERE req.status = 'pending' AND req.requires_approval = true
ORDER BY 
    CASE req.risk_level 
        WHEN 'critical' THEN 1 
        WHEN 'high' THEN 2 
        WHEN 'medium' THEN 3 
        ELSE 4 
    END,
    req.created_at;

COMMENT ON VIEW aos_egress.pending_approval_view IS 'Egress requests pending approval';
