# PBsync 内部候选的构建与恢复

项目自有代码采用 MIT 许可证，完整授权文本位于仓库及源码归档根目录的 `LICENSE`。归档内的 `distribution/dependencies.json` 将每个锁定依赖映射到它自己的授权文本。Mac 和 iPhone 的主程序及凭据扩展中均附 ZIPFoundation 的 MIT 文本。Mac 包内的 pbsync-connector 包含解释器及文件连接器依赖，授权文本在 Contents/Resources/ConnectorNotices。安装后的 1PUX、KDBX 不需要 Python、Homebrew 或源码。可选的 1Password 在线连接仍需用户自行安装并授权官方 op CLI。

在项目根目录执行下列命令。本轮环境为 Xcode 27.2、XcodeGen 2.46.0、Python 3.14、Node.js 及 iOS 26.5 模拟器。构建需要访问 Package.resolved 所列的 Swift 依赖或其已有缓存，以及锁文件对应的 Python 包。

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r tools/connectors/requirements-lock.txt
python3 -m venv build/f14-pack-env
build/f14-pack-env/bin/python -m pip install -r tools/connectors/requirements-build.txt
python3 scripts/build.py mac
python3 scripts/package-mac.py
python3 scripts/build.py ios
python3 scripts/build.py cli
python3 scripts/validate.py
```

Mac 固定路径是 `build/GCSA-PBsync.app`。以 `open -n build/GCSA-PBsync.app --args --profile "$PWD/build/clean-acceptance"` 启动空配置，需选用尚未使用的目录。在新 iPhone 模拟器安装 `build/apple/Build/Products/Debug-iphonesimulator/PBsync.app`。将 `fixtures/format-v1/synthetic-v1.pbsync` 放在该模拟器可浏览的文件夹，通过「从备份连接」选取文件。合成样本的口令与恢复密钥位于同目录的 `expected.json`。预期读到 12 项。真实备份应单独保管解密材料。

`python3 scripts/validate.py --release-check --ui-receipt <实操回执.json>` 运行相同套件并检查发布条件。本地测试错误返回 1，发布条件未齐返回 2。未提供界面回执会标为待实操。回执记录实操现象及本次包内主程序和扩展的 CDHash。新包须重做界面检查。详见 `scripts/candidate_checks.py` 中的必测操作及 `distribution/open-gates.json` 中的逐项待办。

桌面源码通过独立进程调用 `pykeepass`。锁定环境使用 GPL-3.0 的 pykeepass 4.2.0，另有 XML、密钥派生等传递依赖。公开分发前需复核最终打包组合，提供对应许可、声明及适用的源代码材料。内部镜像位于 build/distribution/PBsync-Mac-版本-构建号.dmg。挂载后将 App 复制到应用目录，弹出镜像后启动。当前只验证 Apple Silicon、macOS 27.0.1 的临时签名包；内置 Python 最低系统标记为 26.0。完成签名及实际安装验收后，分别保留 Mac 分发、TestFlight、App Store 的回执。GitHub 与公开云由负责人另行发布。

生成本地源码候选使用 `build/f14-pack-env/bin/python scripts/prepare-source-kit.py`，固定输出到 `build/distribution/PBsync-source-candidate.zip`。归档包含构建输入、测试、合成样本、依赖许可与逐文件 SHA-256 清单，解压后可按上面的步骤构建。

后续平台可复用同一格式样本。安装 Java 17 或更高版本和 .NET 10 SDK 后，运行 `python3 scripts/platform-vectors.py`。JVM 验算由脚本提取的加密字段，.NET 直接读取备份 JSON。两者用主密码与恢复密钥分别解开同一数据密钥，核对解密正文的 SHA-256，并测试认证标签被改动后的拒绝行为。

实际送审阶段，将导出的两个商店 .app 放入本项目 build 目录，追加参数 `--store-apps MAC_APP IPHONE_APP --team TEAM_ID`。命令核对 Apple 信任链、团队、平台、主包和扩展权限及描述文件。收到真实签名产物后还需用它们的 CDHash 重新记录实操，并逐项完成 open-gates.json 的验收。当前候选按本机签名和模拟器路径验收。
