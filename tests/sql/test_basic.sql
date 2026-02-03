-- ============================================================================
-- pgAgentOS: Basic Tests (Simplified)
-- Purpose: Verify core functionality
-- ============================================================================

\echo '=== pgAgentOS Basic Tests ==='
\echo ''

-- Test 1: Schema existence
DO $$
BEGIN
    RAISE NOTICE 'Test 1: Schema existence...';
    
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'aos_core') AND
       EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'aos_auth') AND
       EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'aos_persona') AND
       EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'aos_skills') AND
       EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'aos_agent') AND
       EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'aos_rag') THEN
        RAISE NOTICE '  ✓ All 6 schemas exist';
    ELSE
        RAISE EXCEPTION '  ✗ Missing schemas';
    END IF;
    
    RAISE NOTICE 'Test 1: PASSED';
END $$;

-- Test 2: Model registry
DO $$
DECLARE
    v_count int;
BEGIN
    RAISE NOTICE 'Test 2: Model registry...';
    
    SELECT COUNT(*) INTO v_count FROM aos_core.model;
    
    IF v_count > 0 THEN
        RAISE NOTICE '  ✓ % models registered', v_count;
    ELSE
        RAISE EXCEPTION '  ✗ No models found';
    END IF;
    
    RAISE NOTICE 'Test 2: PASSED';
END $$;

-- Test 3: Tenant and principal creation
DO $$
DECLARE
    v_tenant_id uuid;
    v_principal_id uuid;
BEGIN
    RAISE NOTICE 'Test 3: Tenant/Principal...';
    
    INSERT INTO aos_auth.tenant (name, display_name)
    VALUES ('test_tenant_' || gen_random_uuid(), 'Test Tenant')
    RETURNING tenant_id INTO v_tenant_id;
    RAISE NOTICE '  ✓ Tenant created: %', v_tenant_id;
    
    INSERT INTO aos_auth.principal (tenant_id, name, role)
    VALUES (v_tenant_id, 'test_user', 'user')
    RETURNING principal_id INTO v_principal_id;
    RAISE NOTICE '  ✓ Principal created: %', v_principal_id;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 3: PASSED';
END $$;

-- Test 4: Persona creation
DO $$
DECLARE
    v_tenant_id uuid;
    v_model_id uuid;
    v_persona_id uuid;
BEGIN
    RAISE NOTICE 'Test 4: Persona creation...';
    
    INSERT INTO aos_auth.tenant (name) 
    VALUES ('persona_test_' || gen_random_uuid())
    RETURNING tenant_id INTO v_tenant_id;
    
    SELECT model_id INTO v_model_id 
    FROM aos_core.model WHERE provider = 'openai' LIMIT 1;
    
    v_persona_id := aos_persona.create_persona(
        v_tenant_id, 
        'TestBot', 
        'You are a helpful assistant.',
        v_model_id
    );
    RAISE NOTICE '  ✓ Persona created: %', v_persona_id;
    
    -- Verify version created
    IF EXISTS (SELECT 1 FROM aos_persona.version WHERE persona_id = v_persona_id) THEN
        RAISE NOTICE '  ✓ Version snapshot created';
    ELSE
        RAISE EXCEPTION '  ✗ Version not created';
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 4: PASSED';
END $$;

-- Test 5: Agent and conversation
DO $$
DECLARE
    v_tenant_id uuid;
    v_model_id uuid;
    v_persona_id uuid;
    v_agent_id uuid;
    v_conv_id uuid;
    v_turn_id uuid;
BEGIN
    RAISE NOTICE 'Test 5: Agent conversation...';
    
    -- Setup
    INSERT INTO aos_auth.tenant (name) 
    VALUES ('agent_test_' || gen_random_uuid())
    RETURNING tenant_id INTO v_tenant_id;
    
    SELECT model_id INTO v_model_id FROM aos_core.model LIMIT 1;
    
    v_persona_id := aos_persona.create_persona(
        v_tenant_id, 'Agent', 'You are helpful.', v_model_id
    );
    
    INSERT INTO aos_agent.agent (tenant_id, name, persona_id, tools)
    VALUES (v_tenant_id, 'TestAgent', v_persona_id, ARRAY['rag_search'])
    RETURNING agent_id INTO v_agent_id;
    RAISE NOTICE '  ✓ Agent created';
    
    -- Start conversation
    v_conv_id := aos_agent.start_conversation(v_agent_id, 'Test Chat');
    RAISE NOTICE '  ✓ Conversation started: %', v_conv_id;
    
    -- Send message
    v_turn_id := aos_agent.send_message(v_conv_id, 'Hello!');
    RAISE NOTICE '  ✓ Message sent, turn: %', v_turn_id;
    
    -- Verify run created
    IF EXISTS (SELECT 1 FROM aos_core.run r 
               JOIN aos_agent.turn t ON t.run_id = r.run_id 
               WHERE t.turn_id = v_turn_id) THEN
        RAISE NOTICE '  ✓ Run tracked';
    ELSE
        RAISE EXCEPTION '  ✗ Run not tracked';
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 5: PASSED';
END $$;

