-- ============================================================================
-- pgAgentOS: Agent Schema
-- Purpose: Agent loop (conversation, turn, step, memory)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_agent;

-- ----------------------------------------------------------------------------
-- Table: agent
-- Purpose: Agent instance
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.agent (
    agent_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    name text NOT NULL,
    persona_id uuid REFERENCES aos_persona.persona(persona_id),
    
    -- Tools this agent can use
    tools text[] DEFAULT ARRAY[]::text[],
    
    config jsonb DEFAULT '{}'::jsonb,
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    
    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_agent_tenant ON aos_agent.agent(tenant_id);
CREATE INDEX idx_agent_persona ON aos_agent.agent(persona_id);

-- ----------------------------------------------------------------------------
-- Table: conversation
-- Purpose: Chat session
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.conversation (
    conversation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    agent_id uuid NOT NULL REFERENCES aos_agent.agent(agent_id) ON DELETE CASCADE,
    
    -- Snapshot of persona version at conversation start
    persona_version_id uuid REFERENCES aos_persona.version(version_id),
    
    -- Status
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'paused', 'completed')),
    
    -- Metadata
    title text,
    metadata jsonb DEFAULT '{}'::jsonb,
    
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz
);

CREATE INDEX idx_conversation_tenant ON aos_agent.conversation(tenant_id);
CREATE INDEX idx_conversation_agent ON aos_agent.conversation(agent_id);
CREATE INDEX idx_conversation_status ON aos_agent.conversation(status);

-- ----------------------------------------------------------------------------
-- Table: turn
-- Purpose: Single turn (user message → assistant response)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.turn (
    turn_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES aos_agent.conversation(conversation_id) ON DELETE CASCADE,
    run_id uuid REFERENCES aos_core.run(run_id),
    
    turn_number int NOT NULL,
    
    -- Messages
    user_message text NOT NULL,
    assistant_message text,
    
    -- Status
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'thinking', 'tool_use', 'completed', 'failed')),
    
    -- Timing
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    
    UNIQUE (conversation_id, turn_number)
);

CREATE INDEX idx_turn_conversation ON aos_agent.turn(conversation_id);
CREATE INDEX idx_turn_status ON aos_agent.turn(status);

-- ----------------------------------------------------------------------------
-- Table: step
-- Purpose: Tool execution within a turn
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.step (
    step_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    turn_id uuid NOT NULL REFERENCES aos_agent.turn(turn_id) ON DELETE CASCADE,
    
    step_number int NOT NULL,
    
    -- Tool call
    tool_name text NOT NULL,
    tool_input jsonb NOT NULL,
    tool_output jsonb,
    
    -- Status
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'running', 'completed', 'failed')),
    error text,
    
    -- Timing
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    
    UNIQUE (turn_id, step_number)
);

CREATE INDEX idx_step_turn ON aos_agent.step(turn_id);

-- ----------------------------------------------------------------------------
-- Table: memory
-- Purpose: Session/conversation memory
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.memory (
    memory_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES aos_agent.conversation(conversation_id) ON DELETE CASCADE,
    
    key text NOT NULL,
    value jsonb NOT NULL,
    
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    
    UNIQUE (conversation_id, key)
);

CREATE INDEX idx_memory_conversation ON aos_agent.memory(conversation_id);

-- ----------------------------------------------------------------------------
-- Function: start_conversation
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.start_conversation(
    p_agent_id uuid,
    p_title text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_agent aos_agent.agent;
    v_persona aos_persona.persona;
    v_conv_id uuid;
BEGIN
    SELECT * INTO v_agent FROM aos_agent.agent WHERE agent_id = p_agent_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Agent not found: %', p_agent_id;
    END IF;
    
    -- Get current persona version
    SELECT * INTO v_persona 
    FROM aos_persona.persona WHERE persona_id = v_agent.persona_id;
    
    INSERT INTO aos_agent.conversation (
        tenant_id, agent_id, persona_version_id, title
    ) VALUES (
        v_agent.tenant_id, p_agent_id, v_persona.current_version_id, p_title
    ) RETURNING conversation_id INTO v_conv_id;
    
    RETURN v_conv_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: send_message
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.send_message(
    p_conversation_id uuid,
    p_message text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_conv aos_agent.conversation;
    v_turn_number int;
    v_turn_id uuid;
    v_run_id uuid;
BEGIN
    SELECT * INTO v_conv 
    FROM aos_agent.conversation WHERE conversation_id = p_conversation_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Conversation not found: %', p_conversation_id;
    END IF;
    
    -- Get next turn number
    SELECT COALESCE(MAX(turn_number), 0) + 1 INTO v_turn_number
    FROM aos_agent.turn WHERE conversation_id = p_conversation_id;
    
    -- Create run
    INSERT INTO aos_core.run (tenant_id, run_type, input)
    VALUES (v_conv.tenant_id, 'agent', jsonb_build_object('message', p_message))
    RETURNING run_id INTO v_run_id;
    
    -- Create turn
    INSERT INTO aos_agent.turn (conversation_id, run_id, turn_number, user_message)
    VALUES (p_conversation_id, v_run_id, v_turn_number, p_message)
    RETURNING turn_id INTO v_turn_id;
    
    -- Update conversation
    UPDATE aos_agent.conversation 
    SET updated_at = now() 
    WHERE conversation_id = p_conversation_id;
    
    RETURN v_turn_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: store_memory
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.store_memory(
    p_conversation_id uuid,
    p_key text,
    p_value jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO aos_agent.memory (conversation_id, key, value)
    VALUES (p_conversation_id, p_key, p_value)
    ON CONFLICT (conversation_id, key) DO UPDATE
    SET value = p_value, updated_at = now();
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: recall_memory
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.recall_memory(
    p_conversation_id uuid,
    p_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_key IS NOT NULL THEN
        RETURN (SELECT value FROM aos_agent.memory 
                WHERE conversation_id = p_conversation_id AND key = p_key);
    ELSE
        RETURN (SELECT jsonb_object_agg(key, value) 
                FROM aos_agent.memory 
                WHERE conversation_id = p_conversation_id);
    END IF;
END;
$$;

COMMENT ON SCHEMA aos_agent IS 'pgAgentOS: Agent loop';
COMMENT ON TABLE aos_agent.agent IS 'Agent instances';
COMMENT ON TABLE aos_agent.conversation IS 'Chat sessions';
COMMENT ON TABLE aos_agent.turn IS 'Conversation turns';
COMMENT ON TABLE aos_agent.step IS 'Tool execution steps';
COMMENT ON TABLE aos_agent.memory IS 'Session memory';
