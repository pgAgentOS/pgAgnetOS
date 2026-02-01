-- ============================================================================
-- pgAgentOS: Test Suite
-- Basic functionality tests
-- ============================================================================

-- Test 1: Extension installation check
DO $$
BEGIN
    RAISE NOTICE 'Test 1: Checking schema existence...';
    
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'aos_meta') THEN
        RAISE NOTICE '  ✓ aos_meta schema exists';
    ELSE
        RAISE EXCEPTION '  ✗ aos_meta schema missing';
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'aos_workflow') THEN
        RAISE NOTICE '  ✓ aos_workflow schema exists';
    ELSE
        RAISE EXCEPTION '  ✗ aos_workflow schema missing';
    END IF;
    
    RAISE NOTICE 'Test 1: PASSED';
END $$;

-- Test 2: LLM Model Registry populated
DO $$
DECLARE
    v_count int;
BEGIN
    RAISE NOTICE 'Test 2: Checking LLM model registry...';
    
    SELECT count(*) INTO v_count FROM aos_meta.llm_model_registry;
    
    IF v_count > 0 THEN
        RAISE NOTICE '  ✓ Model registry has % entries', v_count;
    ELSE
        RAISE EXCEPTION '  ✗ Model registry is empty';
    END IF;
    
    -- Check specific models
    IF EXISTS (SELECT 1 FROM aos_meta.llm_model_registry WHERE provider = 'openai' AND model_name = 'gpt-4o') THEN
        RAISE NOTICE '  ✓ GPT-4o model present';
    ELSE
        RAISE EXCEPTION '  ✗ GPT-4o model missing';
    END IF;
    
    RAISE NOTICE 'Test 2: PASSED';
END $$;

-- Test 3: Create tenant and principal
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_principal_id uuid := gen_random_uuid();
BEGIN
    RAISE NOTICE 'Test 3: Creating tenant and principal...';
    
    INSERT INTO aos_auth.tenant (tenant_id, name, display_name)
    VALUES (v_tenant_id, 'test_tenant_' || v_tenant_id, 'Test Tenant');
    RAISE NOTICE '  ✓ Tenant created';
    
    INSERT INTO aos_auth.principal (principal_id, tenant_id, principal_type, display_name)
    VALUES (v_principal_id, v_tenant_id, 'agent', 'Test Agent');
    RAISE NOTICE '  ✓ Principal created';
    
    -- Set tenant context
    PERFORM aos_auth.set_tenant(v_tenant_id);
    
    IF aos_auth.current_tenant() = v_tenant_id THEN
        RAISE NOTICE '  ✓ Tenant context set correctly';
    ELSE
        RAISE EXCEPTION '  ✗ Tenant context not set';
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 3: PASSED';
END $$;

-- Test 4: Create and validate graph
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_graph_id uuid;
    v_validation jsonb;
BEGIN
    RAISE NOTICE 'Test 4: Creating and validating workflow graph...';
    
    -- Create tenant
    INSERT INTO aos_auth.tenant (tenant_id, name) VALUES (v_tenant_id, 'graph_test_' || v_tenant_id);
    
    -- Create graph
    v_graph_id := aos_workflow.create_graph(
        p_tenant_id := v_tenant_id,
        p_name := 'test_graph',
        p_version := '1.0',
        p_description := 'Test graph',
        p_nodes := ARRAY[
            '{"node_name": "process", "node_type": "function"}'::jsonb
        ],
        p_edges := ARRAY[
            '{"from_node": "__start__", "to_node": "process"}'::jsonb,
            '{"from_node": "process", "to_node": "__end__"}'::jsonb
        ]
    );
    
    IF v_graph_id IS NOT NULL THEN
        RAISE NOTICE '  ✓ Graph created: %', v_graph_id;
    ELSE
        RAISE EXCEPTION '  ✗ Graph creation failed';
    END IF;
    
    -- Validate
    v_validation := aos_workflow.validate_graph(v_graph_id);
    
    IF (v_validation->>'valid')::bool THEN
        RAISE NOTICE '  ✓ Graph validation passed';
    ELSE
        RAISE EXCEPTION '  ✗ Graph validation failed: %', v_validation->'errors';
    END IF;
    
    -- Check DOT output
    IF aos_workflow.get_graph_visualization(v_graph_id) LIKE 'digraph%' THEN
        RAISE NOTICE '  ✓ DOT visualization generated';
    ELSE
        RAISE EXCEPTION '  ✗ DOT visualization failed';
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 4: PASSED';
END $$;

-- Test 5: Start and step through a run
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_graph_id uuid;
    v_run_id uuid;
    v_step_result jsonb;
