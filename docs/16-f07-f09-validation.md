# F07—F09 实现与验收记录

2026-11-06。F07 的开发签名受阻，F08 和 F09 部分通过。三项均保留尚待实际验证的原验收条件。仅使用独立测试空间、专用 iOS 模拟器和公开或合成的来源文件。

## F07　真机和系统填充

- Xcode 工程已为主 App 与凭据扩展配置同一 App Group 和自动填充权限。Mac 开发签名与 iPhone 设备构建都已实际尝试。Xcode 报当前团队账号不可用，同时缺少主包及扩展的开发描述文件。设备列表可见已配对的 iPhone 17 Pro Max，Device Hub 显示 iOS 27.0。物理设备没有安装本轮候选。[Mac 签名日志](../build/mac-30.log) · [真机构建日志](../build/ios-26.log)
- 首次运行模拟器候选时，App 明确提示无法访问共享容器。调整模拟器签名设置后，系统回读到分配给主 App 的共享容器。凭据提供器在接受请求时核对具体保险库和条目，选取时重新读取当前版本。[容器回读](../build/f07-f09-20261106-170427/simulator-appgroup.txt)
- 待验收的实际场景包括真机独立 WebDAV 和文件提供器同步、Mac 关机后的补传、Safari 网页及 iPhone App 填充、Mac 邮件／Outlook／Steam 登录，以及 Slack 跳转网页再返回。继续验收需要 Xcode 中可用的开发团队与描述文件、已解锁设备和专用测试登录场景。

## F08　外部保险库

Mac 在「同步与连接」中按目标保险库配置 KDBX 或 1Password CLI 来源。首次连接先预览，再确认。解锁后定期核对来源，以库 ID、条目 ID 和上次导入基线区分来源更新、本地修改及两端冲突。来源缺失保留本地条目，授权或身份失效会暂停连接。Mac 开发候选使用本项目虚拟环境运行随包连接器。

实际操作中，先用 KeePassXC 2.8.0 创建带附件的 KDBX，再从 Mac 界面选文件、输入测试库口令、预览并连接。KeePassXC 保存时会原子替换文件，最初导致连接中断。修复后，在 KeePassXC 新增第 3 项，Mac 自动导入。独立进程重新解锁 PBsync 文件，确认从 2 个条目、2 个版本增至 3 个条目、3 个版本。下一轮界面显示更新与冲突均为 0。[更新前](../build/f07-f09-20261106-170427/auto-before.json) · [更新后](../build/f07-f09-20261106-170427/auto-after.json)

另一次独立回读发现，PyKeePass 能打开的早期 KDBX 3.1 候选被 KeePassXC 拒绝，原因是头部摘要过期。修复后，KeePassXC 打开候选、读到改名条目并导出附件。逐字节核对附件成功，原文件 SHA-256 一致。KDBX 写回沿用「生成候选 → 来源客户端核对并合并」。[来源及迁移回执](../build/f07-f09-20261106-170427/migration-verification.json)

1Password CLI 需要已授权的专用账号和保险库。当前环境完成了实现与合成测试，真实账号的授权、撤销、重连及跨客户端变更仍待验证。此连接只读取指定库。两个来源均未开放自动覆盖写回。开发签名 Mac 沙盒内对外部解释器、所选文件及候选输出目录的权限也须单独验收。

## F09　Safari 与迁移

| 验证对象 | 本轮结果 |
| --- | --- |
| iOS 26.5 模拟器 Safari | 在系统设置中选择书签并成功导出 ZIP。中文 Safari 生成本地化的文件名，早期版本只查找英文名而失败。修复后 PBsync 读取真实 ZIP，导入「个人收藏」文件夹，再添加一个验收网址并导出 ZIP。通过「我的 iPhone → 下载」选择 PBsync 文件后，系统要求设备密码。回导成功及回导后读取指定网址尚待认证。[原始包](../fixtures/safari-zh-simulator.zip) · [系统认证画面](../build/f07-f09-20261106-170427/safari-import-auth.png) |
| Mac Safari 与物理 iPhone | Mac 缺独立测试用户，普通 Safari 用户场景共用书签。保留两个系统的原生导出、回导、重复导入及移动／删除验收。 |
| 1PUX | 最终 Mac 包从「导入文件」实际打开样本，列出两个库。选择 Personal、预览 8 项、确认合并，界面及独立解锁回读均为 8 项。[Mac 界面导入回读](../build/f07-f09-20261106-170427/final-mac-import.json) 使用 KeePassXC 上游互操作样本，两个库分别迁入 8 项和 1 项，包含 18,422 字节附件。重复导入新增／更新数均为 0。9 个导入记录的来源 JSON 与解包原件逐项一致，附件内容与包内文件逐字节相同。[字段与附件回读](../build/f07-f09-20261106-170427/onepux-fidelity.json) 未映射字段保留原始记录。该样本来自公开仓库，现场从真实 1Password 账号新建并导出全类型库仍待验证。[上游样本及哈希](../build/f07-f09-20261106-170427/upstream.json) |
| KDBX 和 CSV | KeePassXC 实际生成 KDBX、导出 CSV，PBsync 分别迁入 3 项和 1 项。与 1PUX 合并后，目标库回读为 13 项、13 个版本。该结果覆盖上述样本。目录结构、插件行为、未知扩展以及全部类型在不同客户端的等价性仍需逐项验收。 |
| 通行密钥 | 接入 Apple 系统凭据交换的接收、选定目标库和预览流程，支持从单条通行密钥发起导出。P-256 交换测试保留凭据 ID，用迁移前登记的公钥验证迁移后对新挑战的签名，错误挑战被拒绝。该测试使用框架数据对象。系统到系统交换及真实网站登录仍待有权限的设备和对端。 |

