# GCSA-PBsync

个人收藏夹与保险库的跨平台开发项目，包含 macOS、iOS、Android 和 Windows 客户端，以及数据核心、浏览器扩展和本地验证服务。产品范围与原始验收标准见 [文档导航](docs/README.md)。

**当前开发版本为 Ver 5.1。** 已验证的构建为 Android (136)、iOS 模拟器 (137)、Windows (138) 和 Mac (139)。Apple 客户端使用 Swift／SwiftUI，Android 使用 Java 和原生界面，Windows 使用 C++／Win32，编译器运行库静态链接。Android 和 Windows 的构建入口见 [Android 构建说明](apps/Portable/README.md)及 [Windows 构建说明](apps/Windows/README.md)。

收藏夹支持目录浏览、移动与排序，密码库提供搜索及条目管理。Android 指纹和 iOS Face ID 已通过模拟器的重启后解锁检查。Mac Touch ID 已核对启用入口，实际指纹解锁待验。Windows 11 已核对无交互远程会话中的主密码回退，Hello 成功解锁待交互桌面验收。真机、各来源持续同步和正式分发分别按专项记录验收。此前的 iPhone 流程见 [模拟器验收记录](reports/2026-11-17-iphone-simulator.md)，浏览器实测见 [修复验收记录](reports/2026-11-10-sync-repair.md)。

## 本机运行

Apple 源码构建需要 Xcode、Swift、XcodeGen、Python 3 与 Node.js。Apple 核心使用系统 CryptoKit、CommonCrypto、Security、LocalAuthentication 和 AuthenticationServices，Safari 书签 ZIP 使用 ZIPFoundation 0.9.20。Mac 文件连接器随构建打包，使用时可直接处理 1PUX 与 KDBX 文件。

```sh
python3 -m venv build/f14-pack-env
build/f14-pack-env/bin/python -m pip install -r tools/connectors/requirements-build.txt
python3 scripts/build.py mac
python3 scripts/package-mac.py
open build/GCSA-PBsync.app --args --profile "$PWD/build/acceptance"
```

每次构建会递增 `BUILD_NUMBER`；Mac App 固定输出到 `build/GCSA-PBsync.app`。默认本机临时签名，用于开发界面与数据流程；系统凭据提供器的真实使用仍需正确开发团队、共享容器授权与真机验收。不要向开发候选放入真实密码。

```sh
python3 scripts/build.py ios
python3 scripts/build.py cli
```

iPhone 模拟器包位于 `build/apple/Build/Products/Debug-iphonesimulator/PBsync.app`；模拟器包不是可直接安装到真机的分发包。Apple 工程定义位于 `apps/Apple/project.yml`，由构建脚本统一生成。

## 生物识别解锁

- Android、iOS 和 Mac 可以在本机副本的主密码解锁界面开启生物识别。Android 使用系统支持的强生物识别，iOS 使用 Face ID 或 Touch ID，Mac 使用 Touch ID。收藏夹和密码库各自开启。
- Windows 11 在解锁本机副本后提供 Windows Hello 入口。系统可以使用已配置的指纹、人脸或 Hello PIN。快速解锁只在本次程序运行中有效。
- 初次连接、新设备和恢复加密备份仍需要主密码或恢复密钥。

