-- ============================================================================
-- pgAgentOS: Simple Agent Example
-- Example using the new Agent Loop Architecture
-- ============================================================================

-- ============================================================================
-- 1. Basic Setup
-- ============================================================================

-- Create Tenant
INSERT INTO aos_auth.tenant (tenant_id, name, display_name)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'demo', 'Demo Company')
ON CONFLICT (name) DO NOTHING;

-- Create Admin User
INSERT INTO aos_auth.principal (principal_id, tenant_id, principal_type, display_name)
VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'human', 'Admin User')
ON CONFLICT DO NOTHING;

-- Set Tenant Context
SELECT aos_auth.set_tenant('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid);

-- ============================================================================
-- 2. Create Persona
-- ============================================================================

INSERT INTO aos_persona.persona (
    persona_id,
    tenant_id,
    name,
    system_prompt,
    traits,
    override_params
)
VALUES (
    'cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid,
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
    'helpful_assistant',
    'You are a helpful AI assistant. You can use tools when needed.
    
When you need to search for information, use the web_search tool.
When you need to run code, use the code_execute tool.
Always explain your thinking process before taking action.
Be concise but thorough in your responses.',
    '{"helpful": true, "cautious": true}'::jsonb,
    '{"temperature": 0.7}'::jsonb
)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 3. Create Agent
-- ============================================================================

INSERT INTO aos_agent.agent (
    agent_id,
    tenant_id,
    name,
    display_name,
    description,
    persona_id,
    tools,
    config
)
VALUES (
    'dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid,
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
    'research_assistant',
    'Research Assistant',
    'Research assistant capable of web search and code execution',
    'cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid,
    ARRAY['web_search', 'code_execute', 'rag_retrieve'],
    '{
        "max_iterations": 10,
        "max_tokens_per_turn": 4096,
        "thinking_visible": true,
        "auto_approve_tools": false,
        "pause_before_tool": false,
        "pause_after_tool": false
    }'::jsonb
)
ON CONFLICT DO NOTHING;

SELECT 'Agent created!' as status;

-- ============================================================================
-- 4. Start Conversation
-- ============================================================================

-- Start Conversation
DO $$
DECLARE
    v_conversation_id uuid;
    v_turn_id uuid;
BEGIN
    -- Create Conversation
    v_conversation_id := aos_agent.start_conversation(
        p_agent_id := 'dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid,
        p_user_principal_id := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
        p_context := '{"intent": "research"}'::jsonb
    );
    
    RAISE NOTICE 'Conversation started: %', v_conversation_id;
    
    -- Send First Message
    v_turn_id := aos_agent.send_message(
        p_conversation_id := v_conversation_id,
        p_message := 'Tell me how to do asynchronous programming in Python.'
    );
    
    RAISE NOTICE 'Turn created: %', v_turn_id;
    
    -- Check Turn Execution Info
    RAISE NOTICE 'Run turn info: %', aos_agent.run_turn(v_turn_id);
END $$;

-- ============================================================================
-- 5. Simulate Agent Behavior
-- ============================================================================

-- In reality, the external LLM runtime performs these tasks.
-- Here we simulate them.

DO $$
DECLARE
    v_turn_id uuid;
    v_step_id uuid;
BEGIN
    -- Get Latest Turn
    SELECT turn_id INTO v_turn_id
    FROM aos_agent.turn
    ORDER BY started_at DESC
    LIMIT 1;
    
    -- Step 1: Record Thinking
    PERFORM aos_agent.record_thinking(
        v_turn_id,
        'The user asked about asynchronous programming in Python. 
I should explain async/await and asyncio. 
I will first search the web for the latest information.',
        'use_tool: web_search'
    );
    RAISE NOTICE 'Thinking step recorded';
    
    -- Step 2: Tool Call (Requires Approval)
    v_step_id := (
        SELECT step_id FROM aos_agent.step
        WHERE turn_id = v_turn_id
        ORDER BY step_number DESC
        LIMIT 1
    );
    
    -- Process Tool Call
    RAISE NOTICE 'Tool call result: %', aos_agent.process_tool_call(
        v_turn_id,
        'web_search',
        '{"query": "python asyncio tutorial 2024"}'::jsonb
    );
END $$;

-- ============================================================================
-- 6. Admin Monitoring
-- ============================================================================

-- Check Pending Tool Calls
SELECT '=== Pending Tool Calls ===' as section;
SELECT * FROM aos_agent.tool_call_queue;

-- Trace Thinking Process
SELECT '=== Agent Thinking Process ===' as section;
SELECT * FROM aos_agent.thinking_trace;

