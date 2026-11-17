# 密码同步实测与直接接入边界

日期：2026-11-11。最终要求是各浏览器自带密码库双向同步，先用独立测试账号验证，不能用 PBsync 自有库同步或网页填充代替。用户已明确暂缓 Apple 签名，先完成可做的测试，并要求研究无需手动 CSV 的接口或文件接入。

## 当前结论

**尚未接通所有浏览器内置密码库的自动双向同步，也未通过 Mac 与 iPhone 真机验收。** 已完成 Chrome、Firefox 独立资料的直接读写与原生填充验收：资料关闭后可用，但运行中分别出现数据库锁和旧缓存覆盖外部更新，不能接成持续后台写入。没有导入、导出、修改或删除日常资料中的密码。

新增 `Tests/PBsyncAppTests/PasswordSyncTests.swift`。两个独立 AppModel 经同一个实际密文目录传播新增、修改、删除，同站另一账号保持原值。使用真实桥接处理函数核对修改后的填充内容，删除后拒绝此前签发的填充许可，重新解锁后不恢复已删除账号。密文中没有出现测试口令及测试密码的明文。两个客户端都在 Mac 测试进程内，不能记为 iPhone 已通过。

## 实际浏览器操作

Chrome 157.0.8103.50，通过界面新建未登录的 `PBsync  20261111` 测试个人资料。版本页确认路径为 `~/Library/Application Support/Google/Chrome/Profile 2`；使用独立测试密码库。

1. 官方密码管理器导入唯一合成账号，界面显示导入 1 个密码。本机表单经原生填充提交，站点回执确认密码版本 1。
2. 同账号第二版文件触发“找到 1 个现有密码”，必须选中测试项并点击“替换”。完成后新页面填充提交，站点回执确认版本 2。
3. 官方界面导出至本轮目录。独立检查只有 1 个合成账号，网址和更新后的密码准确保留；没有读取日常资料的导出。
4. 删除该测试项，界面显示密码已删除并恢复空密码列表。重新进入表单，密码为空，提交验证失败；仍出现的用户名是表单历史建议，不是残留的密码填充。测试窗口已关闭，返回原来的日常窗口。

此轮证明 Chrome 自身的新增、更新、导出、删除和填充行为，不证明 PBsync 已连接其内置密码库。CSV 仅作为本轮测试输入及取证，不是后续自动同步方案。

## 不经手动 CSV 的路线

