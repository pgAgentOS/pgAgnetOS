-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Functions: Workflow Engine (Core Execution Functions)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Function: create_graph
-- Purpose: Create a new workflow graph with nodes and edges
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.create_graph(
    p_tenant_id uuid,
    p_name text,
    p_version text DEFAULT '1.0',
    p_description text DEFAULT NULL,
    p_nodes jsonb[] DEFAULT ARRAY[]::jsonb[],
    p_edges jsonb[] DEFAULT ARRAY[]::jsonb[],
    p_config jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_graph_id uuid;
    v_node jsonb;
    v_edge jsonb;
    v_validation jsonb;
BEGIN
    -- Verify tenant exists
    IF NOT EXISTS (SELECT 1 FROM aos_auth.tenant WHERE tenant_id = p_tenant_id AND is_active = true) THEN
        RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
    END IF;
    
    -- Create graph
    INSERT INTO aos_workflow.workflow_graph (
        tenant_id, name, version, description, config
    ) VALUES (
        p_tenant_id, p_name, p_version, p_description, p_config
    )
    RETURNING graph_id INTO v_graph_id;
    
    -- Create gateway nodes for entry/exit
    INSERT INTO aos_workflow.workflow_graph_node (graph_id, node_name, node_type, description)
    VALUES 
        (v_graph_id, '__start__', 'gateway', 'Entry point'),
        (v_graph_id, '__end__', 'gateway', 'Exit point');
    
    -- Create nodes from JSON array
    FOREACH v_node IN ARRAY p_nodes
    LOOP
        INSERT INTO aos_workflow.workflow_graph_node (
            graph_id,
            node_name,
            node_type,
            skill_key,
            function_name,
            persona_id,
            prompt_template,
            llm_override_params,
            interrupt_before,
            interrupt_after,
            config,
            description,
            position
        ) VALUES (
            v_graph_id,
            v_node->>'node_name',
            COALESCE(v_node->>'node_type', 'skill'),
            v_node->>'skill_key',
            (v_node->>'function_name')::regproc,
            (v_node->>'persona_id')::uuid,
            v_node->>'prompt_template',
            COALESCE(v_node->'llm_override_params', '{}'::jsonb),
            COALESCE((v_node->>'interrupt_before')::bool, false),
            COALESCE((v_node->>'interrupt_after')::bool, false),
            COALESCE(v_node->'config', '{}'::jsonb),
            v_node->>'description',
            v_node->'position'
        );
    END LOOP;
    
    -- Create edges from JSON array
    FOREACH v_edge IN ARRAY p_edges
    LOOP
        INSERT INTO aos_workflow.workflow_graph_edge (
            graph_id,
            from_node,
            to_node,
            is_conditional,
            condition_function,
            condition_expression,
            condition_value,
            label,
            priority,
            description
        ) VALUES (
            v_graph_id,
            v_edge->>'from_node',
            v_edge->>'to_node',
            COALESCE((v_edge->>'is_conditional')::bool, false),
            (v_edge->>'condition_function')::regproc,
            v_edge->>'condition_expression',
            v_edge->'condition_value',
            v_edge->>'label',
            COALESCE((v_edge->>'priority')::int, 0),
            v_edge->>'description'
        );
    END LOOP;
    
    -- Validate graph structure
    v_validation := aos_workflow.validate_graph(v_graph_id);
    IF NOT (v_validation->>'valid')::bool THEN
        RAISE EXCEPTION 'Invalid graph structure: %', v_validation->'errors';
    END IF;
    
    RETURN v_graph_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: start_graph_run
-- Purpose: Start a new workflow run
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.start_graph_run(
    p_graph_id uuid,
    p_initial_state jsonb DEFAULT '{}'::jsonb,
    p_principal_id uuid DEFAULT NULL,
    p_persona_id uuid DEFAULT NULL,
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_run_id uuid;
    v_graph aos_workflow.workflow_graph;
    v_state_id uuid;
BEGIN
    -- Get graph
    SELECT * INTO v_graph FROM aos_workflow.workflow_graph 
    WHERE graph_id = p_graph_id AND is_active = true;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Graph not found or inactive: %', p_graph_id;
    END IF;
    
    -- Create run
    INSERT INTO aos_core.run (
        tenant_id, principal_id, graph_id, persona_id, status, input_data, metadata
    ) VALUES (
        v_graph.tenant_id, p_principal_id, p_graph_id, p_persona_id, 'running', p_initial_state, p_metadata
    )
    RETURNING run_id INTO v_run_id;
    
    -- Create initial state checkpoint
    INSERT INTO aos_workflow.workflow_state (
        run_id, graph_id, checkpoint_version, current_node, state_data, messages
    ) VALUES (
        v_run_id, p_graph_id, 1, v_graph.entry_node, p_initial_state, ARRAY[]::jsonb[]
    )
    RETURNING state_id INTO v_state_id;
    
    -- Create session memory
    INSERT INTO aos_core.session_memory (
        run_id, tenant_id, principal_id, memory_type
    ) VALUES (
        v_run_id, v_graph.tenant_id, p_principal_id, 'working'
    );
    
    -- Log event
    PERFORM aos_core.log_event(
        v_run_id,
        'run_started',
        jsonb_build_object(
            'graph_id', p_graph_id,
            'graph_name', v_graph.name,
            'initial_state', p_initial_state
        )
    );
    
    RETURN v_run_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: step_graph
-- Purpose: Execute a single step in the workflow (Pregel-like)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.step_graph(p_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_run aos_core.run;
    v_state aos_workflow.workflow_state;
    v_node aos_workflow.workflow_graph_node;
    v_graph aos_workflow.workflow_graph;
    v_next_node text;
    v_new_state_data jsonb;
    v_new_messages jsonb[];
    v_new_checkpoint_version int;
    v_execution_result jsonb;
    v_edge record;
    v_start_time timestamptz;
    v_duration_ms bigint;
    v_should_interrupt bool := false;
    v_hooks_result jsonb;
BEGIN
    v_start_time := clock_timestamp();
    
    -- Get run
    SELECT * INTO v_run FROM aos_core.run WHERE run_id = p_run_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Run not found: %', p_run_id;
    END IF;
    
    IF v_run.status NOT IN ('running', 'pending') THEN
        RAISE EXCEPTION 'Run is not in a runnable state: %', v_run.status;
    END IF;
    
    -- Get current state (latest checkpoint)
    SELECT * INTO v_state
    FROM aos_workflow.workflow_state
    WHERE run_id = p_run_id
    ORDER BY checkpoint_version DESC
    LIMIT 1;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No state checkpoint found for run: %', p_run_id;
    END IF;
    
    -- Get graph
    SELECT * INTO v_graph FROM aos_workflow.workflow_graph WHERE graph_id = v_state.graph_id;
    
    -- Check if we've reached an exit node
    IF v_state.current_node = ANY(v_graph.exit_nodes) THEN
        -- Mark run as completed
        UPDATE aos_core.run
        SET status = 'completed', completed_at = now(), output_data = v_state.state_data
        WHERE run_id = p_run_id;
        
        PERFORM aos_core.log_event(p_run_id, 'run_completed', v_state.state_data);
        
        RETURN jsonb_build_object(
            'status', 'completed',
            'state', v_state.state_data,
            'checkpoint_version', v_state.checkpoint_version
        );
    END IF;
    
    -- Get current node
    SELECT * INTO v_node
    FROM aos_workflow.workflow_graph_node
    WHERE graph_id = v_state.graph_id AND node_name = v_state.current_node;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Node not found: %', v_state.current_node;
    END IF;
    
    -- Check interrupt_before
    IF v_node.interrupt_before THEN
        v_should_interrupt := true;
        
        -- Create interrupt
        INSERT INTO aos_workflow.workflow_interrupt (
            run_id, state_id, node_name, interrupt_type, request_message
        ) VALUES (
            p_run_id, v_state.state_id, v_node.node_name, 'approval',
            'Approval required before executing node: ' || v_node.node_name
        );
        
        UPDATE aos_core.run SET status = 'interrupted' WHERE run_id = p_run_id;
        
        PERFORM aos_core.log_event(p_run_id, 'interrupted', jsonb_build_object(
            'node', v_node.node_name,
            'reason', 'interrupt_before'
        ));
        
        RETURN jsonb_build_object(
            'status', 'interrupted',
            'reason', 'interrupt_before',
            'node', v_node.node_name,
            'checkpoint_version', v_state.checkpoint_version
        );
    END IF;
    
    -- Execute pre_node hooks
    v_hooks_result := aos_policy.execute_hooks(
        'pre_node',
        jsonb_build_object(
            'run_id', p_run_id,
            'node_name', v_node.node_name,
            'node_type', v_node.node_type,
            'state', v_state.state_data
        ),
        v_run.tenant_id
    );
    
    IF (v_hooks_result->>'_abort')::bool = true THEN
        PERFORM aos_core.log_event(p_run_id, 'node_aborted', v_hooks_result);
        RETURN jsonb_build_object(
            'status', 'aborted',
            'reason', v_hooks_result->>'_abort_reason'
        );
    END IF;
    
    -- Log node start
    PERFORM aos_core.log_event(p_run_id, 'node_start', jsonb_build_object(
        'node', v_node.node_name,
        'type', v_node.node_type
    ), v_node.node_name);
    
    -- Initialize new state
    v_new_state_data := v_state.state_data;
    v_new_messages := v_state.messages;
    
    -- Execute based on node type
    CASE v_node.node_type
        WHEN 'gateway' THEN
            -- Gateway nodes just pass through
            v_execution_result := jsonb_build_object('passed', true);
            
        WHEN 'skill' THEN
            -- Execute skill
            IF v_node.skill_key IS NOT NULL THEN
                -- This would call the actual skill implementation
                -- For now, record that we would execute the skill
                v_execution_result := jsonb_build_object(
                    'skill_key', v_node.skill_key,
                    'status', 'pending_external_execution'
                );
                
                INSERT INTO aos_core.skill_execution (
                    run_id, skill_key, input_params, status
                ) VALUES (
                    p_run_id, v_node.skill_key, v_new_state_data, 'pending'
                );
            END IF;
            
        WHEN 'llm' THEN
            -- LLM call would happen here
            v_execution_result := jsonb_build_object(
                'type', 'llm',
                'persona_id', v_node.persona_id,
                'prompt_template', v_node.prompt_template,
                'status', 'pending_external_execution'
            );
            
        WHEN 'function' THEN
            -- Execute PL/pgSQL function
            IF v_node.function_name IS NOT NULL THEN
                EXECUTE format('SELECT %s($1)', v_node.function_name)
                INTO v_execution_result
                USING v_new_state_data;
                
                -- Merge result into state
                IF v_execution_result IS NOT NULL THEN
                    v_new_state_data := v_new_state_data || v_execution_result;
                END IF;
            END IF;
            
        WHEN 'router' THEN
            -- Router just determines next node via conditional edges
            v_execution_result := jsonb_build_object('type', 'router');
            
        WHEN 'human' THEN
            -- Human-in-the-loop always interrupts
            v_should_interrupt := true;
            
            INSERT INTO aos_workflow.workflow_interrupt (
                run_id, state_id, node_name, interrupt_type, request_message
            ) VALUES (
                p_run_id, v_state.state_id, v_node.node_name, 'input',
                'Human input required at node: ' || v_node.node_name
            );
            
        ELSE
            RAISE EXCEPTION 'Unknown node type: %', v_node.node_type;
    END CASE;
    
    -- Check interrupt_after
    IF v_node.interrupt_after AND NOT v_should_interrupt THEN
        v_should_interrupt := true;
        
        INSERT INTO aos_workflow.workflow_interrupt (
            run_id, state_id, node_name, interrupt_type, request_message
        ) VALUES (
            p_run_id, v_state.state_id, v_node.node_name, 'review',
            'Review required after executing node: ' || v_node.node_name
        );
    END IF;
    
    -- If interrupted, update run status and return
    IF v_should_interrupt THEN
        UPDATE aos_core.run SET status = 'interrupted' WHERE run_id = p_run_id;
        
        PERFORM aos_core.log_event(p_run_id, 'interrupted', jsonb_build_object(
            'node', v_node.node_name,
            'reason', CASE WHEN v_node.node_type = 'human' THEN 'human_input' ELSE 'interrupt_after' END
        ));
        
        RETURN jsonb_build_object(
            'status', 'interrupted',
            'node', v_node.node_name,
            'checkpoint_version', v_state.checkpoint_version
        );
    END IF;
    
    -- Determine next node via edges
    v_next_node := NULL;
    
    FOR v_edge IN
        SELECT * FROM aos_workflow.workflow_graph_edge
        WHERE graph_id = v_state.graph_id AND from_node = v_state.current_node
        ORDER BY priority DESC
    LOOP
        IF v_edge.is_conditional THEN
            -- Evaluate condition
            IF v_edge.condition_function IS NOT NULL THEN
                EXECUTE format('SELECT %s($1)', v_edge.condition_function)
                INTO v_next_node
                USING v_new_state_data;
                
                IF v_next_node IS NOT NULL THEN
                    v_next_node := v_edge.to_node;
                    EXIT;
                END IF;
            ELSIF v_edge.condition_expression IS NOT NULL THEN
                -- Evaluate SQL expression
                EXECUTE format('SELECT CASE WHEN %s THEN $1 ELSE NULL END', v_edge.condition_expression)
                INTO v_next_node
                USING v_edge.to_node;
                
                IF v_next_node IS NOT NULL THEN
                    EXIT;
                END IF;
            ELSIF v_edge.condition_value IS NOT NULL THEN
                -- Match against state value
                IF v_new_state_data @> v_edge.condition_value THEN
                    v_next_node := v_edge.to_node;
                    EXIT;
                END IF;
            END IF;
        ELSE
            -- Non-conditional edge
            v_next_node := v_edge.to_node;
            EXIT;
        END IF;
    END LOOP;
    
    IF v_next_node IS NULL THEN
        -- No valid edge found, check if current node is an exit
        IF v_state.current_node = ANY(v_graph.exit_nodes) THEN
            v_next_node := v_state.current_node;
        ELSE
            RAISE EXCEPTION 'No valid edge from node: %', v_state.current_node;
        END IF;
    END IF;
    
    -- Execute post_node hooks
    v_hooks_result := aos_policy.execute_hooks(
        'post_node',
        jsonb_build_object(
            'run_id', p_run_id,
            'node_name', v_node.node_name,
            'next_node', v_next_node,
            'state', v_new_state_data,
            'result', v_execution_result
        ),
        v_run.tenant_id
    );
    
    -- Calculate duration
    v_duration_ms := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000;
    
    -- Log node end
    PERFORM aos_core.log_event(p_run_id, 'node_end', jsonb_build_object(
        'node', v_node.node_name,
        'next_node', v_next_node,
        'result', v_execution_result
    ), v_node.node_name, NULL, v_duration_ms);
    
    -- Create new checkpoint
    v_new_checkpoint_version := v_state.checkpoint_version + 1;
    
    INSERT INTO aos_workflow.workflow_state (
        run_id, graph_id, checkpoint_version, current_node, previous_node,
        state_data, messages, parent_state_id
    ) VALUES (
        p_run_id, v_state.graph_id, v_new_checkpoint_version, v_next_node, v_state.current_node,
        v_new_state_data, v_new_messages, v_state.state_id
    );
    
    -- Update run stats
    UPDATE aos_core.run
    SET total_steps = total_steps + 1
    WHERE run_id = p_run_id;
    
    RETURN jsonb_build_object(
        'status', 'stepped',
        'previous_node', v_state.current_node,
        'current_node', v_next_node,
        'checkpoint_version', v_new_checkpoint_version,
        'state', v_new_state_data,
        'duration_ms', v_duration_ms
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: resume_graph
-- Purpose: Resume a workflow after an interrupt
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.resume_graph(
    p_run_id uuid,
    p_from_checkpoint_version int DEFAULT NULL,
    p_state_patch jsonb DEFAULT NULL,
    p_resolved_by uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_run aos_core.run;
    v_state aos_workflow.workflow_state;
    v_interrupt aos_workflow.workflow_interrupt;
    v_new_state_data jsonb;
BEGIN
    -- Get run
    SELECT * INTO v_run FROM aos_core.run WHERE run_id = p_run_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Run not found: %', p_run_id;
    END IF;
    
    IF v_run.status != 'interrupted' THEN
        RAISE EXCEPTION 'Run is not interrupted: %', v_run.status;
    END IF;
    
    -- Resolve any pending interrupts
    UPDATE aos_workflow.workflow_interrupt
    SET status = 'resolved',
        resolved_by = p_resolved_by,
        resolved_at = now(),
        changes = p_state_patch
    WHERE run_id = p_run_id AND status = 'pending'
    RETURNING * INTO v_interrupt;
    
    -- Get state checkpoint (either specified or latest)
    IF p_from_checkpoint_version IS NOT NULL THEN
        SELECT * INTO v_state
        FROM aos_workflow.workflow_state
        WHERE run_id = p_run_id AND checkpoint_version = p_from_checkpoint_version;
    ELSE
        SELECT * INTO v_state
        FROM aos_workflow.workflow_state
        WHERE run_id = p_run_id
        ORDER BY checkpoint_version DESC
        LIMIT 1;
    END IF;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'State checkpoint not found';
    END IF;
    
    -- Apply state patch if provided
    IF p_state_patch IS NOT NULL THEN
        v_new_state_data := v_state.state_data || p_state_patch;
        
        -- Create new checkpoint with patched state
        INSERT INTO aos_workflow.workflow_state (
            run_id, graph_id, checkpoint_version, current_node, previous_node,
            state_data, messages, parent_state_id
        ) VALUES (
            p_run_id, v_state.graph_id, v_state.checkpoint_version + 1, v_state.current_node, v_state.previous_node,
            v_new_state_data, v_state.messages, v_state.state_id
        );
    END IF;
    
    -- Update run status
    UPDATE aos_core.run SET status = 'running' WHERE run_id = p_run_id;
    
    -- Log event
    PERFORM aos_core.log_event(p_run_id, 'resumed', jsonb_build_object(
        'from_checkpoint', COALESCE(p_from_checkpoint_version, v_state.checkpoint_version),
        'state_patched', p_state_patch IS NOT NULL,
        'resolved_by', p_resolved_by
    ));
    
    RETURN jsonb_build_object(
        'status', 'resumed',
        'run_id', p_run_id,
        'checkpoint_version', v_state.checkpoint_version + CASE WHEN p_state_patch IS NOT NULL THEN 1 ELSE 0 END
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: get_state_history
-- Purpose: Get checkpoint history for time-travel debugging
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.get_state_history(
    p_run_id uuid,
    p_limit int DEFAULT 10
)
RETURNS jsonb[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_result jsonb[];
BEGIN
    SELECT array_agg(
        jsonb_build_object(
            'checkpoint_version', checkpoint_version,
            'current_node', current_node,
            'previous_node', previous_node,
            'state_data', state_data,
            'messages', messages,
            'created_at', created_at,
            'is_final', is_final
        ) ORDER BY checkpoint_version DESC
    ) INTO v_result
    FROM aos_workflow.workflow_state
    WHERE run_id = p_run_id
    LIMIT p_limit;
    
    RETURN COALESCE(v_result, ARRAY[]::jsonb[]);
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: run_to_completion
-- Purpose: Run the workflow until completion or interrupt (with max steps)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_workflow.run_to_completion(
    p_run_id uuid,
    p_max_steps int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_step_result jsonb;
    v_step_count int := 0;
BEGIN
    LOOP
        v_step_result := aos_workflow.step_graph(p_run_id);
        v_step_count := v_step_count + 1;
        
        -- Check termination conditions
        IF v_step_result->>'status' IN ('completed', 'interrupted', 'aborted') THEN
            EXIT;
        END IF;
        
        IF v_step_count >= p_max_steps THEN
            -- Update run status
            UPDATE aos_core.run SET status = 'failed', 
                error_info = jsonb_build_object('error', 'Max steps exceeded')
            WHERE run_id = p_run_id;
            
            RETURN jsonb_build_object(
                'status', 'failed',
                'reason', 'max_steps_exceeded',
                'steps_executed', v_step_count
            );
        END IF;
    END LOOP;
    
    RETURN v_step_result || jsonb_build_object('steps_executed', v_step_count);
END;
$$;

COMMENT ON FUNCTION aos_workflow.create_graph IS 'Create a new workflow graph with nodes and edges';
COMMENT ON FUNCTION aos_workflow.start_graph_run IS 'Start a new workflow run';
COMMENT ON FUNCTION aos_workflow.step_graph IS 'Execute a single step in the workflow';
COMMENT ON FUNCTION aos_workflow.resume_graph IS 'Resume a workflow after an interrupt';
COMMENT ON FUNCTION aos_workflow.get_state_history IS 'Get checkpoint history for time-travel';
COMMENT ON FUNCTION aos_workflow.run_to_completion IS 'Run workflow until completion or interrupt';
