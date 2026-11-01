# patches/

程序定制以 patch 文件形式维护，打在干净的上游基线 tag 之上。

## 文件

- `01-mtls-client-cert.patch` — mTLS 双向认证定制（静态 client 证书 + CA 动态签发），单片。

## 来源提交（zero-custom/Xray-core，2026-06 基线）

- P1 `4dcba976` — 静态 mTLS：`config.proto` 加 `CLIENT=3`、
  `BuildClientCertificates()`、JSON `usage="client"`、`GetTLSConfig`
  接 `GetClientCertificate`、uTLS `copyConfig` 透传。
- P2 `afb37257` — CA 动态签发：`CLIENT_AUTHORITY=4`、
  `BuildClientAuthority()`、`issueCertificate` 可变选项、`ExtKeyUsage`、
  `GetClientCertificate` 改动态优先 + 静态替补。
- P3 多证书改造：多证书/多 CA 选择链、动态失败回退静态、
  缓存挂到长生命周期 `*Config`（per-CA + `singleflight` + 5 分钟余量）。

单片内 P1 内容在前、P2/P3 在后，一次打入，无顺序问题。

## 行为

- 选择链（静态与动态共用）：有效期内（留 5 分钟余量）→
  `AcceptableCAs` 匹配（DER DN，链上任一环 issuer）→ `NotAfter`
  降序 → 配置顺序。
- 动态优先：`usage: "client_authority"` 可用时现签；CA 过期、
  签发失败或签出校验失败时回退到 `usage: "client"` 静态证书。
  两者不再互斥。
- 动态缓存：按 `*Config`（outbound 长生命周期）持有，per-CA 键控 +
  `singleflight` 去重；有效期内跨连接复用，不再每个拨号重签。
- 签出校验：可解析、有效期、`ExtKeyUsageClientAuth`、链锚定服务器
  下发的 `AcceptableCAs`。

## 适用基线

- 上游 `XTLS/Xray-core` tag `v26.10.21`（commit `1b1647cd`）。
- 更早 tag（v26.10.10 / v26.9.x）因 `tls.go` 整段（上游已在
  `copyConfig` 原生实现 `GetClientCertificate` 桥接，本 patch 删去
  该段）与 `config.pb.go` rawDesc hunk 差异，`apply --check` 可能
  不通过；重新适配时先跑 `git apply --check`。
- 旧 fork `main` 备份概念：2026-06 基线 `fdb9b616`，custom 顶
  `1d42d147`（工作流修改另行处理，本 patch 只含程序定制）。

## 基线适配说明（v26.9.9 vs 2026-06）

- 枚举检查：上游 `Certificate.Usage` 仍只占用 0/1/2，
  `CLIENT=3` / `CLIENT_AUTHORITY=4` 无需顺延；`.pb.go` 的
  `Usage_value` map 与 `rawDesc` 与旧 patch 逐字节一致，直接沿用。
- 路径变更：`TLSCertConfig.Build()` 的 usage switch 已从
  `infra/conf/transport_internet.go` 搬到
  `infra/conf/transport_security.go`（内容不变），本 patch 内
  `client` / `client_authority` 两段直接落在新路径。

## 使用

```sh
git apply --check patches/01-mtls-client-cert.patch
git apply patches/01-mtls-client-cert.patch
# 或一键：bash .github/scripts/build-patched.sh
```