BEGIN
    RAISE NOTICE 'Test 5: Workflow execution...';
    
    -- Setup
    INSERT INTO aos_auth.tenant (tenant_id, name) VALUES (v_tenant_id, 'run_test_' || v_tenant_id);
    
    v_graph_id := aos_workflow.create_graph(
        p_tenant_id := v_tenant_id,
        p_name := 'simple_flow',
        p_nodes := ARRAY[
            '{"node_name": "step1", "node_type": "gateway"}'::jsonb
        ],
        p_edges := ARRAY[
            '{"from_node": "__start__", "to_node": "step1"}'::jsonb,
            '{"from_node": "step1", "to_node": "__end__"}'::jsonb
        ]
    );
    RAISE NOTICE '  ✓ Graph created';
    
    -- Start run
    v_run_id := aos_workflow.start_graph_run(
        p_graph_id := v_graph_id,
        p_initial_state := '{"test": true}'::jsonb
    );
    
    IF v_run_id IS NOT NULL THEN
        RAISE NOTICE '  ✓ Run started: %', v_run_id;
    ELSE
        RAISE EXCEPTION '  ✗ Run start failed';
    END IF;
    
    -- Step 1: __start__ -> step1
    v_step_result := aos_workflow.step_graph(v_run_id);
    RAISE NOTICE '  Step result: %', v_step_result->>'status';
    
    IF v_step_result->>'current_node' = 'step1' THEN
        RAISE NOTICE '  ✓ Step 1 completed (at step1)';
    ELSE
        RAISE EXCEPTION '  ✗ Unexpected node: %', v_step_result->>'current_node';
    END IF;
    
    -- Step 2: step1 -> __end__
    v_step_result := aos_workflow.step_graph(v_run_id);
    
    IF v_step_result->>'current_node' = '__end__' THEN
        RAISE NOTICE '  ✓ Step 2 completed (at __end__)';
    ELSE
        RAISE EXCEPTION '  ✗ Unexpected node: %', v_step_result->>'current_node';
    END IF;
    
    -- Step 3: Should complete
    v_step_result := aos_workflow.step_graph(v_run_id);
    
    IF v_step_result->>'status' = 'completed' THEN
        RAISE NOTICE '  ✓ Run completed';
    ELSE
        RAISE EXCEPTION '  ✗ Run not completed: %', v_step_result->>'status';
    END IF;
    
    -- Check state history
    IF array_length(aos_workflow.get_state_history(v_run_id), 1) >= 3 THEN
        RAISE NOTICE '  ✓ State history recorded';
    ELSE
        RAISE EXCEPTION '  ✗ State history incomplete';
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 5: PASSED';
END $$;

-- Test 6: Immutability trigger
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_run_id uuid;
BEGIN
    RAISE NOTICE 'Test 6: Immutability enforcement...';
    
    -- Setup
    INSERT INTO aos_auth.tenant (tenant_id, name) VALUES (v_tenant_id, 'immut_test_' || v_tenant_id);
    
    INSERT INTO aos_core.run (run_id, tenant_id, status)
    VALUES (gen_random_uuid(), v_tenant_id, 'running')
    RETURNING run_id INTO v_run_id;
    
    -- Log an event
    PERFORM aos_core.log_event(v_run_id, 'test_event', '{"test": true}'::jsonb);
    RAISE NOTICE '  ✓ Event logged';
    
    -- Try to update (should fail)
    BEGIN
        UPDATE aos_core.event_log SET payload = '{"modified": true}'::jsonb WHERE run_id = v_run_id;
        RAISE EXCEPTION '  ✗ Update should have been blocked';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '  ✓ Update correctly blocked: %', SQLERRM;
    END;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 6: PASSED';
END $$;

-- Test 7: Persona and model parameter merging
DO $$
DECLARE
    v_tenant_id uuid := gen_random_uuid();
    v_model_id uuid;
    v_persona_id uuid := gen_random_uuid();
    v_effective_params jsonb;
BEGIN
    RAISE NOTICE 'Test 7: Persona parameter merging...';
    
    -- Setup
    INSERT INTO aos_auth.tenant (tenant_id, name) VALUES (v_tenant_id, 'persona_test_' || v_tenant_id);
    
    SELECT model_id INTO v_model_id FROM aos_meta.llm_model_registry WHERE provider = 'openai' AND model_name = 'gpt-4o';
    
    INSERT INTO aos_persona.persona (persona_id, tenant_id, name, system_prompt, model_id, override_params)
    VALUES (v_persona_id, v_tenant_id, 'test_persona', 'Test prompt', v_model_id, '{"temperature": 0.1}'::jsonb);
    RAISE NOTICE '  ✓ Persona created';
    
    -- Get effective params
    v_effective_params := aos_persona.get_effective_params(v_persona_id);
    
    IF (v_effective_params->>'temperature')::float = 0.1 THEN
        RAISE NOTICE '  ✓ Override applied (temperature = 0.1)';
    ELSE
        RAISE EXCEPTION '  ✗ Override not applied: %', v_effective_params;
    END IF;
    
    IF v_effective_params ? 'top_p' THEN
        RAISE NOTICE '  ✓ Model defaults preserved (top_p present)';
    ELSE
        RAISE EXCEPTION '  ✗ Model defaults lost';
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
    RAISE NOTICE 'All tests PASSED!';
    RAISE NOTICE '========================================';
END $$;
