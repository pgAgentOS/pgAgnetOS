-- ============================================================================
-- pgAgentOS: Multi-Agent Collaboration System
-- Schema: aos_multi_agent
-- 
-- Core Philosophy:
-- - PostgreSQL acts as the "Central Bus" for inter-agent communication
-- - All agent-to-agent messages are recorded for audit/debugging
-- - Supports collaboration patterns like debate, voting, consensus, etc.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_multi_agent;

-- ============================================================================
-- CORE: Team & Membership
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: team
-- Purpose: Agent Team (Collaboration Group)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.team (
    team_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Basic Info
    name text NOT NULL,
    display_name text,
    description text,
    
    -- Team Type
    team_type text NOT NULL DEFAULT 'collaborative'
        CHECK (team_type IN (
            'collaborative',    -- Collaborative (Work together)
            'hierarchical',     -- Hierarchical (Leader + Members)
            'debate',           -- Debate (Pro/Con)
            'review',           -- Review (Author + Reviewer)
            'swarm'            -- Swarm (Dynamic)
        )),
    
    -- Config
    config jsonb DEFAULT '{
        "max_members": 10,
        "require_consensus": false,
        "consensus_threshold": 0.6,
        "allow_delegation": true,
        "timeout_seconds": 300
    }'::jsonb,
    
    -- Meta
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid REFERENCES aos_auth.principal(principal_id),
    
    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_team_tenant ON aos_multi_agent.team(tenant_id);
CREATE INDEX idx_team_type ON aos_multi_agent.team(team_type);

-- ----------------------------------------------------------------------------
-- Table: team_member
-- Purpose: Team Member (Agent or Human)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.team_member (
    member_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id uuid NOT NULL REFERENCES aos_multi_agent.team(team_id) ON DELETE CASCADE,
    
    -- Member (Set only one)
    agent_id uuid REFERENCES aos_agent.agent(agent_id) ON DELETE CASCADE,
    principal_id uuid REFERENCES aos_auth.principal(principal_id) ON DELETE CASCADE,
    
    -- Role
    role text NOT NULL DEFAULT 'member'
        CHECK (role IN (
            'leader',       -- Leader (Decision Maker)
            'coordinator',  -- Coordinator
            'member',       -- Member
            'observer',     -- Observer (Read-only)
            'critic',       -- Critic (Debate)
            'advocate'      -- Advocate (Debate)
        )),
    
    -- Permissions
    can_initiate bool DEFAULT true,      -- Can start discussion
    can_respond bool DEFAULT true,       -- Can respond
    can_vote bool DEFAULT true,          -- Can vote
    can_delegate bool DEFAULT false,     -- Can delegate
    
    -- Meta
    joined_at timestamptz NOT NULL DEFAULT now(),
    is_active bool DEFAULT true,
    
    CHECK (
        (agent_id IS NOT NULL AND principal_id IS NULL) OR
        (agent_id IS NULL AND principal_id IS NOT NULL)
    )
);

CREATE INDEX idx_team_member_team ON aos_multi_agent.team_member(team_id);
CREATE INDEX idx_team_member_agent ON aos_multi_agent.team_member(agent_id);
CREATE INDEX idx_team_member_principal ON aos_multi_agent.team_member(principal_id);

-- ============================================================================
-- CORE: Discussion
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: discussion
-- Purpose: Inter-agent Discussion/Collaboration Session
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.discussion (
    discussion_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    team_id uuid REFERENCES aos_multi_agent.team(team_id) ON DELETE SET NULL,
    
    -- Discussion Info
    topic text NOT NULL,                          -- Topic
    goal text,                                    -- Goal
    context jsonb DEFAULT '{}'::jsonb,            -- Context
    
    -- Discussion Type
    discussion_type text NOT NULL DEFAULT 'open'
        CHECK (discussion_type IN (
            'open',           -- Free discussion
            'structured',     -- Structured (Sequential)
            'debate',         -- Debate
            'brainstorm',     -- Brainstorming
            'review',         -- Review/Feedback
            'decision'        -- Decision Making
        )),
    
    -- Status
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN (
            'draft',          -- Draft
            'active',         -- Active
            'voting',         -- Voting
            'concluded',      -- Concluded
            'stalled',        -- Stalled
            'cancelled'       -- Cancelled
        )),
    
    -- Conclusion
    conclusion text,                              -- Final Conclusion
    conclusion_rationale text,                    -- Rationale
    concluded_by uuid,                            -- Concluded By
    concluded_at timestamptz,
    
    -- Config
    config jsonb DEFAULT '{
        "max_rounds": 10,
        "max_messages_per_round": 5,
        "require_all_participate": false,
        "allow_abstain": true
    }'::jsonb,
    
    -- Stats
    total_messages int DEFAULT 0,
    participating_agents int DEFAULT 0,
    
    -- Timing
    started_at timestamptz NOT NULL DEFAULT now(),
    deadline_at timestamptz,
    updated_at timestamptz DEFAULT now()
);

