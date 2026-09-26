#!/bin/sh
# 准备版本分支（对标 transmission 的 prepare-branch.sh）。
#
# 逻辑：分支名取上游 tag 名（如 v26.9.10，已存在直接复用）→ 检出 tag →
# 优先 cherry-pick 上一版本分支的补丁提交（-X theirs），无上一版则
# `git apply patches/01-mtls-client-cert.patch` → 一笔提交 → push 分支。
# 失败 → 开/更新 GitHub issue 并以 exit 2 跳过该版本（不阻塞其他版本）。
#
# 环境变量 / 参数：
#   $1           上游 tag（必填，如 v26.9.10）
#   PREV_BRANCH  上一版本分支名（可选；为空则直接 git apply 单片 patch）
#   PATCH_FILE   单片 patch 路径（默认 patches/01-mtls-client-cert.patch，
#                取自 main 分支：git show origin/main:<path>）
#   REMOTE       push 远端（默认 origin）
#
# 退出码：0 成功（输出分支名）；2 已建 issue 并跳过；1 其他错误。
# 依赖：git、gh。
set -eu

TAG="${1:?usage: prepare-branch.sh <upstream-tag>}"
PREV_BRANCH="${PREV_BRANCH:-}"
PATCH_FILE="${PATCH_FILE:-patches/01-mtls-client-cert.patch}"
REMOTE="${REMOTE:-origin}"
BRANCH="$TAG"
LOG="/tmp/prepare-branch.log"
: > "$LOG"

log() {
  echo "$@" | tee -a "$LOG"
}

fail_to_issue() {
  # $1 = 失败摘要。建 issue（同标题 open 的不再重复建），exit 2 跳过该版本。
  TITLE="build: $TAG - patch rebase conflict"
  log "$1"
  if ! gh issue list --search "$TITLE in:title" --state open --json title \
      -q '.[].title' | grep -qx "$TITLE"; then
    gh issue create --title "$TITLE" --body "$(cat <<EOF
Version branch preparation failed for upstream tag \`$TAG\`.

$1

Logs (tail):
\`\`\`
$(tail -40 "$LOG")
\`\`\`
EOF
)" >>"$LOG" 2>&1 || log "warning: gh issue create failed, still skipping $TAG"
  else
    log "issue already open for $TAG, skipping create"
  fi
  exit 2
}

git fetch "$REMOTE" "+refs/heads/*:refs/remotes/$REMOTE/*" >>"$LOG" 2>&1 || true
git fetch upstream tag "$TAG" >>"$LOG" 2>&1 \
  || git fetch upstream '+refs/tags/*:refs/tags/*' >>"$LOG" 2>&1

if git rev-parse --verify --quiet "refs/remotes/$REMOTE/$BRANCH" >/dev/null; then
  log "branch $BRANCH already exists on $REMOTE, reusing"
  git checkout -B "$BRANCH" "$REMOTE/$BRANCH" >>"$LOG" 2>&1
  # 幂等：分支头已是我们的补丁提交（相对基线 tag 恰一笔且信息匹配）→ 直接复用，
  # 避免重复 apply（强制重跑/重 dispatch 场景）。
  if [ "$(git rev-list --count "$TAG..HEAD" 2>/dev/null || echo -1)" = "1" ] \
     && git log -1 --format=%s 2>/dev/null | grep -q "mTLS client cert on $TAG"; then
    log "branch already prepared (patch commit present), reusing as-is"
    git push "$REMOTE" "$BRANCH" >>"$LOG" 2>&1 || true
    log "branch ready: $BRANCH"
    exit 0
  fi
  log "existing branch needs (re)patching, continuing"
else
  log "creating branch $BRANCH from upstream tag $TAG"
  git checkout -B "$BRANCH" "$TAG" >>"$LOG" 2>&1
fi

git config user.email "github-actions@github.com"
git config user.name "GitHub Actions"

if [ -n "$PREV_BRANCH" ] && git rev-parse --verify --quiet "refs/remotes/$REMOTE/$PREV_BRANCH" >/dev/null; then
  log "cherry-picking patch commit from $PREV_BRANCH"
  # 上一版分支相对其基线的补丁提交（单片 patch 对应一笔提交，取最末一笔）。
  PATCH_COMMIT="$(git rev-list --topo-order "$REMOTE/$PREV_BRANCH" --not "$TAG" --reverse | tail -n 1)"
  if [ -z "$PATCH_COMMIT" ]; then
    log "no patch commit found on $PREV_BRANCH, falling back to git apply"
    git show "$REMOTE/main:$PATCH_FILE" | git apply --3way --index >>"$LOG" 2>&1 \
      || fail_to_issue "\`git apply $PATCH_FILE\` conflicted on $TAG."
  elif git cherry-pick -X theirs "$PATCH_COMMIT" >>"$LOG" 2>&1; then
    log "cherry-picked $PATCH_COMMIT"
  else
    git cherry-pick --abort 2>/dev/null || true
    fail_to_issue "cherry-pick of $PATCH_COMMIT from $PREV_BRANCH conflicted."
  fi
else
  log "applying single patch $PATCH_FILE from $REMOTE/main"
  git show "$REMOTE/main:$PATCH_FILE" | git apply --3way --index >>"$LOG" 2>&1 \
    || fail_to_issue "\`git apply $PATCH_FILE\` conflicted on $TAG."
fi

# 落盘为一笔源码提交（信息沿用两原提交 + 基线注脚，见 baseline-release）。
# 若 apply 实为空操作（树已含 patch），直接视为就绪，避免空提交硬错。
if [ -z "$(git status --porcelain)" ]; then
  log "no changes after apply (tree already patched), treating as ready"
else
  git commit -m "mTLS client cert on $TAG" \
    -m "Single patch from main:$PATCH_FILE" \
    -m "Sources: 4dcba976 + afb37257." \
    -m "Baseline: $TAG." >>"$LOG" 2>&1
fi

git push "$REMOTE" "$BRANCH" >>"$LOG" 2>&1
log "branch ready: $BRANCH"