- **Chrome／Edge 等普通扩展**：不能将 Chromium 内部 `passwordsPrivate` 当作公开扩展 API。上游权限定义将其限制于组件扩展，WebUI 接口供内置设置及密码管理页使用。现有 PBsync 日常扩展仅有书签接入，完整扩展处理 PBsync 的保存与填充，不包含浏览器内置密码库同步通道。[上游权限定义](https://chromium.googlesource.com/chromium/src/+/main/chrome/common/extensions/api/_permission_features.json) · [接口上下文定义](https://chromium.googlesource.com/chromium/src/+/main/chrome/common/extensions/api/_api_features.json)
- **Mac 本地库适配**：可以研究，但应视为每种浏览器的专门适配，不能当普通配置文件覆盖。Chromium 使用系统钥匙串中的加密材料；Firefox 的登录数据及密钥分别存放并由 NSS 保护。需要验证授权、当前格式、并发写入、内存缓存、删除记录、云同步冲突及故障恢复。本文未证明直接写回可用。[Chromium 钥匙串实现](https://chromium.googlesource.com/chromium/src/+/HEAD/components/os_crypt/common/keychain_password_mac.mm) · [Mozilla 存储说明](https://support.mozilla.org/en-US/kb/use-primary-password-protect-stored-logins)
- **本机实测限制**：仅对刚新建的 Chrome `Profile 2/Login Data` 尝试只读访问。文件存在，但 SQLite 打开失败，直接读取文件头也返回 `Operation not permitted`。这说明当前工具进程没有完成访问，不证明所有已授权的原生 App 都不能访问。未尝试提取浏览器钥匙串密钥或更改保护设置。
- **自有 Aegis**：建议优先评估在浏览器内部增加受授权的密码库接口，由浏览器自身负责加密与变更通知。这是开发方向，尚未修改 Aegis，也未验收。
- **Safari／iPhone**：Apple 从系统 26 提供系统凭据交换 API，可在参与应用间直接交换而不落 CSV 文件；但过程要由用户在系统界面选择，不能当作任意读取其他 App 私有密码库的后台同步接口。PBsync 现有源码包含系统交换接收和单条通行密钥导出，尚不是全密码双向连接器。Keychain 访问组仍受签名团队限制。[系统交换流程](https://developer.apple.com/documentation/authenticationservices/ascredentialexportmanager) · [Keychain 访问组边界](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)

因此，推荐优先原生接口，再评估 Mac 独立测试库的直接适配；现有证据不支持承诺“所有浏览器和 iPhone 自带密码库均可无人值守双向同步”。

## 继续实施：授权与独立资料适配

用户随后授权继续 Mac 各浏览器接入，限定独立合成账号，优先原生接口，再验证直接读写；要求实际增改删与填充验收。以下覆盖上文早先的权限状态，不表示自动双向同步已经完成。

- 经用户逐项批准，已在系统设置中打开 ChatGPT.app 对 Chrome、Firefox、Edge 的 App 数据访问开关。没有打开“密码”App 数据权限或完全磁盘访问。只读回查 Chrome `Profile 2/Login Data` 成功：版本 43，密码记录为 0；证据为 `build/password-native-20261111/access-after-authorization.json`。
- Chrome 的数据库权限与钥匙串权限是两件事。初次非交互请求 `Chrome Safe Storage` 返回 OSStatus -25293。用户批准并亲自完成一次系统授权后，工具返回 `key_available: true`。后续进程可取得钥匙，使用内存会话完成验收后退出；没有显示或持久化钥匙。电脑工具明确禁止访问 SecurityAgent，没有尝试替代方式操作认证程序。
- Firefox 159.0.1 使用本轮新建的 `build/password-native-20261111/firefox-profile`，首次条款已获用户同意。**修正初步判断：存在 `logins.db` 不等于实际启用 Rust 存储。** 原生界面新增后，账号实际落入 `logins.json`，Rust 两张登录表仍为 0。通过 Firefox 附带的 NSS 库读回并加密写回；脚本在 Rust 表出现记录时拒绝按 JSON 处理。
- Edge 的 `/Applications/Microsoft Edge.app` 当前不存在。已校验 EdgeUpdater 内 157.0.4341.46 的代码签名并启动独立 `edge-profile`，停在首次欢迎及条款页面。已取消设为默认浏览器及可选诊断；等待用户同意条款，未写入测试密码。
- Aegis 的现有本地补丁与 WebUI 处理器检查未找到可供 PBsync 使用的内置密码库 CRUD 桥接；这一检索结果不代表完整源码审计。固定测试版 `~/Applications/GCSA Aegis Test.app` 为 155.0.8059.40，签名校验通过，但 UI 启动返回错误 163，独立进程退出码 -9；无法进行该版本密码实操。未修改、编译、替换或重启正在使用的 Aegis。证据为 `aegis-start-check.json`。
- Safari 的公开凭据交换接口要求用户经系统界面选择导出目标，不等同于后台双向同步；Apple 签名处理仍按此前要求暂缓。[Apple 原生交换流程](https://developer.apple.com/documentation/authenticationservices/ascredentialexportmanager)

新增实验脚本 `scripts/password-native-probe.py` 和 `scripts/firefox-password-native-probe.py`，固定为本轮测试路径、合成账号和本机站点，拒绝其他来源、未知格式与重定向资料路径。提供加密读回、增改删及写前备份；**没有接入产品后台同步**。

### Chrome 直接读写实操

1. 测试资料打开时，写入返回 `database is locked`，回查仍为 0 条。关闭仅测试资料窗口后写入第一版成功；日常 Chrome 窗口保持打开。
2. 重新打开测试资料，本机表单原生填充提交成功，站点确认第一版。关闭测试窗口后直接更新为第二版，重新打开后的实际填充确认第二版。
3. 在 Chrome 自带密码管理页把唯一合成账号改回第一版，关闭测试窗口后直接解密回读，准确识别第一版。
4. 直接删除测试记录，重新打开后密码字段为空，提交验证失败；密码管理页显示空列表。关闭测试窗口，最终数据库 0 条。

使用过账号后，运行中的直接读取也遇到锁。此轮证明关闭资料后的互操作，不证明连续自动同步。证据：`build/password-native-20261111/chrome-direct-verification.json`。

### Firefox 直接读写实操

1. 原生界面新增第一版，通过 NSS 正确读回。首次尝试旧 `PK11SDR_Encrypt` 发现本机库不导出该符号；按当前 Mozilla 实现改用 `PK11SDR_EncryptWithMechanism` 和 AES-CBC 后，真实加密及原生识别通过。
2. **运行中写回失败的实证**：外部把文件更新为第二版，文件读回为第二版；浏览器却仍填充第一版，使用后文件被覆盖回第一版。该实验仅涉及合成账号，已经移除运行中写回选项，脚本默认拒绝此操作。
3. 退出独立 Firefox 后更新第二版，重新启动，实际填充为第二版。原生界面删除后，外部读回 0 条。
4. 退出后直接新增第一版，重启后的实际填充为第一版；再次退出后直接删除，重启后密码为空且提交失败，最终测试文件 0 条。

电脑工具在一次退出后读取 App 状态时意外唤起默认 Firefox 的更新页，已关闭该窗口；未打开日常密码列表或操作日常密码。后续退出改为进程状态核验，避免重开默认资料。证据：`build/password-native-20261111/firefox-direct-verification.json`。

### 本阶段验证

`python3 -W error::ResourceWarning scripts/test-password-native-probe.py`：**12 项通过**，包括临时库增改删与备份、独立 OpenSSL 对照、一次内存授权多步操作、拒绝其他账号与未知格式、拒绝重定向路径、Firefox 运行中拒写，以及 Rust 存储有数据时拒绝按 JSON 操作。初次 SQLite 连接释放警告已修复并重新通过。本阶段实际站点回执共 7 条：Chrome 3 条、Firefox 4 条，均按各阶段预期验证。没有构建或替换 Mac App，版本号未变。

## 测试、版本和剩余项

### 2026-11-16 继续验收 Edge

用户要求继续后重新检查，Edge 不再显示首次条款页，直接进入浏览器；本轮没有代为点击条款确认。实际版本页为 **157.0.4341.60**，虽然启动路径仍含旧目录名 157.0.4341.46。版本页确认资料路径为本轮 `edge-profile/Default`，初始密码 0 条。

通过原生管理器新增唯一合成账号，在本机 `127.0.0.1:62065` 使用原生填充提交，站点确认第一版正确。期间一次粘贴内容没有准确进入网址字段，保存失败；改用直接设置并回读字段后保存成功，最终数据库仅含指定回环网址和合成账号，没有其他条目。运行中的外部只读回查返回 `database is locked`，正常退出独立 Edge 后可以读取元数据。

`Microsoft Edge Safe Storage` 非交互访问返回 **OSStatus -25293**。已询问用户是否允许发起一次 Edge 钥匙串授权，当前等待答复；尚未发起交互提示，未取得钥匙，未尝试真实直接更新或删除。Chrome 的此前授权不等于 Edge 授权。

实验脚本新增固定 Edge 测试路径和独立钥匙串项选择，核对附加表版本，处理合成账号对应的扩展记录，存在云同步状态时拒绝直接操作。修改后 **14 项测试通过**，含 Edge 路径隔离、关联表清理及云同步拒绝；这部分是临时数据库测试，不是 Edge 实际增改删验收。没有构建或替换 Mac App。

阶段证据：`build/password-native-20261111/edge-verification-20261116.json`、`probe-tests-20261116.log`。独立 Edge 已正常退出，**保留 1 个合成账号**等待下一步；没有读取或修改日常密码。原有 Chrome／Firefox 7 条回执保留，本轮增加 1 条 Edge 原生填充回执。自动双向同步仍未接通。

真机构建 92 使用原团队 R3JK7R29AC 失败：账号／证书／描述文件不可用；用户已选择暂不处理签名。本轮没有真机安装，也没有把模拟器或 Mac 双实例计为手机验收。

初次新增用例把同站双账号误作为单账号自动填充场景，产品按规则拒绝，测试失败；调整测试先验证另一账号的反向删除，再验证单账号自动填充。构建 94 测试通过。随后直接运行 XCTest 核对实际计数；首次核心直跑有 1 个本地服务用例跳过，补启动独立回环服务后重新运行完整核心包。最终核心 30、App 19、扩展 16，合计 **65 项通过**。早先口头“49 项全部通过”应以此处明确排除跳过项的最终计数为准。

构建计数由 91 增至 94，版本仍为 4.3。安装运行的 Mac App 仍是 Ver 4.3 (91)，本轮没有重新打包或替换日常 App；没有发布。独立浏览器测试账号已删除，本轮站点在验收后停止；测试资料保留为空密码库。合成 CSV 和测试回执保存在 `build/password-sync-20261111/`，不含真实账号。

剩余项：各浏览器内置密码库的受授权接入和双向变更、实际跨浏览器传播、Mac／iPhone 跨设备同步、真机系统填充、重启及长期运行验证。Edge 还需处理先前旧进程持锁问题，不能沿用 Chrome 结果推断其已恢复。
