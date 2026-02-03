-- ============================================================================
-- pgAgentOS: Triggers (Simplified)
-- Purpose: Immutability and auto-update
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: immutable_record
-- Purpose: Prevent updates to immutable records
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_core.immutable_record()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Cannot update immutable record in %', TG_TABLE_NAME;
    RETURN NULL;
END;
$$;

-- ----------------------------------------------------------------------------
-- Event immutability
-- ----------------------------------------------------------------------------
CREATE TRIGGER trg_event_immutable
    BEFORE UPDATE ON aos_core.event
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.immutable_record();

-- ----------------------------------------------------------------------------
-- Persona version immutability
-- ----------------------------------------------------------------------------
CREATE TRIGGER trg_persona_version_immutable
    BEFORE UPDATE ON aos_persona.version
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.immutable_record();

-- ----------------------------------------------------------------------------
-- Function: auto_update_timestamp
-- Purpose: Auto-update updated_at column
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

-- Apply to tables with updated_at
CREATE TRIGGER trg_conversation_updated
    BEFORE UPDATE ON aos_agent.conversation
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_memory_updated
    BEFORE UPDATE ON aos_agent.memory
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();

CREATE TRIGGER trg_persona_updated
    BEFORE UPDATE ON aos_persona.persona
    FOR EACH ROW
    EXECUTE FUNCTION aos_core.auto_update_timestamp();
