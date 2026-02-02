# pgAgentOS: PostgreSQL을 위한 AI 에이전트 운영체제

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14+-336791.svg)](https://www.postgresql.org)

**pgAgentOS**는 PostgreSQL 내부에 온전히 구축된 최초의 진정한 **에이전트 운영체제(Agent Operating System)**입니다. AI 런타임을 데이터 계층으로 이동시켜, 분절된 마이크로서비스나 외부 오케스트레이션 프레임워크의 복잡성 없이 상태 저장(stateful) 자율 에이전트를 구축, 배포 및 관리할 수 있습니다.

---

## 🧠 철학: 왜 pgAgentOS인가?

현대의 AI 기술 스택은 위험할 정도로 파편화되어 있습니다. 일반적인 에이전트 애플리케이션은 다음과 같이 구성됩니다:
1.  **벡터 DB**: 임베딩 저장용.
2.  **애플리케이션 DB**: 트랜잭션 비즈니스 데이터용.
3.  **앱 서버**: API 처리용.
4.  **에이전트 프레임워크**: 또 다른 서버에서 실행되는 LangChain/LangGraph/AutoGPT.
5.  **큐 시스템**: 비동기 에이전트 작업을 관리하기 위함.

이러한 아키텍처는 엄청난 레이턴시, 데이터 동기화 문제, 운영상의 취약점을 야기합니다.

**pgAgentOS**는 스택을 통합하여 이를 해결합니다. 이 프로젝트는 **데이터 중력(Data Gravity)**을 믿습니다:
> *에이전트는 데이터(문맥, 메모리, 비즈니스 상태)에 의존합니다. 따라서 에이전트는 데이터가 있는 곳에 살아야 합니다.*

### 핵심 원칙
1.  **트랜잭션 무결성 (Transactional Integrity)**: 에이전트의 "생각"은 금융 거래만큼 원자적(atomic)이고 신뢰할 수 있어야 합니다. 에이전트 단계가 실패하면 상태는 완벽하게 롤백됩니다.
2.  **제로 레이턴시 컨텍스트 (Zero-Latency Context)**: 에이전트는 비즈니스 데이터에 즉시 SQL로 접근할 수 있습니다. "사용자 프로필 조회"나 "재고 확인"을 위해 API 호출이나 네트워크 홉이 필요 없습니다.
3.  **기본적인 상태 저장 (Stateful by Default)**: 모든 상호작용, 메모리, 상태 변경은 즉시 영구 저장됩니다. 서버를 종료하고 다시 시작해도 에이전트는 정확히 중단된 지점부터 다시 시작합니다.

---

## 🏗 아키텍처

pgAgentOS는 PostgreSQL 데이터베이스 내의 모듈식 스키마 세트로 구현됩니다.

| 스키마 | 역할 | 설명 |
| :--- | :--- | :--- |
| **`aos_auth`** | 보안 및 신원 | 멀티 테넌시(`tenant`), 사용자(`principal`), 역할 기반 접근 제어(RBAC)를 관리합니다. 한 테넌트가 다른 테넌트의 에이전트나 데이터에 접근할 수 없도록 보장합니다. |
| **`aos_meta`** | 하드웨어 추상화 | LLM을 위한 "장치 드라이버" 계층입니다. OpenAI, Anthropic, Gemini 및 로컬 Ollama 모델 간의 차이를 추상화합니다. |
| **`aos_persona`** | 에이전트 정체성 | 에이전트가 *누구*인지 정의합니다. 시스템 프롬프트, 성격 특성, 규칙 및 모델 구성을 포함합니다. |
| **`aos_skills`** | 능력/도구 | "도구(Tool)" 계층입니다. 웹 검색, SQL 실행, RAG와 같은 기능을 등록합니다. 역할별로 권한을 세밀하게 제어할 수 있습니다. |
| **`aos_core`** | 커널 | 실행 엔진입니다. `runs`(대화), `steps`(생각/행동), `event_log`(감사 기록), `session_memory`를 추적합니다. |
| **`aos_agent`** | API 계층 | 애플리케이션이 시스템과 상호작용하기 위해 사용하는 고수준 함수(`run_turn`, `add_user_message`)입니다. |

---

## ⚡️ 빠른 시작

### 1. 요구 사항
- **PostgreSQL 14 이상**
- 확장 프로그램: `vector`, `pgcrypto`

### 2. 설치
저장소를 복제하고 확장을 설치합니다:
```bash
git clone https://github.com/your-repo/pgagentos.git
cd pgagentos
make install
```

데이터베이스에서 활성화합니다:
```sql
CREATE EXTENSION vector;
CREATE EXTENSION pgcrypto;
CREATE EXTENSION pgagentos;
```

---

## 📖 포괄적 사용 가이드

이 가이드는 데이터베이스 스키마에 대한 질문에 답할 수 있는 **Postgres 전문가 봇**을 구축하는 과정을 안내합니다.

### 1단계: 기반 (테넌트 및 사용자)
pgAgentOS의 모든 것은 테넌트별로 격리됩니다.

```sql
-- 1. 조직/테넌트 생성
INSERT INTO aos_auth.tenant (name, display_name) 
VALUES ('tech_corp', 'Tech Corp Inc.');

-- 2. 테넌트 ID 확인 (나중에 사용하기 위해 저장)
-- 가정: 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'

-- 3. 사용자(자신) 생성
INSERT INTO aos_auth.principal (tenant_id, principal_type, display_name)
VALUES ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'user', 'Admin User');
```

### 2단계: 두뇌 (모델 설정)
pgAgentOS는 인기 있는 모델에 대한 기본 프리셋을 생성합니다. 외부 러너(Runner)가 환경 변수를 관리하도록 하거나, 데이터베이스 내에 API 키를 업데이트할 수 있습니다(pgcrypto로 보안 권장).

```sql
-- 사용 가능한 모델 확인
SELECT model_name, context_window FROM aos_meta.llm_model_registry WHERE is_active = true;
```

### 3단계: 정체성 (페르소나 생성)
"Postgres 전문가"를 정의해 봅시다.

```sql
INSERT INTO aos_persona.persona (
    tenant_id, 
    name, 
    system_prompt, 
    model_id
) VALUES (
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
    'pg_expert',
    '당신은 PostgreSQL 데이터베이스 관리자입니다. 
     문서를 찾아보기 위해 RAG 도구에 접근할 수 있습니다. 
     답변하기 전에 항상 SQL 구문을 검증하십시오.',
    (SELECT model_id FROM aos_meta.llm_model_registry WHERE model_name = 'gpt-4o')
);
```

### 4단계: 신체 (에이전트 및 대화)
에이전트 인스턴스를 생성하고 대화 스레드를 시작합니다.

```sql
-- 1. 에이전트 생성
INSERT INTO aos_agent.agent (tenant_id, name, persona_id)
VALUES (
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
    'my_pg_bot',
    (SELECT persona_id FROM aos_persona.persona WHERE name = 'pg_expert')
);

-- 2. 대화(Run) 생성
-- conversation_id를 반환합니다. 예: '123e4567-e89b-12d3-a456-426614174000'
INSERT INTO aos_agent.conversation (agent_id, tenant_id)
VALUES (
    (SELECT agent_id FROM aos_agent.agent WHERE name = 'my_pg_bot'),
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'
);
```

### 5단계: 에이전트 루프 (실행)
pgAgentOS는 얇은 "워커(worker)" 스크립트(Python/Node/Go)에 의해 구동되도록 설계되었습니다. 데이터베이스가 상태를 관리하고, 워커는 단순히 LLM API와의 IO 브리지 역할을 합니다.

#### 순환 주기 (The Cycle):

1.  **입력 (Input)**: 사용자가 메시지를 보냅니다.
    ```sql
    SELECT aos_agent.add_user_message('conversation_id', '조인을 최적화하려면 어떻게 해야 하나요?');
    ```
2.  **턴 시작 (Start Turn)**: 생각하는 과정을 초기화합니다.
    ```sql
    SELECT aos_agent.start_turn('conversation_id');
    ```
3.  **폴링 및 실행 (Poll & Execute)**: 워커의 폴링 루프입니다.
    ```sql
    -- 현재 상태 가져오기
    SELECT * FROM aos_agent.run_turn('turn_id');
    ```
    DB는 다음을 반환합니다: `{"messages": [...], "tools": [...], "system_prompt": "..."}`
    
    워커는 이 페이로드를 OpenAI/Anthropic에 전송합니다.

4.  **관찰 및 행동 (Observe & Act)**:
    *   **사례 A: LLM이 말하고 싶어함**: 
        워커가 응답을 기록합니다:
        ```sql
        SELECT aos_agent.finish_turn('turn_id', 'INNER JOIN을 사용해야 합니다...');
        ```
    *   **사례 B: LLM이 생각하거나 도구를 실행하고 싶어함**:
        워커가 도구 호출을 기록합니다:
        ```sql
        SELECT aos_agent.process_tool_call('turn_id', 'web_search', '{"query": "postgres join optimization"}');
        ```
        워커가 도구를 *실행*하고(예: 구글 검색), 결과를 보고합니다:
        ```sql
        SELECT aos_agent.record_tool_result('turn_id', 'web_search', '{"result": "..."}');
        ```
        에이전트가 답변할 때까지 이 루프가 반복됩니다.

---

## 🔒 보안

*   **행 수준 보안 (RLS)**: pgAgentOS는 RLS를 염두에 두고 설계되었습니다. 테넌트는 자신의 데이터만 볼 수 있습니다.
*   **승인 모드 (Approval Mode)**: 고위험 도구(`delete_table` 또는 `send_email` 등)는 실행 전 사람의 승인을 받도록 설정할 수 있습니다. 에이전트 루프는 `process_tool_call`이 `status: awaiting_approval`을 반환할 때 자연스럽게 일시 중지됩니다.

## 📄 라이선스

이 프로젝트는 **GNU General Public License v3.0 (GPLv3)** 라이선스 하에 배포됩니다.
