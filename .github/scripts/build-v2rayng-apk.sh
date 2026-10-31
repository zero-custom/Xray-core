#!/bin/sh
# 为上游 v2rayNG 构建嵌入 mTLS 核心（libv2ray.aar）的签名 APK，并独立发布。
#
# 依赖方向：v2rayNG → AndroidLibXrayLite → Xray-core。每个 v2rayNG release 更换
# AndroidLibXrayLite pin ⇒ AAR 必须按目标 v2rayNG 的 `LIB_REF` 重建（复用
# build-aar.sh），core 取 v2rayNG 期望的版本（由其 go.mod 的 pseudo-version 映射）。
#
# 用法（在 fork 根目录）：
#   sh .github/scripts/build-v2rayng-apk.sh <v2rayng-ref>
#
# 参数：
#   $1                 v2rayNG ref（tag 或 commit，必填；如 2.3.11）
#
# 环境变量：
#   LIB_REF            AndroidLibXrayLite commit；设置时断言等于目标 submodule pin
#   CORE_REF           上游 Xray-core tag；设置时跳过 go.mod → tag 映射
#   AAR_SRC_DIR        复用本地已构建 libv2ray.aar（离线/测试），跳过 gomobile
#   WORK_DIR           v2rayNG 检出目录（默认 /tmp/v2rayng-src）
#   OUT_DIR            产物输出目录（默认 $GITHUB_WORKSPACE/dist，回退 $PWD/dist）
#   RELEASE_SUFFIX     Release 修订号 N（默认 1）
#   NDK_VERSION        Android NDK 版本（默认 30.0.16248370）
#   V2RAYNG_REPO       v2rayNG 仓库 URL（默认 2dust 上游）
#   V2RAYNG_PATCH      v2rayNG 源码补丁路径
#                      （默认 $REPO_ROOT/.github/patches/v2rayng-mtls-ui.patch；
#                       置空则跳过补丁，仅调试用）。补丁不适用即 fail-fast。
#   CORE_REPO          上游 Xray-core 仓库 URL（映射 tag 用）
#   ANDROID_HOME       Android SDK 根（必填）
#   NDK_HOME           Android NDK 根（必填，compile-hevtun.sh 需要）
#   签名：ANDROID_KEYSTORE_PATH / APP_KEYSTORE_PASSWORD /
#         APP_KEYSTORE_ALIAS / APP_KEY_PASSWORD（SKIP_SIGN != true 时必填）
#   SKIP_SIGN          true 则不签名（调试）
#   SKIP_UPLOAD        true 则只构建不上传
#   GH_REPO            gh 目标仓库（默认 zero-custom/Xray-core）
#
# 退出码：0 成功；1 失败；prepare-branch.sh 的 2（已建冲突 issue）原样透传。
set -eu

V2RAYNG_REF="${1:?usage: build-v2rayng-apk.sh <v2rayng-ref>}"
LIB_REF="${LIB_REF:-}"
CORE_REF="${CORE_REF:-}"
AAR_SRC_DIR="${AAR_SRC_DIR:-}"
WORK_DIR="${WORK_DIR:-/tmp/v2rayng-src}"
OUT_DIR="${OUT_DIR:-${GITHUB_WORKSPACE:-$PWD}/dist}"
RELEASE_SUFFIX="${RELEASE_SUFFIX:-1}"
NDK_VERSION="${NDK_VERSION:-30.0.16248370}"
V2RAYNG_REPO="${V2RAYNG_REPO:-https://github.com/2dust/v2rayNG.git}"
CORE_REPO="${CORE_REPO:-https://github.com/XTLS/Xray-core.git}"
CORE_DIR="${CORE_DIR:-/tmp/vb}"
GH_REPO="${GH_REPO:-zero-custom/Xray-core}"
SKIP_SIGN="${SKIP_SIGN:-false}"
SKIP_UPLOAD="${SKIP_UPLOAD:-false}"

die() { echo "::error::$1" >&2; exit 1; }

# --- 0. 前置 ----------------------------------------------------------------
command -v gh >/dev/null 2>&1 || die "gh not found on PATH"
[ -n "${ANDROID_HOME:-}" ] || die "ANDROID_HOME is not set"
[ -n "${NDK_HOME:-}" ] || die "NDK_HOME is not set (compile-hevtun.sh requires it)"
mkdir -p "$OUT_DIR"

