# pgAgentOS

<div align="center">

![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14+-blue?logo=postgresql)
![License](https://img.shields.io/badge/license-GPL3-green)
![Version](https://img.shields.io/badge/version-1.0.0-orange)

**AI Agent Operating System & Framework built natively in PostgreSQL**

*An Agent OS where every action is transparently recorded, observable, and intervenable.*

</div>

---

## 🎯 Overview

**pgAgentOS** is an **Agent Operating System** designed to manage and execute AI agents directly within PostgreSQL.
It manages the entire lifecycle of agents using only PostgreSQL, without the need for external frameworks like LangChain or CrewAI.

### Why PostgreSQL?

| Problem with Existing Frameworks | pgAgentOS Solution |
|----------------------------------|--------------------|
| Agent behavior is a "black box" | Every step is transparently recorded in the DB |
| Difficult debugging | State can be queried via SQL at any time |
| Complex state management | Consistency guaranteed via ACID transactions |
| Difficult multi-tenancy | Perfect isolation via Row-Level Security (RLS) |
| Separate logging/auditing | Immutable event logs built-in |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Your Application                          │
├─────────────────────────────────────────────────────────────────┤
│                       External Runtime                           │
│              (Python/Node.js + LLM API Client)                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│     ┌──────────────────────────────────────────────────────┐    │
│     │                    pgAgentOS                          │    │
│     │    ┌─────────────────────────────────────────────┐   │    │
│     │    │              aos_agent                       │   │    │
│     │    │   Agent → Conversation → Turn → Step        │   │    │
│     │    └─────────────────────────────────────────────┘   │    │
│     │    ┌─────────────┐  ┌─────────────┐  ┌───────────┐   │    │
│     │    │ aos_persona │  │ aos_skills  │  │ aos_auth  │   │    │
│     │    └─────────────┘  └─────────────┘  └───────────┘   │    │
│     │    ┌─────────────┐  ┌─────────────┐  ┌───────────┐   │    │
│     │    │   aos_kg    │  │ aos_embed   │  │ aos_meta  │   │    │
│     │    └─────────────┘  └─────────────┘  └───────────┘   │    │
│     └──────────────────────────────────────────────────────┘    │
│                                                                  │
│                         PostgreSQL 14+                           │
└─────────────────────────────────────────────────────────────────┘
```

### Core Concept: Conversation → Turn → Step

```
User: "Teach me about Python Asyncio"
                    ↓
┌─────────────────────────────────────────────────┐
│  Turn #1                                         │
│  ├─ Step 1: think     "Need to search..."        │
│  ├─ Step 2: tool_call  web_search ← [Admin OK]   │
│  ├─ Step 3: tool_result {...search results...}   │
│  ├─ Step 4: think     "Summarizing..."          │
│  └─ Step 5: respond   "# Python Asyncio..."      │
└─────────────────────────────────────────────────┘
                    ↓
Agent: "# Python Asyncio is..."
```

---

## ✨ Key Features

### 🔍 Full Observability
- All reasoning processes (Chain of Thought) are recorded in the `step` table.
- Complete tracking of tool calls and I/O.
- Real-time monitoring via streaming views.

### 🎮 Human-in-the-Loop
- Approve or reject tool calls.
- Inject messages during conversation.
- Override agent responses.
- Real-time rating and feedback.

### 🔐 Security & Multi-tenancy
- Perfect tenant isolation using Row-Level Security.
- Immutable audit logs.
- Role-based skill permissions.

### 📊 Analytics & Monitoring
- Usage statistics per agent (tokens, cost, success rate).
- Hourly activity metrics.
- Tool usage patterns.

### 🔌 LLM Independence
- Support for various LLM presets (OpenAI, Anthropic, Google, Ollama).
- Hierarchical parameter configuration (Model → Persona → Runtime).
- Clean separation from external runtimes.

---

## 📦 Installation

### Requirements

- PostgreSQL 14+
- pgvector extension
- pgcrypto extension

### Install

```bash
# 1. Clone repository
git clone https://github.com/your-org/pgAgentOS.git
cd pgAgentOS

# 2. Build extension (Optional)
make
sudo make install

# 3. Create extension in PostgreSQL
psql -d your_database -c "CREATE EXTENSION pgagentos CASCADE;"
```

### Manual Install (Without Extension)

```bash
# Execute SQL files in order
psql -d your_database -f sql/schemas/00_extensions.sql
psql -d your_database -f sql/schemas/01_aos_meta.sql
# ... (all schema files)
psql -d your_database -f sql/functions/agent_loop_engine.sql
psql -d your_database -f sql/triggers/immutability_triggers.sql
psql -d your_database -f sql/views/admin_dashboard.sql
psql -d your_database -f sql/rls/rls_policies.sql
```

---

## 🚀 Quick Start

### 1. Setup Tenant & User

```sql
-- Create Tenant
INSERT INTO aos_auth.tenant (name, display_name)
VALUES ('my_company', 'My Company')
RETURNING tenant_id;

-- Set Context
SELECT aos_auth.set_tenant('your-tenant-uuid');
```

### 2. Create Persona

```sql
INSERT INTO aos_persona.persona (
    tenant_id, name, system_prompt, traits
) VALUES (
    aos_auth.current_tenant(),
    'helpful_assistant',
    'You are a helpful AI assistant. Answer concisely.',
    '{"helpful": true, "concise": true}'
);
```

### 3. Create Agent

```sql
SELECT aos_agent.create_agent(
    p_tenant_id := aos_auth.current_tenant(),
    p_name := 'research_agent',
    p_persona_id := 'your-persona-uuid',
    p_tools := ARRAY['web_search', 'code_execute'],
    p_config := '{"auto_approve_tools": false}'
);
```

### 4. Start Conversation

```sql
-- Create Conversation
SELECT aos_agent.start_conversation(
    p_agent_id := 'your-agent-uuid'
);

-- Send Message
SELECT aos_agent.send_message(
    p_conversation_id := 'your-conversation-uuid',
    p_message := 'How do I do async programming in Python?'
);
```

### 5. External Runtime Integration (Python Example)

```python
import psycopg2
import openai

conn = psycopg2.connect("postgresql://...")
cur = conn.cursor()

# Get execution info for the turn
cur.execute("SELECT aos_agent.run_turn(%s)", (turn_id,))
run_info = cur.fetchone()[0]

# Call LLM
response = openai.chat.completions.create(
    model="gpt-4o",
    messages=[
        {"role": "system", "content": run_info['system_prompt']},
        *run_info['messages']
    ],
    tools=run_info['tools']
)

# Record Result
if response.choices[0].message.tool_calls:
    tool_call = response.choices[0].message.tool_calls[0]
    cur.execute("""
        SELECT aos_agent.process_tool_call(%s, %s, %s)
    """, (turn_id, tool_call.function.name, tool_call.function.arguments))
else:
    cur.execute("""
        SELECT aos_agent.complete_turn(%s, %s, %s, %s)
    """, (turn_id, response.choices[0].message.content, 
          response.usage.total_tokens, 0.003))

conn.commit()
```

### 6. Admin Monitoring

```sql
-- Check real-time steps
SELECT * FROM aos_agent.realtime_steps LIMIT 10;

-- Steps awaiting approval
SELECT * FROM aos_agent.tool_call_queue;

-- Trace reasoning
SELECT * FROM aos_agent.thinking_trace 
WHERE conversation_id = 'your-conversation-uuid';

-- Approve tool call
SELECT aos_agent.approve_step(
    p_step_id := 'step-uuid',
    p_approved := true,
    p_admin_id := 'admin-uuid',
    p_note := 'Approved'
);
```

---

## 📁 Project Structure

```
pgAgentOS/
├── pgagentos.control          # Extension control file
├── Makefile                   # PGXS build configuration
├── README.md                  # This file
│
├── sql/
│   ├── schemas/               # Table definitions
│   │   ├── 00_extensions.sql  # Dependencies (pgvector, pgcrypto)
│   │   ├── 01_aos_meta.sql    # Metadata & LLM registry
│   │   ├── 02_aos_auth.sql    # Multi-tenancy & principals
│   │   ├── 03_aos_persona.sql # Agent personas
│   │   ├── 04_aos_skills.sql  # Tool registry
│   │   ├── 05_aos_core.sql    # Run & event logging
│   │   ├── 06_aos_workflow.sql# Graph-based workflows (legacy)
│   │   ├── 07_aos_egress.sql  # External API control
│   │   ├── 08_aos_kg.sql      # Knowledge graph
│   │   ├── 09_aos_embed.sql   # Vector embeddings
│   │   ├── 10_aos_collab.sql  # Task collaboration
│   │   ├── 11_aos_policy.sql  # Policy hooks
│   │   ├── 12_aos_agent.sql   # Agent Loop (primary)
│   │   └── 13_aos_multi_agent.sql # Multi-Agent System
│   │
│   ├── functions/             # Core functions
│   │   ├── agent_loop_engine.sql   # Main agent execution
│   │   ├── rag_retrieval.sql       # Hybrid RAG search
│   │   ├── utilities.sql           # Helper functions
│   │   └── workflow_engine.sql     # Graph workflow (legacy)
│   │
│   ├── triggers/              # Immutability & validation
│   │   └── immutability_triggers.sql
│   │
│   ├── views/                 # Monitoring views
│   │   ├── admin_dashboard.sql
│   │   └── system_views.sql
│   │
│   └── rls/                   # Row-Level Security
│       └── rls_policies.sql
│
├── examples/                  # Usage examples
│   ├── simple_agent.sql       # Basic agent example
│   ├── multi_agent_collab.sql # Consensus/Debate example
│   └── sample_workflow.sql    # Graph workflow example
│
└── tests/                     # Test suite
    └── sql/
        └── test_basic.sql
```

---

## 🔧 Schema Overview

| Schema | Purpose | Key Tables |
|--------|---------|------------|
| `aos_agent` | **Core** Agent Loop | `agent`, `conversation`, `turn`, `step` |
| `aos_multi_agent` | **Multi-Agent** | `team`, `discussion`, `agent_message` |
| `aos_persona` | Agent Personality | `persona` |
| `aos_skills` | Tools Registry | `skill`, `skill_impl`, `role_skill` |
| `aos_auth` | Auth/Multi-tenancy | `tenant`, `principal`, `role_grant` |
| `aos_meta` | Metadata | `llm_model_registry` |
| `aos_kg` | Knowledge Graph | `doc`, `doc_relationship` |
| `aos_embed` | Vector Embeddings | `embedding`, `job` |
| `aos_egress` | External API Control | `request`, `allowlist` |
| `aos_policy` | Policy Hooks | `hooks`, `policy_rule` |

---

## 🛠️ Core Functions

### Agent Management

| Function | Description |
|----------|-------------|
| `aos_agent.create_agent(...)` | Create new agent |
| `aos_agent.start_conversation(...)` | Start conversation |
| `aos_agent.send_message(...)` | Send user message |
| `aos_agent.run_turn(...)` | Get turn execution info |
| `aos_agent.complete_turn(...)` | Complete turn |

### Tool Execution

| Function | Description |
|----------|-------------|
| `aos_agent.process_tool_call(...)` | Process tool call (with approval flow) |
| `aos_agent.record_tool_result(...)` | Record tool result |
| `aos_agent.record_thinking(...)` | Record reasoning |
| `aos_agent.approve_step(...)` | Approve/Reject step |

### Admin Intervention

| Function | Description |
|----------|-------------|
| `aos_agent.bulk_approve_tools(...)` | Bulk approval |
| `aos_agent.inject_message(...)` | Inject message into chat |
| `aos_agent.override_response(...)` | Override response |
| `aos_agent.pause_conversation(...)` | Pause conversation |
| `aos_agent.rate_turn(...)` | Rate turn |
| `aos_agent.flag_issue(...)` | Flag issue |

### Monitoring

| View | Description |
|------|-------------|
| `aos_agent.realtime_steps` | Real-time step stream |
| `aos_agent.tool_call_queue` | Approval queue |
| `aos_agent.thinking_trace` | Reasoning trace |
| `aos_agent.conversation_timeline` | Full timeline |
| `aos_agent.agent_stats` | Agent stats |
| `aos_agent.dashboard_overview` | Dashboard overview |

---

## 🔐 Security

### Multi-tenancy (RLS)

All tables use Row-Level Security:

```sql
-- Set Tenant Context
SELECT aos_auth.set_tenant('tenant-uuid');

-- Query only returns data for current tenant
SELECT * FROM aos_agent.agent;
```

### Immutability

`event_log` and finalized `workflow_state` cannot be modified or deleted.

---

## 📈 Analytics

### Agent Analytics

```sql
SELECT aos_agent.get_agent_analytics(
    'agent-uuid',
    7  -- last 7 days
);
```

Returns:
```json
{
  "total_conversations": 42,
  "total_turns": 156,
  "total_tokens": 245000,
  "total_cost_usd": 4.82,
  "avg_turn_duration_ms": 2340,
  "success_rate": 94.5,
  "tool_usage": {"web_search": 45, "code_execute": 23}
}
```

### Hourly Activity

```sql
SELECT * FROM aos_agent.get_hourly_activity('tenant-uuid', 1);
```

---

## 🔮 Roadmap

- [ ] **v1.1**: Streaming response sup
- [ ] **v1.2**: Advanced Multi-Agent patterns (Swarm)
- [ ] **v1.3**: Automatic memory compression
- [ ] **v2.0**: GUI Admin Dashboard
- [ ] **v2.1**: Kubernetes Operator

---

## 🤝 Contributing

Contributions are welcome! Please read our [Contributing Guide](CONTRIBUTING.md) first.

---

## 📄 License

GPL 3 License - see [LICENSE](LICENSE) for details.

---

<div align="center">

**Built with ❤️ for the AI Agent community**

[Documentation](docs/) • [Examples](examples/) • [Issues](https://github.com/your-org/pgAgentOS/issues)

</div>
