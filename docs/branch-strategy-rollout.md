# 브랜치 전략 개편: 시범 구축 결과 및 프로덕션 이행 가이드

> 시범 저장소: `seungjaey/branch-test1` · 작성일: 2026-06-26

## 1. 배경 — 왜 바꾸는가

`release → main` 머지 이후 잔여 `release/*`·`hotfix/*` 브랜치를 **`rebase + force push`**
로 동기화하던 패턴이 근본 원인이었다. force push는 기존 커밋을 덮어써 **커밋 손실**을
일으킨다. 처방은 세 가지다.

1. **(A) 동기화 트리거 제거** — rebase 후 force push하는 습관 자체를 막는다.
2. **(B) merge-in으로 교체** — `rebase + force push` 대신 `main`을 브랜치로 **머지해
   흡수**(merge-in)한다. 기존 커밋 해시가 불변이고 force push가 필요 없다.
3. **(C) 가드레일 4축** — 예방·탐지·표준화·가시성을 자동화로 보장한다.

프로덕션에 적용하기 전, 실제 GitHub 저장소에서 두 가설을 검증했다.

- **가설 ①**: merge-in은 force push·커밋 손실 없이 동기화된다.
- **가설 ②**: 자동화로 동기화 toil을 제거할 수 있다.

## 2. 가드레일 4축 — 무엇을 구축했나

| 축 | 목적 | 구현 | 상태 |
|----|------|------|------|
| **예방** | force push·삭제를 플랫폼이 거부 | Branch Rulesets (`non_fast_forward`, `deletion`, `pull_request`) | ✅ |
| **탐지** | 우회 force push 감사 + 미동기화 차단 | `detect-force-push.yml`, `verify-sync.yml` | ✅ |
| **표준화** | merge-in을 자동/반자동으로 수행 | `auto-merge-in.yml`, `scripts/sync-release.sh` | ✅ |
| **가시성** | 자동화 결과·이상을 Slack 통보 | 워크플로 내 Slack webhook 스텝 | ✅ (Secret 설정 시 활성) |

### 산출물

```
.github/workflows/detect-force-push.yml   # 축 2 — force push 감사 (이중방어)
.github/workflows/verify-sync.yml         # 축 2 — release→main PR 동기화 검증 (required check)
.github/workflows/auto-merge-in.yml       # 축 3 — main 전진 시 merge-in PR 자동 생성+auto-merge
scripts/sync-release.sh                   # 축 3 — 수동 merge-in 헬퍼
```

## 3. 동작 방식

### 3.1 평상시 흐름

```
1. 피처 개발  →  release/* 에 squash merge
2. 배포       →  release/* → main 머지
3. 자동 동기화 →  main 전진 감지
                   auto-merge-in 워크플로 실행
                   └─ 각 release/*, hotfix/*에 merge-in PR 자동 생성
                      └─ 충돌 없으면 auto-merge(squash)로 자동 완료
                         충돌 있으면 PR 유지 + Slack 알림 → 수동 해소
4. 다음 배포 PR → verify-sync 가 merge-in 완료 여부 검사
                   미동기화 → required status check 실패 → 머지 차단
                   동기화 완료 → 통과
```

### 3.2 squash-only 제약과 PR 기반 추적 (핵심 설계 포인트)

`release`·`hotfix` 룰셋이 **squash merge만 허용**한다. squash는 git ancestry를 보존하지
않으므로 `git merge-base --is-ancestor` 기반 동기화 검사가 불가능하다.

→ **PR 제목을 계약(contract)으로 사용**해 우회했다.

- `auto-merge-in`(및 `sync-release.sh`)이 만드는 merge-in PR 제목 형식:

  ```
  [merge-in] main → <branch> @ <short-sha>
  ```

- `verify-sync`는 GitHub PR API로 머지된 merge-in PR을 찾아 제목의 SHA를 파싱,
  현재 `main` SHA와 비교한다. 일치하면 통과, 다르면(merge-in 이후 main이 또 전진했으면) 차단.

## 4. 검증 결과

| 검증 항목 | 결과 | 증빙 |
|-----------|------|------|
| 보호 브랜치 force push 거부 | ✅ | `GH013: push declined`, 테스트 전부 거부 |
| 보호 브랜치 삭제 거부 | ✅ | deletion 룰 적용 확인 |
| merge-in 무 force push·무손실 | ✅ | PR #3/#7/#8 squash merge, force push 0건 |
| 기존 커밋 SHA 불변 | ✅ | release/1·hotfix/1 히스토리 보존 |
| `auto-merge-in` 자동 발화 | ✅ | main 전진 시 PR #7(hotfix/1)·#8(release/1) 자동 생성+머지 |
| `verify-sync` 통과 | ✅ | PR #9에서 merge-in PR #8 탐지, SHA(`7ecc854`) 일치 → SUCCESS |
| `detect-force-push` | ✅ | force push 없어 `skipped` (정상 — 이중방어) |

**가설 ①② 모두 입증.** merge-in은 force push·손실 없이 동기화되고, 자동화가 동기화 toil을 제거했다.

## 5. 프로덕션 이행 체크리스트

### 5.1 저장소 설정

시범 구축 중 기본값에서 변경해야 했던 항목들이다. 프로덕션 저장소에서도 동일하게 적용한다.

