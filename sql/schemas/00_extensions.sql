-- ============================================================================
-- pgAgentOS: PostgreSQL Agent Operating System
-- Schema: Extensions & Dependencies
-- ============================================================================

-- Required extensions
CREATE EXTENSION IF NOT EXISTS pgvector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Verify minimum PostgreSQL version
DO $$
BEGIN
    IF current_setting('server_version_num')::int < 140000 THEN
        RAISE EXCEPTION 'pgAgentOS requires PostgreSQL 14 or higher';
    END IF;
END $$;
