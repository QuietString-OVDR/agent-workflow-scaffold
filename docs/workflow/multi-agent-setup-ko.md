# 멀티 에이전트 개발 워크플로우

`openai/codex-plugin-cc` 플러그인을 통해 Claude Code 세션 하나에서 Codex + Claude 파이프라인을 실행합니다. Codex가 설계 검토와 조사를 담당하고, Claude가 구현과 파일 편집을 담당합니다. 브랜치 문서가 소스 오브 트루스입니다.

---

## 환경 구성

| 레이어 | 도구 | 역할 |
|---|---|---|
| 기본 세션 | **Claude Code CLI** | 파이프라인 전체를 실행하는 단일 셸 창 |
| 세컨드 오피니언 에이전트 | **Codex** (`codex-plugin-cc` 플러그인 경유) | 리뷰, 설계 도전, 범위 한정 조사 |
| 터미널 (선택) | **Warp** | 백그라운드 Codex 작업의 시각적 상태 배지 및 시스템 알림 |

별도의 Codex 터미널 창은 필요하지 않습니다. 모든 작업이 Claude Code 세션 하나에서 진행됩니다.

---

## 역할과 책임

### Claude Code
- 브랜치 작업 시작 전 브랜치 README를 읽습니다.
- 로컬 작업 조율 시 브랜치 문서를 생성하거나 업데이트합니다.
- 무제한 채팅 요청이 아닌 `plans/next-agent-handoff.md`를 기반으로 구현합니다.
- 지정된 파일/모듈 범위 내에서만 작업합니다.
- 소스 코드 변경 후 `status/implementation-status.md`와 `status/code-map.md`를 업데이트합니다.
- 구현이 스펙이나 설계를 무효화할 경우 중단하고 보고합니다.
- 리뷰, 도전, 또는 조사가 필요할 때 Codex 플러그인 명령어를 호출합니다.

### Codex (플러그인 경유)
- `/codex:review`로 커밋되지 않은 변경사항 또는 브랜치 diff를 리뷰합니다.
- `/codex:adversarial-review`로 설계 또는 구현 가정에 의문을 제기합니다.
- `/codex:rescue`로 버그, 빌드 실패, 위험 설계 영역을 조사합니다.
- 장시간 리뷰나 조사는 백그라운드로 실행합니다.
- 발견 사항을 반환하면 Claude 또는 개발자가 브랜치 문서로 정리합니다.
- 명시적으로 위임되고 모니터링되는 경우를 제외하고 쓰기 가능한 기본 구현 작업자로 사용하지 않습니다.

### 개발자
- 숨겨진 자동 훅에 의존하지 않고 의도적으로 Codex 리뷰를 시작합니다.
- 리뷰 결과를 읽고 수락 또는 거부합니다.
- Codex rescue 결과를 적용, 무시, 또는 핸드오프 패킷으로 전환할지 결정합니다.
- 워크플로우와 비용 구조를 파악할 때까지 리뷰 게이트 자동화를 비활성화 상태로 유지합니다.

---

## 설치

### 사전 조건

- Node.js 18.18+ 및 npm이 PATH에 설정되어 있어야 함
- OpenAI 계정 (API 키 또는 ChatGPT 구독)
- Claude Code CLI 설치 및 인증 완료

Codex CLI 수동 설치:
```bash
npm install -g @openai/codex
```

Claude Code 안에서 Codex 인증:
```
!codex login
```

### Codex 플러그인 설치

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

### 리뷰 게이트 즉시 비활성화

플러그인의 자동 리뷰 게이트는 Stop 훅을 사용하며 비용이 큰 Claude/Codex 루프를 만들 수 있습니다. 워크플로우가 안정화될 때까지 비활성화합니다:

```
/codex:setup --disable-review-gate
```

실제 브랜치에서 리뷰 신호와 비용을 검증한 후에만 활성화합니다.

### Warp 터미널 (선택)

