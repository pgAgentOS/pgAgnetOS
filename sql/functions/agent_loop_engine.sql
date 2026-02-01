-- ============================================================================
-- pgAgentOS: Agent Loop Engine
-- Core functions for interacting with external execution engine
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: run_turn
-- Purpose: Execute Turn (Agent Loop: Think → Tool → Observe → Repeat)
-- 
-- This function is called by the runtime that interfaces with the external LLM.
-- PostgreSQL manages only state and recording.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.run_turn(p_turn_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_turn aos_agent.turn;
    v_conversation aos_agent.conversation;
    v_agent aos_agent.agent;
    v_persona aos_persona.persona;
    v_messages jsonb[];
    v_tools jsonb[];
    v_system_prompt text;
    v_effective_params jsonb;
BEGIN
    -- Get Turn Info
    SELECT * INTO v_turn FROM aos_agent.turn WHERE turn_id = p_turn_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Turn not found: %', p_turn_id;
    END IF;
    
    -- Conversation Info
    SELECT * INTO v_conversation 
    FROM aos_agent.conversation WHERE conversation_id = v_turn.conversation_id;
    
    -- Agent Info
    SELECT * INTO v_agent FROM aos_agent.agent WHERE agent_id = v_conversation.agent_id;
    
    -- Persona Info
    IF v_agent.persona_id IS NOT NULL THEN
        SELECT * INTO v_persona FROM aos_persona.persona WHERE persona_id = v_agent.persona_id;
        v_system_prompt := v_persona.system_prompt;
        v_effective_params := aos_persona.get_effective_params(v_agent.persona_id);
    ELSE
        v_system_prompt := 'You are a helpful assistant.';
        v_effective_params := '{}'::jsonb;
    END IF;
    
    -- Assemble Chat History
    SELECT array_agg(
        CASE 
            WHEN row_number() OVER (ORDER BY turn_number) % 2 = 1 THEN
                jsonb_build_object('role', 'user', 'content', user_message)
            ELSE
                jsonb_build_object('role', 'assistant', 'content', assistant_message)
        END
    ) INTO v_messages
    FROM aos_agent.turn
    WHERE conversation_id = v_turn.conversation_id
      AND turn_number <= v_turn.turn_number
      AND (assistant_message IS NOT NULL OR turn_number = v_turn.turn_number);
    
    -- Generate Tool Schema
    SELECT array_agg(
        jsonb_build_object(
            'type', 'function',
            'function', jsonb_build_object(
                'name', s.skill_key,
                'description', s.description,
                'parameters', si.input_schema
            )
        )
    ) INTO v_tools
    FROM unnest(v_agent.tools) AS tool_key
    JOIN aos_skills.skill s ON s.skill_key = tool_key
    LEFT JOIN aos_skills.skill_impl si ON si.skill_key = s.skill_key AND si.enabled = true;
    
    -- Return execution info (for external runtime to call LLM)
    RETURN jsonb_build_object(
        'turn_id', p_turn_id,
        'conversation_id', v_turn.conversation_id,
        'agent', jsonb_build_object(
            'agent_id', v_agent.agent_id,
            'name', v_agent.name,
            'config', v_agent.config
        ),
        'system_prompt', v_system_prompt,
        'messages', v_messages,
        'tools', COALESCE(v_tools, ARRAY[]::jsonb[]),
        'parameters', v_effective_params,
        'current_iteration', v_turn.iteration_count
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: process_tool_call
-- Purpose: Process tool call (Wait if approval needed)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.process_tool_call(
    p_turn_id uuid,
    p_tool_name text,
    p_tool_input jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_agent aos_agent.agent;
    v_conversation aos_agent.conversation;
    v_step_id uuid;
    v_requires_approval bool;
    v_skill aos_skills.skill;
BEGIN
    -- Check Agent Config
    SELECT a.* INTO v_agent
    FROM aos_agent.turn t
    JOIN aos_agent.conversation c ON c.conversation_id = t.conversation_id
    JOIN aos_agent.agent a ON a.agent_id = c.agent_id
    WHERE t.turn_id = p_turn_id;
    
    -- Check Skill
    SELECT * INTO v_skill FROM aos_skills.skill WHERE skill_key = p_tool_name;
    
    -- Determine Approval Requirement
    v_requires_approval := 
        (v_agent.config->>'auto_approve_tools')::bool = false
        OR (v_skill.risk_level IN ('high', 'critical'));
    
    -- Record Tool Call Step
    v_step_id := aos_agent.record_step(
        p_turn_id,
        'tool_call',
        jsonb_build_object(
            'tool', p_tool_name,
            'input', p_tool_input,
            'requires_approval', v_requires_approval
        ),
        CASE WHEN v_requires_approval THEN 'pending' ELSE 'completed' END
    );
    
    -- Update Turn Status if Approval Needed
    IF v_requires_approval THEN
        UPDATE aos_agent.turn
        SET status = 'waiting_tool'
        WHERE turn_id = p_turn_id;
        
        RETURN jsonb_build_object(
            'status', 'awaiting_approval',
            'step_id', v_step_id,
            'tool', p_tool_name
        );
    END IF;
    
    -- Ready to Execute if No Approval Needed
    RETURN jsonb_build_object(
        'status', 'approved',
        'step_id', v_step_id,
        'tool', p_tool_name,
        'input', p_tool_input
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: record_tool_result
-- Purpose: Record Tool Execution Result
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.record_tool_result(
    p_turn_id uuid,
    p_tool_name text,
    p_output jsonb,
    p_success bool DEFAULT true,
    p_error_message text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_step_id uuid;
BEGIN
    v_step_id := aos_agent.record_step(
        p_turn_id,
        'tool_result',
        jsonb_build_object(
            'tool', p_tool_name,
            'output', p_output,
            'success', p_success,
            'error', p_error_message
        ),
        CASE WHEN p_success THEN 'completed' ELSE 'failed' END
    );
    
    -- Return to Processing State (Next Thought Step)
    UPDATE aos_agent.turn
    SET status = 'processing',
        iteration_count = iteration_count + 1
    WHERE turn_id = p_turn_id;
    
    RETURN v_step_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: record_thinking
-- Purpose: Record Agent Thinking Process (Chain of Thought)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.record_thinking(
    p_turn_id uuid,
    p_reasoning text,
    p_next_action text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN aos_agent.record_step(
        p_turn_id,
        'think',
        jsonb_build_object(
            'reasoning', p_reasoning,
            'next_action', p_next_action
        )
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_turn_state
-- Purpose: Get Current Turn State (For Debugging/Monitoring)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.get_turn_state(p_turn_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_turn aos_agent.turn;
    v_steps jsonb[];
    v_pending_approval uuid;
BEGIN
    SELECT * INTO v_turn FROM aos_agent.turn WHERE turn_id = p_turn_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Turn not found: %', p_turn_id;
    END IF;
    
    -- Get All Steps
    SELECT array_agg(jsonb_build_object(
        'step_id', step_id,
        'step_number', step_number,
        'step_type', step_type,
        'content', content,
        'status', status,
        'created_at', created_at,
        'duration_ms', duration_ms
    ) ORDER BY step_number) INTO v_steps
    FROM aos_agent.step WHERE turn_id = p_turn_id;
    
    -- Find Step Pending Approval
    SELECT step_id INTO v_pending_approval
    FROM aos_agent.step
    WHERE turn_id = p_turn_id AND status = 'pending'
    ORDER BY step_number
    LIMIT 1;
    
    RETURN jsonb_build_object(
        'turn_id', v_turn.turn_id,
        'turn_number', v_turn.turn_number,
        'status', v_turn.status,
        'user_message', v_turn.user_message,
        'assistant_message', v_turn.assistant_message,
        'iteration_count', v_turn.iteration_count,
        'steps', COALESCE(v_steps, ARRAY[]::jsonb[]),
        'step_count', array_length(v_steps, 1),
        'pending_approval_step', v_pending_approval,
        'started_at', v_turn.started_at,
        'duration_ms', EXTRACT(EPOCH FROM (COALESCE(v_turn.completed_at, now()) - v_turn.started_at)) * 1000
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_conversation_history
-- Purpose: Get Full Conversation History
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.get_conversation_history(
    p_conversation_id uuid,
    p_include_steps bool DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_conversation aos_agent.conversation;
    v_turns jsonb[];
BEGIN
    SELECT * INTO v_conversation 
    FROM aos_agent.conversation WHERE conversation_id = p_conversation_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Conversation not found: %', p_conversation_id;
    END IF;
    
    IF p_include_steps THEN
        SELECT array_agg(aos_agent.get_turn_state(turn_id) ORDER BY turn_number)
        INTO v_turns
        FROM aos_agent.turn WHERE conversation_id = p_conversation_id;
    ELSE
        SELECT array_agg(jsonb_build_object(
            'turn_number', turn_number,
            'user_message', user_message,
            'assistant_message', assistant_message,
            'status', status
        ) ORDER BY turn_number) INTO v_turns
        FROM aos_agent.turn WHERE conversation_id = p_conversation_id;
    END IF;
    
    RETURN jsonb_build_object(
        'conversation_id', v_conversation.conversation_id,
        'agent_id', v_conversation.agent_id,
        'status', v_conversation.status,
        'total_turns', v_conversation.total_turns,
        'total_tokens', v_conversation.total_tokens,
        'total_cost_usd', v_conversation.total_cost_usd,
        'turns', COALESCE(v_turns, ARRAY[]::jsonb[]),
        'started_at', v_conversation.started_at,
        'last_activity_at', v_conversation.last_activity_at
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: pause_conversation
-- Purpose: Pause Conversation (Admin Intervention)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.pause_conversation(
    p_conversation_id uuid,
    p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE aos_agent.conversation
    SET status = 'paused'
    WHERE conversation_id = p_conversation_id;
    
    -- Pause processing turn
    UPDATE aos_agent.turn
    SET status = 'waiting_human'
    WHERE conversation_id = p_conversation_id AND status = 'processing';
    
    IF p_reason IS NOT NULL THEN
        PERFORM aos_agent.record_step(
            (SELECT turn_id FROM aos_agent.turn 
             WHERE conversation_id = p_conversation_id 
             ORDER BY turn_number DESC LIMIT 1),
            'pause',
            jsonb_build_object('reason', p_reason, 'paused_by', 'admin')
        );
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: resume_conversation
-- Purpose: Resume Conversation
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_agent.resume_conversation(p_conversation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE aos_agent.conversation
    SET status = 'active'
    WHERE conversation_id = p_conversation_id AND status = 'paused';
    
    -- Resume waiting turn
    UPDATE aos_agent.turn
    SET status = 'processing'
    WHERE conversation_id = p_conversation_id AND status = 'waiting_human';
END;
$$;

COMMENT ON FUNCTION aos_agent.run_turn IS 'Returns info for turn execution (for external LLM runtime)';
COMMENT ON FUNCTION aos_agent.process_tool_call IS 'Process tool call (includes approval flow)';
COMMENT ON FUNCTION aos_agent.record_tool_result IS 'Record tool execution result';
COMMENT ON FUNCTION aos_agent.record_thinking IS 'Record agent thinking process';
COMMENT ON FUNCTION aos_agent.get_turn_state IS 'Get turn state';
COMMENT ON FUNCTION aos_agent.get_conversation_history IS 'Get conversation history';
