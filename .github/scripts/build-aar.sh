#!/bin/sh
# 构建 Android AAR（gomobile）——把 mTLS 核心打进 libv2ray.aar 并附加到对应 Release。
#
# 用法（在 fork 根目录、且 release job 已建好版本分支 worktree 后）：
#   sh .github/scripts/build-aar.sh <upstream-tag>
#
# 环境变量：
#   CORE_DIR       mTLS 核心 worktree（默认 /tmp/vb）
#   OUT_DIR        产物输出目录（默认 $GITHUB_WORKSPACE/dist，回退 $PWD/dist）
#   ANDROID_API    gomobile -androidapi（默认 24，对齐 2dust/AndroidLibXrayLite）
#   LIB_REPO       AndroidLibXrayLite 仓库（默认 2dust 上游）
#   LIB_REF        检出 ref/commit（默认 pin 值，保证可复现）
#   LIB_DIR        AndroidLibXrayLite 检出目录（默认 /tmp/AndroidLibXrayLite）
#   AAR_BASENAME   产物基名（默认 libv2ray）
#   SKIP_UPLOAD    true 则只构建不上传（本地复现用）
#
# 退出码：0 成功；1 构建/校验/上传失败。上传失败也会非零，但 CI 侧由 step 的
#         continue-on-error 容忍，不影响已发布的其他产物。
set -eu

TAG="${1:?usage: build-aar.sh <upstream-tag>}"
CORE_DIR="${CORE_DIR:-/tmp/vb}"
OUT_DIR="${OUT_DIR:-${GITHUB_WORKSPACE:-$PWD}/dist}"
ANDROID_API="${ANDROID_API:-24}"
LIB_REPO="${LIB_REPO:-https://github.com/2dust/AndroidLibXrayLite.git}"
LIB_REF="${LIB_REF:-1f3e2c5df1c248ed42630cee2bf747643d303ecc}"
LIB_DIR="${LIB_DIR:-/tmp/AndroidLibXrayLite}"
AAR_BASENAME="${AAR_BASENAME:-libv2ray}"
SKIP_UPLOAD="${SKIP_UPLOAD:-false}"

command -v go >/dev/null 2>&1 || { echo "go not found on PATH" >&2; exit 1; }
# CORE_DIR is a `git worktree` in CI (/tmp/vb), whose .git is a file, not a dir.
git -C "$CORE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "core worktree not found or not a git tree: $CORE_DIR" >&2; exit 1; }
mkdir -p "$OUT_DIR"

echo "==> checking out binding layer $LIB_REPO@$LIB_REF -> $LIB_DIR"
rm -rf "$LIB_DIR"
git clone --filter=blob:none --no-checkout "$LIB_REPO" "$LIB_DIR"
git -C "$LIB_DIR" checkout "$LIB_REF"
git -C "$LIB_DIR" rev-parse HEAD

echo "==> swapping core for local mTLS worktree: $CORE_DIR"
( cd "$LIB_DIR" && go mod edit -replace "github.com/xtls/xray-core=$CORE_DIR" )

echo "==> installing gomobile + gobind"
export PATH="$PATH:$(go env GOPATH)/bin"
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
gomobile init

echo "==> fetching geo assets"
( cd "$LIB_DIR" && mkdir -p assets data && bash gen_assets.sh download && cp -v data/*.dat assets/ )

echo "==> gomobile bind (-androidapi $ANDROID_API, all 4 ABIs)"
export GOFLAGS="${GOFLAGS:--buildvcs=false -trimpath}"
export CGO_LDFLAGS="${CGO_LDFLAGS:--Wl,--build-id=none}"
export CGO_CFLAGS="${CGO_CFLAGS:--ffile-prefix-map=$LIB_DIR=.}"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:--ffile-prefix-map=$LIB_DIR=.}"
( cd "$LIB_DIR" && go mod tidy && gomobile bind -v -androidapi "$ANDROID_API" -trimpath \
    -ldflags='-s -w -buildid= -checklinkname=0' ./ )

AAR="$LIB_DIR/$AAR_BASENAME.aar"
[ -f "$AAR" ] || { echo "expected AAR not found: $AAR" >&2; exit 1; }
cp -v "$AAR" "$OUT_DIR/"
if [ -f "$LIB_DIR/$AAR_BASENAME-sources.jar" ]; then
  cp -v "$LIB_DIR/$AAR_BASENAME-sources.jar" "$OUT_DIR/"
fi

echo "==> verifying ABIs"
MISSING=""
for abi in armeabi-v7a arm64-v8a x86 x86_64; do
  if unzip -l "$AAR" 2>/dev/null | grep -q "jni/$abi/libgojni.so"; then
    echo "  ok: $abi"
  else
    echo "  MISSING: $abi" >&2
    MISSING="$MISSING $abi"
  fi
done
[ -z "$MISSING" ] || { echo "AAR missing ABI(s):$MISSING" >&2; exit 1; }

echo "==> writing checksums and commit note"
( cd "$OUT_DIR" && sha256sum "$AAR_BASENAME.aar" > "$AAR_BASENAME.aar.sha256" )
git -C "$CORE_DIR" rev-parse HEAD > "$OUT_DIR/$AAR_BASENAME.aar.commit"
cat "$OUT_DIR/$AAR_BASENAME.aar.sha256" "$OUT_DIR/$AAR_BASENAME.aar.commit"

if [ "$SKIP_UPLOAD" = "true" ]; then
  echo "SKIP_UPLOAD=true: built only, not uploading"
  exit 0
fi

command -v gh >/dev/null 2>&1 || { echo "gh not found; set SKIP_UPLOAD=true to build only" >&2; exit 1; }

echo "==> resolving release ${TAG}-mtls.*"
MTLS_TAG="$(gh release list --limit 100 --json tagName -q '.[].tagName' 2>/dev/null \
  | grep -E "^${TAG}-mtls\\.[0-9]+$" | sort -V | tail -n 1 || true)"
[ -n "$MTLS_TAG" ] || { echo "no release ${TAG}-mtls.* found; cannot upload AAR" >&2; exit 1; }

echo "==> uploading AAR assets to $MTLS_TAG"
ASSETS="$OUT_DIR/$AAR_BASENAME.aar $OUT_DIR/$AAR_BASENAME.aar.sha256 $OUT_DIR/$AAR_BASENAME.aar.commit"
if [ -f "$OUT_DIR/$AAR_BASENAME-sources.jar" ]; then
  ASSETS="$ASSETS $OUT_DIR/$AAR_BASENAME-sources.jar"
fi
# shellcheck disable=SC2086
gh release upload "$MTLS_TAG" $ASSETS --clobber
echo "uploaded AAR assets to $MTLS_TAG"
