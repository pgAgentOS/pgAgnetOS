-- ============================================================================
-- pgAgentOS: Sample Workflow Graph
-- Example: Simple Q&A Agent with RAG
-- ============================================================================

-- This example creates a simple RAG-based Q&A workflow:
-- START -> Retrieve -> LLM Generate -> END

-- First, create a test tenant and principal
INSERT INTO aos_auth.tenant (tenant_id, name, display_name)
VALUES ('11111111-1111-1111-1111-111111111111', 'demo_tenant', 'Demo Tenant')
ON CONFLICT (name) DO NOTHING;

INSERT INTO aos_auth.principal (principal_id, tenant_id, principal_type, display_name, db_role_name)
VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'agent', 'Demo Agent', 'demo_agent')
ON CONFLICT DO NOTHING;

-- Grant agent role
INSERT INTO aos_auth.role_grant (principal_id, role_key)
VALUES ('22222222-2222-2222-2222-222222222222', 'agent')
ON CONFLICT DO NOTHING;

-- Set up tenant context
SELECT aos_auth.set_tenant('11111111-1111-1111-1111-111111111111'::uuid);

-- Create a persona that uses GPT-4o
INSERT INTO aos_persona.persona (
    persona_id,
    tenant_id,
    principal_id,
    name,
    system_prompt,
    model_id,
    traits,
    override_params
)
SELECT 
    '33333333-3333-3333-3333-333333333333'::uuid,
    '11111111-1111-1111-1111-111111111111'::uuid,
    '22222222-2222-2222-2222-222222222222'::uuid,
    'qa_assistant',
    'You are a helpful Q&A assistant. Answer questions based on the provided context. If you cannot find the answer in the context, say so clearly.',
    model_id,
    '{"helpful": true, "concise": true}'::jsonb,
    '{"temperature": 0.3}'::jsonb
FROM aos_meta.llm_model_registry
WHERE provider = 'openai' AND model_name = 'gpt-4o'
ON CONFLICT DO NOTHING;

-- Create the Q&A workflow graph
SELECT aos_workflow.create_graph(
    p_tenant_id := '11111111-1111-1111-1111-111111111111'::uuid,
    p_name := 'simple_qa',
    p_version := '1.0',
    p_description := 'Simple RAG-based Q&A workflow',
    p_nodes := ARRAY[
        '{"node_name": "retrieve", "node_type": "skill", "skill_key": "rag_retrieve", "description": "Retrieve relevant documents"}'::jsonb,
        '{"node_name": "generate", "node_type": "llm", "persona_id": "33333333-3333-3333-3333-333333333333", "prompt_template": "Context:\n{{context}}\n\nQuestion: {{question}}\n\nAnswer:", "description": "Generate answer from context"}'::jsonb,
        '{"node_name": "review", "node_type": "human", "interrupt_before": true, "description": "Optional human review"}'::jsonb
    ],
    p_edges := ARRAY[
        '{"from_node": "__start__", "to_node": "retrieve"}'::jsonb,
        '{"from_node": "retrieve", "to_node": "generate"}'::jsonb,
        '{"from_node": "generate", "to_node": "review", "is_conditional": true, "condition_expression": "(state_data->>''require_review'')::bool = true", "label": "needs_review"}'::jsonb,
        '{"from_node": "generate", "to_node": "__end__", "label": "direct"}'::jsonb,
        '{"from_node": "review", "to_node": "__end__"}'::jsonb
    ],
    p_config := '{"max_steps": 10}'::jsonb
);

-- Show what was created
SELECT 'Graph created:' as info;
SELECT graph_id, name, version, description FROM aos_workflow.workflow_graph WHERE tenant_id = '11111111-1111-1111-1111-111111111111';

SELECT 'Nodes:' as info;
SELECT node_name, node_type, skill_key, description 
FROM aos_workflow.workflow_graph_node n
JOIN aos_workflow.workflow_graph g ON g.graph_id = n.graph_id
WHERE g.tenant_id = '11111111-1111-1111-1111-111111111111';

SELECT 'Edges:' as info;
SELECT from_node, to_node, is_conditional, label
FROM aos_workflow.workflow_graph_edge e
JOIN aos_workflow.workflow_graph g ON g.graph_id = e.graph_id
WHERE g.tenant_id = '11111111-1111-1111-1111-111111111111';

-- Generate DOT visualization
SELECT 'Graph visualization (DOT format):' as info;
SELECT aos_workflow.get_graph_visualization(graph_id)
FROM aos_workflow.workflow_graph
WHERE tenant_id = '11111111-1111-1111-1111-111111111111' AND name = 'simple_qa';

-- Example: Start a run
/*
SELECT aos_workflow.start_graph_run(
    p_graph_id := (SELECT graph_id FROM aos_workflow.workflow_graph WHERE name = 'simple_qa' LIMIT 1),
    p_initial_state := '{"question": "What is pgAgentOS?"}'::jsonb,
    p_principal_id := '22222222-2222-2222-2222-222222222222'::uuid,
    p_persona_id := '33333333-3333-3333-3333-333333333333'::uuid
);

-- Step through the workflow
SELECT aos_workflow.step_graph(run_id) FROM aos_core.run WHERE status = 'running' LIMIT 1;

-- Check state history
SELECT * FROM aos_workflow.get_state_history(
    (SELECT run_id FROM aos_core.run WHERE status IN ('running', 'completed') ORDER BY started_at DESC LIMIT 1)
);
*/
