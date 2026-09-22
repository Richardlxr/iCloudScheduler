# v0.5.0 发布核验

日期：2026-09-22。版本 0.5.0，`CFBundleVersion` 8（由 7 递增）。

## 发布前

- `./scripts/build-app.sh release` 生成 Universal 应用：`lipo -archs` 为 `x86_64 arm64`，ad-hoc 严格签名校验通过。
- 267 项离线检查通过：核心 136、原生 37、工作流 94。日志 `dist/validation/release-v0.5.0-{core,native,workflow}.log`。
- `ALLOW_ADHOC_RELEASE=1 ./scripts/package-release.sh` 生成 DMG 与 ZIP，`hdiutil verify` 通过。
- `python3 scripts/generate-update-feed.py` 从钥匙串读取签名能力，公钥与包内 `SUPublicEDKey` 一致，DMG 与 `appcast.xml` 均已签名并验证；私钥未导出。

## 发布

- 提交 `8f54237` 推送到 main，标签 `v0.5.0` 指向同一提交。
- 先创建草稿 Release，一次上传 DMG、ZIP、SHA256SUMS、appcast.xml，核对四个附件均为 `uploaded` 且摘要与本机一致后，才公开并设为 latest。

## 发布后核对

- `releases/latest` 的 tag 为 `v0.5.0`；线上 `appcast.xml` 与本机签名文件 SHA256 完全一致（`41590d68…`），enclosure 长度 4742061 与 DMG 实际大小一致。
- 下载的 DMG SHA256 为 `6f6b7523…`，与 SHA256SUMS 一致；挂载后应用版本 0.5.0、构建 8、`x86_64 arm64`，`codesign --verify --strict` 通过，包内 `--self-check` 37 项通过。
- 包内 `Info.plist` 含 `NSRemindersFullAccessUsageDescription`，这是本版新增的提醒事项权限说明。

## 未覆盖

- 未执行 0.4.0 → 0.5.0 的真实应用内更新演练，也未在独立用户下核对更新后的授权连续性。本版新增提醒事项权限，首次写入待办时会弹出系统授权。
- 未做真实 EventKit 写入：提醒事项清单、重复日程在系统日历与提醒事项中的落地、跨设备同步与系统通知仍需人工验收。
- 未执行 `--model-contract-check`，六家服务商对新增字段的遵循情况尚未联网核对。
- 仍为 ad-hoc 签名，没有 Developer ID 签名与公证。