-- Real-time Steps
SELECT '=== Real-time Steps ===' as section;
SELECT step_type, content, status, seconds_ago 
FROM aos_agent.realtime_steps 
LIMIT 10;

-- ============================================================================
-- 7. Simulate Admin Intervention
-- ============================================================================

DO $$
DECLARE
    v_pending_step_id uuid;
    v_admin_id uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid;
BEGIN
    -- Find Pending Step
    SELECT step_id INTO v_pending_step_id
    FROM aos_agent.step
    WHERE status = 'pending' AND step_type = 'tool_call'
    ORDER BY created_at
    LIMIT 1;
    
    IF v_pending_step_id IS NOT NULL THEN
        -- Approve
        PERFORM aos_agent.approve_step(
            v_pending_step_id,
            true,
            v_admin_id,
            'Web search allowed'
        );
        RAISE NOTICE 'Tool call approved: %', v_pending_step_id;
        
        -- Record Tool Result (Simulation)
        PERFORM aos_agent.record_tool_result(
            (SELECT turn_id FROM aos_agent.step WHERE step_id = v_pending_step_id),
            'web_search',
            '{
                "results": [
                    {"title": "Python Asyncio Tutorial", "snippet": "Asynchronous programming using async/await..."},
                    {"title": "Async Programming in Python", "snippet": "Event loops and coroutines..."}
                ]
            }'::jsonb,
            true
        );
        RAISE NOTICE 'Tool result recorded';
    ELSE
        RAISE NOTICE 'No pending tool calls found';
    END IF;
END $$;

-- ============================================================================
-- 8. Complete Response
-- ============================================================================

DO $$
DECLARE
    v_turn_id uuid;
BEGIN
    -- Get Latest Turn
    SELECT turn_id INTO v_turn_id
    FROM aos_agent.turn
    ORDER BY started_at DESC
    LIMIT 1;
    
    -- Final Thought
    PERFORM aos_agent.record_thinking(
        v_turn_id,
        'Based on the web search results, I will explain Python asynchronous programming.',
        'respond'
    );
    
    -- Complete Response
    PERFORM aos_agent.complete_turn(
        v_turn_id,
        '# Python Asynchronous Programming

In Python, asynchronous programming uses the `asyncio` module and `async/await` syntax.

## Basic Example

```python
import asyncio

async def main():
    print("Hello")
    await asyncio.sleep(1)
    print("World")

asyncio.run(main())
```

## Core Concepts

1. **Coroutine**: Function defined with `async def`
2. **await**: Pauses execution of the coroutine and waits for the result
3. **Event Loop**: Schedules and executes asynchronous tasks

Do you have any more questions?',
        1500,  -- tokens
        0.003  -- cost
    );
    
    RAISE NOTICE 'Turn completed!';
END $$;

-- ============================================================================
-- 9. Verify Results
-- ============================================================================

-- Conversation History
SELECT '=== Conversation History ===' as section;
SELECT aos_agent.get_conversation_history(
    (SELECT conversation_id FROM aos_agent.conversation ORDER BY started_at DESC LIMIT 1),
    true  -- include steps
);

-- Turn State
SELECT '=== Turn State ===' as section;
SELECT aos_agent.get_turn_state(
    (SELECT turn_id FROM aos_agent.turn ORDER BY started_at DESC LIMIT 1)
);

-- Timeline
SELECT '=== Conversation Timeline ===' as section;
SELECT actor, step_type, 
       CASE WHEN length(content) > 100 THEN substring(content, 1, 100) || '...' ELSE content END as content_preview,
       timestamp
FROM aos_agent.conversation_timeline
WHERE conversation_id = (SELECT conversation_id FROM aos_agent.conversation ORDER BY started_at DESC LIMIT 1)
ORDER BY timestamp;

-- ============================================================================
-- 10. Admin Rating
-- ============================================================================

DO $$
DECLARE
    v_turn_id uuid;
    v_admin_id uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid;
BEGIN
    SELECT turn_id INTO v_turn_id
    FROM aos_agent.turn
    ORDER BY started_at DESC
    LIMIT 1;
    
    -- Rate
    PERFORM aos_agent.rate_turn(
        v_turn_id,
        v_admin_id,
        4,
        '{"accuracy": 5, "helpfulness": 4, "clarity": 4}'::jsonb
    );
    
    RAISE NOTICE 'Turn rated!';
END $$;

-- Agent Analytics
SELECT '=== Agent Analytics ===' as section;
SELECT aos_agent.get_agent_analytics('dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid, 7);
