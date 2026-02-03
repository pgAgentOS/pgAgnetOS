# pgAgentOS: PostgreSQL 기반의 투명한 AI 거버넌스

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14+-336791.svg)](https://www.postgresql.org)

**pgAgentOS**는 PostgreSQL을 자율 에이전트를 위한 단일 거버넌스 프레임워크로 변환하는 AI 에이전트 운영체제입니다. AI를 데이터베이스에 직접 통합함으로써, 모든 행동이 투명하고 예측 가능하며 인간이 설계한 체계 안에서 엄격하게 제어되는 **"글래스 박스(Glass Box) AI"**를 지향합니다.

---

## 🏛 비전: 인간의 설계 아래 작동하는 AI

현대 AI 에이전트의 근본적인 한계는 **투명성(Transparency)**과 **예측 가능성(Predictability)**의 부재입니다. 대부분의 에이전트는 휘발성 메모리나 블랙박스 같은 애플리케이션 계층에서 복잡하게 작동하여, 감사와 제어가 어렵고 안전하게 확장하기 힘듭니다.

**pgAgentOS**는 이 패러다임을 바꿉니다:
> *AI에게 자유롭게 돌아다닐 서버를 주는 대신, 구조화된 데이터베이스 안의 **인가된 계정(Principal)**을 부여합니다.*

pgAgentOS 내에서 에이전트는 데이터베이스 세계의 질서 있는 시민이 됩니다. 가장 민감한 금융 및 비즈니스 데이터를 다스리는 것과 동일한 엄격한 규칙(Consistency, Isolation, Durability)이 에이전트의 모든 활동에 적용됩니다.

### 핵심 가치

#### 1. 블랙박스에서 글래스 박스로
에이전트의 모든 "생각", 도구 호출, 상태 변화는 테이블의 한 행(Row)으로 기록됩니다. 에이전트가 무엇을 하고 있는지 알기 위해 복잡한 관측 도구가 필요하지 않습니다. 그저 `SELECT` 쿼리 하나면 충분합니다.

#### 2. 스키마에 의한 통제 (Governance by Schema)
에이전트는 PostgreSQL 스키마를 벗어나 "환각(Hallucination)"을 일으킬 수 없습니다. 에이전트의 능력은 SQL 타입으로 정의되고, 권한은 행 단위 보안(RLS)에 의해 제한되며, 메모리는 관계형 제약 조건에 의해 관리됩니다. 인간이 구축한 아키텍처가 AI 자율성의 안전 가드레일이 됩니다.

#### 3. 원자적 추론 (Atomic Reasoning)
에이전트의 모든 추론 단계는 PostgreSQL 트랜잭션으로 보호됩니다. 논리적 오류가 발생하거나 보안 트리거가 작동하면 상태는 단순히 망가지는 것이 아니라 완벽하게 롤백(Rollback)됩니다. 비결정적인 인공지능을 위한 결정적인 상태 관리를 제공합니다.

#### 4. 데이터 중력 (Kernel vs. User Space)
전통적인 OS에서 커널이 가장 민감한 자원을 관리하듯, pgAgentOS에서는 PostgreSQL이 커널 역할을 합니다. 에이전트를 데이터에 가깝게 배치함으로써 지연 시간을 제거하고, 데이터 무결성 규칙을 우회하는 AI 로직이 존재할 수 없도록 보장합니다.

---

## 🏗 아키텍처: 글래스 박스 프레임워크

pgAgentOS는 에이전트의 환경을 정의하는 6개의 필수 스키마를 제공합니다:

| 스키마 | 역할 | 거버넌스 측면 |
| :--- | :--- | :--- |
| **`aos_core`** | 커널 | **감사 가능성**: 모든 LLM 호출, 실행, 이벤트의 완벽한 기록. |
| **`aos_auth`** | 보안 | **권한 부여**: 엄격한 RLS 기반 멀티테넌시. 허용된 데이터만 접근 가능. |
| **`aos_persona`** | 정체성 | **행동 규범**: 시스템 프롬프트와 행동 규칙의 버전에 따른 관리. |
| **`aos_skills`** | 능력 | **제약 조건**: 사용 가능한 도구와 입출력 스키마의 명확한 정의. |
| **`aos_agent`** | 런타임 | **추적 가능성**: 대화, 턴, 스텝, 세션 메모리의 구조적 추적. |
| **`aos_rag`** | 지식 | **맥락 제어**: 벡터 및 키워드 검색을 통한 엔터프라이즈 지식 접근 제어. |

---

## ⚡️ 빠른 시작

### 1. 요구사항
- **PostgreSQL 14+**
- 확장 모듈: `vector`, `pgcrypto`

### 2. 설치
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

## 📖 거버넌스 실제 예시

### 통제된 에이전트 정의
에이전트는 인간이 정의한 **페르소나(Persona)** 하에 등록되며, 모든 지침은 버전별로 관리되어 임의로 수정할 수 없습니다.

```sql
-- 1. 안전한 테넌트 설정
INSERT INTO aos_auth.tenant (name) VALUES ('enterprise_unit_1') RETURNING tenant_id;

-- 2. 불변의 페르소나 생성
SELECT aos_persona.create_persona(
    'tenant-uuid',
    'SafetyAnalyst',
    '사내 보안 가이드라인을 엄격히 준수하는 보안 분석봇입니다...',
    (SELECT model_id FROM aos_core.model WHERE name = 'gpt-4o')
);
```

### 에이전트 단계 관찰
에이전트의 "생각" 과정을 추적하는 것은 테이블을 쿼리하는 것만큼이나 간단합니다. 외부 로그 시스템이 필요하지 않습니다.

```sql
-- 특정 대화에서 에이전트가 수행한 모든 단계 확인
SELECT turn_number, user_message, assistant_message, status 
FROM aos_agent.turn 
WHERE conversation_id = 'uuid';
```

---

## 🔒 보안 및 예측 가능성

- **PostgreSQL RLS**: 데이터베이스 레벨의 원천적 격리로 테넌트 간 데이터 유출 방지.
- **트랜잭션 메모리**: 모든 `store_memory` 호출은 ACID를 준수하여 데이터 정합성 보장.
- **입력 유효성 검사**: `aos_skills`는 JSON Schema를 사용하여 에이전트가 도구에 유효한 데이터만 전달하도록 강제.

---

## 📊 SQL을 활용한 관찰성

```sql
-- 현재 실행 중인 작업은?
SELECT * FROM aos_core.active_runs;

-- 내 에이전트들은 지금 어떤 대화를 하고 있는가?
SELECT * FROM aos_agent.conversation_summary;
```

---

## 🤝 기술을 넘어선 철학

pgAgentOS는 단순한 "에이전트 구축 도구"가 아닙니다. AI를 지난 30년간 검증된 PostgreSQL의 거버넌스 체계 안으로 끌어들여, 비즈니스 현장에서 **실제로 믿고 배포할 수 있는 AI**를 만드는 것이 우리의 목적입니다.

## 📄 라이선스

GPL v3 - [LICENSE](LICENSE) 참조
