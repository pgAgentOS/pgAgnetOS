-- ============================================================================
-- pgAgentOS: Multi-Agent Collaboration Example
-- Example of multiple agents debating and collaborating
-- ============================================================================

-- ============================================================================
-- 1. Basic Setup
-- ============================================================================

-- Create Tenant
INSERT INTO aos_auth.tenant (tenant_id, name, display_name)
VALUES ('11111111-1111-1111-1111-111111111111', 'collab_demo', 'Collaboration Demo')
ON CONFLICT (name) DO NOTHING;

SELECT aos_auth.set_tenant('11111111-1111-1111-1111-111111111111'::uuid);

-- ============================================================================
-- 2. Create Agents with Different Roles
-- ============================================================================

-- Researcher Agent (Information Gathering)
INSERT INTO aos_agent.agent (agent_id, tenant_id, name, display_name, description, tools)
VALUES (
    '22222222-2222-2222-2222-222222222222',
    '11111111-1111-1111-1111-111111111111',
    'researcher',
    'Researcher',
    'Agent that collects and analyzes information',
    ARRAY['web_search', 'rag_retrieve']
) ON CONFLICT DO NOTHING;

-- Critic Agent (Critical Review)
INSERT INTO aos_agent.agent (agent_id, tenant_id, name, display_name, description, tools)
VALUES (
    '33333333-3333-3333-3333-333333333333',
    '11111111-1111-1111-1111-111111111111',
    'critic',
    'Critic',
    'Agent that critically reviews proposals',
    ARRAY['rag_retrieve']
) ON CONFLICT DO NOTHING;

-- Creative Agent (Idea Generation)
INSERT INTO aos_agent.agent (agent_id, tenant_id, name, display_name, description, tools)
VALUES (
    '44444444-4444-4444-4444-444444444444',
    '11111111-1111-1111-1111-111111111111',
    'creative',
    'Creative',
    'Agent that proposes new ideas',
    ARRAY['code_execute']
) ON CONFLICT DO NOTHING;

-- Coordinator Agent (Decision Making)
INSERT INTO aos_agent.agent (agent_id, tenant_id, name, display_name, description, tools)
VALUES (
    '55555555-5555-5555-5555-555555555555',
    '11111111-1111-1111-1111-111111111111',
    'coordinator',
    'Coordinator',
    'Agent that moderates discussion and makes conclusions',
    ARRAY[]
) ON CONFLICT DO NOTHING;

SELECT '4 Agents Created' as status;

-- ============================================================================
-- 3. Create Team (Debate Team)
-- ============================================================================

DO $$
DECLARE
    v_team_id uuid;
BEGIN
    -- Create Debate Team
    v_team_id := aos_multi_agent.create_team(
        p_tenant_id := '11111111-1111-1111-1111-111111111111'::uuid,
        p_name := 'debate_team',
        p_team_type := 'debate',
        p_agent_ids := ARRAY[
            '55555555-5555-5555-5555-555555555555'::uuid,  -- Coordinator (Leader)
            '22222222-2222-2222-2222-222222222222'::uuid,  -- Researcher
            '33333333-3333-3333-3333-333333333333'::uuid,  -- Critic
            '44444444-4444-4444-4444-444444444444'::uuid   -- Creative
        ],
        p_config := '{"require_consensus": true, "consensus_threshold": 0.75}'::jsonb
    );
    
    RAISE NOTICE 'Debate Team Created: %', v_team_id;
END $$;

-- ============================================================================
-- 4. Start Discussion
-- ============================================================================

DO $$
DECLARE
    v_team_id uuid;
    v_discussion_id uuid;
BEGIN
    -- Get Team ID
    SELECT team_id INTO v_team_id
    FROM aos_multi_agent.team WHERE name = 'debate_team';
    
    -- Start Discussion
    v_discussion_id := aos_multi_agent.start_discussion(
        p_tenant_id := '11111111-1111-1111-1111-111111111111'::uuid,
        p_topic := 'Prioritizing New AI Product Features',
        p_team_id := v_team_id,
        p_discussion_type := 'decision',
        p_goal := 'Decide on 3 features to develop in the next quarter',
        p_context := '{
            "product": "AI Assistant",
            "constraints": ["budget: $100k", "timeline: 3 months"],
            "options": ["Voice Recognition", "Document Summarization", "Multilingual Support", "API Extension"]
        }'::jsonb
    );
    
    RAISE NOTICE 'Discussion Started: %', v_discussion_id;
END $$;

-- ============================================================================
-- 5. Simulate Agent Discussion
-- ============================================================================

DO $$
DECLARE
    v_discussion_id uuid;
    v_msg_id uuid;
    v_proposal_id uuid;
