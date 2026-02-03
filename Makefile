EXTENSION = pgagentos
EXTVERSION = 1.0
DATA = pgagentos--$(EXTVERSION).sql

SQL_FILES = sql/schemas/00_extensions.sql \
            sql/schemas/01_aos_core.sql \
            sql/schemas/02_aos_auth.sql \
            sql/schemas/03_aos_persona.sql \
            sql/schemas/04_aos_skills.sql \
            sql/schemas/05_aos_agent.sql \
            sql/schemas/06_aos_rag.sql \
            sql/triggers/immutability_triggers.sql \
            sql/views/system_views.sql \
            sql/rls/rls_policies.sql

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Generate extension SQL
pgagentos--$(EXTVERSION).sql: $(SQL_FILES)
	@echo "-- pgAgentOS v$(EXTVERSION) - AI Agent Operating System for PostgreSQL" > $@
	@echo "-- Generated on $$(date)" >> $@
	@echo "" >> $@
	@for f in $(SQL_FILES); do \
		cat $$f >> $@; \
		echo "" >> $@; \
	done
	@echo "Extension SQL generated: $@"

# Clean generated SQL
clean-sql:
	rm -f pgagentos--$(EXTVERSION).sql

# Development helpers
.PHONY: dev-install dev-test clean-sql

dev-install: pgagentos--$(EXTVERSION).sql
	psql -d postgres -c "DROP EXTENSION IF EXISTS pgagentos CASCADE;"
	psql -d postgres -c "CREATE EXTENSION pgagentos;"

dev-test: dev-install
	psql -d postgres -f tests/sql/test_basic.sql
