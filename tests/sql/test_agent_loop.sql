-- ============================================================================
-- pgAgentOS: Test Suite for Agent Loop Architecture
-- Tests for aos_agent schema
-- ============================================================================

-- Test 1: Agent Creation
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_agent_id uuid;
BEGIN
    RAISE NOTICE 'Test 1: Agent creation...';
    
    -- Create tenant
    INSERT INTO aos_auth.tenant (tenant_id, name) 
    VALUES (v_tenant_id, 'agent_test_' || v_tenant_id);
    
    -- Create agent
    v_agent_id := aos_agent.create_agent(
        p_tenant_id := v_tenant_id,
        p_name := 'test_agent',
        p_tools := ARRAY['web_search', 'code_execute'],
        p_config := '{"auto_approve_tools": true}'::jsonb
    );
    
    IF v_agent_id IS NOT NULL THEN
        RAISE NOTICE '  ✓ Agent created: %', v_agent_id;
    ELSE
        RAISE EXCEPTION '  ✗ Agent creation failed';
    END IF;
    
    -- Verify config merge
    IF (SELECT (config->>'auto_approve_tools')::bool FROM aos_agent.agent WHERE agent_id = v_agent_id) = true THEN
        RAISE NOTICE '  ✓ Config merged correctly';
    ELSE
        RAISE EXCEPTION '  ✗ Config merge failed';
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 1: PASSED';
END $$;

-- Test 2: Conversation and Turn Flow
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_agent_id uuid;
    v_conversation_id uuid;
    v_turn_id uuid;
    v_step_count int;
BEGIN
    RAISE NOTICE 'Test 2: Conversation and turn flow...';
    
    -- Setup
    INSERT INTO aos_auth.tenant (tenant_id, name) 
    VALUES (v_tenant_id, 'conv_test_' || v_tenant_id);
    
    v_agent_id := aos_agent.create_agent(
        v_tenant_id, 'conv_agent', NULL, ARRAY['test_tool']
    );
    RAISE NOTICE '  ✓ Agent created';
    
    -- Start conversation
    v_conversation_id := aos_agent.start_conversation(v_agent_id);
    IF v_conversation_id IS NOT NULL THEN
        RAISE NOTICE '  ✓ Conversation started: %', v_conversation_id;
    ELSE
        RAISE EXCEPTION '  ✗ Conversation start failed';
    END IF;
    
    -- Send message
    v_turn_id := aos_agent.send_message(v_conversation_id, 'Hello, agent!');
    IF v_turn_id IS NOT NULL THEN
        RAISE NOTICE '  ✓ Message sent, turn created: %', v_turn_id;
    ELSE
        RAISE EXCEPTION '  ✗ Message send failed';
    END IF;
    
    -- Verify initial step created
    SELECT count(*) INTO v_step_count FROM aos_agent.step WHERE turn_id = v_turn_id;
    IF v_step_count = 1 THEN
        RAISE NOTICE '  ✓ Initial think step created';
    ELSE
        RAISE EXCEPTION '  ✗ Expected 1 step, found %', v_step_count;
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 2: PASSED';
END $$;

-- Test 3: Step Recording
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_agent_id uuid;
    v_conversation_id uuid;
    v_turn_id uuid;
    v_step_id uuid;
    v_step_types text[];
BEGIN
    RAISE NOTICE 'Test 3: Step recording...';
    
    -- Setup
    INSERT INTO aos_auth.tenant (tenant_id, name) 
    VALUES (v_tenant_id, 'step_test_' || v_tenant_id);
    v_agent_id := aos_agent.create_agent(v_tenant_id, 'step_agent');
    v_conversation_id := aos_agent.start_conversation(v_agent_id);
    v_turn_id := aos_agent.send_message(v_conversation_id, 'Test message');
    
    -- Record thinking
    PERFORM aos_agent.record_thinking(v_turn_id, 'Analyzing request...', 'use_tool');
    RAISE NOTICE '  ✓ Thinking step recorded';
    
    -- Record tool call
    v_step_id := aos_agent.record_step(
        v_turn_id, 'tool_call',
        '{"tool": "test_tool", "input": {"query": "test"}}'::jsonb,
        'pending'
    );
    RAISE NOTICE '  ✓ Tool call step recorded';
    
    -- Verify steps
    SELECT array_agg(step_type ORDER BY step_number) INTO v_step_types
    FROM aos_agent.step WHERE turn_id = v_turn_id;
    
    IF v_step_types = ARRAY['think', 'think', 'tool_call'] THEN
        RAISE NOTICE '  ✓ Step sequence correct: %', v_step_types;
    ELSE
        RAISE EXCEPTION '  ✗ Unexpected step sequence: %', v_step_types;
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 3: PASSED';
END $$;