BEGIN
    -- Get Discussion ID
    SELECT discussion_id INTO v_discussion_id
    FROM aos_multi_agent.discussion 
    WHERE topic = 'Prioritizing New AI Product Features'
    ORDER BY started_at DESC LIMIT 1;
    
    RAISE NOTICE '=== Discussion Started ===';
    
    -- Coordinator: Opening Statement
    PERFORM aos_multi_agent.send_agent_message(
        v_discussion_id,
        '55555555-5555-5555-5555-555555555555'::uuid,
        'statement',
        'Hello team, we need to decide on the features for the next quarter.
        
Options:
1. Voice Recognition
2. Document Summarization
3. Multilingual Support
4. API Extension

Constraints: Budget $100k, 3 months timeline. Please share your thoughts.',
        ARRAY[]::uuid[]
    );
    RAISE NOTICE 'Coordinator: Opening Statement';
    
    -- Researcher: Provide Market Analysis
    PERFORM aos_multi_agent.send_agent_message(
        v_discussion_id,
        '22222222-2222-2222-2222-222222222222'::uuid,
        'statement',
        'Sharing market research results:

**Voice Recognition**: 25% market growth, high competition
**Document Summarization**: High enterprise demand, medium competition
**Multilingual Support**: Essential for global expansion, complex implementation
**API Extension**: Directly linked to B2B revenue, technically easier

I personally recommend Document Summarization and API Extension.',
        ARRAY[]::uuid[],
        '{"confidence": 0.85, "sources": ["market_report_2024", "competitor_analysis"]}'::jsonb
    );
    RAISE NOTICE 'Researcher: Market Analysis Shared';
    
    -- Creative: New Proposal
    PERFORM aos_multi_agent.send_agent_message(
        v_discussion_id,
        '44444444-4444-4444-4444-444444444444'::uuid,
        'proposal',
        'I propose a new approach!

**Integrated Proposal**: "Smart Document Hub"
- Combine Document Summarization + Multilingual Support
- Address two needs with one feature set
- Implementation possible within budget

This way we can develop 3 features more efficiently.',
        ARRAY[]::uuid[],
        '{"confidence": 0.7}'::jsonb
    );
    RAISE NOTICE 'Creative: Integrated Proposal';
    
    -- Critic: Critical Review
    PERFORM aos_multi_agent.send_agent_message(
        v_discussion_id,
        '33333333-3333-3333-3333-333333333333'::uuid,
        'objection',
        'I have some concerns about the Creative''s proposal:

1. **Increased Complexity**: Integrated development requires 30% more effort than simple sum
2. **Lack of Risk Dispersion**: If one fails, the whole thing fails
3. **Testing Difficulty**: Combination testing required

As an alternative, I suggest doing API Extension first and deferring others to next quarter.',
        ARRAY[]::uuid[],
        '{"confidence": 0.8}'::jsonb
    );
    RAISE NOTICE 'Critic: Objection Raised';
    
    -- Researcher: Provide Additional Data
    PERFORM aos_multi_agent.send_agent_message(
        v_discussion_id,
        '22222222-2222-2222-2222-222222222222'::uuid,
        'answer',
        'Data regarding Critic''s concerns:

- Estimated Integrated Development Cost: $85k (Within budget)
- Single Feature Development Cost: $40-50k each
- Only API Extension: High opportunity cost (Competitors taking lead)

Conclusion: Integrated approach is risky but advantageous for competitive edge.',
        ARRAY['33333333-3333-3333-3333-333333333333'::uuid],  -- Reply to Critic
        '{"in_reply_to": "critic_objection"}'::jsonb
    );
    RAISE NOTICE 'Researcher: Additional Data Provided';
    
    -- Coordinator: Propose Vote
    PERFORM aos_multi_agent.send_agent_message(
        v_discussion_id,
        '55555555-5555-5555-5555-555555555555'::uuid,
        'statement',
        'Great discussion. To summarize:

**Option A**: Smart Document Hub (Summarization + Multilingual) + API Extension
**Option B**: API Extension only, rest next quarter

We will proceed to vote.',
        ARRAY[]::uuid[]
    );
    RAISE NOTICE 'Coordinator: Vote Proposed';
    
END $$;

-- ============================================================================
-- 6. Create Proposal & Vote
-- ============================================================================

DO $$
DECLARE
    v_discussion_id uuid;
    v_proposal_id uuid;
