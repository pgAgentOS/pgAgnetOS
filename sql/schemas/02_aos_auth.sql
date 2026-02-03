-- ============================================================================
-- pgAgentOS: Authentication & Multi-tenancy
-- Purpose: Tenant isolation and principal identity
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
    settings jsonb DEFAULT '{}'::jsonb,
    is_active bool DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_tenant_active ON aos_auth.tenant(is_active) WHERE is_active = true;

-- ----------------------------------------------------------------------------
-- Table: principal
-- Purpose: User or agent identity
-- ----------------------------------------------------------------------------
CREATE TABLE aos_auth.principal (
    principal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE,
    
    principal_type text NOT NULL DEFAULT 'user' 
        CHECK (principal_type IN ('user', 'agent', 'service')),
    
    name text NOT NULL,
    email text,
    role text DEFAULT 'user' CHECK (role IN ('admin', 'user', 'agent')),
    
    is_active bool DEFAULT true,
    metadata jsonb DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    
    UNIQUE (tenant_id, name)
);

CREATE INDEX idx_principal_tenant ON aos_auth.principal(tenant_id);
CREATE INDEX idx_principal_type ON aos_auth.principal(principal_type);

-- ----------------------------------------------------------------------------
-- Add FK to aos_core.run
-- ----------------------------------------------------------------------------
ALTER TABLE aos_core.run 
ADD CONSTRAINT fk_run_tenant 
FOREIGN KEY (tenant_id) REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE;

ALTER TABLE aos_core.event
ADD CONSTRAINT fk_event_tenant
FOREIGN KEY (tenant_id) REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE;

ALTER TABLE aos_core.job
ADD CONSTRAINT fk_job_tenant
FOREIGN KEY (tenant_id) REFERENCES aos_auth.tenant(tenant_id) ON DELETE CASCADE;

-- ----------------------------------------------------------------------------
-- Function: set_tenant (for RLS)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.set_tenant(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM aos_auth.tenant WHERE tenant_id = p_tenant_id AND is_active) THEN
        RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
    END IF;
    PERFORM set_config('aos.tenant_id', p_tenant_id::text, false);
END;
$$;

-- ----------------------------------------------------------------------------
-- Function: current_tenant
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aos_auth.current_tenant()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('aos.tenant_id', true), '')::uuid;
$$;

COMMENT ON SCHEMA aos_auth IS 'pgAgentOS: Authentication and multi-tenancy';
COMMENT ON TABLE aos_auth.tenant IS 'Tenant isolation units';
COMMENT ON TABLE aos_auth.principal IS 'Users and agents';
