# v0.4.0 发布核验

日期：2026-09-22。版本 0.4.0，`CFBundleVersion` 7（由 6 递增）。

## 发布前

- `./scripts/build-app.sh release` 生成 Universal 应用：`lipo -archs` 为 `x86_64 arm64`，ad-hoc 严格签名校验通过。
- 225 项离线检查通过：核心 108、原生 33、工作流 84。日志 `dist/validation/release-v0.4.0-{core,native,workflow}.log`。
- `ALLOW_ADHOC_RELEASE=1 ./scripts/package-release.sh` 生成 DMG 与 ZIP，`hdiutil verify` 通过，SHA256SUMS 记录两个包。
- `python3 scripts/generate-update-feed.py` 从钥匙串读取签名能力，公钥与包内 `SUPublicEDKey` 一致，DMG 与 `appcast.xml` 均已签名并验证；私钥未导出。

## 发布

- 提交 `a969ab4` 推送到 main，标签 `v0.4.0` 指向同一提交。
- 先创建草稿 Release，一次上传 DMG、ZIP、SHA256SUMS、appcast.xml，核对四个附件均为 `uploaded` 且摘要与本机一致后，才公开并设为 latest。

## 发布后核对

- `releases/latest` 的 tag 为 `v0.4.0`；`releases/latest/download/appcast.xml` 返回 200。
- 线上 `appcast.xml` 与本机签名文件的 SHA256 完全一致（`75851417…`），`shortVersionString` 为 0.4.0，enclosure 指向 v0.4.0 的 DMG，长度 4550555 与实际一致。
- 下载的 DMG SHA256 为 `4b8ff36f…`，与 SHA256SUMS 一致；挂载后应用版本 0.4.0、构建 7、`x86_64 arm64`，`codesign --verify --strict` 通过，包内 `--self-check` 33 项通过。

## 未覆盖

- 未执行 0.3.1 → 0.4.0 的真实应用内更新演练（Sparkle 下载、替换与重启），也未在独立用户下核对更新后的日历、钥匙串授权连续性。
- 仍为 ad-hoc 签名，没有 Developer ID 签名与公证；更新后可能再次请求日历或钥匙串授权。
- 未执行 `--model-contract-check`，六家服务商对新增 `dueHint` 字段的实际遵循情况尚未联网核对。