## 统一测试

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r tools/connectors/requirements-lock.txt
python3 scripts/make-fixtures.py
python3 scripts/package-extension.py
python3 scripts/validate.py
```

测试仅使用合成数据，统一运行密码学、合并、恢复、存储、外部格式、扩展和服务测试，并保存日志。实际 Mac 操作与桌面浏览器接入见专项报告，Safari 导入、iPhone 真机、真实 NAS 和外部测试账号仍需分别留证；自动化通过不能替代这些结果。

## Mac 书签接入

仅书签扩展 2.1.3 自动协调写回。对于经实测的浏览器版本、单一且可核对的配置、已有纯网址目录，原生通道可在现有网址前插入或修改标题。删除直接由浏览器书签接口执行，整目录先删子项再删父项；移动、末尾追加、空目录、文件夹操作、混排和无法确认的配置也自动使用扩展。原生写入回执不确定时先核对实际书签；原生新增结果未能唯一识别时暂缓这一轮，避免重复创建。[Edge 和 Aegis 的逐项测试及 iPhone 方案](docs/02-compatibility-and-feasibility.md#edge-和-aegis-自动选路)

在「同步与连接」中仅选择收藏夹，启用「Mac 解锁期间允许此收藏夹后台同步」后生成配对密钥。每个配置首次确认合并后，扩展自动传播本地变动并定期拉取。Mac 会话锁定、睡眠、手动锁库或退出 PBsync 后暂停。

在「同步与连接」为已解锁的收藏夹开启「Safari 文件后台交换」，可从固定输入目录合并书签并写出 Safari ZIP。普通配置使用 `~/PBsync-书签交换/<收藏夹标识>/`，独立 `--profile` 使用该资料下的 `书签交换/`。来源依次查找 `待导入/Safari-收藏夹.zip`、`Safari-收藏夹.html`、`Bookmarks.html`，输出放入 `已导出/`。后台失败显示状态，手动检查文件可选择并记住替代路径。旧文件不会重复导入，文件缺项不触发删除，内容相同的输出不会重复写入。覆盖旧输出前保留历史副本。App 运行且收藏夹解锁时处理，锁屏、手动锁定或退出时暂停。**Safari 导入仍由 Safari 端完成。**

## 扩展

`build/extensions/chromium` 用于 Chrome／Edge／Aegis 的开发者加载；Firefox 包位于 `build/extensions/firefox`。仅书签版位于 `build/extensions/chromium-bookmarks` 与 `build/extensions/firefox-bookmarks`。每种浏览器都需要单独验收。

```sh
python3 scripts/install-native-host.py --browser chrome --extension-id 扩展ID --profile "$PWD/build/acceptance"
```

为 Chromium 系浏览器添加 `--bookmark-profile` 并指定实际日常配置目录，可启用原生书签写入候选。宿主只读取该目录的书签和配置标识来核对目标，数据变更由浏览器自身执行。省略此参数时使用扩展写入。该命令只在你明确指定浏览器后安装本机通信清单。已有不同清单会拒绝覆盖。Aegis 需明确 `--manifest-dir`，脚本不猜测或修改另一个项目。配对密钥在 App 的“同步与连接”中生成，粘贴到扩展设置。消息在扩展与 App 之间进行认证加密；默认填充需要 App 确认。

## 外部来源

`tools/connectors/connector.py` 处理合成或用户主动提供的 1PUX／KDBX，以及明确授权的 1Password CLI 保险库。秘密使用受控环境或交互输入，不放到命令参数中。连接器输出可能包含明文，请通过受控管道交给 `pbsync import --format connector`，或使用权限为 0600 的临时文件并按明确生命周期处理。

KDBX 仅生成候选、独立重新加载并核对未知字段与附件，始终不替换原文件；`--apply` 会明确拒绝。候选附带来源 SHA-256 和生成期间来源是否变化的状态，需在来源客户端核对与合并；这不是持续双向写回完成。1Password CLI 在缺少经验证的原子版本条件时拒绝自动覆盖，不把“预览候选”描述成双向同步完成。

本机临时签名构建升级后，旧来源的登录钥匙串访问可能需要重新授权。连接页仍可浏览，授权入口位于「连接来源」中的「恢复来源钥匙串授权」。

## 本地云与 WebDAV

`services/local/server.py` 只监听 `127.0.0.1`，不打开公网端口。凭据从项目之外或 `build` 中的专用测试秘密文件读取，数据根目录只保存密文对象。文件夹本身不提供跨设备传输；需要用户选择可在设备间传输的目录提供器。

## 许可证与发布

项目源码托管于 [gcsagroup/gsync](https://github.com/gcsagroup/gsync)。正式项目许可证尚待项目负责人选择。桌面可选 `pykeepass` 使用 GPL-3.0，相关依赖及分发影响见 [依赖说明](docs/11-engineering-and-dependencies.md)。各端安装包与商店分发的状态以相应构建和验收记录为准。
