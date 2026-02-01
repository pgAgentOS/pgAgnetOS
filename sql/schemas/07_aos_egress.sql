-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_egress (External API Control)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_egress;

-- ----------------------------------------------------------------------------
-- Table: request
-- Purpose: External API request queue with approval flow
-- ----------------------------------------------------------------------------
CREATE TABLE aos_egress.request (
    request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id uuid REFERENCES aos_core.run(run_id) ON DELETE CASCADE,
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Target
    target_type text NOT NULL CHECK (target_type IN ('api', 'db', 'file', 'webhook', 'email')),
    target text NOT NULL,                            -- URL, connection string, file path, etc.
    method text DEFAULT 'POST',                      -- HTTP method
    
    -- Request data
    headers jsonb DEFAULT '{}'::jsonb,
    payload jsonb NOT NULL,
    
    -- Risk assessment
    risk_level text DEFAULT 'low' CHECK (risk_level IN ('low', 'medium', 'high', 'critical')),
    risk_factors jsonb DEFAULT '[]'::jsonb,
    
    -- Approval flow
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'executed', 'rejected', 'failed', 'timeout')),
    requires_approval bool DEFAULT false,
    approval_notes text,
    approved_by uuid REFERENCES aos_auth.principal(principal_id),
    
    -- Response
    response_status int,
    response_headers jsonb,
    response_body jsonb,
    error_message text,
    
    -- Timing
    created_at timestamptz NOT NULL DEFAULT now(),
    approved_at timestamptz,
    executed_at timestamptz,
    duration_ms bigint
);

CREATE INDEX idx_egress_request_run ON aos_egress.request(run_id);
CREATE INDEX idx_egress_request_tenant ON aos_egress.request(tenant_id);
CREATE INDEX idx_egress_request_status ON aos_egress.request(status);
CREATE INDEX idx_egress_request_pending ON aos_egress.request(status, created_at) 
    WHERE status = 'pending';

-- ----------------------------------------------------------------------------
-- Table: allowlist
-- Purpose: Pre-approved external endpoints
-- ----------------------------------------------------------------------------
CREATE TABLE aos_egress.allowlist (
    allowlist_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    -- Pattern matching
    target_pattern text NOT NULL,                    -- Regex pattern for URL/endpoint
    target_type text NOT NULL CHECK (target_type IN ('api', 'db', 'file', 'webhook', 'email')),
    
    -- Permissions
    allowed_methods text[] DEFAULT ARRAY['GET', 'POST']::text[],
    max_payload_bytes int DEFAULT 1048576,           -- 1MB default
    rate_limit_per_minute int DEFAULT 60,
    
    -- Metadata
    description text,
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid REFERENCES aos_auth.principal(principal_id)
);

CREATE INDEX idx_egress_allowlist_tenant ON aos_egress.allowlist(tenant_id);
CREATE INDEX idx_egress_allowlist_active ON aos_egress.allowlist(is_active) WHERE is_active = true;

-- ----------------------------------------------------------------------------
-- Function: check_allowlist
-- Purpose: Check if a request is pre-approved
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_egress.check_allowlist(
    p_tenant_id uuid,
    p_target_type text,
    p_target text,
    p_method text DEFAULT 'POST'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
    v_match aos_egress.allowlist;
BEGIN
    SELECT * INTO v_match
    FROM aos_egress.allowlist
    WHERE tenant_id = p_tenant_id
      AND target_type = p_target_type
      AND is_active = true
      AND p_target ~ target_pattern
      AND p_method = ANY(allowed_methods)
    LIMIT 1;
    
    IF FOUND THEN
        RETURN jsonb_build_object(
            'allowed', true,
            'allowlist_id', v_match.allowlist_id,
            'rate_limit_per_minute', v_match.rate_limit_per_minute,
            'max_payload_bytes', v_match.max_payload_bytes
        );
    ELSE
        RETURN jsonb_build_object('allowed', false);
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: create_egress_request
-- Purpose: Create an egress request with automatic approval check
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_egress.create_egress_request(
    p_run_id uuid,
    p_target_type text,
    p_target text,
    p_payload jsonb,
    p_method text DEFAULT 'POST',
    p_headers jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_tenant_id uuid;
    v_request_id uuid;
    v_allowlist_check jsonb;
    v_requires_approval bool := true;
    v_status text := 'pending';
BEGIN
    -- Get tenant from run
    SELECT tenant_id INTO v_tenant_id
    FROM aos_core.run
    WHERE run_id = p_run_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Run not found: %', p_run_id;
    END IF;
    
    -- Check allowlist
    v_allowlist_check := aos_egress.check_allowlist(v_tenant_id, p_target_type, p_target, p_method);
    
    IF (v_allowlist_check->>'allowed')::bool THEN
        v_requires_approval := false;
        v_status := 'approved';
    END IF;
    
    -- Create request
    INSERT INTO aos_egress.request (
        run_id, tenant_id, target_type, target, method, headers, payload,
        requires_approval, status
    ) VALUES (
        p_run_id, v_tenant_id, p_target_type, p_target, p_method, p_headers, p_payload,
        v_requires_approval, v_status
    )
    RETURNING request_id INTO v_request_id;
    
    -- Log event
    PERFORM aos_core.log_event(
        p_run_id,
        'egress_request',
        jsonb_build_object(
            'request_id', v_request_id,
            'target', p_target,
            'requires_approval', v_requires_approval
        )
    );
    
    RETURN v_request_id;
END;
$$;

-- Insert default allowlists
INSERT INTO aos_egress.allowlist (tenant_id, target_pattern, target_type, description)
SELECT tenant_id, '^https://api\.openai\.com/', 'api', 'OpenAI API'
FROM aos_auth.tenant LIMIT 0;  -- Template only, no actual insert

COMMENT ON SCHEMA aos_egress IS 'pgAgentOS: External API request control';
COMMENT ON TABLE aos_egress.request IS 'External API request queue with approval flow';
COMMENT ON TABLE aos_egress.allowlist IS 'Pre-approved external endpoints';
