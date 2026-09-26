#!/bin/sh
# 检测上游新版本 tag（对标 transmission 的 detect-new-tags.sh）。
#
# 逻辑：取上游 tags → 只留语义化 v* 版本 → 跳过 fork 已发 `<tag>-mtls.N`
# 的 → 跳过 ≤ 当前基线的（旧版本不 backport）→ 输出待处理 tag 列表。
# 无待处理 tag 时输出空（调用方 skip）。支持手动指定 tag + force 重建。
#
# 环境变量：
#   UPSTREAM_REPO  上游仓库 URL（默认 https://github.com/XTLS/Xray-core.git）
#   BASELINE_TAG   当前基线 tag（默认 v26.9.9；≤ 它的上游 tag 一律跳过）
#   MANUAL_TAG     手动指定只处理该 tag（可为空）
#   FORCE          true 时即使已有 `<tag>-mtls.N` Release 也不跳过（默认 false）
#   GITHUB_OUTPUT  若设置，写入 pending_tags / has_pending 输出变量
#
# 输出：pending_tags（空格分隔）、has_pending（true/false）。
# 依赖：git、gh（已登录，有 repo 读权限）。
set -eu

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/XTLS/Xray-core.git}"
BASELINE_TAG="${BASELINE_TAG:-v26.9.9}"
MANUAL_TAG="${MANUAL_TAG:-}"
FORCE="${FORCE:-false}"

is_released() {
  # $1 = upstream tag；fork 存在 $1-mtls.* Release 即视为已发
  echo "$RELEASED_TAGS" | grep -qx "$1-mtls.*"
}

echo "==> upstream tags from $UPSTREAM_REPO (baseline: $BASELINE_TAG)"
UPSTREAM_TAGS="$(git ls-remote --tags "$UPSTREAM_REPO" \
  | awk '{print $2}' \
  | sed -e 's|refs/tags/||' \
  | grep -v '\^{}$' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -u -V)"

echo "==> fork releases already published"
RELEASED_TAGS="$(gh release list --limit 100 --json tagName -q '.[].tagName' 2>/dev/null || true)"

PENDING=""
if [ -n "$MANUAL_TAG" ]; then
  CANDIDATES="$MANUAL_TAG"
else
  # 只要严格大于基线的（sort -V 保证顺序，取基线之后的部分）
  CANDIDATES="$(printf '%s\n%s\n' "$UPSTREAM_TAGS" "$BASELINE_TAG" \
    | sort -u -V \
    | awk -v base="$BASELINE_TAG" 'f{print} $0==base{f=1}')"
fi

for tag in $CANDIDATES; do
  # 旧版本不 backport：只处理严格大于基线的 tag；
  # 手动指定 + FORCE=true 时操作员意图明确，放行基线门（已发检查同样放行）。
  if [ -z "$MANUAL_TAG" ] || [ "$FORCE" != "true" ]; then
    SMALLEST="$(printf '%s\n%s\n' "$BASELINE_TAG" "$tag" | sort -V | head -n 1)"
    if [ "$tag" = "$BASELINE_TAG" ] || [ "$SMALLEST" = "$tag" ]; then
      echo "skip (<= baseline): $tag"
      continue
    fi
  fi
  if [ "$FORCE" != "true" ] && is_released "$tag"; then
    echo "skip (already released): $tag"
    continue
  fi
  echo "pending: $tag"
  PENDING="$PENDING $tag"
done
PENDING="$(echo "$PENDING" | sed 's/^ //')"

if [ -z "$PENDING" ]; then
  echo "no pending upstream tags"
  HAS_PENDING="false"
else
  HAS_PENDING="true"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "pending_tags=$PENDING" >> "$GITHUB_OUTPUT"
  echo "has_pending=$HAS_PENDING" >> "$GITHUB_OUTPUT"
else
  echo "pending_tags: $PENDING"
  echo "has_pending: $HAS_PENDING"
fi
