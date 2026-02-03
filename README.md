# pgAgentOS: Transparent AI Governance for PostgreSQL

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14+-336791.svg)](https://www.postgresql.org)

**pgAgentOS** is an AI Agent Operating System that transforms PostgreSQL into a unified governance framework for autonomous agents. By integrating AI directly into the database, we move from "Black Box" AI to **"Glass Box" AI**, where every action is transparent, predictable, and strictly controlled by human-defined systems.

---

## 🏛 The Vision: AI under Human Governance

The fundamental challenge with modern AI agents is their lack of **Transparency** and **Predictability**. Most agents operate in volatile memory or hidden application layers, making them difficult to audit, control, or scale safely.

**pgAgentOS** changes the paradigm:
> *Instead of giving AI a server to roam, we give AI a Principal account in a structured Database.*

By housing the Agent OS within PostgreSQL, the agent becomes a disciplined citizen of the database world, subject to the same rigorous laws that govern your most sensitive financial and business data.

### Core Values

#### 1. From Black Box to Glass Box
Every "thought," tool call, and state change is a row in a table. You don't need magic observability tools to see what the agent is doing—you just need a `SELECT` statement.

#### 2. Governance by Schema
An agent cannot "hallucinate" its way out of a PostgreSQL schema. Its capabilities are defined by SQL types, its permissions by Row-Level Security (RLS), and its memory by relational constraints. Human-built architecture provides the guardrails for AI autonomy.

#### 3. Atomic Reasoning
Every agentic step is wrapped in a PostgreSQL transaction. If a logic error occurs or a safety trigger is tripped, the state doesn't just "break"—it rolls back. Predictable state management for non-deterministic intelligence.

#### 4. Data Gravity (Kernel vs. User Space)
In a traditional OS, the kernel manages the most sensitive resources. In pgAgentOS, PostgreSQL is the Kernel. Moving agents closer to the data eliminates latency and synchronicity issues while ensuring that AI logic never bypasses your data integrity rules.

---

## 🏗 Architecture: The Glass Box Framework

pgAgentOS provides 6 essential schemas that define the agent's environment:

| Schema | Role | Governance Aspect |
| :--- | :--- | :--- |
| **`aos_core`** | Kernel | **Auditability**: Complete record of every LLM call, run, and event. |
| **`aos_auth`** | Security | **Authorization**: Strict RLS-based multi-tenancy. Agents only see what they are allowed to see. |
| **`aos_persona`** | Identity | **Behavior**: Versioned snapshots of system prompts and behavioral rules. |
| **`aos_skills`** | Capabilities | **Constraints**: Explicit definitions of available tools and their input/output schemas. |
| **`aos_agent`** | Runtime | **Traceability**: Structured tracking of conversations, turns, steps, and session memory. |
| **`aos_rag`** | Knowledge | **Context**: Controlled access to enterprise knowledge via vector and keyword search. |

---

## ⚡️ Quick Start

### 1. Requirements
- **PostgreSQL 14+**
- Extensions: `vector`, `pgcrypto`

### 2. Installation
```bash
git clone https://github.com/your-repo/pgagentos.git
cd pgagentos
make install
```

```sql
CREATE EXTENSION vector;
CREATE EXTENSION pgcrypto;
CREATE EXTENSION pgagentos;
```

---

## 📖 Governance in Action

### Defining a Controlled Agent
Agents are registered under a human-defined **Persona**, ensuring their instructions are versioned and immutable.

```sql
-- 1. Setup a secure tenant
INSERT INTO aos_auth.tenant (name) VALUES ('enterprise_unit_1') RETURNING tenant_id;

-- 2. Create an Immutable Persona
SELECT aos_persona.create_persona(
    'tenant-uuid',
    'SafetyAnalyst',
    'You are a corporate safety bot. Strictly follow internal guidelines...',
    (SELECT model_id FROM aos_core.model WHERE name = 'gpt-4o')
);
```

### Observing Agent steps
Tracking an agent's "thinking" process is as easy as querying a table. No external logs required.

```sql
-- View everything the agent did in a specific conversation
SELECT turn_number, user_message, assistant_message, status 
FROM aos_agent.turn 
WHERE conversation_id = 'uuid';
```

---

## 🔒 Security & Predictability

- **PostgreSQL RLS**: Native data isolation prevents cross-tenant leaks.
- **Transactional Memory**: Every `store_memory` call is ACID compliant.
- **Input Validation**: `aos_skills` uses JSON Schema (Optional) to ensure agents pass valid data to tools.

---

## 📊 Observability with SQL

```sql
-- What is running right now?
SELECT * FROM aos_core.active_runs;

-- What are my agents thinking about?
SELECT * FROM aos_agent.conversation_summary;
```

---

## � Philosophy over Hype

pgAgentOS isn't just about making agents "easier to build"—it's about making them **safe to deploy** by bringing them under the proven, 30-year-old governance of PostgreSQL.

## 📄 License

GPL v3 - See [LICENSE](LICENSE)