CREATE INDEX idx_discussion_tenant ON aos_multi_agent.discussion(tenant_id);
CREATE INDEX idx_discussion_team ON aos_multi_agent.discussion(team_id);
CREATE INDEX idx_discussion_status ON aos_multi_agent.discussion(status);

-- ============================================================================
-- CORE: Message
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: agent_message
-- Purpose: Inter-agent Message (Communication Protocol)
-- 
-- CORE: All agent communications are recorded here.
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.agent_message (
    message_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    discussion_id uuid NOT NULL REFERENCES aos_multi_agent.discussion(discussion_id) ON DELETE CASCADE,
    
    -- Sender/Recipient
    sender_agent_id uuid REFERENCES aos_agent.agent(agent_id),
    sender_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    recipient_agent_ids uuid[] DEFAULT ARRAY[]::uuid[],     -- Specific recipients (Empty = Broadcast)
    
    -- Message Type
    message_type text NOT NULL DEFAULT 'statement'
        CHECK (message_type IN (
            'statement',      -- Statement/Opinion
            'question',       -- Question
            'answer',         -- Answer
            'proposal',       -- Proposal
            'objection',      -- Objection
            'support',        -- Support
            'clarification',  -- Clarification Request
            'summary',        -- Summary
            'vote',           -- Vote
            'delegate',       -- Delegate
            'system'          -- System Message
        )),
    
    -- Content
    content text NOT NULL,
    attachments jsonb DEFAULT '[]'::jsonb,
    
    -- Metadata
    metadata jsonb DEFAULT '{}'::jsonb,
    /*
    {
        "confidence": 0.85,
        "sources": ["doc_1", "doc_2"],
        "reasoning_trace": "...",
        "in_reply_to": "message_uuid",
        "vote_value": "agree|disagree|abstain",
        "proposal_id": "...",
        "delegation_to": "agent_uuid"
    }
    */
    
    -- Sequence
    round_number int,                             -- Round Number
    sequence_number int NOT NULL,                 -- Sequence in Discussion
    
    -- Reactions
    reactions jsonb DEFAULT '{}'::jsonb,
    /*
    {
        "agent_1_uuid": {"type": "agree", "strength": 0.8},
        "agent_2_uuid": {"type": "disagree", "strength": 0.6}
    }
    */
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    
    -- Turn Link
    source_turn_id uuid REFERENCES aos_agent.turn(turn_id),
    
    CHECK (
        (sender_agent_id IS NOT NULL AND sender_principal_id IS NULL) OR
        (sender_agent_id IS NULL AND sender_principal_id IS NOT NULL)
    )
);

CREATE INDEX idx_agent_message_discussion ON aos_multi_agent.agent_message(discussion_id);
CREATE INDEX idx_agent_message_sender ON aos_multi_agent.agent_message(sender_agent_id);
CREATE INDEX idx_agent_message_type ON aos_multi_agent.agent_message(message_type);
CREATE INDEX idx_agent_message_order ON aos_multi_agent.agent_message(discussion_id, sequence_number);

-- ============================================================================
-- CORE: Proposal & Voting
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: proposal
-- Purpose: Proposal in discussion (Voting Target)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.proposal (
    proposal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    discussion_id uuid NOT NULL REFERENCES aos_multi_agent.discussion(discussion_id) ON DELETE CASCADE,
    
    -- Proposal Info
    title text NOT NULL,
    description text NOT NULL,
    proposed_by uuid REFERENCES aos_agent.agent(agent_id),
    
    -- Status
    status text NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'voting', 'accepted', 'rejected', 'withdrawn')),
    
    -- Vote Results
    votes_for int DEFAULT 0,
    votes_against int DEFAULT 0,
    votes_abstain int DEFAULT 0,
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    voting_deadline timestamptz,
    resolved_at timestamptz
);

