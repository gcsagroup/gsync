# 工程、依赖与运行约定

更新日期：2026-11-06

## 源码结构

- `Sources/PBsyncCore`：加密空间、不可变版本、历史、存储、迁移、格式、凭据算法和本机通信。
- `Sources/PBsyncApp`：SwiftUI Mac／iPhone 客户端。
- `Sources/PBsyncCLI`：脚本与验收入口、本机消息宿主。
- `apps/Apple`：XcodeGen 工程与凭据提供器。
- `extensions/browser`：同一来源生成 Chromium 与 Firefox 包。
- `tools/connectors`：桌面外部来源工具。
- `services/local`：仅监听本机的 WebDAV／密文服务。
- `Tests`、`tests`、`fixtures`：集中测试及合成样本。

## 格式与密码学参数

开发格式为 JSON 外层、AES-256-GCM 认证加密内容。主密码使用 CommonCrypto PBKDF2-HMAC-SHA256，32 字节盐，600,000 次迭代；恢复密钥为 32 字节随机秘密。对象认证绑定空间 ID、格式版本、密钥代次和对象 ID，正文包括全部条目、附件、原始来源字段及历史。

这是可测试的开发格式，不是第三方安全审计结论。参数仍需在真实 iPhone、Android／Windows 后续实现中测量。原生编辑器中达到 64 KiB 的新增附件独立加密并按需下载，单附件上限 10 MiB。小文件和旧历史可内联，真机耗电待测。参见[F10—F12 实测](17-f10-f12-validation.md)。

冲突使用混合逻辑时钟和固定设备／操作身份决胜；因果后继保持较新，双方历史都保留。物理时钟异常时界面提示，不承诺判断现实时间的绝对先后。全新设备无法仅凭一个自洽旧快照证明它是最新版本。

## 主要同步位置迁移

先合并旧位置、复制完整状态到空的新位置、回读核对，再使用版本条件冻结旧位置，最后切换本地配置并生成新的密钥与恢复材料。旧数据不删除。旧设备看到冻结标记后拒绝继续提交；未同步内容留在原设备供核对。

无法保证在所有 NAS／网盘上同时冻结已离线或恶意设备。撤销存储凭据、密钥轮换、删除设备记录是不同操作；已下载的旧明文不能远程擦除。迁移中途失败时保留候选和源库，必须根据实际阶段恢复，不能自动清空目标重试。

## 外部依赖

| 依赖 | 用途 | 许可证／处理 |
| --- | --- | --- |
| Apple CryptoKit、CommonCrypto、Security、AuthenticationServices | 加密、钥匙串、系统填充 | 系统框架，按 Apple SDK 使用条款；不是项目自有开源实现 |
| ZIPFoundation 0.9.20 | Safari 书签 ZIP 的内存读写 | MIT，固定版本见 Package.resolved |
| Python 标准库 | 本地服务、构建与导入包防护 | Python 发行许可证 |
| pykeepass 4.2.0 | 可选桌面 KDBX 读写工具 | GPL-3.0；公开分发时需落实对应源代码和许可证义务 |
| cryptography | 独立测试验证 P-256 签名 | Apache-2.0 OR BSD-3-Clause；仅测试环境使用 |
| pykeepass 传递依赖 | XML、KDF、KDBX 容器 | 锁定版本记录在 requirements-lock.txt，完整许可证清单由安装元数据生成 |

正式项目许可证未选择，不私自写入 MIT、Apache 或 GPL 的整体授权声明。可选工具采用独立进程不能自动证明分发组合免于任何许可证义务；公开源码／App 打包前单独审查。Mac 70 号起随包带 CPython、文件连接器及第三方声明，打包工具版本在 requirements-build.txt。iPhone 不包含此运行时。

## 签名与验收环境

Mac 固定路径 `build/GCSA-PBsync.app`，单独验收资料目录 `build/acceptance`。临时签名 Mac 包不启用共享容器，不会谎称系统提供器已完成配对。正式 Apple 工程保留共享容器与凭据扩展声明；需选定开发团队并通过实际签名、安装和权限操作。

本轮设备列表可以识别配对的 iPhone 17 Pro Max，开发签名阻塞见[最新报告](16-f07-f09-validation.md)；模拟器与真机结果分别记录。Aegis 只走扩展，不读取或修改浏览器源码。没有使用 Docker，没有公开部署。

## 构建与结果追溯

每次执行 scripts/build.py 都递增构建号并写入 build/build-history.jsonl；失败构建也保留编号和日志。测试编译同样递增编号。最终报告必须引用真实 App 构建号，不能用较新的测试编号冒充 App 已重新打包。

**F03 修复后的实际结果：** XcodeGen 及四个 Info.plist 使用构建变量，构建脚本回读主 App 与凭据扩展的版本、身份和数量；不一致即失败。Mac 临时签名执行完整验证。当时 Mac 为 Ver 1.0 (13)，iPhone 模拟器包为 Ver 1.0 (14)，两者仍不代表正式分发签名通过。

**F02 安全限制：** KDBX 始终保留源文件，仅生成并回读校验候选，拒绝 `--apply` 原地写回。来源在生成期间发生变化时明确标注；外部客户端持续写回仍未完成。详见[专项报告](14-f01-f03-validation.md)。
