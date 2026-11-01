#!/bin/sh
# 打单片 mTLS patch 并构建验证。
# 用法：在干净的 v26.9.9 工作树根目录执行：
#   sh .github/scripts/build-patched.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "==> apply check"
git apply --check patches/01-mtls-client-cert.patch

# 若 6 个目标文件已有修改，说明 patch 可能已打过，拒绝重复打入。
if [ -n "$(git status --porcelain -- \
  common/protocol/tls/cert/cert.go \
  infra/conf/transport_security.go \
  transport/internet/tls/config.go \
  transport/internet/tls/config.pb.go \
  transport/internet/tls/config.proto \
  transport/internet/tls/tls.go)" ]; then
  echo "target files already modified; refusing to apply twice" >&2
  git status --porcelain
  exit 1
fi

echo "==> apply patches/01-mtls-client-cert.patch"
git apply patches/01-mtls-client-cert.patch

echo "==> gofmt check"
gofmt -l \
  transport/internet/tls/config.go \
  transport/internet/tls/config.pb.go \
  transport/internet/tls/tls.go \
  common/protocol/tls/cert/cert.go \
  infra/conf/transport_security.go
test -z "$(gofmt -l \
  transport/internet/tls/config.go \
  transport/internet/tls/config.pb.go \
  transport/internet/tls/tls.go \
  common/protocol/tls/cert/cert.go \
  infra/conf/transport_security.go)"

echo "==> go build ./..."
go build ./...

echo "==> go vet (touched packages)"
# 注：./infra/conf/... 在干净基线即有 pre-existing 的
# xray.go:606 unreachable code，不在本 patch 范围，故此处只 vet
# 本 patch 实际触及且自身干净的两个包；infra/conf 改动仅为
# transport_security.go 的 usage switch 两行，已由 go build 覆盖。
go vet \
  ./transport/internet/tls/... \
  ./common/protocol/tls/cert/...

echo "==> clean check (no .rej leftovers)"
test -z "$(git status --porcelain | grep -E '\.rej$|\.orig$' || true)"

echo OK
