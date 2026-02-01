-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- RLS: Row Level Security Policies
-- ============================================================================

-- Enable RLS on all tables
ALTER TABLE aos_auth.tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_auth.principal ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_auth.role_grant ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_persona.persona ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_skills.skill ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_skills.skill_impl ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_skills.role_skill ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.run ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.event_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.skill_execution ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.session_memory ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_workflow.workflow_graph ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_workflow.workflow_graph_node ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_workflow.workflow_graph_edge ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_workflow.workflow_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_workflow.workflow_interrupt ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_egress.request ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_egress.allowlist ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_kg.doc ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_kg.doc_relationship ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_embed.job ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_embed.embedding ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_collab.task ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_collab.run_link ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_collab.comment ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_policy.hooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_policy.policy_rule ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------------------
-- Helper function: Check if current user is superuser or has admin role
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.is_admin()
RETURNS bool
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
BEGIN
    -- Superusers bypass RLS anyway, but let's be explicit
    IF current_setting('is_superuser', true) = 'on' THEN
        RETURN true;
    END IF;
    
    -- Check for admin role
    RETURN EXISTS (
        SELECT 1 FROM aos_auth.role_grant rg
        JOIN aos_auth.principal p ON p.principal_id = rg.principal_id
        WHERE p.db_role_name = current_user
          AND rg.role_key = 'admin'
          AND rg.is_active = true
          AND (rg.expires_at IS NULL OR rg.expires_at > now())
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Tenant Policies
-- ----------------------------------------------------------------------------
-- Tenants: visible to members of that tenant or admins
CREATE POLICY tenant_select_policy ON aos_auth.tenant
    FOR SELECT
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY tenant_modify_policy ON aos_auth.tenant
    FOR ALL
    USING (aos_auth.is_admin());

-- ----------------------------------------------------------------------------
-- Principal Policies
-- ----------------------------------------------------------------------------
CREATE POLICY principal_select_policy ON aos_auth.principal
    FOR SELECT
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY principal_modify_policy ON aos_auth.principal
    FOR ALL
    USING (aos_auth.is_admin());

-- ----------------------------------------------------------------------------
-- Role Grant Policies
-- ----------------------------------------------------------------------------
CREATE POLICY role_grant_policy ON aos_auth.role_grant
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_auth.principal p
            WHERE p.principal_id = role_grant.principal_id
              AND (p.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- ----------------------------------------------------------------------------
-- Persona Policies
-- ----------------------------------------------------------------------------
CREATE POLICY persona_policy ON aos_persona.persona
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Skill Policies (skills are global, but role_skill is tenant-scoped)
-- ----------------------------------------------------------------------------
CREATE POLICY skill_select_policy ON aos_skills.skill
    FOR SELECT
    USING (true);  -- Skills are globally visible

CREATE POLICY skill_modify_policy ON aos_skills.skill
    FOR ALL
    USING (aos_auth.is_admin());

CREATE POLICY skill_impl_policy ON aos_skills.skill_impl
    FOR ALL
    USING (true);  -- Implementations are global

CREATE POLICY role_skill_policy ON aos_skills.role_skill
    FOR ALL
    USING (true);  -- Role-skill mappings are global

-- ----------------------------------------------------------------------------
-- Run Policies
-- ----------------------------------------------------------------------------
CREATE POLICY run_policy ON aos_core.run
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Event Log Policies
-- ----------------------------------------------------------------------------
CREATE POLICY event_log_policy ON aos_core.event_log
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM aos_core.run r
            WHERE r.run_id = event_log.run_id
              AND (r.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- INSERT allowed for all (internal use)
CREATE POLICY event_log_insert_policy ON aos_core.event_log
    FOR INSERT
    WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- Skill Execution Policies
-- ----------------------------------------------------------------------------
CREATE POLICY skill_execution_policy ON aos_core.skill_execution
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_core.run r
            WHERE r.run_id = skill_execution.run_id
              AND (r.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- ----------------------------------------------------------------------------
-- Session Memory Policies
-- ----------------------------------------------------------------------------
CREATE POLICY session_memory_policy ON aos_core.session_memory
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Workflow Policies
-- ----------------------------------------------------------------------------
CREATE POLICY workflow_graph_policy ON aos_workflow.workflow_graph
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY workflow_node_policy ON aos_workflow.workflow_graph_node
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_workflow.workflow_graph g
            WHERE g.graph_id = workflow_graph_node.graph_id
              AND (g.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY workflow_edge_policy ON aos_workflow.workflow_graph_edge
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_workflow.workflow_graph g
            WHERE g.graph_id = workflow_graph_edge.graph_id
              AND (g.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY workflow_state_policy ON aos_workflow.workflow_state
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_core.run r
            WHERE r.run_id = workflow_state.run_id
              AND (r.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY workflow_interrupt_policy ON aos_workflow.workflow_interrupt
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_core.run r
            WHERE r.run_id = workflow_interrupt.run_id
              AND (r.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- ----------------------------------------------------------------------------
-- Egress Policies
-- ----------------------------------------------------------------------------
CREATE POLICY egress_request_policy ON aos_egress.request
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY egress_allowlist_policy ON aos_egress.allowlist
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Knowledge Graph Policies
-- ----------------------------------------------------------------------------
CREATE POLICY kg_doc_policy ON aos_kg.doc
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY kg_relationship_policy ON aos_kg.doc_relationship
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Embedding Policies
-- ----------------------------------------------------------------------------
CREATE POLICY embed_job_policy ON aos_embed.job
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY embed_embedding_policy ON aos_embed.embedding
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_kg.doc d
            WHERE d.doc_id = embedding.doc_id
              AND (d.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- ----------------------------------------------------------------------------
-- Collaboration Policies
-- ----------------------------------------------------------------------------
CREATE POLICY collab_task_policy ON aos_collab.task
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY collab_run_link_policy ON aos_collab.run_link
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_core.run r
            WHERE r.run_id = run_link.run_id
              AND (r.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY collab_comment_policy ON aos_collab.comment
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_collab.task t
            WHERE t.task_id = comment.task_id
              AND (t.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

-- ----------------------------------------------------------------------------
-- Policy Policies
-- ----------------------------------------------------------------------------
CREATE POLICY policy_hooks_global ON aos_policy.hooks
    FOR SELECT
    USING (tenant_id IS NULL);  -- Global hooks visible to all

CREATE POLICY policy_hooks_tenant ON aos_policy.hooks
    FOR ALL
    USING (
        tenant_id IS NULL OR tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY policy_rule_policy ON aos_policy.policy_rule
    FOR ALL
    USING (
        tenant_id IS NULL OR tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

-- ----------------------------------------------------------------------------
-- Grant execute on SECURITY DEFINER functions to bypass RLS
-- ----------------------------------------------------------------------------
-- Note: SECURITY DEFINER functions run as the function owner (typically superuser)
-- so they bypass RLS automatically. Regular users call these functions.

-- ============================================================================
-- aos_agent Policies (Agent Loop Architecture)
-- ============================================================================

ALTER TABLE aos_agent.agent ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.conversation ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.turn ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.step ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.memory ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.observation ENABLE ROW LEVEL SECURITY;

CREATE POLICY agent_policy ON aos_agent.agent
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY conversation_policy ON aos_agent.conversation
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY turn_policy ON aos_agent.turn
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_agent.conversation c
            WHERE c.conversation_id = turn.conversation_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY step_policy ON aos_agent.step
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_agent.turn t
            JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
            WHERE t.turn_id = step.turn_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY memory_policy ON aos_agent.memory
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_agent.agent a
            WHERE a.agent_id = memory.agent_id
              AND (a.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
        OR
        EXISTS (
            SELECT 1 FROM aos_agent.conversation c
            WHERE c.conversation_id = memory.conversation_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY observation_policy ON aos_agent.observation
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_agent.conversation c
            WHERE c.conversation_id = observation.conversation_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
        OR
        EXISTS (
            SELECT 1 FROM aos_agent.turn t
            JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
            WHERE t.turn_id = observation.turn_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
        OR
        EXISTS (
            SELECT 1 FROM aos_agent.step s
            JOIN aos_agent.turn t ON t.turn_id = s.turn_id
            JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
            WHERE s.step_id = observation.step_id
              AND (c.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

COMMENT ON FUNCTION aos_auth.is_admin IS 'Check if current user has admin privileges';

-- ============================================================================
-- aos_multi_agent Policies (Multi-Agent Collaboration)
-- ============================================================================

ALTER TABLE aos_multi_agent.team ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.team_member ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.discussion ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.agent_message ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.proposal ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.vote ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_multi_agent.shared_artifact ENABLE ROW LEVEL SECURITY;

CREATE POLICY team_policy ON aos_multi_agent.team
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY team_member_policy ON aos_multi_agent.team_member
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_multi_agent.team t
            WHERE t.team_id = team_member.team_id
              AND (t.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY discussion_policy ON aos_multi_agent.discussion
    FOR ALL
    USING (
        tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin()
    );

CREATE POLICY agent_message_policy ON aos_multi_agent.agent_message
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_multi_agent.discussion d
            WHERE d.discussion_id = agent_message.discussion_id
              AND (d.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY proposal_policy ON aos_multi_agent.proposal
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_multi_agent.discussion d
            WHERE d.discussion_id = proposal.discussion_id
              AND (d.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY vote_policy ON aos_multi_agent.vote
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_multi_agent.proposal p
            JOIN aos_multi_agent.discussion d ON d.discussion_id = p.discussion_id
            WHERE p.proposal_id = vote.proposal_id
              AND (d.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

CREATE POLICY shared_artifact_policy ON aos_multi_agent.shared_artifact
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM aos_multi_agent.discussion d
            WHERE d.discussion_id = shared_artifact.discussion_id
              AND (d.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
        OR
        EXISTS (
            SELECT 1 FROM aos_multi_agent.team t
            WHERE t.team_id = shared_artifact.team_id
              AND (t.tenant_id = aos_auth.current_tenant() OR aos_auth.is_admin())
        )
    );