[Warp](https://warp.dev)에서 Claude Code를 실행하면 백그라운드 Codex 작업의 진행 상태를 시각적 배지로 확인하고 완료 시 시스템 알림을 받을 수 있습니다. 별도 설정 없이 Warp가 Claude Code를 자동으로 감지합니다.

---

## 플러그인 명령어

| 명령어 | 용도 | 기본 동작 |
|---|---|---|
| `/codex:setup` | 플러그인, Codex 설치, 인증 확인 | 설정 전용 |
| `/codex:review` | 커밋되지 않은 변경사항 또는 브랜치 diff 리뷰 | 읽기 전용 |
| `/codex:adversarial-review` | 설계 결정, 숨겨진 가정, 위험 영역 도전 | 읽기 전용 |
| `/codex:rescue` | 백그라운드 조사 또는 범위 한정 위임 작업 | 쓰기 가능 — 주의 모니터링 필요 |
| `/codex:status` | 실행 중인 Codex 작업 진행 상황 확인 | 읽기 전용 |
| `/codex:result` | 완료된 Codex 결과 읽기 | 읽기 전용 |
| `/codex:cancel` | 실행 중인 백그라운드 Codex 작업 중지 | 제어 전용 |

멀티 파일 리뷰와 조사는 `--background` 사용을 권장합니다. 전체 브랜치 리뷰 시 `--base <ref>` 사용:

```
/codex:review --base main --background
/codex:adversarial-review --base main --background 이 구현이 너무 광범위한지, 롤백/수동 검증이 충분한지 검토해줘.
```

---

## 역할 분담

| 작업 | 에이전트 | 호출 방법 |
|---|---|---|
| 브랜치 셋업 및 문서 초기화 | **Claude** | `"브랜치 README 읽고 누락된 문서 초기화해줘"` |
| 아키텍처 설계 | **Claude** | `"docs/branches/{branch}/design/X.md에 설계 문서 작성해줘"` |
| 설계 도전 리뷰 | **Codex** | `/codex:adversarial-review --background <포커스>` |
| 핸드오프 패킷 작성 | **Claude** | `/prepare-handoff` 커맨드 또는 수동 작성 |
| 구현 | **Claude** | `"plans/next-agent-handoff.md 읽고 구현해줘"` |
| 코드 리뷰 | **Codex** | `/codex:review --background` |
| 고위험 아키텍처 리뷰 | **Codex** | `/codex:adversarial-review --base main --background <포커스>` |
| 버그 조사 | **Codex** | `/codex:rescue --background X가 왜 실패하는지 조사해줘` |
| PR 전 최종 diff 리뷰 | **Codex** | `/codex:review --base main --background` |

---

## 디렉토리 구조

```
docs/
├── workflow/                          ← 프로젝트 전체 워크플로우 문서 (이 파일)
└── branches/{branch}/
    ├── README.md                      ← 읽기 순서 및 현재 결론 (Claude 관리)
    ├── spec/
    │   └── technical-spec.md          ← 요구사항 및 동작 계약
    ├── design/                        ← 아키텍처 및 구현 방향
    ├── plans/
    │   ├── next-agent-handoff.md      ← 구현을 위한 태스크 패킷 (Claude 작성)
    │   ├── design-review.md           ← 설계 리뷰 결과 (Codex 작성, Claude 정리)
    │   └── code-review.md             ← PR 전 코드 리뷰 결과 (Codex 작성, Claude 정리)
    ├── status/
    │   ├── implementation-status.md   ← 완료 / 진행 중 / 블로킹 / 검증됨 (Claude 작성)
    │   └── code-map.md                ← 수정된 파일 및 이유 (Claude 작성)
    └── research/                      ← 참고 자료

.claude/
├── settings.json                      ← 훅 설정 (Level 3 가드레일)
├── hooks/
│   └── post-write-review.sh           ← 실험적; 명시적 /codex:* 명령어 우선
├── agents/
│   ├── branch-implementer.md          ← 쓰기 가능 구현 작업자
│   ├── design-reviewer.md             ← Claude 네이티브 설계 리뷰어 (폴백)
│   └── code-reviewer.md               ← Claude 네이티브 코드 리뷰어 (폴백)
└── commands/
    ├── review-with-codex.md           ← Codex 리뷰 실행 + 결과 정리 커맨드
    └── prepare-handoff.md             ← 브랜치 문서에서 핸드오프 패킷 생성 커맨드

.agent-work/                           ← 에이전트 원시 로그, 임시 출력, 스크래치 파일 (gitignore)
.agents/
└── skills/                            ← Codex 리포 스킬 (워크플로우 안정화 후)
```

---

## 공유 지시 파일

| 파일 | 용도 |
|---|---|
| `AGENTS.md` | 모든 에이전트를 위한 리포 표준 지시사항 |
| `CLAUDE.md` | Claude Code 진입점 (`@AGENTS.md`) |
| `REVIEW.md` | 리뷰 전용 규칙 (Unreal 컨벤션, API 계약, 테스트 요구사항) |

권장 루트 `CLAUDE.md`:

```md
@AGENTS.md
```

구현 세션에서 노이즈가 될 수 있는 리뷰 전용 지침은 `CLAUDE.md`가 아닌 `REVIEW.md`에 작성합니다.

---

## 자동화 수준

### Level 1 — 명시적 플러그인 명령어 (여기서 시작)

자동화 없이 명시적 명령어만 사용합니다. 개발자가 Codex 실행 시점을 직접 제어합니다.

설계 문서 작성 후:
```
/codex:adversarial-review --background 현재 브랜치 설계 문서에서 누락된 요구사항, 불안전한 가정, 롤아웃 위험, 불명확한 소유권, 불명확한 구현 범위를 검토해줘.
```

결과 확인 및 `plans/design-review.md`에 정리:
```
/codex:status
/codex:result
```

구현 완료 후:
```
/codex:review --background
```

고위험 아키텍처 또는 통합 작업:
```
/codex:adversarial-review --base main --background 범위 초과, Unreal 라이프타임/스레딩 위험, 검증 누락, 롤백 위험, 재검토해야 할 설계 가정을 찾아줘.
```

이 수준에서는 제어가 명확하며 예상치 못한 루프가 발생하지 않습니다.

### Level 2 — Claude 커맨드 파일 및 서브에이전트

리뷰 프롬프트의 효과가 검증된 후, Claude 커맨드 파일과 서브에이전트로 인코딩합니다.

**`.claude/commands/review-with-codex.md`** — 구현 완료 후 실행:
```md
/codex:review --background 를 실행합니다.
/codex:result 가 준비되면 결과를 읽습니다.
수락된 발견 사항을 docs/branches/{branch}/plans/code-review.md에 정리합니다.
각 발견 사항을 수락 또는 거부로 표시하고 간단한 이유를 작성합니다.
critical 및 major 발견 사항 요약을 사용자에게 보고합니다.
```

**`.claude/commands/prepare-handoff.md`** — 구현 요청 전 실행:
```md
docs/branches/{branch}/README.md, spec/technical-spec.md, 관련 설계 문서를 읽습니다.
plans/design-review.md가 있으면 읽습니다.
표준 템플릿을 사용하여 plans/next-agent-handoff.md에 핸드오프 패킷을 작성합니다.
포함 항목: 정확한 태스크, 필수 읽기 순서, 허용 쓰기 범위, 수정 금지 목록, 제약 조건, 검증 절차, Codex 리뷰 게이트 알림.
```

커맨드 실행:
```
/review-with-codex
/prepare-handoff
```

### Level 3 — 가드레일 훅

훅은 규율을 강제하는 용도이지 워크플로우를 숨기는 용도가 아닙니다.

**좋은 훅 사용:**
- 코드 변경 후 필수 상태 문서가 업데이트되지 않았을 때 Claude 세션 종료 차단
- 구현 완료 후 `/codex:review --background` 실행 알림
- `.agent-work/`에 에이전트 원시 출력 로깅

**피해야 할 위험한 훅 사용:**
- 모든 `Write` 이벤트에서 리뷰 실행
- 비용을 이해하지 않은 채 Codex 플러그인 리뷰 게이트 활성화
- 문서 편집 후 쓰기 가능한 구현 에이전트 자동 실행
- 명시적인 사용자 의도 없이 커밋, 푸시, 파일 삭제, 브랜치 문서 재작성

기존 `.claude/hooks/post-write-review.sh`는 실험적인 것으로 취급합니다. 훅보다 명시적인 `/codex:*` 명령어를 우선합니다.

### Level 4 — CI 및 PR 자동화

CI를 권위 있는 공유 게이트로 사용합니다. 로컬 훅은 보조 수단입니다.

1. 기존 UE 리뷰 봇 워크플로우를 계속 유지합니다.
2. 새로운 LLM 리뷰어 활성화 전에 루트 `REVIEW.md`를 먼저 작성합니다.
3. 원한다면 Codex GitHub 설정에서 자동 PR 리뷰를 활성화합니다.
4. Claude Code GitHub Action은 처음에 수동 모드(`@claude` 코멘트 트리거)로 추가합니다.
5. 오탐률, 지연 시간, 비용을 파악할 때까지 모든 LLM 리뷰 작업은 **비차단(non-blocking)**으로 유지합니다.
6. 리뷰 결과가 머지를 차단해야 한다면, 결정론적 CI 스텝(심각도 카운트, JSON 출력)으로 변환합니다.

---

## 핸드오프 패킷

구현 전에 Claude가 `docs/branches/{branch}/plans/next-agent-handoff.md`를 작성합니다. `/prepare-handoff` 커맨드(Level 2) 또는 수동으로 작성합니다.

```md
## 태스크

spec/technical-spec.md의 <특정 동작>을 구현합니다.

## 먼저 읽을 파일

- docs/branches/{branch}/README.md
- docs/branches/{branch}/spec/technical-spec.md
- docs/branches/{branch}/design/<design-doc>.md
- docs/branches/{branch}/plans/design-review.md
- 관련 소스 경로:
  - <경로>

## 허용된 쓰기 범위

- <경로 또는 모듈>
- docs/branches/{branch}/status/implementation-status.md
- docs/branches/{branch}/status/code-map.md

## 수정 금지

- <경로 또는 모듈>

## 제약 조건

- 관련 없는 시스템은 리팩토링하지 않습니다.
- 스펙에서 명시적으로 허용하지 않는 한 공개 계약의 하위 호환성을 유지합니다.
- 소스 코드 주석은 AGENTS.md의 언어 정책을 따릅니다.
- 개발자가 명시적으로 수락하지 않는 한 Codex rescue 결과를 적용하지 않습니다.

## 필수 검증

- 가능하면 `<타깃 명령어>`를 실행합니다.
- 수동 테스트가 필요한 경우, 정확한 절차와 기대 결과를 작성합니다.

## Codex 리뷰 게이트

- 구현 완료 후 `/codex:review --background`를 실행합니다.
- 고위험 아키텍처 또는 통합 작업은 `/codex:adversarial-review --background <포커스>`를 실행합니다.
- 수락된 발견 사항을 plans/code-review.md에 정리합니다.

## 출력

- 코드 변경 요약
- 검증 근거
- 업데이트된 상태 문서
- 수락 또는 거부된 Codex 발견 사항
- 미결 위험 사항 또는 후속 항목
```

---

## 일상적인 워크플로우

모든 단계가 Claude Code 세션 하나에서 실행됩니다.

```
개발자 (Claude Code 세션 하나)
   │
   ▼
[1단계] 브랜치 준비 (Claude)
   "브랜치 README 읽고 브랜치 문서 업데이트해줘."
   Claude가 spec/, design/, README.md 작성/업데이트
   │
   ▼
[2단계] 설계 도전 (Codex, 플러그인 경유)
   /codex:adversarial-review --background <포커스>
   → /codex:status  →  /codex:result
   → Claude가 발견 사항을 plans/design-review.md에 정리
   │
   ▼
[개발자가 결과 검토 — 필요 시 수정 반복, 승인]
   │
   ▼
[3단계] 핸드오프 패킷 (Claude)
   /prepare-handoff   (또는 수동 작성)
   → plans/next-agent-handoff.md 생성
   │
   ▼
[4단계] 구현 (Claude)
   "plans/next-agent-handoff.md를 읽고 구현해줘."
   → 허용 범위 내에서 코드 작성
   → status/implementation-status.md, status/code-map.md 업데이트
   │
   ▼
[5단계] 코드 리뷰 (Codex, 플러그인 경유)
   /codex:review --background
   (또는 /review-with-codex 커맨드)
   → /codex:status  →  /codex:result
   → Claude가 수락된 발견 사항을 plans/code-review.md에 정리
   │
   ▼
[개발자가 critical 항목 해결 후 PR 오픈]
   │
   ▼
[6단계] PR (CI + 기존 UE 리뷰 봇)
```

---

## Claude 서브에이전트 정의

`.claude/agents/`에 배치합니다. Codex 플러그인 폴백 또는 병렬 서브태스크용으로 사용합니다.

**`.claude/agents/branch-implementer.md`**
```md
---
name: branch-implementer
description: docs/branches/{branch}/plans/next-agent-handoff.md의 태스크를 구현하고 브랜치 상태 문서를 업데이트합니다.
tools: Read, Glob, Grep, Bash, Edit, Write
model: sonnet
permissionMode: acceptEdits
---

핸드오프 패킷에 기술된 태스크만 구현합니다.
허용 쓰기 범위를 준수합니다. 수정 금지 목록에 있는 항목은 변경하지 않습니다.
소스 코드 변경 후 status/implementation-status.md와 status/code-map.md를 업데이트합니다.
구현이 스펙이나 설계를 무효화할 경우, 계약을 임의로 변경하지 말고 불일치를 보고합니다.
구현 완료 후 메인 Claude 세션에 /codex:review --background 실행을 요청합니다.
```

**`.claude/agents/design-reviewer.md`**
```md
---
name: design-reviewer
description: 브랜치 스펙 및 설계 문서를 리뷰합니다. Codex 플러그인을 사용할 수 없을 때의 폴백입니다.
tools: Read, Glob, Grep, Bash
model: sonnet
permissionMode: plan
---

당신은 이 리포지토리의 설계 리뷰어입니다.
브랜치 README를 먼저 읽고 브랜치 문서 루트를 기준으로 삼습니다.
소스 코드는 수정하지 않습니다.
발견 사항을 심각도(critical / major / minor), 근거, 구체적인 수정 권고안과 함께 보고합니다.
지속적인 발견 사항은 docs/branches/{branch}/plans/design-review.md에 작성합니다.
해결된 항목은 삭제하지 말고 "해결됨"으로 표시합니다.
독립적인 세컨드 오피니언이 필요하면 /codex:adversarial-review --background 실행을 권장합니다.
```

**`.claude/agents/code-reviewer.md`**
```md
---
name: code-reviewer
description: 코드 변경사항을 리뷰합니다. Codex 플러그인을 사용할 수 없을 때의 폴백입니다.
tools: Read, Glob, Grep, Bash
model: sonnet
permissionMode: plan
---

당신은 이 리포지토리의 코드 리뷰어입니다.
우선순위: 버그, 회귀, 데이터 손실, 스레딩/라이프타임 위험, API 계약 위반, 검증 누락.
실제 결함이 숨겨진 경우가 아니라면 스타일 변경은 요청하지 않습니다.
모든 발견 사항에 파일 경로와 라인 번호를 명시합니다.
발견 사항을 docs/branches/{branch}/plans/code-review.md에 작성합니다.
최종 세컨드 오피니언 리뷰는 /codex:review --background 또는 /codex:adversarial-review --background <포커스> 실행을 권장합니다.
```

---

## Codex Rescue 예시

`/codex:rescue`는 범위 한정 조사용으로 사용합니다. 기본 구현 작업자로 사용하지 않습니다.

```
/codex:rescue --background 타깃 빌드가 왜 실패하기 시작했는지 조사하고 가장 작은 수정 방법을 보고해줘.

/codex:rescue --background 현재 설계를 기존 UGC 퍼블리시/로드 플로우와 비교하고 숨겨진 통합 위험을 식별해줘.

/codex:rescue --model gpt-5.4-mini --effort medium 플레이키 테스트를 조사하고 근거만 보고해줘.
```

rescue 결과는 브랜치 문서의 인풋으로 취급합니다. 개발자 또는 Claude 코디네이터가 수락하지 않는 한 rescue 변경사항을 맹목적으로 적용하지 않습니다.

---

## Codex 스킬 후보

워크플로우가 안정화된 후 `.agents/skills/`에 리포 전용 Codex 스킬을 생성합니다.

| 스킬 | 트리거 | 동작 |
|---|---|---|
| `branch-docs` | 브랜치 작업 시작 또는 재개 시 | 브랜치 문서 루트 확인, README 읽기, 누락된 문서 초기화 |
| `design-author` | 아키텍처 또는 스펙 작성 시 | `spec/` 또는 `design/` 업데이트 후 README 결론 업데이트 |
| `implementation-handoff` | Claude에게 구현 요청 전 | 허용 쓰기 범위가 포함된 핸드오프 패킷 생성 |

---

## 권장 도입 순서

1. `codex-plugin-cc` 설치 → `/codex:setup` → **즉시 `/codex:setup --disable-review-gate`**
2. `AGENTS.md`를 참조하는 루트 `CLAUDE.md` 추가
3. 프로젝트 전용 리뷰 기준이 담긴 루트 `REVIEW.md` 추가
4. **Level 1:** 한두 개 브랜치에서 `/codex:adversarial-review --background`와 `/codex:review --background`를 명시적으로 실행. 결과 품질 검증.
5. `.claude/agents/` 서브에이전트 정의 파일 커밋
6. **Level 2:** 프롬프트 검증 후 `.claude/commands/review-with-codex.md`와 `prepare-handoff.md` 추가
7. **Level 3:** Level 2 안정화 후에만 가드레일 훅 추가 (상태 문서 알림, 범위 강제)
8. **Level 4:** 비차단 모드로 PR 레벨 자동화 추가
9. 검증된 Codex 워크플로우를 `.agents/skills/`로 승격

---

## 토큰 비용 고려사항

Codex 호출마다 Claude Code와 OpenAI 양쪽 토큰이 소모됩니다.

| 위험 | 대응 |
|---|---|
| 리뷰 게이트가 예상치 못한 루프 생성 | `--disable-review-gate`로 비활성화 유지 |
| 백그라운드 작업이 쌓임 | 새 작업 시작 전 `/codex:status` 확인 |
| 소규모 변경에 Adversarial Review 사용 | 설계 문서와 고위험 브랜치에만 사용 |
| Rescue 결과를 검토 없이 적용 | 개발자가 명시적으로 수락 후에만 Claude가 적용 |

---

## 트러블슈팅

**`/codex:setup` 실패 시:**
```bash
node --version   # 18.18+ 필요
npm --version
echo $OPENAI_API_KEY
codex --version
```

**`/codex:rescue` 결과가 없거나 에러 발생 시:**
- `/codex:status`로 이전 작업이 아직 실행 중인지 확인
- `/codex:cancel`로 막힌 작업을 정리한 후 새 작업 시작

**리뷰 품질이 낮을 때:**
- 포커스를 구체화: 명령어에 구체적인 우려 사항 추가
- 더 강한 모델 시도: `/codex:rescue --model gpt-5.4-mini --effort high`

**Write 훅이 실행되지 않을 때 (실험적):**
```bash
ls -la .claude/hooks/post-write-review.sh
echo '{"tool_input":{"file_path":"/절대/경로/design/feature-x.md"}}' \
  | bash .claude/hooks/post-write-review.sh
```

---

## 파일 참조

| 파일 | 용도 |
|---|---|
| `AGENTS.md` | 모든 에이전트를 위한 리포 표준 규칙 |
| `CLAUDE.md` | Claude 진입점 (`@AGENTS.md`) |
| `REVIEW.md` | 리뷰 전용 규칙 |
| `.claude/settings.json` | 훅 설정 (Level 3 가드레일) |
| `.claude/hooks/post-write-review.sh` | 실험적 Write 훅 |
| `.claude/agents/branch-implementer.md` | 구현 작업자 서브에이전트 |
| `.claude/agents/design-reviewer.md` | Claude 네이티브 설계 리뷰어 (폴백) |
| `.claude/agents/code-reviewer.md` | Claude 네이티브 코드 리뷰어 (폴백) |
| `.claude/commands/review-with-codex.md` | Codex 리뷰 + 정리 커맨드 |
| `.claude/commands/prepare-handoff.md` | 핸드오프 패킷 생성 커맨드 |
| `.agent-work/` | 에이전트 원시 로그 및 스크래치 파일 (gitignore) |
| `docs/workflow/multi-agent-setup.md` | 영문 워크플로우 문서 |
| `docs/workflow/multi-agent-setup-ko.md` | 이 문서 |
| `docs/branches/{branch}/plans/next-agent-handoff.md` | 태스크 패킷 |
| `docs/branches/{branch}/plans/design-review.md` | 설계 리뷰 결과 |
| `docs/branches/{branch}/plans/code-review.md` | 코드 리뷰 결과 |
