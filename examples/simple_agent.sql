-- ============================================================================
-- pgAgentOS: Simple Agent Example
-- Purpose: Demonstrate basic agent creation and conversation
-- ============================================================================

\echo '=== pgAgentOS Simple Agent Example ==='

-- 1. Create Tenant
INSERT INTO aos_auth.tenant (tenant_id, name, display_name)
VALUES ('11111111-1111-1111-1111-111111111111', 'demo_tenant', 'Demo Company')
ON CONFLICT (name) DO NOTHING;

\echo '✓ Tenant created'

-- 2. Create User
INSERT INTO aos_auth.principal (tenant_id, name, role)
VALUES ('11111111-1111-1111-1111-111111111111', 'demo_user', 'admin')
ON CONFLICT (tenant_id, name) DO NOTHING;

\echo '✓ User created'

-- 3. Create Persona
DO $$
DECLARE
    v_persona_id uuid;
    v_model_id uuid;
BEGIN
    SELECT model_id INTO v_model_id 
    FROM aos_core.model WHERE name = 'gpt-4o';
    
    -- Check if persona exists
    SELECT persona_id INTO v_persona_id
    FROM aos_persona.persona 
    WHERE tenant_id = '11111111-1111-1111-1111-111111111111' 
    AND name = 'HelpfulAssistant';
    
    IF v_persona_id IS NULL THEN
        v_persona_id := aos_persona.create_persona(
            '11111111-1111-1111-1111-111111111111',
            'HelpfulAssistant',
            'You are a helpful AI assistant. You answer questions clearly and concisely.',
            v_model_id
        );
        RAISE NOTICE '✓ Persona created: %', v_persona_id;
    ELSE
        RAISE NOTICE '✓ Persona already exists: %', v_persona_id;
    END IF;
END $$;

-- 4. Create Agent
INSERT INTO aos_agent.agent (tenant_id, name, persona_id, tools)
SELECT 
    '11111111-1111-1111-1111-111111111111',
    'SimpleBot',
    p.persona_id,
    ARRAY['rag_search', 'llm_chat']
FROM aos_persona.persona p
WHERE p.tenant_id = '11111111-1111-1111-1111-111111111111'
AND p.name = 'HelpfulAssistant'
ON CONFLICT (tenant_id, name) DO NOTHING;

\echo '✓ Agent created'

-- 5. Start a Conversation
DO $$
DECLARE
    v_agent_id uuid;
    v_conv_id uuid;
    v_turn_id uuid;
BEGIN
    SELECT agent_id INTO v_agent_id
    FROM aos_agent.agent
    WHERE tenant_id = '11111111-1111-1111-1111-111111111111'
    AND name = 'SimpleBot';
    
    -- Start conversation
    v_conv_id := aos_agent.start_conversation(v_agent_id, 'Demo Conversation');
    RAISE NOTICE '✓ Conversation started: %', v_conv_id;
    
    -- Send first message
    v_turn_id := aos_agent.send_message(v_conv_id, 'Hello! What can you help me with?');
    RAISE NOTICE '✓ Message sent, turn: %', v_turn_id;
    
    -- Store in memory
    PERFORM aos_agent.store_memory(v_conv_id, 'user_name', '"Demo User"'::jsonb);
    RAISE NOTICE '✓ Memory stored';
    
    -- Recall memory
    RAISE NOTICE 'Memory: %', aos_agent.recall_memory(v_conv_id);
END $$;

-- 6. View conversation state
\echo ''
\echo '=== Conversation State ==='
SELECT 
    c.conversation_id,
    a.name as agent,
    c.title,
    c.status,
    COUNT(t.turn_id) as turns
FROM aos_agent.conversation c
JOIN aos_agent.agent a ON a.agent_id = c.agent_id
LEFT JOIN aos_agent.turn t ON t.conversation_id = c.conversation_id
WHERE c.tenant_id = '11111111-1111-1111-1111-111111111111'
GROUP BY c.conversation_id, a.name, c.title, c.status;

-- 7. View runs
\echo ''
\echo '=== Runs ==='
SELECT run_id, run_type, status, created_at
FROM aos_core.run
WHERE tenant_id = '11111111-1111-1111-1111-111111111111'
ORDER BY created_at DESC
LIMIT 5;

\echo ''
\echo '=== Example Complete ==='
