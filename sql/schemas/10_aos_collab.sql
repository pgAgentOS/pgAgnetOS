-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_collab (Collaboration & Task Management)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_collab;

-- ----------------------------------------------------------------------------
-- Table: task
-- Purpose: Task/issue tracking for agent work
-- ----------------------------------------------------------------------------
CREATE TABLE aos_collab.task (
    task_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Task details
    title text NOT NULL,
    description text,
    task_type text DEFAULT 'task' CHECK (task_type IN ('task', 'bug', 'feature', 'research', 'review')),
    
    -- Status
    status text NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'in_progress', 'blocked', 'review', 'done', 'cancelled')),
    priority int DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    
    -- Assignment
    assignee_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    reporter_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    
    -- Hierarchy
    parent_task_id uuid REFERENCES aos_collab.task(task_id),
    
    -- Metadata
    labels text[] DEFAULT ARRAY[]::text[],
    metadata jsonb DEFAULT '{}'::jsonb,
    
    -- Timing
    due_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    completed_at timestamptz
);

CREATE INDEX idx_collab_task_tenant ON aos_collab.task(tenant_id);
CREATE INDEX idx_collab_task_status ON aos_collab.task(status);
CREATE INDEX idx_collab_task_assignee ON aos_collab.task(assignee_principal_id);
CREATE INDEX idx_collab_task_parent ON aos_collab.task(parent_task_id) WHERE parent_task_id IS NOT NULL;
CREATE INDEX idx_collab_task_labels ON aos_collab.task USING GIN(labels);

-- ----------------------------------------------------------------------------
-- Table: run_link
-- Purpose: Link runs to tasks
-- ----------------------------------------------------------------------------
CREATE TABLE aos_collab.run_link (
    run_id uuid NOT NULL REFERENCES aos_core.run(run_id) ON DELETE CASCADE,
    task_id uuid NOT NULL REFERENCES aos_collab.task(task_id) ON DELETE CASCADE,
    
    link_type text NOT NULL DEFAULT 'works_on'
        CHECK (link_type IN ('works_on', 'generated_by', 'reviews', 'blocks', 'relates_to')),
    
    metadata jsonb DEFAULT '{}'::jsonb,
    linked_at timestamptz NOT NULL DEFAULT now(),
    linked_by uuid REFERENCES aos_auth.principal(principal_id),
    
    PRIMARY KEY (run_id, task_id, link_type)
);

CREATE INDEX idx_collab_run_link_task ON aos_collab.run_link(task_id);
CREATE INDEX idx_collab_run_link_type ON aos_collab.run_link(link_type);

-- ----------------------------------------------------------------------------
-- Table: comment
-- Purpose: Comments on tasks
-- ----------------------------------------------------------------------------
CREATE TABLE aos_collab.comment (
    comment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id uuid NOT NULL REFERENCES aos_collab.task(task_id) ON DELETE CASCADE,
    
    content text NOT NULL,
    author_principal_id uuid REFERENCES aos_auth.principal(principal_id),
    
    -- For threaded comments
    parent_comment_id uuid REFERENCES aos_collab.comment(comment_id),
    
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz,
    is_edited bool DEFAULT false
);

CREATE INDEX idx_collab_comment_task ON aos_collab.comment(task_id);
CREATE INDEX idx_collab_comment_author ON aos_collab.comment(author_principal_id);

COMMENT ON SCHEMA aos_collab IS 'pgAgentOS: Collaboration and task management';
COMMENT ON TABLE aos_collab.task IS 'Task/issue tracking';
COMMENT ON TABLE aos_collab.run_link IS 'Links between runs and tasks';
COMMENT ON TABLE aos_collab.comment IS 'Comments on tasks';