BEGIN
    SELECT discussion_id INTO v_discussion_id
    FROM aos_multi_agent.discussion 
    WHERE topic = 'Prioritizing New AI Product Features'
    ORDER BY started_at DESC LIMIT 1;
    
    -- Create Proposal A
    v_proposal_id := aos_multi_agent.create_proposal(
        v_discussion_id,
        'Option A: Smart Document Hub + API Extension',
        'Develop Smart Document Hub integrating document summarization and multilingual support, along with API extension.',
        '44444444-4444-4444-4444-444444444444'::uuid  -- Proposed by Creative
    );
    RAISE NOTICE 'Proposal A Created: %', v_proposal_id;
    
    -- Vote
    -- Creative: For (Own Proposal)
    PERFORM aos_multi_agent.cast_vote(
        v_proposal_id,
        '44444444-4444-4444-4444-444444444444'::uuid,
        'for',
        'Integrated approach is most efficient.'
    );
    
    -- Researcher: For
    PERFORM aos_multi_agent.cast_vote(
        v_proposal_id,
        '22222222-2222-2222-2222-222222222222'::uuid,
        'for',
        'Data supports this approach.'
    );
    
    -- Critic: Against
    PERFORM aos_multi_agent.cast_vote(
        v_proposal_id,
        '33333333-3333-3333-3333-333333333333'::uuid,
        'against',
        'Risk is too high. More conservative approach needed.'
    );
    
    -- Coordinator: For (Majority Secured)
    PERFORM aos_multi_agent.cast_vote(
        v_proposal_id,
        '55555555-5555-5555-5555-555555555555'::uuid,
        'for',
        'Reflecting the team''s majority opinion.'
    );
    
    -- Update Proposal Status
    UPDATE aos_multi_agent.proposal
    SET status = 'accepted'
    WHERE proposal_id = v_proposal_id;
    
    RAISE NOTICE 'Voting Complete! Proposal A Accepted (3:1)';
END $$;

-- ============================================================================
-- 7. Conclude Discussion
-- ============================================================================

DO $$
DECLARE
    v_discussion_id uuid;
BEGIN
    SELECT discussion_id INTO v_discussion_id
    FROM aos_multi_agent.discussion 
    WHERE topic = 'Prioritizing New AI Product Features'
    ORDER BY started_at DESC LIMIT 1;
    
    PERFORM aos_multi_agent.conclude_discussion(
        v_discussion_id,
        'Option A Accepted: Develop Smart Document Hub (Summarization + Multilingual) + API Extension next quarter',
        'Voting result 3:1 in favor of integrated approach. Will address Critic''s concerns with risk mitigation plan.',
        '55555555-5555-5555-5555-555555555555'::uuid
    );
    
    RAISE NOTICE 'Discussion Concluded!';
END $$;

-- ============================================================================
-- 8. View Results
-- ============================================================================

-- Discussion Summary
SELECT '=== Discussion Summary ===' as section;
SELECT * FROM aos_multi_agent.discussion_summary;

-- Message History
SELECT '=== Discussion Messages ===' as section;
SELECT 
    sequence_number,
    sender_name,
    message_type,
    SUBSTRING(content, 1, 80) || '...' as content_preview
FROM aos_multi_agent.get_discussion_messages(
    (SELECT discussion_id FROM aos_multi_agent.discussion 
     WHERE topic = 'Prioritizing New AI Product Features' 
     ORDER BY started_at DESC LIMIT 1),
    20
);

-- Voting Results
SELECT '=== Voting Results ===' as section;
SELECT 
    p.title,
    p.status,
    p.votes_for,
    p.votes_against,
    p.votes_abstain
FROM aos_multi_agent.proposal p
JOIN aos_multi_agent.discussion d ON d.discussion_id = p.discussion_id
WHERE d.topic = 'Prioritizing New AI Product Features';

-- ============================================================================
-- 9. External Runtime Integration Example
-- ============================================================================

/*
Flow for agent participation in external runtime (Python/Node.js):

1. Check messages requiring response
   SELECT * FROM aos_multi_agent.get_pending_messages_for_agent('agent-uuid');

2. Get discussion context
   SELECT * FROM aos_multi_agent.get_discussion_messages('discussion-uuid', 50);

3. Generate response with LLM and send message
   SELECT aos_multi_agent.send_agent_message(
       'discussion-uuid',
       'agent-uuid',
       'statement',  -- or 'question', 'objection', etc.
       'Generated response content',
       ARRAY[]::uuid[],
       '{"confidence": 0.85}'::jsonb
   );

4. React to message
   SELECT aos_multi_agent.react_to_message(
       'message-uuid',
       'agent-uuid',
       'agree',
       0.9
   );

5. Vote on proposal
   SELECT aos_multi_agent.cast_vote(
       'proposal-uuid',
       'agent-uuid',
       'for',
       'Reason for vote'
   );
*/

SELECT '=== Multi-Agent Collaboration Example Completed ===' as section;