echo "==> v2rayNG ref: $V2RAYNG_REF (repo: $V2RAYNG_REPO)"

# --- 1. 解析绑定层 LIB_REF 与 core CORE_REF ---------------------------------
echo "==> checking out v2rayNG@$V2RAYNG_REF -> $WORK_DIR"
rm -rf "$WORK_DIR"
git clone "$V2RAYNG_REPO" "$WORK_DIR"
if ! git -C "$WORK_DIR" checkout --quiet "$V2RAYNG_REF" 2>/dev/null; then
  git -C "$WORK_DIR" fetch --quiet origin "$V2RAYNG_REF"
  git -C "$WORK_DIR" checkout --quiet FETCH_HEAD
fi
git -C "$WORK_DIR" submodule update --init --recursive
V2RAYNG_HEAD="$(git -C "$WORK_DIR" rev-parse HEAD)"
echo "    v2rayNG HEAD: $V2RAYNG_HEAD"

# --- 1.5 apply the v2rayNG mTLS UI patch -----------------------------------
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
V2RAYNG_PATCH="${V2RAYNG_PATCH:-$REPO_ROOT/.github/patches/v2rayng-mtls-ui.patch}"
V2RAYNG_PATCH_SHA=""
if [ -n "$V2RAYNG_PATCH" ]; then
  [ -f "$V2RAYNG_PATCH" ] || die "v2rayNG UI patch not found: $V2RAYNG_PATCH"
  git -C "$WORK_DIR" apply --check "$V2RAYNG_PATCH" \
    || die "v2rayNG UI patch does not apply to $V2RAYNG_REF ($V2RAYNG_HEAD); rebase $V2RAYNG_PATCH"
  git -C "$WORK_DIR" apply "$V2RAYNG_PATCH"
  V2RAYNG_PATCH_SHA="$(sha256sum "$V2RAYNG_PATCH" | awk '{print $1}')"
  echo "    applied v2rayNG UI patch: $V2RAYNG_PATCH_SHA"
else
  echo "::warning::V2RAYNG_PATCH is empty; building without the mTLS UI" >&2
fi

LIB_SUBDIR="AndroidLibXrayLite"
[ -d "$WORK_DIR/$LIB_SUBDIR" ] || die "submodule $LIB_SUBDIR missing in v2rayNG@$V2RAYNG_REF"
LIB_REF_ACTUAL="$(git -C "$WORK_DIR/$LIB_SUBDIR" rev-parse HEAD)"
echo "    AndroidLibXrayLite pin: $LIB_REF_ACTUAL"

if [ -n "$LIB_REF" ] && [ "$LIB_REF" != "$LIB_REF_ACTUAL" ]; then
  die "LIB_REF mismatch: requested $LIB_REF but v2rayNG@$V2RAYNG_REF pins $LIB_REF_ACTUAL (bindings would be wrong)"
fi
# 后续一律使用实际 pin，保证 AAR 与目标 v2rayNG 的 Java API 一致。
LIB_REF="$LIB_REF_ACTUAL"

# go.mod 中的 xray-core pseudo-version → commit → 上游 tag（除非显式给 CORE_REF）。
CORE_COMMIT=""
if [ -z "$CORE_REF" ]; then
  GOMOD="$WORK_DIR/$LIB_SUBDIR/go.mod"
  [ -f "$GOMOD" ] || die "go.mod not found at $GOMOD"
  LINE="$(grep -E '^[[:space:]]*github\.com/xtls/xray-core v' "$GOMOD" | head -n 1 || true)"
  [ -n "$LINE" ] || die "no xray-core require line in $GOMOD"
  # 取 require 行最后一个 token（pseudo-version），再去掉结尾的 -<12hex>。
  CORE_COMMIT="$(printf '%s\n' "$LINE" | sed 's|//.*$||' | awk '{print $NF}' | tr -d '\r')"
  CORE_COMMIT="${CORE_COMMIT##*-}"
  CORE_COMMIT="${CORE_COMMIT%%+*}"
  case "$CORE_COMMIT" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) die "could not parse xray-core commit from '$LINE' in $GOMOD" ;;
  esac
  echo "    xray-core commit: $CORE_COMMIT (mapping to upstream tag)"
  TAGS="$(git ls-remote --tags "$CORE_REPO" 2>/dev/null | grep -v '\^{}$' || true)"
  [ -n "$TAGS" ] || die "git ls-remote --tags $CORE_REPO returned nothing"
  CORE_REF="$(printf '%s\n' "$TAGS" \
    | awk -v c="$CORE_COMMIT" 'substr($1,1,length(c))==c { sub("refs/tags/","",$2); print $2 }' \
    | head -n 1 || true)"
  if [ -z "$CORE_REF" ]; then
    die "could not map xray-core commit $CORE_COMMIT (from v2rayNG@$V2RAYNG_REF) to an upstream tag; pass CORE_REF=<tag> explicitly"
  fi