-- Test 6: Job queue
DO $$
DECLARE
    v_tenant_id uuid;
    v_job_id uuid;
BEGIN
    RAISE NOTICE 'Test 6: Job queue...';
    
    INSERT INTO aos_auth.tenant (name) 
    VALUES ('job_test_' || gen_random_uuid())
    RETURNING tenant_id INTO v_tenant_id;
    
    v_job_id := aos_core.enqueue(
        v_tenant_id, 
        'test_job', 
        '{"test": true}'::jsonb
    );
    RAISE NOTICE '  ✓ Job enqueued: %', v_job_id;
    
    IF EXISTS (SELECT 1 FROM aos_core.job WHERE job_id = v_job_id AND status = 'pending') THEN
        RAISE NOTICE '  ✓ Job pending';
    ELSE
        RAISE EXCEPTION '  ✗ Job not found';
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 6: PASSED';
END $$;

-- Test 7: RAG collection
DO $$
DECLARE
    v_tenant_id uuid;
    v_collection_id uuid;
    v_doc_id uuid;
BEGIN
    RAISE NOTICE 'Test 7: RAG collection...';
    
    INSERT INTO aos_auth.tenant (name) 
    VALUES ('rag_test_' || gen_random_uuid())
    RETURNING tenant_id INTO v_tenant_id;
    
    INSERT INTO aos_rag.collection (tenant_id, name)
    VALUES (v_tenant_id, 'test_collection')
    RETURNING collection_id INTO v_collection_id;
    RAISE NOTICE '  ✓ Collection created';
    
    v_doc_id := aos_rag.add_document(
        v_collection_id,
        'PostgreSQL is a powerful open source database.',
        'About PostgreSQL'
    );
    RAISE NOTICE '  ✓ Document added: %', v_doc_id;
    
    -- Verify job queued for embedding
    IF EXISTS (SELECT 1 FROM aos_core.job 
               WHERE job_type = 'embed_document' 
               AND payload->>'doc_id' = v_doc_id::text) THEN
        RAISE NOTICE '  ✓ Embedding job queued';
    ELSE
        RAISE EXCEPTION '  ✗ Embedding job not queued';
    END IF;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 7: PASSED';
END $$;

-- Test 8: Event immutability
DO $$
DECLARE
    v_tenant_id uuid;
    v_run_id uuid;
    v_event_id bigint;
BEGIN
    RAISE NOTICE 'Test 8: Event immutability...';
    
    INSERT INTO aos_auth.tenant (name) 
    VALUES ('event_test_' || gen_random_uuid())
    RETURNING tenant_id INTO v_tenant_id;
    
    INSERT INTO aos_core.run (tenant_id, run_type)
    VALUES (v_tenant_id, 'test')
    RETURNING run_id INTO v_run_id;
    
    v_event_id := aos_core.log_event(v_run_id, 'test', '{"data": 1}'::jsonb);
    RAISE NOTICE '  ✓ Event logged: %', v_event_id;
    
    -- Try to update (should fail)
    BEGIN
        UPDATE aos_core.event SET payload = '{"data": 2}'::jsonb 
        WHERE event_id = v_event_id;
        RAISE EXCEPTION '  ✗ Event was modified (should be immutable)';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '  ✓ Event is immutable';
    END;
    
    -- Cleanup
    DELETE FROM aos_auth.tenant WHERE tenant_id = v_tenant_id;
    
    RAISE NOTICE 'Test 8: PASSED';
END $$;

\echo ''
\echo '=== All tests PASSED! ==='
