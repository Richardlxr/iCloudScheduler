# v0.6.0 发布核验

日期：2026-09-22。版本 0.6.0，`CFBundleVersion` 9（由 8 递增）。

## 发布前

- `./scripts/build-app.sh release` 生成 Universal 应用：`lipo -archs` 为 `x86_64 arm64`，ad-hoc 严格签名校验通过。
- 294 项离线检查通过：核心 149、原生 37、工作流 108。日志 `dist/validation/release-v0.6.0-{core,native,workflow}.log`。
- `ALLOW_ADHOC_RELEASE=1 ./scripts/package-release.sh` 生成 DMG 与 ZIP，`hdiutil verify` 通过。
- `python3 scripts/generate-update-feed.py` 从钥匙串读取签名能力，公钥与包内 `SUPublicEDKey` 一致，DMG 与 `appcast.xml` 均已签名并验证；私钥未导出。

## 发布

- 提交 `d9ab5c3` 推送到 main，标签 `v0.6.0` 指向同一提交。
- 先创建草稿 Release，一次上传四个附件，核对状态与大小后才公开并设为 latest。

## 发布后核对

- `releases/latest` 的 tag 为 `v0.6.0`；线上 `appcast.xml` 与本机签名文件 SHA256 完全一致（`388b8ac9…`），enclosure 长度 4926721 与 DMG 实际大小一致。
- 下载的 DMG SHA256 前缀 `58bc5a68…` 与 SHA256SUMS 一致；挂载后应用版本 0.6.0、`x86_64 arm64`，`codesign --verify --strict` 通过，包内 `--self-check` 37 项通过。

## 未覆盖

- 未做真实 EventKit 改动：改期、取消在系统日历中的实际落地、撤销重建、跨设备同步仍需人工验收。
- 未执行 0.5.0 → 0.6.0 的真实应用内更新演练。
- 未执行 `--model-contract-check`，六家服务商对 `action`/`targetTitle`/`targetStartLocal` 的遵循情况尚未联网核对。
- 仍为 ad-hoc 签名，没有 Developer ID 签名与公证。