fi
echo "    core ref: $CORE_REF"

# --- 2. 构建 AAR（复用 build-aar.sh；或复用 AAR_SRC_DIR） --------------------
AAR="$OUT_DIR/libv2ray.aar"
if [ -n "$AAR_SRC_DIR" ]; then
  [ -f "$AAR_SRC_DIR/libv2ray.aar" ] || die "AAR_SRC_DIR set but $AAR_SRC_DIR/libv2ray.aar missing"
  echo "==> reusing prebuilt AAR from $AAR_SRC_DIR"
  cp -f "$AAR_SRC_DIR/libv2ray.aar" "$AAR"
else
  echo "==> preparing core worktree $CORE_DIR for $CORE_REF"
  # 记住 fork 检出点：prepare-branch.sh 会把本检出切到版本分支（其中没有
  # fork 专属的 .github/scripts/*），构建 AAR 前必须切回，否则脚本自身消失。
  ORIG_REF="$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)"
  git remote add upstream "$CORE_REPO" 2>/dev/null || true
  git fetch origin '+refs/heads/*:refs/remotes/origin/*' >>/tmp/prepare-branch.log 2>&1 || true
  # 幂等：分支已存在则复用。prepare-branch.sh 在冲突时建 issue 并 exit 2，原样透传。
  set +e
  CORE_DIR="$CORE_DIR" sh .github/scripts/prepare-branch.sh "$CORE_REF"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "::error::prepare-branch.sh failed for $CORE_REF (exit $rc)" >&2
    exit "$rc"
  fi
  # 切回原检出点后再建 worktree（避免「分支已在别处检出」冲突）。
  git checkout --quiet "$ORIG_REF" 2>/dev/null || git checkout --quiet main 2>/dev/null || true
  git worktree remove --force "$CORE_DIR" 2>/dev/null || true
  rm -rf "$CORE_DIR"
  # The worktree MUST be the patched version branch: a tag fallback would
  # silently build the unpatched upstream core (no mTLS), so fail loudly.
  git worktree add --detach "$CORE_DIR" "refs/heads/$CORE_REF" 2>/dev/null \
    || die "could not create core worktree at $CORE_DIR from refs/heads/$CORE_REF (prepare-branch.sh must create that branch)"

  echo "==> building mTLS AAR for $CORE_REF (LIB_REF=$LIB_REF)"
  CORE_DIR="$CORE_DIR" LIB_REF="$LIB_REF" OUT_DIR="$OUT_DIR" SKIP_UPLOAD=true \
    sh .github/scripts/build-aar.sh "$CORE_REF"
fi
[ -f "$AAR" ] || die "AAR not found: $AAR"
AAR_SHA="$(sha256sum "$AAR" | awk '{print $1}')"
echo "    AAR sha256: $AAR_SHA"

# --- 3. 构建 APK ------------------------------------------------------------
echo "==> building libhevtun native libs (compile-hevtun.sh)"
( cd "$WORK_DIR" && bash compile-hevtun.sh )
echo "==> staging native libs into V2rayNG/app"
( cd "$WORK_DIR" && cp -r libs V2rayNG/app )
( cd "$WORK_DIR" && mkdir -p V2rayNG/app/libs && cp -f "$AAR" V2rayNG/app/libs/libv2ray.aar )

echo "==> injecting ndkVersion = \"$NDK_VERSION\" into build.gradle.kts"
GRADLE="$WORK_DIR/V2rayNG/app/build.gradle.kts"
[ -f "$GRADLE" ] || die "gradle file not found: $GRADLE"
if grep -q 'ndkVersion' "$GRADLE"; then
  echo "    ndkVersion already present, leaving as-is"