CREATE INDEX idx_proposal_discussion ON aos_multi_agent.proposal(discussion_id);
CREATE INDEX idx_proposal_status ON aos_multi_agent.proposal(status);

-- ----------------------------------------------------------------------------
-- Table: vote
-- Purpose: Vote Record
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.vote (
    vote_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    proposal_id uuid NOT NULL REFERENCES aos_multi_agent.proposal(proposal_id) ON DELETE CASCADE,
    
    -- Voter
    voter_agent_id uuid REFERENCES aos_agent.agent(agent_id),
    voter_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    
    -- Vote
    vote_value text NOT NULL CHECK (vote_value IN ('for', 'against', 'abstain')),
    weight float DEFAULT 1.0,                     -- Weighted Voting
    rationale text,                               -- Rationale
    
    -- Timing
    voted_at timestamptz NOT NULL DEFAULT now(),
    
    -- One vote per proposal per voter
    UNIQUE (proposal_id, voter_agent_id),
    UNIQUE (proposal_id, voter_principal_id),
    
    CHECK (
        (voter_agent_id IS NOT NULL AND voter_principal_id IS NULL) OR
        (voter_agent_id IS NULL AND voter_principal_id IS NOT NULL)
    )
);

CREATE INDEX idx_vote_proposal ON aos_multi_agent.vote(proposal_id);