-- Test 4: Admin Approval Flow
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_admin_id uuid := gen_random_uuid();
    v_agent_id uuid;
    v_conversation_id uuid;
    v_turn_id uuid;
    v_step_id uuid;
    v_step_status text;
BEGIN
    RAISE NOTICE 'Test 4: Admin approval flow...';
    
    -- Setup
    INSERT INTO aos_auth.tenant (tenant_id, name) 
    VALUES (v_tenant_id, 'approval_test_' || v_tenant_id);
    
    INSERT INTO aos_auth.principal (principal_id, tenant_id, principal_type, display_name)
    VALUES (v_admin_id, v_tenant_id, 'human', 'Test Admin');
    
    v_agent_id := aos_agent.create_agent(v_tenant_id, 'approval_agent');
    v_conversation_id := aos_agent.start_conversation(v_agent_id);
    v_turn_id := aos_agent.send_message(v_conversation_id, 'Test');
    
    -- Create pending tool call
    v_step_id := aos_agent.record_step(
        v_turn_id, 'tool_call',
        '{"tool": "dangerous_tool", "requires_approval": true}'::jsonb,
        'pending'
    );
    RAISE NOTICE '  ✓ Pending tool call created';
    
    -- Verify in pending_approvals view
    IF EXISTS (SELECT 1 FROM aos_agent.pending_approvals WHERE step_id = v_step_id) THEN
        RAISE NOTICE '  ✓ Step visible in pending_approvals view';
    ELSE
        RAISE EXCEPTION '  ✗ Step not in pending_approvals view';
    END IF;
    
    -- Approve step
    PERFORM aos_agent.approve_step(v_step_id, true, v_admin_id, 'Approved for testing');
    
    SELECT status INTO v_step_status FROM aos_agent.step WHERE step_id = v_step_id;
    IF v_step_status = 'approved' THEN
        RAISE NOTICE '  ✓ Step approved successfully';
    ELSE
        RAISE EXCEPTION '  ✗ Step approval failed, status: %', v_step_status;
    END IF;
    
    -- Verify admin feedback recorded
    IF (SELECT admin_feedback IS NOT NULL FROM aos_agent.step WHERE step_id = v_step_id) THEN
        RAISE NOTICE '  ✓ Admin feedback recorded';
    ELSE
        RAISE EXCEPTION '  ✗ Admin feedback not recorded';
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 4: PASSED';
END $$;

-- Test 5: Turn Completion
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_agent_id uuid;
    v_conversation_id uuid;
    v_turn_id uuid;
    v_turn_status text;
    v_conversation_tokens int;
BEGIN
    RAISE NOTICE 'Test 5: Turn completion...';
    
    -- Setup
    INSERT INTO aos_auth.tenant (tenant_id, name) 
    VALUES (v_tenant_id, 'complete_test_' || v_tenant_id);
    v_agent_id := aos_agent.create_agent(v_tenant_id, 'complete_agent');
    v_conversation_id := aos_agent.start_conversation(v_agent_id);
    v_turn_id := aos_agent.send_message(v_conversation_id, 'Hello');
    
    -- Complete turn
    PERFORM aos_agent.complete_turn(v_turn_id, 'Hello! How can I help?', 150, 0.002);
    
    SELECT status INTO v_turn_status FROM aos_agent.turn WHERE turn_id = v_turn_id;
    IF v_turn_status = 'completed' THEN
        RAISE NOTICE '  ✓ Turn completed';
    ELSE
        RAISE EXCEPTION '  ✗ Turn not completed, status: %', v_turn_status;
    END IF;
    
    -- Verify conversation stats updated
    SELECT total_tokens INTO v_conversation_tokens
    FROM aos_agent.conversation WHERE conversation_id = v_conversation_id;
    
    IF v_conversation_tokens = 150 THEN
        RAISE NOTICE '  ✓ Conversation tokens updated: %', v_conversation_tokens;
    ELSE
        RAISE EXCEPTION '  ✗ Conversation tokens wrong: %', v_conversation_tokens;
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 5: PASSED';
END $$;

