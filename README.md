# pgAgentOS: AI Agent Operating System for PostgreSQL

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14+-336791.svg)](https://www.postgresql.org)

**pgAgentOS** is the first true **Agent Operating System** built entirely within PostgreSQL. It moves the AI runtime *to* the data layer, allowing you to build, deploy, and manage stateful, autonomous agents without the complexity of disjointed microservices or external orchestration frameworks.

---

## 🧠 Philosophy: Why pgAgentOS?

The modern AI stack is becoming dangerously fragmented. A typical agentic application today consists of:
1.  **Vector DB**: For embeddings.
2.  **Application DB**: For transactional business data.
3.  **App Server**: For API handling.
4.  **Agent Framework**: LangChain/LangGraph/AutoGPT running on yet another server.
5.  **Queue System**: To manage async agent tasks.

This architecture introduces massive latency, data synchronization headaches, and operational fragility.

**pgAgentOS** solves this by unifying the stack. It believes in **Data Gravity**:
> *Agents rely on data (context, memory, business state). Therefore, agents should live where the data lives.*

### Core Principles
1.  **Transactional Integrity**: An agent's "thought" should be as atomic and reliable as a financial transaction. If an agent step fails, the state rolls back perfectly.
2.  **Zero-Latency Context**: Your agents have instant SQL access to your business data. No API calls or network hops required to "fetch user profile" or "check inventory".
3.  **Stateful by Default**: Every interaction, memory, and state change is persisted immediately. You can kill the server, restart it, and the agent picks up exactly where it left off.

---

## 🏗 Architecture

pgAgentOS is implemented as a set of modular schemas within your PostgreSQL database.

| Schema | Role | Description |
| :--- | :--- | :--- |
| **`aos_auth`** | Security & Identity | Manages multi-tenancy (`tenant`), users (`principal`), and role-based access control (RBAC). Ensures one tenant cannot access another's agents or data. |
| **`aos_meta`** | Hardware Abstraction | The "Device Driver" layer for LLMs. It abstracts away the differences between OpenAI, Anthropic, Gemini, and local Ollama models. |
| **`aos_persona`** | Agent Identity | Defines *who* the agent is. Contains system prompts, personality traits, rules, and model configurations. |
| **`aos_skills`** | Capabilities | The "Tool" layer. Registers capabilities like Web Search, SQL Execution, or RAG. Permissions can be granularly controlled per role. |
| **`aos_core`** | Kernel | The execution engine. Tracks `runs` (conversations), `steps` (thoughts/acts), `event_log` (audit trail), and `session_memory`. |
| **`aos_agent`** | API Layer | High-level functions (`run_turn`, `add_user_message`) used by your application to interact with the system. |

---

## ⚡️ Quick Start

### 1. Requirements
- **PostgreSQL 14+**
- Extensions: `vector`, `pgcrypto`

### 2. Installation
Clone the repo and install the extension:
```bash
git clone https://github.com/your-repo/pgagentos.git
cd pgagentos
make install
```

Enable it in your database:
```sql
CREATE EXTENSION vector;
CREATE EXTENSION pgcrypto;
CREATE EXTENSION pgagentos;
```

---

## 📖 Comprehensive Usage Guide

This guide walks you through building a **Postgres Expert Bot** that can answer questions about your database schema.

### Step 1: Foundation (Tenant & User)
Everything in pgAgentOS is isolated by Tenant.

```sql
-- 1. Create a Organization/Tenant
INSERT INTO aos_auth.tenant (name, display_name) 
VALUES ('tech_corp', 'Tech Corp Inc.');

-- 2. Get the Tenant ID (store this variable for later)
-- Assume: 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'

-- 3. Create a User (You)
INSERT INTO aos_auth.principal (tenant_id, principal_type, display_name)
VALUES ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'user', 'Admin User');
```

### Step 2: The Brain (Model Setup)
pgAgentOS creates default presets for popular models. You just need to ensure your environment variables (managed by the external runner) are set, or you can update the API keys in the database (secured via pgcrypto recommended).

```sql
-- View available models
SELECT model_name, context_window FROM aos_meta.llm_model_registry WHERE is_active = true;
```

### Step 3: Identity (Create Persona)
Let's define the "Postgres Expert".

```sql
INSERT INTO aos_persona.persona (
    tenant_id, 
    name, 
    system_prompt, 
    model_id
) VALUES (
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
    'pg_expert',
    'You are a PostgreSQL Database Administrator. 
     You have access to RAG tools to look up documentation. 
     Always verify your SQL syntax before answering.',
    (SELECT model_id FROM aos_meta.llm_model_registry WHERE model_name = 'gpt-4o')
);
```

### Step 4: The Body (Agent & Conversation)
Instantiate the agent and start a conversation thread.

```sql
-- 1. Create the Agent
INSERT INTO aos_agent.agent (tenant_id, name, persona_id)
VALUES (
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
    'my_pg_bot',
    (SELECT persona_id FROM aos_persona.persona WHERE name = 'pg_expert')
);

-- 2. Create a Conversation (Run)
-- This returns a conversation_id, e.g., '123e4567-e89b-12d3-a456-426614174000'
INSERT INTO aos_agent.conversation (agent_id, tenant_id)
VALUES (
    (SELECT agent_id FROM aos_agent.agent WHERE name = 'my_pg_bot'),
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'
);
```

### Step 5: The Agent Loop (Execution)
pgAgentOS is designed to be driven by a thin "worker" script (Python/Node/Go). The database manages the state; the worker just acts as the IO bridge to the LLM API.

#### The Cycle:

1.  **Input**: User sends a message.
    ```sql
    SELECT aos_agent.add_user_message('conversation_id', 'How do I optimize a join?');
    ```
2.  **Start Turn**: Initialize the thinking process.
    ```sql
    SELECT aos_agent.start_turn('conversation_id');
    ```
3.  **Poll & Execute**: The worker polling loop.
    ```sql
    -- Get current state
    SELECT * FROM aos_agent.run_turn('turn_id');
    ```
    The DB returns: `{"messages": [...], "tools": [...], "system_prompt": "..."}`
    
    The worker sends this payload to OpenAI/Anthropic.

4.  **Observe & Act**:
    *   **Case A: LLM wants to talk**: 
        The worker writes the response back:
        ```sql
        SELECT aos_agent.finish_turn('turn_id', 'You should use an INNER JOIN...');
        ```
    *   **Case B: LLM wants to think/execute tool**:
        The worker records the tool call:
        ```sql
        SELECT aos_agent.process_tool_call('turn_id', 'web_search', '{"query": "postgres join optimization"}');
        ```
        The worker *executes* the tool (e.g., searches Google), then reports the result:
        ```sql
        SELECT aos_agent.record_tool_result('turn_id', 'web_search', '{"result": "..."}');
        ```
        The loop repeats until the agent answers.

---

## 🔒 Security

*   **Row Level Security (RLS)**: pgAgentOS is designed with RLS in mind. Tenants can only see their own data.
*   **Approval Mode**: High-risk tools (like `delete_table` or `send_email`) can be configured to require human approval before execution. The agent loop naturally pauses at `process_tool_call` returning `status: awaiting_approval`.

## 📄 License

This project is licensed under the **GNU General Public License v3.0 (GPLv3)**.
