#!/usr/bin/env bash
# 축 3 (표준화) — 수동 merge-in 헬퍼
#
# 사용법: bash scripts/sync-release.sh <branch>
# 예시:   bash scripts/sync-release.sh release/2024.07.01.1
#
# main이 전진했을 때 release/* 또는 hotfix/* 브랜치에 merge-in PR을 생성합니다.
# rebase + force push 대신 squash merge PR을 사용합니다 (커밋 해시 불변).
# auto-merge-in.yml 워크플로가 자동 처리하지 못한 경우 이 스크립트를 실행합니다.

set -euo pipefail

BRANCH="${1:-}"

# --- 입력 검증 ---
if [ -z "$BRANCH" ]; then
  echo "사용법: bash scripts/sync-release.sh <branch>"
  echo "예시:   bash scripts/sync-release.sh release/2024.07.01.1"
  exit 1
fi

if ! printf '%s' "$BRANCH" | grep -qE '^(release|hotfix)/[a-zA-Z0-9._-]+$'; then
  echo "❌ 오류: 브랜치명은 release/* 또는 hotfix/* 형식이어야 합니다."
  echo "   입력값: $BRANCH"
  exit 1
fi

# --- gh CLI 확인 ---
if ! command -v gh &>/dev/null; then
  echo "❌ 오류: gh CLI가 설치돼 있지 않습니다."
  echo "   설치: https://cli.github.com"
  exit 1
fi

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
if [ -z "$REPO" ]; then
  echo "❌ 오류: gh CLI가 저장소에 연결돼 있지 않습니다. 'gh auth login'을 실행하세요."
  exit 1
fi

# --- 원격 최신화 ---
echo "🔄 원격 최신화 중..."
git fetch origin main "$BRANCH" --quiet

# --- 동기화 필요 여부 확인 ---
DIFF_COUNT=$(git rev-list --count "origin/$BRANCH..origin/main")
if [ "$DIFF_COUNT" -eq 0 ]; then
  echo "✅ '$BRANCH'는 이미 main과 동기화돼 있습니다. 작업 불필요."
  exit 0
fi
echo "ℹ️  main이 '$BRANCH'보다 $DIFF_COUNT 커밋 앞서 있습니다."

# --- 기존 open merge-in PR 확인 ---
EXISTING=$(gh pr list \
  --repo "$REPO" \
  --base "$BRANCH" \
  --head main \
  --state open \
  --limit 1 \
  --json number,url \
  | jq -r '.[0] | "\(.number) \(.url)"' 2>/dev/null || true)

if [ -n "$EXISTING" ]; then
  PR_NUM=$(echo "$EXISTING" | cut -d' ' -f1)
  PR_URL=$(echo "$EXISTING" | cut -d' ' -f2)
  echo "⚠️  이미 open merge-in PR #$PR_NUM 이 있습니다: $PR_URL"
  echo "   해당 PR을 머지하거나 충돌을 해소하세요."
  exit 0
fi

# --- PR 제목 구성 (verify-sync가 파싱하는 형식) ---
MAIN_SHA=$(git rev-parse --short origin/main)
PR_TITLE="[merge-in] main → $BRANCH @ $MAIN_SHA"

PR_BODY=$(jq -rn \
  --arg branch "$BRANCH" \
  --arg sha "$(git rev-parse origin/main)" \
  --arg short "$MAIN_SHA" \
  '"## 수동 merge-in\n\nmain의 신규 커밋을 `\($branch)`로 흡수합니다.\n\n- main SHA: `\($sha)` (`\($short)`)\n- 동기화 방식: **squash merge** (커밋 해시 불변, force push 없음)\n\n> `verify-sync` 체크는 이 PR의 제목에서 main SHA를 파싱합니다."')

# --- PR 생성 ---
echo "📬 merge-in PR 생성 중..."
PR_URL=$(gh pr create \
  --repo "$REPO" \
  --base "$BRANCH" \
  --head main \
  --title "$PR_TITLE" \
  --body "$PR_BODY")

echo "✅ PR 생성됨: $PR_URL"
echo ""
echo "다음 단계:"
echo "  1. PR에서 충돌이 없으면 Squash merge로 머지하세요."
echo "  2. 충돌이 있으면 수동으로 해소한 뒤 머지하세요."
echo "  3. 머지 완료 후 release→main PR의 verify-sync 체크가 통과됩니다."