-- Test 6: Observation and Feedback
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_admin_id uuid := gen_random_uuid();
    v_agent_id uuid;
    v_conversation_id uuid;
    v_turn_id uuid;
    v_observation_id uuid;
    v_rating_count int;
BEGIN
    RAISE NOTICE 'Test 6: Observation and feedback...';
    
    -- Setup
    INSERT INTO aos_auth.tenant (tenant_id, name) 
    VALUES (v_tenant_id, 'obs_test_' || v_tenant_id);
    
    INSERT INTO aos_auth.principal (principal_id, tenant_id, principal_type, display_name)
    VALUES (v_admin_id, v_tenant_id, 'human', 'Test Admin');
    
    v_agent_id := aos_agent.create_agent(v_tenant_id, 'obs_agent');
    v_conversation_id := aos_agent.start_conversation(v_agent_id);
    v_turn_id := aos_agent.send_message(v_conversation_id, 'Rate me');
    PERFORM aos_agent.complete_turn(v_turn_id, 'Done!', 50, 0.001);
    
    -- Add rating
    v_observation_id := aos_agent.add_observation(
        v_admin_id, 'rating',
        '{"score": 4, "aspects": {"accuracy": 5, "speed": 3}}'::jsonb,
        p_turn_id := v_turn_id
    );
    
    IF v_observation_id IS NOT NULL THEN
        RAISE NOTICE '  ✓ Rating observation created';
    ELSE
        RAISE EXCEPTION '  ✗ Rating observation failed';
    END IF;
    
    -- Verify observation exists
    SELECT count(*) INTO v_rating_count
    FROM aos_agent.observation
    WHERE turn_id = v_turn_id AND observation_type = 'rating';
    
    IF v_rating_count = 1 THEN
        RAISE NOTICE '  ✓ Rating observation found';
    ELSE
        RAISE EXCEPTION '  ✗ Rating observation not found';
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 6: PASSED';
END $$;

-- Test 7: Get Turn State
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_agent_id uuid;
    v_conversation_id uuid;
    v_turn_id uuid;
    v_state jsonb;
BEGIN
    RAISE NOTICE 'Test 7: Get turn state...';
    
    -- Setup
    INSERT INTO aos_auth.tenant (tenant_id, name) 
    VALUES (v_tenant_id, 'state_test_' || v_tenant_id);
    v_agent_id := aos_agent.create_agent(v_tenant_id, 'state_agent');
    v_conversation_id := aos_agent.start_conversation(v_agent_id);
    v_turn_id := aos_agent.send_message(v_conversation_id, 'State test');
    
    -- Add some steps
    PERFORM aos_agent.record_thinking(v_turn_id, 'Thinking...', 'respond');
    PERFORM aos_agent.complete_turn(v_turn_id, 'Response', 100, 0.001);
    
    -- Get state
    v_state := aos_agent.get_turn_state(v_turn_id);
    
    IF v_state->>'status' = 'completed' THEN
        RAISE NOTICE '  ✓ Turn state retrieved, status: completed';
    ELSE
        RAISE EXCEPTION '  ✗ Wrong status in state: %', v_state->>'status';
    END IF;
    
    IF (v_state->>'step_count')::int >= 3 THEN
        RAISE NOTICE '  ✓ Steps included in state: %', v_state->>'step_count';
    ELSE
        RAISE EXCEPTION '  ✗ Wrong step count: %', v_state->>'step_count';
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 7: PASSED';
END $$;

-- Summary
DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'All Agent Loop tests PASSED!';
    RAISE NOTICE '========================================';
END $$;
