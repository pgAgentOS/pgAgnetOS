-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Triggers: Immutability Enforcement
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Trigger Function: prevent_modification
-- Purpose: Prevent UPDATE/DELETE on immutable records
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.prevent_modification()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Cannot update immutable record in %.%: %', 
            TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD;
    ELSIF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Cannot delete immutable record in %.%: %',
            TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD;
    END IF;
    RETURN NULL;
END;
$$;

-- ----------------------------------------------------------------------------
-- Trigger: Immutable event_log
-- Purpose: Prevent any modification to event_log entries
-- ----------------------------------------------------------------------------
CREATE TRIGGER trg_event_log_immutable
    BEFORE UPDATE OR DELETE ON aos_core.event_log
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.prevent_modification();

-- ----------------------------------------------------------------------------
-- Trigger Function: prevent_final_state_modification
-- Purpose: Prevent modification of finalized state checkpoints
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.prevent_final_state_modification()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF OLD.is_final = true THEN
            RAISE EXCEPTION 'Cannot update finalized state checkpoint: %', OLD.state_id;
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        IF OLD.is_final = true THEN
            RAISE EXCEPTION 'Cannot delete finalized state checkpoint: %', OLD.state_id;
        END IF;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

-- ----------------------------------------------------------------------------
-- Trigger: Protect finalized state checkpoints
-- ----------------------------------------------------------------------------
CREATE TRIGGER trg_workflow_state_immutable
    BEFORE UPDATE OR DELETE ON aos_workflow.workflow_state
    FOR EACH ROW
    EXECUTE FUNCTION aos_workflow.prevent_final_state_modification();

-- ----------------------------------------------------------------------------
-- Trigger Function: auto_update_timestamp
-- Purpose: Automatically update updated_at timestamp
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.auto_update_timestamp()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- Apply auto_update_timestamp to tables with updated_at column
CREATE TRIGGER trg_tenant_updated
    BEFORE UPDATE ON aos_auth.tenant
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_principal_updated
    BEFORE UPDATE ON aos_auth.principal
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_persona_updated
    BEFORE UPDATE ON aos_persona.persona
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_skill_updated
    BEFORE UPDATE ON aos_skills.skill
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_workflow_graph_updated
    BEFORE UPDATE ON aos_workflow.workflow_graph
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_doc_updated
    BEFORE UPDATE ON aos_kg.doc
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_task_updated
    BEFORE UPDATE ON aos_collab.task
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_model_registry_updated
    BEFORE UPDATE ON aos_meta.llm_model_registry
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_agent_updated
    BEFORE UPDATE ON aos_agent.agent
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_conversation_updated
    BEFORE UPDATE ON aos_agent.conversation
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_team_updated
    BEFORE UPDATE ON aos_multi_agent.team
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_discussion_updated
    BEFORE UPDATE ON aos_multi_agent.discussion
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_shared_artifact_updated
    BEFORE UPDATE ON aos_multi_agent.shared_artifact
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

-- ----------------------------------------------------------------------------
-- Trigger Function: log_graph_changes
-- Purpose: Audit log for graph modifications
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.log_graph_changes()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Log creation
        INSERT INTO aos_core.event_log (run_id, event_type, event_subtype, payload)
        SELECT 
            r.run_id,
            'graph_modified',
            'node_added',
            jsonb_build_object(
                'graph_id', NEW.graph_id,
                'node_name', NEW.node_name,
                'node_type', NEW.node_type
            )
        FROM aos_core.run r
        WHERE r.graph_id = NEW.graph_id AND r.status = 'running'
        LIMIT 1;
        
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        -- Log update
        INSERT INTO aos_core.event_log (run_id, event_type, event_subtype, payload)
        SELECT 
            r.run_id,
            'graph_modified',
            'node_updated',
            jsonb_build_object(
                'graph_id', NEW.graph_id,
                'node_name', NEW.node_name,
                'changes', jsonb_build_object(
                    'old', row_to_json(OLD),
                    'new', row_to_json(NEW)
                )
            )
        FROM aos_core.run r
        WHERE r.graph_id = NEW.graph_id AND r.status = 'running'
        LIMIT 1;
        
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        -- Log deletion
        INSERT INTO aos_core.event_log (run_id, event_type, event_subtype, payload)
        SELECT 
            r.run_id,
            'graph_modified',
            'node_deleted',
            jsonb_build_object(
                'graph_id', OLD.graph_id,
                'node_name', OLD.node_name
            )
        FROM aos_core.run r
        WHERE r.graph_id = OLD.graph_id AND r.status = 'running'
        LIMIT 1;
        
        RETURN OLD;
    END IF;
    
    RETURN NULL;
END;
$$;

-- Apply graph change logging (optional - can be enabled per-tenant)
-- CREATE TRIGGER trg_workflow_node_audit
--     AFTER INSERT OR UPDATE OR DELETE ON aos_workflow.workflow_graph_node
--     FOR EACH ROW
--     EXECUTE FUNCTION aos_workflow.log_graph_changes();

-- ----------------------------------------------------------------------------
-- Trigger Function: validate_run_status_transition
-- Purpose: Ensure valid status transitions for runs
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.validate_run_status_transition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_valid_transitions jsonb := '{
        "pending": ["running", "cancelled"],
        "running": ["completed", "failed", "interrupted", "cancelled"],
        "interrupted": ["running", "cancelled", "failed"],
        "completed": [],
        "failed": [],
        "cancelled": []
    }'::jsonb;
    v_allowed_next text[];
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    
    SELECT array_agg(value::text) INTO v_allowed_next
    FROM jsonb_array_elements_text(v_valid_transitions->OLD.status);
    
    IF NEW.status = ANY(v_allowed_next) THEN
        RETURN NEW;
    ELSE
        RAISE EXCEPTION 'Invalid status transition from % to %', OLD.status, NEW.status;
    END IF;
END;
$$;

CREATE TRIGGER trg_run_status_transition
    BEFORE UPDATE ON aos_core.run
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION aos_core.validate_run_status_transition();

COMMENT ON FUNCTION aos_core.prevent_modification IS 'Prevent UPDATE/DELETE on immutable records';
COMMENT ON FUNCTION aos_workflow.prevent_final_state_modification IS 'Protect finalized state checkpoints';
COMMENT ON FUNCTION aos_core.auto_update_timestamp IS 'Auto-update updated_at timestamp';
COMMENT ON FUNCTION aos_core.validate_run_status_transition IS 'Validate run status transitions';