else
  awk -v nv="$NDK_VERSION" '
    !inserted && /android[[:space:]]*\{/ {
      print;
      print "    ndkVersion = \"" nv "\"";
      inserted=1;
      next
    }
    { print }
  ' "$GRADLE" > "$GRADLE.new"
  mv "$GRADLE.new" "$GRADLE"
  grep -q "ndkVersion = \"$NDK_VERSION\"" "$GRADLE" \
    || die "failed to inject ndkVersion into $GRADLE"
fi

# AGP strips debug symbols from native libs on release builds, which would make
# the APK's libgojni.so differ byte-for-byte from the AAR we built (breaking the
# AC2 provenance check). Keep symbols for libgojni.so so the packaged lib stays
# identical to the AAR member.
echo "==> disabling native-lib stripping for libgojni.so (keepDebugSymbols)"
if grep -q 'keepDebugSymbols' "$GRADLE"; then
  echo "    keepDebugSymbols already present, leaving as-is"
else
  awk '
    { print }
    !done && /^[[:space:]]*packaging[[:space:]]*\{/ { in_pkg=1 }
    in_pkg && !done && /^[[:space:]]*jniLibs[[:space:]]*\{/ {
      print "            keepDebugSymbols += \"**/libgojni.so\"";
      done=1
    }
  ' "$GRADLE" > "$GRADLE.new"
  mv "$GRADLE.new" "$GRADLE"
  grep -q 'keepDebugSymbols.*libgojni' "$GRADLE" \
    || die "failed to inject keepDebugSymbols into $GRADLE (no packaging/jniLibs block?)"
fi

echo "==> writing V2rayNG/local.properties"
printf 'sdk.dir=%s\n' "$ANDROID_HOME" > "$WORK_DIR/V2rayNG/local.properties"

SIGN_ARGS=""
if [ "$SKIP_SIGN" = "true" ]; then
  echo "==> SKIP_SIGN=true: building unsigned"
else
  [ -n "${ANDROID_KEYSTORE_PATH:-}" ] && [ -f "$ANDROID_KEYSTORE_PATH" ] \
    || die "ANDROID_KEYSTORE_PATH not set or file missing (set SKIP_SIGN=true to skip signing)"
  [ -n "${APP_KEYSTORE_PASSWORD:-}" ] || die "APP_KEYSTORE_PASSWORD not set"
  [ -n "${APP_KEYSTORE_ALIAS:-}" ] || die "APP_KEYSTORE_ALIAS not set"
  [ -n "${APP_KEY_PASSWORD:-}" ] || die "APP_KEY_PASSWORD not set"
  SIGN_ARGS="-Pandroid.injected.signing.store.file=$ANDROID_KEYSTORE_PATH"
  SIGN_ARGS="$SIGN_ARGS -Pandroid.injected.signing.store.password=$APP_KEYSTORE_PASSWORD"
  SIGN_ARGS="$SIGN_ARGS -Pandroid.injected.signing.key.alias=$APP_KEYSTORE_ALIAS"
  SIGN_ARGS="$SIGN_ARGS -Pandroid.injected.signing.key.password=$APP_KEY_PASSWORD"
fi

echo "==> gradle assemblePlaystoreRelease"
( cd "$WORK_DIR/V2rayNG" && chmod +x gradlew \
    && JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-}" ./gradlew --no-daemon assemblePlaystoreRelease $SIGN_ARGS )

APK_DIR="$WORK_DIR/V2rayNG/app/build/outputs/apk/playstore/release"
[ -d "$APK_DIR" ] || die "APK output dir not found: $APK_DIR"
APK_FILES=""
for apk in "$APK_DIR"/*.apk; do
  [ -f "$apk" ] || continue
  APK_FILES="$APK_FILES $apk"
done
[ -n "$APK_FILES" ] || die "no APKs produced in $APK_DIR"

# --- 4. 校验 ----------------------------------------------------------------
echo "==> verifying per-ABI native libs (AAR jni/<abi> vs APK lib/<abi>)"
find_apk() {
  # $1 = abi；输出该 ABI 的 APK 路径（universal 不算）。
  _abi="$1"
  for _apk in $APK_FILES; do
    case "$_apk" in
      *_"$_abi".apk) printf '%s\n' "$_apk"; return 0 ;;
    esac
  done
  return 1
}

for abi in armeabi-v7a arm64-v8a x86 x86_64; do
  # 先守卫成员存在性，避免 `unzip -p` 空输入导致 sha256 双方等值（假通过）。
  unzip -l "$AAR" 2>/dev/null | grep -q "jni/$abi/libgojni.so" \
    || die "AAR missing jni/$abi/libgojni.so"
  APK="$(find_apk "$abi" || true)"
  [ -n "$APK" ] || die "no APK for ABI $abi in $APK_DIR"
  unzip -l "$APK" 2>/dev/null | grep -q "lib/$abi/libgojni.so" \
    || die "APK $APK missing lib/$abi/libgojni.so"
  HA="$(unzip -p "$AAR" "jni/$abi/libgojni.so" | sha256sum | awk '{print $1}')"
  HP="$(unzip -p "$APK" "lib/$abi/libgojni.so" | sha256sum | awk '{print $1}')"
  [ "$HA" = "$HP" ] || die "libgojni.so mismatch for $abi (AAR $HA vs APK $HP)"
  echo "    ok: $abi ($HP)"
done

UNIVERSAL=""
for apk in $APK_FILES; do
  case "$apk" in *_universal.apk) UNIVERSAL="$apk" ;; esac
done
[ -n "$UNIVERSAL" ] || die "universal APK not found in $APK_DIR"
echo "    ok: universal ($UNIVERSAL)"

AAPT2="$(ls "$ANDROID_HOME"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -n 1 || true)"
[ -n "$AAPT2" ] || die "aapt2 not found under $ANDROID_HOME/build-tools/*"
BADGING="$("$AAPT2" dump badging "$UNIVERSAL")"
printf '%s\n' "$BADGING" | grep -q "package: name='com.v2ray.ang'" \
  || die "unexpected package name (expected com.v2ray.ang)"
V2RAYNG_VER="$(printf '%s\n' "$BADGING" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | head -n 1 || true)"
[ -n "$V2RAYNG_VER" ] || V2RAYNG_VER="$V2RAYNG_REF"
echo "    package com.v2ray.ang versionName=$V2RAYNG_VER"

# --- 5. 发布 ----------------------------------------------------------------
REL_TAG="v2rayNG-${V2RAYNG_VER}-mtls.${RELEASE_SUFFIX}"
echo "==> release tag: $REL_TAG"

if [ "$SKIP_UPLOAD" = "true" ]; then
  echo "SKIP_UPLOAD=true: built only, not publishing"
  echo "APKs:"; for apk in $APK_FILES; do echo "  $apk"; done
  exit 0
fi

# 发布产物落地 OUT_DIR（APK + sha256 + buildinfo）。
for apk in $APK_FILES; do
  cp -f "$apk" "$OUT_DIR/"
done
# REL_TAG already carries the `v2rayNG-` prefix; do not double it.
SHA_ASSET="$OUT_DIR/${REL_TAG}.sha256"
BUILDINFO="$OUT_DIR/${REL_TAG}.buildinfo"
( cd "$OUT_DIR" && for apk in $APK_FILES; do sha256sum "$(basename "$apk")"; done > "$(basename "$SHA_ASSET")" )
cat > "$BUILDINFO" <<EOF
v2rayng-ref=$V2RAYNG_REF
v2rayng-head=$V2RAYNG_HEAD
lib-ref=$LIB_REF
android-lib-ref=$LIB_REF
core-ref=$CORE_REF
core-commit=${CORE_COMMIT:-}
aar-sha256=$AAR_SHA
v2rayng-patch-sha256=${V2RAYNG_PATCH_SHA:-}
EOF
cat "$SHA_ASSET" "$BUILDINFO"

gh release view "$REL_TAG" -R "$GH_REPO" >/dev/null 2>&1 || \
  gh release create "$REL_TAG" -R "$GH_REPO" --title "$REL_TAG" --notes "$(cat <<EOF
mTLS v2rayNG build on upstream \`$V2RAYNG_REF\`.

- v2rayNG ref: \`$V2RAYNG_REF\` (\`$V2RAYNG_HEAD\`)
- AndroidLibXrayLite pin: \`$LIB_REF\`
- Xray-core (mTLS): \`$CORE_REF\`
- AAR sha256: \`$AAR_SHA\`

Install: uninstall any upstream v2rayNG first (same package name
\`com.v2ray.ang\`, different signing key).
EOF
)"

echo "==> uploading assets to $REL_TAG"
# shellcheck disable=SC2086
gh release upload "$REL_TAG" -R "$GH_REPO" \
  "$OUT_DIR"/v2rayNG_"$V2RAYNG_VER"_*.apk \
  "$SHA_ASSET" "$BUILDINFO" --clobber
echo "published: $REL_TAG"
