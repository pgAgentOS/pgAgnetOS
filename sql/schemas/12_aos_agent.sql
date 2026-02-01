-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_agent (Simplified Agent Loop Architecture)
-- 
-- New Design Philosophy:
-- - "Conversation → Turn → Step" structure instead of graphs
-- - All steps are transparently observable
-- - Admin can intervene at any time
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_agent;

-- ============================================================================
-- CORE: Agent Definition
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: agent
-- Purpose: Agent Definition (Persona + Tools + Config)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.agent (
    agent_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Basic Info
    name text NOT NULL,
    display_name text,
    description text,
    avatar_url text,
    
    -- Persona Link
    persona_id uuid REFERENCES aos_persona.persona(persona_id),
    
    -- Available Tools (Skill Key Array)
    tools text[] DEFAULT ARRAY[]::text[],
    
    -- Behavior Config
    config jsonb DEFAULT '{
        "max_iterations": 10,
        "max_tokens_per_turn": 4096,
        "thinking_visible": true,
        "auto_approve_tools": false,
        "pause_before_tool": false,
        "pause_after_tool": false
    }'::jsonb,
    
    -- Meta
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    
    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_agent_tenant ON aos_agent.agent(tenant_id);
CREATE INDEX idx_agent_active ON aos_agent.agent(is_active) WHERE is_active = true;

-- ============================================================================
-- CORE: Conversation
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: conversation
-- Purpose: Conversation session between user and agent
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.conversation (
    conversation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    agent_id uuid NOT NULL REFERENCES aos_agent.agent(agent_id) ON DELETE CASCADE,
    
    -- Participants
    user_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    
    -- Status
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'paused', 'completed', 'archived')),
    
    -- Context
    title text,                                      -- Auto-generated or user-defined
    summary text,                                    -- AI generated summary
    context jsonb DEFAULT '{}'::jsonb,               -- Additional context
    
    -- Stats
    total_turns int DEFAULT 0,
    total_tokens int DEFAULT 0,
    total_cost_usd numeric(10,6) DEFAULT 0,
    
    -- Timing
    started_at timestamptz NOT NULL DEFAULT now(),
    last_activity_at timestamptz DEFAULT now(),
    completed_at timestamptz
);

CREATE INDEX idx_conversation_tenant ON aos_agent.conversation(tenant_id);
CREATE INDEX idx_conversation_agent ON aos_agent.conversation(agent_id);
CREATE INDEX idx_conversation_user ON aos_agent.conversation(user_principal_id);
CREATE INDEX idx_conversation_status ON aos_agent.conversation(status);
CREATE INDEX idx_conversation_recent ON aos_agent.conversation(last_activity_at DESC);

-- ============================================================================
-- CORE: Turn
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: turn
-- Purpose: Each turn in conversation (User Input → Agent Response)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.turn (
    turn_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid NOT NULL REFERENCES aos_agent.conversation(conversation_id) ON DELETE CASCADE,
    
    -- Sequence
    turn_number int NOT NULL,
    
    -- User Input
    user_message text NOT NULL,
    user_attachments jsonb DEFAULT '[]'::jsonb,      -- files, images, etc.
    
    -- Agent Response
    assistant_message text,
    assistant_attachments jsonb DEFAULT '[]'::jsonb,
    
    -- Status
    status text NOT NULL DEFAULT 'processing'
        CHECK (status IN (
            'processing',     -- processing
            'waiting_tool',   -- waiting for tool approval
            'waiting_human',  -- waiting for human input
            'completed',      -- completed
            'failed',         -- failed
            'cancelled'       -- cancelled
        )),
    
    -- Error Info
    error_message text,
    error_details jsonb,
    
    -- Stats
    iteration_count int DEFAULT 0,
    tokens_used int DEFAULT 0,
    cost_usd numeric(10,6) DEFAULT 0,
    
    -- Timing
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    duration_ms bigint,
    
    UNIQUE (conversation_id, turn_number)
);