- [ ] **Settings → Actions → General → Workflow permissions**
  - `Read and write` 선택
  - **"Allow GitHub Actions to create and approve pull requests" 체크**
  - CLI: `gh api -X PUT repos/<org>/<repo>/actions/permissions/workflow --field default_workflow_permissions=write --field can_approve_pull_request_reviews=true`
  - ⚠️ 미설정 시 `auto-merge-in`이 PR을 못 만든다 (`GitHub Actions is not permitted to create or approve pull requests`).

- [ ] **Settings → General → "Allow auto-merge" 활성화**
  - CLI: `gh api -X PATCH repos/<org>/<repo> --field allow_auto_merge=true`

- [ ] `default_branch`가 `main`인지 확인.

### 5.2 워크플로 이식

- [ ] 워크플로 4종을 그대로 복사: `detect-force-push.yml`, `verify-sync.yml`, `auto-merge-in.yml`, `scripts/sync-release.sh`
- [ ] `verify-sync`의 `check` job을 `main` 룰셋의 **required status check**로 등록
  ```bash
  # integration_id 15368 = GitHub Actions
  gh api -X PUT repos/<org>/<repo>/rulesets/<main-ruleset-id> \
    --input - <<'JSON'
  {
    "rules": [
      {
        "type": "required_status_checks",
        "parameters": {
          "required_status_checks": [{ "context": "check", "integration_id": 15368 }],
          "strict_required_status_checks_policy": false
        }
      }
    ]
  }
  JSON
  ```
  > ⚠️ 이 API 호출은 룰셋 전체를 덮어쓴다. 기존 규칙(deletion, non_fast_forward, pull_request)을 함께 포함시켜야 한다.

### 5.3 룰셋

- [ ] `main`·`release/**`·`hotfix/**` 룰셋에 동일 규칙 적용:
  - `non_fast_forward` (force push 차단)
  - `deletion` (브랜치 삭제 차단)
  - `pull_request` (직접 push 차단, 승인 수는 팀 정책에 따라)

- [ ] **결정 필요**: release/hotfix 룰셋의 `allowed_merge_methods`

  | 선택지 | 장점 | 단점 |
  |--------|------|------|
  | squash-only 유지 | 현 설계 그대로 사용 가능 | `verify-sync`가 PR 제목 파싱에 의존(취약) |
  | merge commit 허용 추가 | `git merge-base --is-ancestor`로 단순화 가능, ancestry 추적 정확 | 머지 커밋이 히스토리에 남음 |

  프로덕션 팀이 선택. 현재 설계는 squash-only를 전제로 동작한다.

### 5.4 가시성

- [ ] `SLACK_WEBHOOK_URL`을 repo Secret으로 등록
  - 미등록 시 알림 스텝은 조건부 skip, 워크플로는 정상 동작
  - `gh secret set SLACK_WEBHOOK_URL --body "<webhook-url>" --repo <org>/<repo>`

## 6. 미해결 합의 항목 (시범 범위 밖)

- **`develop` 브랜치 폐지 시점** — dev 환경 배포 대안이 마련돼야 폐지 가능 (`suggest.md` §5). 팀 합의 필요.
- **조직 권한 모델 확인** — 시범은 개인 계정(`seungjaey/branch-test1`)이어서 조직 룰셋 bypass 액터 목록, CODEOWNERS, 조직 기본 workflow 권한이 다를 수 있다. 프로덕션 이식 전 재확인.

## 7. 주의·한계

### 워크플로 트리거
GITHUB_TOKEN으로 생성된 PR은 다른 워크플로를 자동으로 트리거하지 않는다
([GitHub 문서](https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication#using-the-github_token-in-a-workflow)).
`verify-sync`가 merge-in PR에서 자동 실행되지 않아도 문제 없다(merge-in은 내부 동기화 PR이라 verify-sync 검사 대상이 아님). 다만, `verify-sync`가 release→main PR에서도 트리거되지 않는다면 PAT 또는 `pull_request_target` 이벤트로 전환을 검토한다.

### detect-force-push의 실효성
룰셋(`non_fast_forward`)이 이미 force push를 플랫폼 수준에서 막기 때문에 `detect-force-push.yml`은 보호 브랜치에서 거의 발화하지 않는다. **감사(audit) 및 bypass 권한 사용자 모니터링** 목적으로 유지한다.

### bash 함정 — `jq '// empty'`
`jq '.[0].number // empty'`는 일부 jq 버전에서 exit code 5를 반환한다. `set -eo pipefail` 환경(GitHub Actions 기본)에서는 스크립트 전체가 실패한다. 반드시 `// ""`를 사용한다.

```bash
# ❌ 위험
EXISTING=$(... | jq -r '.[0].number // empty')

# ✅ 안전
EXISTING=$(... | jq -r '.[0].number // ""')
```

### 인젝션 방지
모든 `${{ github.* }}` 표현식은 `env:` 블록을 경유해 환경 변수로 주입하고, 셸에서는 환경 변수를 사용한다. 브랜치명은 셸에서 사용하기 전에 정규식으로 검증한다.

```yaml
# ✅ 올바른 패턴
env:
  HEAD_BRANCH: ${{ github.head_ref }}
run: |
  if ! printf '%s' "$HEAD_BRANCH" | grep -qE '^[a-zA-Z0-9/_-]+$'; then
    echo "::error::Invalid branch name"
    exit 1
  fi
```
