-- ============================================================================
-- pgAgentOS: RLS Policies (Simplified)
-- Purpose: Row-level security for multi-tenancy
-- ============================================================================

-- ----------------------------------------------------------------------------
-- aos_core policies
-- ----------------------------------------------------------------------------
ALTER TABLE aos_core.run ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.event ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_core.job ENABLE ROW LEVEL SECURITY;

CREATE POLICY run_tenant_isolation ON aos_core.run
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY event_tenant_isolation ON aos_core.event
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY job_tenant_isolation ON aos_core.job
    USING (tenant_id = aos_auth.current_tenant());

-- ----------------------------------------------------------------------------
-- aos_auth policies
-- ----------------------------------------------------------------------------
ALTER TABLE aos_auth.tenant ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_auth.principal ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON aos_auth.tenant
    USING (tenant_id = aos_auth.current_tenant() OR aos_auth.current_tenant() IS NULL);

CREATE POLICY principal_tenant_isolation ON aos_auth.principal
    USING (tenant_id = aos_auth.current_tenant());

-- ----------------------------------------------------------------------------
-- aos_persona policies
-- ----------------------------------------------------------------------------
ALTER TABLE aos_persona.persona ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_persona.version ENABLE ROW LEVEL SECURITY;

CREATE POLICY persona_tenant_isolation ON aos_persona.persona
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY version_tenant_isolation ON aos_persona.version
    USING (EXISTS (
        SELECT 1 FROM aos_persona.persona p 
        WHERE p.persona_id = version.persona_id 
          AND p.tenant_id = aos_auth.current_tenant()
    ));

-- ----------------------------------------------------------------------------
-- aos_agent policies
-- ----------------------------------------------------------------------------
ALTER TABLE aos_agent.agent ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.conversation ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.turn ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.step ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_agent.memory ENABLE ROW LEVEL SECURITY;

CREATE POLICY agent_tenant_isolation ON aos_agent.agent
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY conversation_tenant_isolation ON aos_agent.conversation
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY turn_tenant_isolation ON aos_agent.turn
    USING (EXISTS (
        SELECT 1 FROM aos_agent.conversation c 
        WHERE c.conversation_id = turn.conversation_id 
          AND c.tenant_id = aos_auth.current_tenant()
    ));

CREATE POLICY step_tenant_isolation ON aos_agent.step
    USING (EXISTS (
        SELECT 1 FROM aos_agent.turn t
        JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
        WHERE t.turn_id = step.turn_id 
          AND c.tenant_id = aos_auth.current_tenant()
    ));

CREATE POLICY memory_tenant_isolation ON aos_agent.memory
    USING (EXISTS (
        SELECT 1 FROM aos_agent.conversation c 
        WHERE c.conversation_id = memory.conversation_id 
          AND c.tenant_id = aos_auth.current_tenant()
    ));

-- ----------------------------------------------------------------------------
-- aos_rag policies
-- ----------------------------------------------------------------------------
ALTER TABLE aos_rag.collection ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_rag.document ENABLE ROW LEVEL SECURITY;
ALTER TABLE aos_rag.chunk ENABLE ROW LEVEL SECURITY;

CREATE POLICY collection_tenant_isolation ON aos_rag.collection
    USING (tenant_id = aos_auth.current_tenant());

CREATE POLICY document_tenant_isolation ON aos_rag.document
    USING (EXISTS (
        SELECT 1 FROM aos_rag.collection c 
        WHERE c.collection_id = document.collection_id 
          AND c.tenant_id = aos_auth.current_tenant()
    ));

CREATE POLICY chunk_tenant_isolation ON aos_rag.chunk
    USING (EXISTS (
        SELECT 1 FROM aos_rag.document d
        JOIN aos_rag.collection c ON c.collection_id = d.collection_id
        WHERE d.doc_id = chunk.doc_id 
          AND c.tenant_id = aos_auth.current_tenant()
    ));