CREATE INDEX idx_turn_conversation ON aos_agent.turn(conversation_id);
CREATE INDEX idx_turn_status ON aos_agent.turn(status);
CREATE INDEX idx_turn_order ON aos_agent.turn(conversation_id, turn_number);

-- ============================================================================
-- CORE: Step (Observable Step)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: step
-- Purpose: Each step within a turn (Granular execution log)
-- 
-- Types:
--   think     : Chain of Thought
--   tool_call : Request tool execution
--   tool_result: Result of tool execution
--   respond   : Generate response
--   pause     : Paused (waiting approval)
--   error     : Error occurred
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.step (
    step_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    turn_id uuid NOT NULL REFERENCES aos_agent.turn(turn_id) ON DELETE CASCADE,
    
    -- Step Sequence
    step_number int NOT NULL,
    
    -- Type
    step_type text NOT NULL CHECK (step_type IN (
        'think',
        'tool_call',
        'tool_result',
        'respond',
        'pause',
        'error'
    )),
    
    -- Content (Schema varies by type)
    content jsonb NOT NULL DEFAULT '{}'::jsonb,
    /*
    think:       {"reasoning": "...", "next_action": "..."}
    tool_call:   {"tool": "web_search", "input": {...}, "requires_approval": true}
    tool_result: {"tool": "web_search", "output": {...}, "success": true}
    respond:     {"message": "...", "confidence": 0.95}
    pause:       {"reason": "tool_approval", "awaiting": "admin"}
    error:       {"type": "rate_limit", "message": "...", "recoverable": true}
    */
    
    -- Status
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled', 'approved', 'rejected')),
    
    -- Admin Feedback
    admin_feedback jsonb,                            -- {"action": "approve", "note": "OK", "by": "..."}
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    duration_ms bigint,
    
    UNIQUE (turn_id, step_number)
);

CREATE INDEX idx_step_turn ON aos_agent.step(turn_id);
CREATE INDEX idx_step_type ON aos_agent.step(step_type);
CREATE INDEX idx_step_status ON aos_agent.step(status);
CREATE INDEX idx_step_order ON aos_agent.step(turn_id, step_number);
CREATE INDEX idx_step_pending ON aos_agent.step(status) WHERE status IN ('pending', 'running');

