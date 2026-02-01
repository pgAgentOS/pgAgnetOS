-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: aos_auth (Authentication & Authorization)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS aos_auth;

-- ----------------------------------------------------------------------------
-- Table: tenant
-- Purpose: Multi-tenancy isolation unit
-- ----------------------------------------------------------------------------
CREATE TABLE aos_auth.tenant (
    tenant_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL UNIQUE,
    display_name text,
    is_active bool DEFAULT true,
    settings jsonb DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz
);

CREATE INDEX idx_tenant_active ON aos_auth.tenant(is_active) WHERE is_active = true;

-- ----------------------------------------------------------------------------
-- Table: principal
-- Purpose: User/Agent principal entity
-- ----------------------------------------------------------------------------
CREATE TABLE aos_auth.principal (
    principal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    principal_type text NOT NULL DEFAULT 'user' CHECK (principal_type IN ('user', 'agent', 'service')),
    db_role_name text UNIQUE,                        -- PostgreSQL role name for RLS
    display_name text,
    email text,
    is_active bool DEFAULT true,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz
);

CREATE INDEX idx_principal_tenant ON aos_auth.principal(tenant_id);
CREATE INDEX idx_principal_type ON aos_auth.principal(principal_type);
CREATE INDEX idx_principal_db_role ON aos_auth.principal(db_role_name) WHERE db_role_name IS NOT NULL;

-- ----------------------------------------------------------------------------
-- Table: role_grant
-- Purpose: Role assignment to principals (admin, developer, auditor)
-- ----------------------------------------------------------------------------
CREATE TABLE aos_auth.role_grant (
    grant_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    principal_id uuid NOT NULL REFERENCES aos_auth.principal(principal_id) ON DELETE CASCADE,
    role_key text NOT NULL CHECK (role_key IN ('admin', 'developer', 'auditor', 'agent', 'viewer')),
    granted_at timestamptz NOT NULL DEFAULT now(),
    granted_by uuid REFERENCES aos_auth.principal(principal_id),
    expires_at timestamptz,                          -- NULL means never expires
    is_active bool DEFAULT true,
    metadata jsonb DEFAULT '{}'::jsonb,
    UNIQUE (principal_id, role_key)
);

CREATE INDEX idx_role_grant_principal ON aos_auth.role_grant(principal_id);
CREATE INDEX idx_role_grant_role ON aos_auth.role_grant(role_key);
CREATE INDEX idx_role_grant_active ON aos_auth.role_grant(is_active, expires_at);

-- ----------------------------------------------------------------------------
-- Function: set_tenant
-- Purpose: Set current tenant context for RLS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.set_tenant(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Verify tenant exists and is active
    IF NOT EXISTS (
        SELECT 1 FROM aos_auth.tenant 
        WHERE tenant_id = p_tenant_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
    END IF;
    
    PERFORM set_config('aos.tenant_id', p_tenant_id::text, false);
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: current_tenant
-- Purpose: Get current tenant ID from session
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.current_tenant()
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_tenant_id text;
BEGIN
    v_tenant_id := current_setting('aos.tenant_id', true);
    IF v_tenant_id IS NULL OR v_tenant_id = '' THEN
        RETURN NULL;
    END IF;
    RETURN v_tenant_id::uuid;
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: current_principal
-- Purpose: Get current principal ID from session
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.current_principal()
RETURNS uuid
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_principal_id text;
BEGIN
    v_principal_id := current_setting('aos.principal_id', true);
    IF v_principal_id IS NULL OR v_principal_id = '' THEN
        RETURN NULL;
    END IF;
    RETURN v_principal_id::uuid;
END;
$$;

COMMENT ON SCHEMA aos_auth IS 'pgAgentOS: Authentication and authorization';
COMMENT ON TABLE aos_auth.tenant IS 'Multi-tenancy isolation units';
COMMENT ON TABLE aos_auth.principal IS 'Users, agents, and service principals';
COMMENT ON TABLE aos_auth.role_grant IS 'Role assignments to principals';
COMMENT ON FUNCTION aos_auth.set_tenant IS 'Set current tenant context for RLS';