[Apple 系统凭据交换接口](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager) · [Safari 用户场景共享规则](https://support.apple.com/en-ie/105100)

## 统一测试与产物

最终 Mac 候选为 **Ver 3.0 (43)**，iPhone 模拟器候选为 **Ver 3.0 (44)**，后者已安装到专用模拟器。两包主程序及其凭据扩展均已回读版本和 Bundle ID。Mac 为本机临时签名。因新增外部库连接及系统交换等多项功能，本轮按项目约定升至 3.0。[Mac 产物](../build/product-mac-43.json) · [模拟器产物](../build/product-ios-44.json)

最终一轮统一测试通过 **63 项**，包括 Swift 38、Python 18、扩展 7，另通过独立密码学校验。此前同一套件中的本地服务六方并发创建测试出现过一次连接重置。保留该轮失败记录，原用例单独连续复测三次及最后整套复测均通过。该现象尚未确定根因，本轮未改动服务或该用例。[最终统一结果](../build/validation-20261106-173404/summary.json) · [曾失败的记录](../build/validation-20261106-173203/python.log) · [三次单测复核](../build/f07-f09-20261106-170427/concurrency-recheck.out)

继续实机验收需要有效的 Apple 开发签名、可用的专用 1Password 账号、独立的 Mac Safari 测试用户，以及在设备上完成系统认证。测试仅使用本地资料，没有发布。

## 补验　公开 1Password 样本与 iPhone 模拟器

按用户确认，手机侧先使用 iPhone 17 Pro Max 模拟器，Safari 回导的设备认证保留待验。沿用本报告的候选版本。

- Proton Pass 仓库提供了完整的 1PUX 测试文件。PBsync 的随包连接器按库读取，5 个库分别为 0、12、4、1、1 条。逐库导入、重新解锁和计数一致，重复导入均增加 0 个版本。已逐项比较全部 18 条原始记录。[Proton 固定版本样本](https://github.com/ProtonMail/WebClients/blob/43ba5f750c48e87e4ea322d7ecd8529f4a3135ec/packages/pass/lib/import/providers/1password/mocks/1password.1pux)
- Bitwarden 仓库提供脱敏的导出数据对象。本轮将数据封装为 1PUX 测试包。7 条的库完整导入，重复导入新增 0 项。另一个库共 21 条，样本引用了未附带的附件，连接器拒绝整库导入。该库保留为缺附件的负向样本。[Bitwarden 固定版本样本](https://github.com/bitwarden/clients/blob/ba30ea55001fde3e5b3de47b08d0339ef9c116bf/libs/importer/src/importers/spec-data/onepassword-1pux/sanitized-export.ts) · [逐库回执](../build/f07-f09-20261106-170427/public-fixtures/readback.json)
- 在 iOS 26.5 模拟器运行 PBsync 3.0 (44)，通过「从备份连接」选择由 Proton 的 12 条记录生成的 PBsync 加密库，输入测试口令后看到新库。独立核对模拟器共享容器中的副本，与输入逐字节相同，解锁读到 12 项、12 个版本。1PUX 解析在桌面执行，手机验证的是恢复加密备份。[模拟器回执](../build/f07-f09-20261106-170427/public-fixtures/simulator-result.json)

这两份公开资料用于离线文件迁移。此次搜索没有找到发布者明确授权用于登录、修改和撤销的公开在线测试库，1Password CLI 持续连接保留待验。