-- ============================================================================
-- CORE: Memory (Conversation Memory)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: memory
-- Purpose: Agent's Long/Short-term memory
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.memory (
    memory_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id uuid REFERENCES aos_agent.conversation(conversation_id) ON DELETE CASCADE,
    agent_id uuid REFERENCES aos_agent.agent(agent_id) ON DELETE CASCADE,
    
    -- Memory Type
    memory_type text NOT NULL CHECK (memory_type IN (
        'conversation',   -- Conversation History
        'working',        -- Working Memory
        'episodic',       -- Episodic Memory
        'semantic',       -- Semantic Memory (Facts)
        'procedural'      -- Procedural Memory (Methods)
    )),
    
    -- Content
    key text NOT NULL,
    value jsonb NOT NULL,
    
    -- Importance & Access
    importance float DEFAULT 0.5,
    access_count int DEFAULT 0,
    last_accessed_at timestamptz DEFAULT now(),
    
    -- Expiry
    expires_at timestamptz,
    
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_memory_conversation ON aos_agent.memory(conversation_id);
CREATE INDEX idx_memory_agent ON aos_agent.memory(agent_id);
CREATE INDEX idx_memory_type ON aos_agent.memory(memory_type);
CREATE INDEX idx_memory_key ON aos_agent.memory(key);

-- ============================================================================
-- ADMIN: Observation & Intervention
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: observation
-- Purpose: Admin observations and feedback
-- ----------------------------------------------------------------------------
CREATE TABLE aos_agent.observation (
    observation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Target (Set only one)
    conversation_id uuid REFERENCES aos_agent.conversation(conversation_id),
    turn_id uuid REFERENCES aos_agent.turn(turn_id),
    step_id uuid REFERENCES aos_agent.step(step_id),
    
    -- content
    observer_id uuid REFERENCES aos_auth.principal(principal_id),
    observation_type text NOT NULL CHECK (observation_type IN (
        'note',           -- Note
        'flag',           -- Issue Flag
        'correction',     -- Correction Proposal
        'approval',       -- Approval
        'rejection',      -- Rejection
        'rating'          -- Rating
    )),
    
    content jsonb NOT NULL,
    /*
    note:       {"text": "Good"}
    flag:       {"severity": "warning", "reason": "Cost too high"}
    correction: {"original": "...", "corrected": "...", "reason": "..."}
    approval:   {"approved": true, "note": "OK"}
    rejection:  {"reason": "Unsafe", "alternative": "..."}
    rating:     {"score": 4, "aspects": {"accuracy": 5, "speed": 3}}
    */
    
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_observation_conversation ON aos_agent.observation(conversation_id);
CREATE INDEX idx_observation_turn ON aos_agent.observation(turn_id);
CREATE INDEX idx_observation_step ON aos_agent.observation(step_id);
CREATE INDEX idx_observation_type ON aos_agent.observation(observation_type);

-- ============================================================================
-- FUNCTIONS: Core Agent Functions
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: create_agent
-- Purpose: Create new agent
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.create_agent(
    p_tenant_id uuid,
    p_name text,
    p_persona_id uuid DEFAULT NULL,
    p_tools text[] DEFAULT ARRAY[]::text[],
    p_config jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_agent_id uuid;
    v_default_config jsonb := '{
        "max_iterations": 10,
        "max_tokens_per_turn": 4096,
        "thinking_visible": true,
        "auto_approve_tools": false,
        "pause_before_tool": false,
        "pause_after_tool": false
    }'::jsonb;
BEGIN
    INSERT INTO aos_agent.agent (tenant_id, name, persona_id, tools, config)
    VALUES (p_tenant_id, p_name, p_persona_id, p_tools, v_default_config || p_config)
    RETURNING agent_id INTO v_agent_id;
    
    RETURN v_agent_id;
END;
$$;


-- ----------------------------------------------------------------------------
-- Function: start_conversation
-- Purpose: Start conversation
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.start_conversation(
    p_agent_id uuid,
    p_user_principal_id uuid DEFAULT NULL,
    p_context jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_agent aos_agent.agent;
    v_conversation_id uuid;
BEGIN
    SELECT * INTO v_agent FROM aos_agent.agent WHERE agent_id = p_agent_id AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Agent not found or inactive: %', p_agent_id;
    END IF;
    
    INSERT INTO aos_agent.conversation (tenant_id, agent_id, user_principal_id, context)
    VALUES (v_agent.tenant_id, p_agent_id, p_user_principal_id, p_context)
    RETURNING conversation_id INTO v_conversation_id;
    
    RETURN v_conversation_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: send_message
-- Purpose: Send user message → Start new turn
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.send_message(
    p_conversation_id uuid,
    p_message text,
    p_attachments jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_conversation aos_agent.conversation;
    v_turn_number int;
    v_turn_id uuid;
BEGIN
    -- Check conversation
    SELECT * INTO v_conversation 
    FROM aos_agent.conversation 
    WHERE conversation_id = p_conversation_id AND status = 'active';
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Conversation not found or not active: %', p_conversation_id;
    END IF;
    
    -- Next turn number
    SELECT COALESCE(MAX(turn_number), 0) + 1 INTO v_turn_number
    FROM aos_agent.turn WHERE conversation_id = p_conversation_id;
    
    -- Create turn
    INSERT INTO aos_agent.turn (conversation_id, turn_number, user_message, user_attachments)
    VALUES (p_conversation_id, v_turn_number, p_message, p_attachments)
    RETURNING turn_id INTO v_turn_id;
    
    -- Update conversation stats
    UPDATE aos_agent.conversation
    SET total_turns = total_turns + 1,
        last_activity_at = now()
    WHERE conversation_id = p_conversation_id;
    
    -- Create first step (think)
    INSERT INTO aos_agent.step (turn_id, step_number, step_type, status, content)
    VALUES (v_turn_id, 1, 'think', 'pending', 
            jsonb_build_object('input', p_message, 'reasoning', NULL));
    
    RETURN v_turn_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: record_step
-- Purpose: Record step (called by external execution engine)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.record_step(
    p_turn_id uuid,
    p_step_type text,
    p_content jsonb,
    p_status text DEFAULT 'completed'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_step_number int;
    v_step_id uuid;
BEGIN
    -- Next step number
    SELECT COALESCE(MAX(step_number), 0) + 1 INTO v_step_number
    FROM aos_agent.step WHERE turn_id = p_turn_id;
    
    -- Create step
    INSERT INTO aos_agent.step (turn_id, step_number, step_type, content, status, completed_at)
    VALUES (p_turn_id, v_step_number, p_step_type, p_content, p_status,
            CASE WHEN p_status = 'completed' THEN now() ELSE NULL END)
    RETURNING step_id INTO v_step_id;
    
    RETURN v_step_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: approve_step
-- Purpose: Admin approves/rejects pending step
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.approve_step(
    p_step_id uuid,
    p_approved bool,
    p_admin_id uuid,
    p_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE aos_agent.step
    SET status = CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END,
        admin_feedback = jsonb_build_object(
            'action', CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END,
            'by', p_admin_id,
            'note', p_note,
            'at', now()
        ),
        completed_at = now()
    WHERE step_id = p_step_id AND status IN ('pending', 'running');
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Step not found or not in pending/running state: %', p_step_id;
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: complete_turn
-- Purpose: Complete turn (set response)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.complete_turn(
    p_turn_id uuid,
    p_assistant_message text,
    p_tokens_used int DEFAULT 0,
    p_cost_usd numeric DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_conversation_id uuid;
    v_duration_ms bigint;
BEGIN
    -- Update turn
    UPDATE aos_agent.turn
    SET assistant_message = p_assistant_message,
        status = 'completed',
        tokens_used = p_tokens_used,
        cost_usd = p_cost_usd,
        completed_at = now(),
        duration_ms = EXTRACT(EPOCH FROM (now() - started_at)) * 1000
    WHERE turn_id = p_turn_id
    RETURNING conversation_id, duration_ms INTO v_conversation_id, v_duration_ms;
    
    -- Update conversation stats
    UPDATE aos_agent.conversation
    SET total_tokens = total_tokens + p_tokens_used,
        total_cost_usd = total_cost_usd + p_cost_usd,
        last_activity_at = now()
    WHERE conversation_id = v_conversation_id;
    
    -- Record response step
    PERFORM aos_agent.record_step(p_turn_id, 'respond', 
        jsonb_build_object('message', p_assistant_message));
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: add_observation
-- Purpose: Add Admin observation
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.add_observation(
    p_observer_id uuid,
    p_observation_type text,
    p_content jsonb,
    p_conversation_id uuid DEFAULT NULL,
    p_turn_id uuid DEFAULT NULL,
    p_step_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_observation_id uuid;
BEGIN
    INSERT INTO aos_agent.observation (
        observer_id, observation_type, content,
        conversation_id, turn_id, step_id
    ) VALUES (
        p_observer_id, p_observation_type, p_content,
        p_conversation_id, p_turn_id, p_step_id
    )
    RETURNING observation_id INTO v_observation_id;
    
    RETURN v_observation_id;
END;
$$;

-- ============================================================================
-- VIEWS: Admin Dashboard Views
-- ============================================================================

-- ----------------------------------------------------------------------------
-- View: live_activity
-- Purpose: Real-time agent activity monitoring
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.live_activity AS
SELECT 
    c.conversation_id,
    a.name as agent_name,
    c.status as conversation_status,
    t.turn_id,
    t.turn_number,
    t.user_message,
    t.status as turn_status,
    s.step_id,
    s.step_number,
    s.step_type,
    s.content,
    s.status as step_status,
    s.created_at as step_started_at,
    EXTRACT(EPOCH FROM (now() - s.created_at))::int as seconds_ago
FROM aos_agent.conversation c
JOIN aos_agent.agent a ON a.agent_id = c.agent_id
LEFT JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id
LEFT JOIN aos_agent.step s ON s.turn_id = t.turn_id
WHERE c.status = 'active'
  AND (t.status IN ('processing', 'waiting_tool', 'waiting_human') OR t.status IS NULL)
ORDER BY s.created_at DESC;

-- ----------------------------------------------------------------------------
-- View: pending_approvals
-- Purpose: Steps awaiting approval
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.pending_approvals AS
SELECT 
    s.step_id,
    a.name as agent_name,
    c.conversation_id,
    t.turn_number,
    t.user_message,
    s.step_number,
    s.step_type,
    s.content,
    s.created_at,
    EXTRACT(EPOCH FROM (now() - s.created_at))::int as waiting_seconds
FROM aos_agent.step s
JOIN aos_agent.turn t ON t.turn_id = s.turn_id
JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
JOIN aos_agent.agent a ON a.agent_id = c.agent_id
WHERE s.status = 'pending' 
  AND s.step_type IN ('tool_call', 'pause')
ORDER BY s.created_at;

-- ----------------------------------------------------------------------------
-- View: conversation_timeline
-- Purpose: Conversation timeline (chronological steps)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.conversation_timeline AS
SELECT 
    c.conversation_id,
    t.turn_id,
    t.turn_number,
    'user' as actor,
    t.user_message as content,
    NULL as step_type,
    t.started_at as timestamp
FROM aos_agent.conversation c
JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id

UNION ALL

SELECT 
    c.conversation_id,
    t.turn_id,
    t.turn_number,
    'agent' as actor,
    s.content::text as content,
    s.step_type,
    s.created_at as timestamp
FROM aos_agent.conversation c
JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id
JOIN aos_agent.step s ON s.turn_id = t.turn_id

ORDER BY conversation_id, timestamp;

-- ----------------------------------------------------------------------------
-- View: agent_stats
-- Purpose: Agent Statistics
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_agent.agent_stats AS
SELECT 
    a.agent_id,
    a.name,
    a.display_name,
    count(DISTINCT c.conversation_id) as total_conversations,
    count(DISTINCT t.turn_id) as total_turns,
    sum(t.tokens_used) as total_tokens,
    sum(t.cost_usd) as total_cost,
    avg(t.duration_ms)::int as avg_turn_duration_ms,
    count(*) FILTER (WHERE t.status = 'completed') as successful_turns,
    count(*) FILTER (WHERE t.status = 'failed') as failed_turns,
    max(c.last_activity_at) as last_activity
FROM aos_agent.agent a
LEFT JOIN aos_agent.conversation c ON c.agent_id = a.agent_id
LEFT JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id
GROUP BY a.agent_id, a.name, a.display_name;

COMMENT ON SCHEMA aos_agent IS 'pgAgentOS: Simplified Agent Loop Architecture';
COMMENT ON TABLE aos_agent.agent IS 'Agent Definition';
COMMENT ON TABLE aos_agent.conversation IS 'Conversation Session';
COMMENT ON TABLE aos_agent.turn IS 'Conversation Turn';
COMMENT ON TABLE aos_agent.step IS 'Observable Step';
COMMENT ON TABLE aos_agent.memory IS 'Agent Memory';
COMMENT ON TABLE aos_agent.observation IS 'Admin Observation & Feedback';
