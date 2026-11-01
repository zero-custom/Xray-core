#!/bin/sh
# 发布版本 Release（对标 transmission 的 publish-release.sh）。
#
# 逻辑：产物齐套检查 → 计算修订号 N（同基线已发 `<tag>-mtls.*` 数量 +1，
# 新基线从 .1 起）→ `gh release create <tag>-mtls.N`（notes 模板：基线 /
# patch 来源 / 用法）。已发 Release 只追加 `.N+1` 修订，不改写已发 tag。
#
# 环境变量 / 参数：
#   $1           上游 tag（必填，如 v26.9.10）
#   ARTIFACTS    产物路径清单（空格分隔，可为空；为空则只检查分支存在）
#   BRANCH       版本分支名（默认 = $1，即上游 tag 名）
#   TARGET_REF   Release --target（默认版本分支名）
#   DRAFT        true 则建 draft Release（默认 false，直接发布）
#   NOTES_FILE   自定义 notes 文件（可选；默认用内置模板生成）
#
# 退出码：0 成功（输出 Release tag）；1 缺产物/失败（产物缺失时先建 issue）。
# 依赖：git、gh。
set -eu

TAG="${1:?usage: publish-release.sh <upstream-tag>}"
ARTIFACTS="${ARTIFACTS:-}"
BRANCH="${BRANCH:-$TAG}"
TARGET_REF="${TARGET_REF:-$BRANCH}"
DRAFT="${DRAFT:-false}"
NOTES_FILE="${NOTES_FILE:-}"

RELEASE_TAG="$(gh release list --limit 100 --json tagName -q '.[].tagName' 2>/dev/null \
  | grep -E "^${TAG}-mtls\\.[0-9]+$" | sort -V | tail -n 1 || true)"
if [ -z "$RELEASE_TAG" ]; then
  N=1
else
  N="$(echo "$RELEASE_TAG" | sed 's/.*\.//')"
  N="$((N + 1))"
fi
MTLS_TAG="$TAG-mtls.$N"
echo "==> publishing $MTLS_TAG (branch: $BRANCH)"

# 产物齐套检查
MISSING=""
for a in $ARTIFACTS; do
  if [ ! -e "$a" ]; then
    MISSING="$MISSING $a"
  fi
done
if [ -n "$MISSING" ]; then
  TITLE="build: $TAG - missing artifacts, release skipped"
  if ! gh issue list --search "$TITLE in:title" --state open --json title \
      -q '.[].title' | grep -qx "$TITLE"; then
    gh issue create --title "$TITLE" --body "$(cat <<EOF
Planned release \`$MTLS_TAG\` skipped: missing artifacts:$MISSING

Branch \`$BRANCH\` is kept; re-run the build job, then re-run publish.
EOF
)"
  else
    echo "issue already open for missing artifacts of $TAG"
  fi
  echo "missing artifacts:$MISSING" >&2
  exit 1
fi

# Release notes（内置模板；NOTES_FILE 优先）
if [ -z "$NOTES_FILE" ]; then
  NOTES_FILE="/tmp/release-notes-$MTLS_TAG.md"
  cat > "$NOTES_FILE" <<EOF
## $MTLS_TAG

mTLS client-cert build on upstream \`$TAG\`.

- Baseline: \`XTLS/Xray-core@$TAG\` (\`$(git rev-list -n 1 "$TAG" 2>/dev/null || echo "see branch $BRANCH")\`)
- Patch: \`patches/01-mtls-client-cert.patch\` (single file, P1 first then P2)
  - P1 \`4dcba976\` — static mTLS: CLIENT usage, BuildClientCertificates
  - P2 \`afb37257\` — CA dynamic issuance: CLIENT_AUTHORITY, cached GetClientCertificate
- Version branch: \`$BRANCH\` (one patch commit on \`$TAG\`)
- Docker images (Alpine, single config): \`docker/mtls.Dockerfile*\`

Usage: replace the upstream binary/image with this release's artifact; client
certificates use \`usage: "client"\`, CA issuance uses \`"client_authority"\`.
EOF
fi

CREATE_ARGS="--target $TARGET_REF --notes-file $NOTES_FILE --title $MTLS_TAG"
if [ "$DRAFT" = "true" ]; then
  CREATE_ARGS="$CREATE_ARGS --draft"
fi

# shellcheck disable=SC2086
gh release create "$MTLS_TAG" $CREATE_ARGS $ARTIFACTS
echo "released: $MTLS_TAG"
