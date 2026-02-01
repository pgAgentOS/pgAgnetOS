EXTENSION = pgagentos
DATA = pgagentos--1.0.sql

# List of modular SQL files in order of dependency
SQL_FILES = sql/schemas/00_extensions.sql \
            sql/schemas/01_aos_meta.sql \
            sql/schemas/02_aos_auth.sql \
            sql/schemas/03_aos_persona.sql \
            sql/schemas/04_aos_skills.sql \
            sql/schemas/05_aos_core.sql \
            sql/schemas/06_aos_workflow.sql \
            sql/schemas/07_aos_egress.sql \
            sql/schemas/08_aos_kg.sql \
            sql/schemas/09_aos_embed.sql \
            sql/schemas/10_aos_collab.sql \
            sql/schemas/11_aos_policy.sql \
            sql/schemas/12_aos_agent.sql \
            sql/schemas/13_aos_multi_agent.sql \
            sql/triggers/immutability_triggers.sql \
            sql/functions/utilities.sql \
            sql/functions/workflow_engine.sql \
            sql/functions/rag_retrieval.sql \
            sql/functions/agent_loop_engine.sql \
            sql/views/system_views.sql \
            sql/views/admin_dashboard.sql \
            sql/rls/rls_policies.sql

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Generate the main installation script by concatenating modular files
pgagentos--1.0.sql: $(SQL_FILES)
	@echo "-- pgAgentOS v1.0 - AI Agent Operating System for PostgreSQL" > $@
	@echo "-- Generated on $(shell date)" >> $@
	@echo "" >> $@
	cat $(SQL_FILES) >> $@

clean-sql:
	rm -f pgagentos--1.0.sql

all: pgagentos--1.0.sql

.PHONY: all clean-sql