-- ============================================================================
-- CORE: Shared Workspace
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table: shared_artifact
-- Purpose: Shared Artifacts (Docs, Code, etc.)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_multi_agent.shared_artifact (
    artifact_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    discussion_id uuid REFERENCES aos_multi_agent.discussion(discussion_id) ON DELETE SET NULL,
    team_id uuid REFERENCES aos_multi_agent.team(team_id) ON DELETE SET NULL,
    
    -- Artifact Info
    artifact_type text NOT NULL CHECK (artifact_type IN (
        'document', 'code', 'plan', 'diagram', 'data', 'other'
    )),
    name text NOT NULL,
    description text,
    
    -- Content
    content text,
    content_format text DEFAULT 'text',           -- 'text', 'markdown', 'json', 'code'
    metadata jsonb DEFAULT '{}'::jsonb,
    
    -- Versioning
    version int NOT NULL DEFAULT 1,
    parent_version_id uuid REFERENCES aos_multi_agent.shared_artifact(artifact_id),
    
    -- Contributors
    created_by uuid,                              -- agent_id or principal_id
    created_by_type text CHECK (created_by_type IN ('agent', 'human')),
    
    -- Status
    status text DEFAULT 'draft' CHECK (status IN ('draft', 'review', 'approved', 'archived')),
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

CREATE INDEX idx_shared_artifact_discussion ON aos_multi_agent.shared_artifact(discussion_id);
CREATE INDEX idx_shared_artifact_team ON aos_multi_agent.shared_artifact(team_id);

-- ============================================================================
-- FUNCTIONS: Team Management
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: create_team
-- Purpose: Create Team
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.create_team(
    p_tenant_id uuid,
    p_name text,
    p_team_type text DEFAULT 'collaborative',
    p_agent_ids uuid[] DEFAULT ARRAY[]::uuid[],
    p_config jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_team_id uuid;
    v_agent_id uuid;
    v_default_config jsonb := '{
        "max_members": 10,
        "require_consensus": false,
        "consensus_threshold": 0.6,
        "allow_delegation": true,
        "timeout_seconds": 300
    }'::jsonb;
BEGIN
    -- Create Team
    INSERT INTO aos_multi_agent.team (tenant_id, name, team_type, config)
    VALUES (p_tenant_id, p_name, p_team_type, v_default_config || p_config)
    RETURNING team_id INTO v_team_id;
    
    -- Add Members
    FOREACH v_agent_id IN ARRAY p_agent_ids
    LOOP
        INSERT INTO aos_multi_agent.team_member (team_id, agent_id, role)
        VALUES (v_team_id, v_agent_id, 
                CASE WHEN v_agent_id = p_agent_ids[1] THEN 'leader' ELSE 'member' END);
    END LOOP;
    
    RETURN v_team_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: add_team_member
-- Purpose: Add member to team
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.add_team_member(
    p_team_id uuid,
    p_agent_id uuid DEFAULT NULL,
    p_principal_id uuid DEFAULT NULL,
    p_role text DEFAULT 'member'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_member_id uuid;
BEGIN
    INSERT INTO aos_multi_agent.team_member (team_id, agent_id, principal_id, role)
    VALUES (p_team_id, p_agent_id, p_principal_id, p_role)
    RETURNING member_id INTO v_member_id;
    
    RETURN v_member_id;
END;
$$;

-- ============================================================================
-- FUNCTIONS: Discussion Management
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: start_discussion
-- Purpose: Start Discussion
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.start_discussion(
    p_tenant_id uuid,
    p_topic text,
    p_team_id uuid DEFAULT NULL,
    p_discussion_type text DEFAULT 'open',
    p_goal text DEFAULT NULL,
    p_context jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_discussion_id uuid;
BEGIN
    INSERT INTO aos_multi_agent.discussion (
        tenant_id, team_id, topic, goal, context, discussion_type
    ) VALUES (
        p_tenant_id, p_team_id, p_topic, p_goal, p_context, p_discussion_type
    )
    RETURNING discussion_id INTO v_discussion_id;
    
    -- System Notification
    INSERT INTO aos_multi_agent.agent_message (
        discussion_id, sender_principal_id, message_type, content, sequence_number
    ) VALUES (
        v_discussion_id, 
        NULL,  -- System
        'system',
        format('Discussion started: %s', p_topic),
        1
    );
    
    RETURN v_discussion_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: send_agent_message
-- Purpose: Send Message between Agents (CORE!)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.send_agent_message(
    p_discussion_id uuid,
    p_sender_agent_id uuid,
    p_message_type text,
    p_content text,
    p_recipient_agent_ids uuid[] DEFAULT ARRAY[]::uuid[],
    p_metadata jsonb DEFAULT '{}'::jsonb,
    p_source_turn_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_message_id uuid;
    v_sequence int;
    v_round int;
BEGIN
    -- Next Sequence
    SELECT COALESCE(MAX(sequence_number), 0) + 1 INTO v_sequence
    FROM aos_multi_agent.agent_message WHERE discussion_id = p_discussion_id;
    
    -- Current Round
    SELECT COALESCE(MAX(round_number), 1) INTO v_round
    FROM aos_multi_agent.agent_message WHERE discussion_id = p_discussion_id;
    
    -- Insert Message
    INSERT INTO aos_multi_agent.agent_message (
        discussion_id, sender_agent_id, message_type, content,
        recipient_agent_ids, metadata, sequence_number, round_number,
        source_turn_id
    ) VALUES (
        p_discussion_id, p_sender_agent_id, p_message_type, p_content,
        p_recipient_agent_ids, p_metadata, v_sequence, v_round,
        p_source_turn_id
    )
    RETURNING message_id INTO v_message_id;
    
    -- Update Discussion Stats
    UPDATE aos_multi_agent.discussion
    SET total_messages = total_messages + 1,
        updated_at = now()
    WHERE discussion_id = p_discussion_id;
    
    -- Log to Event Log
    INSERT INTO aos_core.event_log (
        run_id, event_type, actor_type, actor_id, event_name, payload
    )
    SELECT 
        NULL,  -- Need to fix this to handle run_id eventually
        'agent_communication',
        'agent',
        p_sender_agent_id,
        'message_sent',
        jsonb_build_object(
            'discussion_id', p_discussion_id,
            'message_id', v_message_id,
            'message_type', p_message_type,
            'recipients', p_recipient_agent_ids
        );
    
    RETURN v_message_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: react_to_message
-- Purpose: React to a message
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.react_to_message(
    p_message_id uuid,
    p_reactor_agent_id uuid,
    p_reaction_type text,  -- 'agree', 'disagree', 'neutral', 'clarify'
    p_strength float DEFAULT 1.0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE aos_multi_agent.agent_message
    SET reactions = reactions || jsonb_build_object(
        p_reactor_agent_id::text,
        jsonb_build_object('type', p_reaction_type, 'strength', p_strength, 'at', now())
    )
    WHERE message_id = p_message_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: create_proposal
-- Purpose: Create Proposal
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.create_proposal(
    p_discussion_id uuid,
    p_title text,
    p_description text,
    p_proposed_by uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_proposal_id uuid;
BEGIN
    INSERT INTO aos_multi_agent.proposal (
        discussion_id, title, description, proposed_by
    ) VALUES (
        p_discussion_id, p_title, p_description, p_proposed_by
    )
    RETURNING proposal_id INTO v_proposal_id;
    
    -- Auto-generate Proposal Message
    PERFORM aos_multi_agent.send_agent_message(
        p_discussion_id,
        p_proposed_by,
        'proposal',
        format('**Proposal:** %s\n\n%s', p_title, p_description),
        ARRAY[]::uuid[],
        jsonb_build_object('proposal_id', v_proposal_id)
    );
    
    RETURN v_proposal_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: cast_vote
-- Purpose: Cast Vote
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.cast_vote(
    p_proposal_id uuid,
    p_voter_agent_id uuid,
    p_vote_value text,
    p_rationale text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_discussion_id uuid;
BEGIN
    -- Record Vote
    INSERT INTO aos_multi_agent.vote (
        proposal_id, voter_agent_id, vote_value, rationale
    ) VALUES (
        p_proposal_id, p_voter_agent_id, p_vote_value, p_rationale
    )
    ON CONFLICT (proposal_id, voter_agent_id) DO UPDATE
    SET vote_value = EXCLUDED.vote_value,
        rationale = EXCLUDED.rationale,
        voted_at = now();
    
    -- Update Count
    UPDATE aos_multi_agent.proposal p
    SET votes_for = (SELECT count(*) FROM aos_multi_agent.vote v WHERE v.proposal_id = p.proposal_id AND v.vote_value = 'for'),
        votes_against = (SELECT count(*) FROM aos_multi_agent.vote v WHERE v.proposal_id = p.proposal_id AND v.vote_value = 'against'),
        votes_abstain = (SELECT count(*) FROM aos_multi_agent.vote v WHERE v.proposal_id = p.proposal_id AND v.vote_value = 'abstain')
    WHERE p.proposal_id = p_proposal_id;
    
    -- Create Vote Message
    SELECT discussion_id INTO v_discussion_id
    FROM aos_multi_agent.proposal WHERE proposal_id = p_proposal_id;
    
    PERFORM aos_multi_agent.send_agent_message(
        v_discussion_id,
        p_voter_agent_id,
        'vote',
        COALESCE(p_rationale, format('Vote: %s', p_vote_value)),
        ARRAY[]::uuid[],
        jsonb_build_object(
            'proposal_id', p_proposal_id,
            'vote_value', p_vote_value
        )
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: conclude_discussion
-- Purpose: Conclude discussion
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.conclude_discussion(
    p_discussion_id uuid,
    p_conclusion text,
    p_rationale text DEFAULT NULL,
    p_concluded_by uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE aos_multi_agent.discussion
    SET status = 'concluded',
        conclusion = p_conclusion,
        conclusion_rationale = p_rationale,
        concluded_by = p_concluded_by,
        concluded_at = now(),
        updated_at = now()
    WHERE discussion_id = p_discussion_id;
    
    -- Conclusion Message
    INSERT INTO aos_multi_agent.agent_message (
        discussion_id, message_type, content, sequence_number
    )
    SELECT 
        p_discussion_id,
        'system',
        format('**Conclusion:** %s', p_conclusion),
        COALESCE(MAX(sequence_number), 0) + 1
    FROM aos_multi_agent.agent_message
    WHERE discussion_id = p_discussion_id;
END;
$$;

-- ============================================================================
-- FUNCTIONS: Message Queries
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: get_discussion_messages
-- Purpose: Get discussion messages (context for agent)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.get_discussion_messages(
    p_discussion_id uuid,
    p_limit int DEFAULT 50,
    p_since_sequence int DEFAULT 0
)
RETURNS TABLE (
    message_id uuid,
    sender_agent_id uuid,
    sender_name text,
    message_type text,
    content text,
    metadata jsonb,
    reactions jsonb,
    sequence_number int,
    created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        m.message_id,
        m.sender_agent_id,
        COALESCE(a.display_name, a.name, 'System') as sender_name,
        m.message_type,
        m.content,
        m.metadata,
        m.reactions,
        m.sequence_number,
        m.created_at
    FROM aos_multi_agent.agent_message m
    LEFT JOIN aos_agent.agent a ON a.agent_id = m.sender_agent_id
    WHERE m.discussion_id = p_discussion_id
      AND m.sequence_number > p_since_sequence
    ORDER BY m.sequence_number
    LIMIT p_limit;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_pending_messages_for_agent
-- Purpose: Get messages requiring response
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_multi_agent.get_pending_messages_for_agent(
    p_agent_id uuid
)
RETURNS TABLE (
    discussion_id uuid,
    discussion_topic text,
    message_id uuid,
    sender_name text,
    message_type text,
    content text,
    created_at timestamptz,
    needs_response bool
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        d.discussion_id,
        d.topic as discussion_topic,
        m.message_id,
        COALESCE(a.display_name, a.name) as sender_name,
        m.message_type,
        m.content,
        m.created_at,
        -- Needs Response? (Question or Direct Mention)
        (m.message_type = 'question' OR p_agent_id = ANY(m.recipient_agent_ids)) as needs_response
    FROM aos_multi_agent.discussion d
    JOIN aos_multi_agent.agent_message m ON m.discussion_id = d.discussion_id
    LEFT JOIN aos_agent.agent a ON a.agent_id = m.sender_agent_id
    WHERE d.status = 'active'
      AND m.sender_agent_id != p_agent_id
      AND (
          p_agent_id = ANY(m.recipient_agent_ids)  -- Direct Recipient
          OR array_length(m.recipient_agent_ids, 1) IS NULL  -- Broadcast
      )
      AND NOT EXISTS (  -- Not yet replied
          SELECT 1 FROM aos_multi_agent.agent_message reply
          WHERE reply.discussion_id = d.discussion_id
            AND reply.sender_agent_id = p_agent_id
            AND reply.sequence_number > m.sequence_number
            AND reply.metadata->>'in_reply_to' = m.message_id::text
      )
    ORDER BY m.created_at DESC;
END;
$$;

-- ============================================================================
-- VIEWS: Monitoring
-- ============================================================================

-- ----------------------------------------------------------------------------
-- View: active_discussions
-- Purpose: Active Discussions
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_multi_agent.active_discussions AS
SELECT 
    d.discussion_id,
    d.topic,
    d.discussion_type,
    d.status,
    t.name as team_name,
    d.total_messages,
    d.participating_agents,
    d.started_at,
    d.updated_at,
    EXTRACT(EPOCH FROM (now() - d.updated_at))::int as seconds_since_activity
FROM aos_multi_agent.discussion d
LEFT JOIN aos_multi_agent.team t ON t.team_id = d.team_id
WHERE d.status IN ('active', 'voting')
ORDER BY d.updated_at DESC;

-- ----------------------------------------------------------------------------
-- View: discussion_summary
-- Purpose: Discussion Summary
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW aos_multi_agent.discussion_summary AS
SELECT 
    d.discussion_id,
    d.topic,
    d.status,
    d.conclusion,
    d.total_messages,
    array_agg(DISTINCT a.name) as participants,
    (SELECT count(DISTINCT message_type) FROM aos_multi_agent.agent_message m 
     WHERE m.discussion_id = d.discussion_id) as message_type_diversity,
    (SELECT count(*) FROM aos_multi_agent.proposal p 
     WHERE p.discussion_id = d.discussion_id) as proposals_count,
    (SELECT count(*) FROM aos_multi_agent.proposal p 
     WHERE p.discussion_id = d.discussion_id AND p.status = 'accepted') as accepted_proposals
FROM aos_multi_agent.discussion d
LEFT JOIN aos_multi_agent.agent_message m ON m.discussion_id = d.discussion_id
LEFT JOIN aos_agent.agent a ON a.agent_id = m.sender_agent_id
GROUP BY d.discussion_id, d.topic, d.status, d.conclusion, d.total_messages;

COMMENT ON SCHEMA aos_multi_agent IS 'pgAgentOS: Multi-Agent Collaboration System';
COMMENT ON TABLE aos_multi_agent.team IS 'Agent Team';
COMMENT ON TABLE aos_multi_agent.team_member IS 'Team Member';
COMMENT ON TABLE aos_multi_agent.discussion IS 'Discussion Session';
COMMENT ON TABLE aos_multi_agent.agent_message IS 'Agent Message (Core Protocol)';
COMMENT ON TABLE aos_multi_agent.proposal IS 'Proposal in Discussion';
COMMENT ON TABLE aos_multi_agent.vote IS 'Vote Record';
COMMENT ON TABLE aos_multi_agent.shared_artifact IS 'Shared Artifact';

COMMENT ON FUNCTION aos_multi_agent.send_agent_message IS 'Send agent message (Multi-agent communication)';
COMMENT ON FUNCTION aos_multi_agent.get_pending_messages_for_agent IS 'Get messages requiring agent response';
