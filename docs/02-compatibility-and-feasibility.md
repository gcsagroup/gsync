# 兼容性与可行性

文档版本：0.1  
更新日期：2026-11-07（北京时间）  
状态：下表记录接入范围，Mac 原生读写结果见本页实测记录。

## 1. 判断原则

分别判断四种能力：读取来源、写回来源、在自有设备间同步、向网站或 App 填充。它们不能互相代替。

以下“接口支持”只说明存在开发入口；连接器安装、权限、字段保真、后台运行和错误恢复仍需验证。表中“未确认”不表示证明永久不可能，也不构成首版支持承诺。

状态用语统一为：**有公开入口／待原型验证／手动交换／当前接口不支持／未核查**。各端的实际测试结果单独记录。

## 2. 收藏夹矩阵

| 来源与平台 | 官方能力依据 | 本产品目标与验证重点 | 阶段 |
| --- | --- | --- | --- |
| Chrome 桌面 | 可读写收藏夹、监听变化，需权限；见 [S01](08-references.md#s01) | 全量树同步；根目录映射、排序、批量导入、配置文件隔离 | 首轮 Mac，后续 Windows |
| Edge 桌面 | 收藏夹接口兼容性有支持记录；见 [S02](08-references.md#s02) | 同类扩展适配；不能用 Chrome 测试代替 Edge 实测 | Mac 兼容验证，后续 Windows |
| Firefox 桌面 | `bookmarks` 有公开支持；见 [S02](08-references.md#s02) | 独立打包与权限验证；全量同步、事件差异与签名分发 | 首轮 Mac，后续 Windows |
| Aegis 桌面 | 本机 Aegis 提供 Chromium 书签扩展接口与 Mac 脚本字典 | Mac 优先验证原生接入，扩展自动通道作为备选 | 首轮 Mac |
| Safari Mac | 官方文件导入、导出；见 [S04](08-references.md#s04)、[S05](08-references.md#s05) | 保留手动交换；验证文件结构、重复导入和目录顺序 | 首轮 |
| Safari iPhone／iPad | 官方文件导入、导出；见 [S06](08-references.md#s06)、[S07](08-references.md#s07) | 用户在本机操作；不依赖 Mac，不承诺持续监听或完整覆盖已有树 | 首轮 iPhone，后续 iPad |
| Firefox Android | 当前兼容性数据标记 `bookmarks` 未支持；见 [S02](08-references.md#s02) | 不能直接移植桌面收藏夹扩展；另行评估官方迁移路径 | 后续能力调查 |
| Firefox iOS | 不支持桌面 Firefox 扩展；见 [S03](08-references.md#s03) | 不承诺通过同一扩展接入原生收藏夹 | 后续能力调查 |
| Chrome／Edge Android、iOS | 本次未完成各版本扩展及文件入口核查 | 不把桌面能力外推到移动端；用户仍可在本产品 App 使用独立收藏库 | 后续能力调查 |

收藏夹全量同步仅适用于已验证可读写的连接；Safari 手动交换是明确例外。浏览器内置账号同步与本产品同时启用可能重复传播，必须验证去重与回环，不能默认关闭用户原有同步。

### Mac 原生书签接口实测（2026-11-07）

Chrome、Edge、Aegis 的 Mac 应用包都声明了书签 Apple Events 接口。PBsync CLI 可通过 `inspect-native-bookmarks --pid <进程号>` 核对指定进程的书签栏与其他书签，输出条数、目录数、混排目录数及有序内容摘要。默认只查询已有授权；显式加 `--request-permission` 才会请求系统授权。Chrome 日常配置实读 315 条网址、19 个目录，其中 2 个目录既有文件夹也有网址。

隔离 Chrome 156.0.8078.81 的结果决定了当前可启用的范围。

| 原生操作 | 回读结果 |
| --- | --- |
| 在同类现有条目前创建网址、改名、删除 | 三项成功，删除后保留原有两条网址。[回执](../build/native-crud-cy2ro3jz/result.json) |
| 在空目录中创建目录 | 浏览器进程退出，系统崩溃记录指向原生创建事件。[回执](../build/native-crud-12sa9sbl/result.json) |
| 将网址移动到文件夹后面 | 浏览器进程退出，连接返回 -609。[回执](../build/native-crud-10sx8nvj/result.json) |

原生写入暂缓切换到日常配置。Chromium 将文件夹和网址作为两个集合写入，原生属性能读出实际顺序，但插入接口难以表达任意混排。其原生书签模型还依据上次使用的配置选择数据。后续启用自动写入需要逐端验证目标配置、空目录与跨类型顺序。已配对的扩展目前承担自动同步，手动操作用于配对与恢复。[Chromium 实现](https://github.com/chromium/chromium/blob/main/chrome/browser/ui/cocoa/applescript/bookmark_folder_applescript.mm)

Firefox 的 Places 接口运行在浏览器内部，书签和历史共用数据库，同步状态和变更计数由 Places 维护。直接写入运行中浏览器的配置文件不作为接入路径。桌面 Firefox 的本机临时扩展仅在本次浏览器会话有效，常驻安装须有签名。Safari 继续使用书签文件交换。[Firefox Places](https://firefox-source-docs.mozilla.org/browser/places/architecture-overview.html) · [Firefox 同步引擎](https://firefox-source-docs.mozilla.org/services/sync/engines.html)

### Edge 和 Aegis 自动选路

2026-11-07 分别启动隔离的 Edge 156.0.4314.58 和 Aegis 155.0.8059.40，每项直接原生操作都有独立测试配置。两个浏览器均成功在同类现有网址之前新增、改名并删除书签。同一目录中把第二条网址移到第一条之前时，两者均返回错误码 5，进程继续运行。[Edge 直接调用](../build/native-pair-C580yt/edge.json) · [Aegis 直接调用](../build/native-pair-C580yt/aegis-permission/aegis.json)

在真实扩展、本机消息宿主和合成共享库组成的集成测试中，两端在同一次同步序列分别执行原生新增、原生改名、扩展移动、原生删除，通过浏览器原生树逐项回读。原生可用范围仅含纯网址、非空目录中的已测操作。移动、末尾追加、根类型不适配、混排、权限缺失、版本不在验证范围内或磁盘与内存不一致时，选路器在写入前使用扩展。原生请求发送后回执不明时先核对结果；新增期间持久化身份映射恢复所需信息。[Edge 选路回执](../build/native-pair-C580yt/edge-7YVDXH/route.json) · [Aegis 选路回执](../build/native-pair-C580yt/aegis-live-o2qjz3en/receipt.json)

当前日常三端都加载 2.1.1，仅申请书签、存储、本机消息和定时器权限。本机源文件只用于与进程和目标 GUID 交叉核对；运行中版本、包版本、配置记录必须匹配验证版本。实测期间日常 Edge 的已加载引擎为 154.0.4258.37、Chrome 为 155.0.8059.85，这两者落在扩展路径。Aegis 的运行版本符合原生选路条件。日常三端独立读回均为 315 条网址、19 个目录，两个目录混排，有序摘要相同。

### iPhone 上如何看到同一套收藏夹

| 希望书签出现的位置 | 推荐路径 | 需要验证的边界 |
| --- | --- | --- |
| PBsync iPhone App | Mac 和 iPhone 分别解锁同一加密收藏库，连接同一 WebDAV 目录；也可选双方都能访问的文件提供器 | iPhone 可独立访问远端。当前代码在解锁、保存、前台期间及返回前台时同步。系统挂起后无常驻轮询 |
| Chrome、Edge、Firefox 的原生书签页 | Mac 端先用 PBsync 合并，再使用同品牌账号同步到 iPhone。由本人决定是否将书签存入对应服务，并核对所选数据类别 | 首次云端合并保留两侧原有内容。需实机检查目录、新增和删除，以及回到 Mac 后是否重复传播 |
| Safari 的原生书签页 | Safari 与 PBsync 用官方书签文件合并一次。使用同一 Apple 账号并开启 iCloud Safari 时，Apple 负责 Mac Safari 与 iPhone Safari 间同步 | 其他浏览器以后新增的书签仍需再次与 Safari 交换。iCloud Safari 也会同步其他 Safari 数据 |
| Aegis iOS 的原生书签页 | 建议在 Aegis 自己的 BrowserDataStore 内接入收藏库，直接读取选定远端，不依赖 Mac 在线 | 当前 BrowserBookmark 记录有身份、标题、网址与创建时间，完整目录、同级顺序和删除同步仍需设计与真机验证 |

iOS 沙箱限制第三方 App 访问其他 App 的私有文件。桌面 Apple Events 写回不能迁移到 iPhone。上表的同品牌接力是可用产品能力组合，本轮未登录厂商账号或在用户手机上部署验证。[Apple 沙箱](https://support.apple.com/guide/security/sec15bfe098e/web) · [Safari 与 iCloud](https://support.apple.com/guide/icloud/mm5400ef10c4/icloud) · [Chrome iOS](https://support.google.com/chrome/answer/165139?co=GENIE.Platform%3DiOS) · [Edge](https://support.microsoft.com/en-us/edge/sign-in-to-sync-microsoft-edge-across-devices) · [Firefox iOS](https://support.mozilla.org/en-US/kb/sync-bookmarks-logins-and-browsing-history-firefox)

## 3. Safari 结论与范围变更

曾提出的组合条件为：Safari 原生收藏夹持续双向同步、iPhone 独立运行、App Store 发布。现有资料未提供满足该组合的公开路径：

1. 标准 `bookmarks` 扩展接口在 Safari 与 Safari iOS 上未支持。[S02](08-references.md#s02)
2. BrowserKit 提供用户通过系统面板发起的数据转移，要求接入应用符合浏览器相关条件；它不是可任意读取 Safari 数据库的授权。[S08](08-references.md#s08)、[S09](08-references.md#s09)
3. Safari Services 提供阅读列表添加、网页扩展及文件迁移入口，没有由本次核查确认的完整收藏夹持续读写入口。[S29](08-references.md#s29)
4. 私有 API 或越过数据访问范围不符合本项目的公开发布路线。[S10](08-references.md#s10)

用户随后接受：**Safari 改为手动导入、导出。** 不再把旧的自动同步条件作为首版阻塞，也不把 Safari 整体从产品目标删除。

首轮使用 Safari 官方文件流程；独立保险库 App 不为获得 BrowserKit 资格伪装成完整浏览器。是否有合理的 BrowserKit 后续集成另行评估，不改动 Aegis 来绕过资格条件。

## 4. 密码来源矩阵

| 来源 | 已有依据 | 可先做的验证 | 不能提前承诺 |
| --- | --- | --- | --- |
| 自有保险库 | 本项目设计，尚无实现 | Mac↔iPhone 密文同步、恢复、各类条目与填充 | 已安全审计、已支持所有类型或设备 |
| Apple「密码」 | 文件迁移入口与凭据交换接口分别存在；见 [S06](08-references.md#s06)、[S12](08-references.md#s12) | 用户主动迁移；具体系统、参与应用、类型和字段验证 | 获得自动填充权限后就能持续读写 Apple 全部密码 |
| Google 密码管理工具／Chrome 内置密码 | 官方迁移文档；桌面 CSV 流程有说明；见 [S18](08-references.md#s18) | 密码导入导出；Passkey 通过实际系统的官方交换流程单独验证 | 通用后台双向 API，或 CSV 能承载 Passkey |
| Edge 内置密码 | 桌面导出 CSV 有官方说明；见 [S20](08-references.md#s20) | 桌面导入来源解析，目标写回流程另测 | Android／iOS 同样提供该导出入口，或扩展可读全部内置密码 |
| Firefox 内置密码 | 桌面 CSV 导出、导入有官方说明；见 [S19](08-references.md#s19) | 密码文件迁移，主密码与系统验证流程 | 书签 API 权限自动包含密码库读写权限 |
| Aegis 内置密码 | 尚未核查实际实现 | 原生导出是否存在、格式与权限；扩展只使用允许的接口 | 因为我们拥有另一个项目就可绕过解锁或直接读取数据文件 |
| 1Password 桌面 | 1PUX／CSV 导出，CLI 条目读写；见 [S13](08-references.md#s13)、[S14](08-references.md#s14) | 1PUX 完整导入；CLI 在用户授权下小范围读写，再测连接器 | CLI 可永久无人值守运行，或所有字段／附件均无损往返 |
| 1Password 手机 | 官方支持通过凭据交换迁移到参与应用；见 [S13](08-references.md#s13) | 在用户 iPhone 与测试库验证主动交换，包括 Passkey | 手机持续双向监控 1Password，或桌面 CLI 可在 iOS 原样运行 |
| KeePass／KDBX | 格式与合并规则公开；见 [S16](08-references.md#s16)、[S17](08-references.md#s17) | KDBX 读取、写回、历史、删除标记、附件与密钥文件互操作 | 任意 KDBX 版本、插件算法、客户端扩展字段全部兼容 |

**1Password 授权约束：** 桌面集成存在会话授权、有效期和锁定撤销，连接器应进入“需要授权”状态而不是循环弹窗或绕过授权。是否适合日常双向连接仍需原型。[S15](08-references.md#s15)

**独立运行边界：** iPhone 访问自有保险库不得依赖 Mac。若外部来源仅有桌面连接器，其新数据进入自有库仍依赖该连接器上线；必须明确显示该来源待同步，不能把这一来源包装成“手机独立持续同步”。

## 5. 完整保险库与迁移保真

| 类型 | 首版设计目标 | 外部迁移要求 |
| --- | --- | --- |
| 网站／App 密码 | 保存、历史、更新、填充 | 核对多网址、用户名、备注、App 身份与字段类型 |
| TOTP | 保存种子、生成验证码、可用场景填充 | 保存算法、位数和周期；使用测试向量验证，不把二维码文本误当作验证码 |
| Passkey | 创建、使用、加密同步与可用平台提供器 | 作为独立凭据类型；来源可否导出、目标可否导入、导入后能否认证逐项测试 |
| 恢复码 | 加密保存、显示、复制和修改记录 | 不保证系统自动识别是否已被网站使用 |
| 银行卡、身份、安全笔记 | 可编辑、检索、同步与导出 | 不把系统支付令牌或 Apple Pay 当作普通银行卡数据迁移 |
| 附件、自定义字段 | 加密保存、完整性校验和按需读取 | 对未知字段保留加密原始表示；无法安全写回时阻止破坏性写回 |

用户主动凭据交换不是后台同步。不能因为已有 Passkey 对象格式，就宣称外部库中的硬件绑定凭据均可导出。Apple 的凭据导入管理器是实际可调查的入口，尚无本项目互操作证据。[S12](08-references.md#s12)

## 6. 自动填充与保存

| 场景 | 路线 | 验证与限制 |
| --- | --- | --- |
| Chrome／Edge／Firefox／Aegis 网页 | 扩展与本地保险库协作 | 表单、多账号、跨域 iframe、伪装域名、锁定状态、更新保存 |
| iPhone Safari 与 App | 系统凭据提供器 | 官方允许第三方提供器参与填充；实际目标 App、Passkey、TOTP 与保存能力分别验证；见 [S11](08-references.md#s11)、[S12](08-references.md#s12) |
| Mac Safari | 系统提供器／必要的 Safari 扩展 | 与收藏夹接口限制无关；签名、分发、授权及解锁流程需实测 |
| Mac 桌面 App | 优先公开系统机制，必要时研究显式授权的辅助方式 | 不承诺任意输入框均可识别，不默认开启全局键盘监听 |
| Android 网站／App | Credential Manager 与 Autofill 适配 | 是向系统提供自有凭据，不是读取其他提供器的全部数据；见 [S21](08-references.md#s21) |

Mac 样本为 Apple 邮件添加普通邮箱、Outlook 添加 IMAP 邮箱、Steam 客户端账号密码登录。不同邮箱供应商可能跳转网页登录；Slack 用于测试跳转浏览器再返回，不能计为桌面原生输入框通过。[S25](08-references.md#s25)—[S28](08-references.md#s28)

## 7. 自备存储与后台运行

- **WebDAV：** 先探测读写、认证、条件写入、目录列举、容量和网络错误。具体 NAS 产品须登记版本，不能只测一个开发服务就宣传通用兼容。[S24](08-references.md#s24)
- **本地文件夹：** 单机目录本身没有跨设备传输能力；放入网盘目录时，传输由文件提供器完成，本产品负责加密、合并、校验和状态区分。
- **iPhone 文件夹：** 通过系统文件选择器获得用户授权，正确处理安全范围 URL、文件协调、权限失效与文件未下载。某个网盘可在“文件”中显示，不代表支持完整目录读写及可靠多端同步。[S23](08-references.md#s23)
- **iOS 后台：** 独立运行不等于永久后台在线。前台打开、允许的后台时机和用户主动刷新触发同步；系统调度可能延迟，不能承诺固定秒级后台周期。[S22](08-references.md#s22)
- **锁定状态：** 可研究只传输密文；解密合并、外部来源读取和填充可能等待解锁，必须显示区别。

## 8. 能力声明升级规则

资料存在 → 最小原型 → 双端互操作 → 异常恢复 → 签名真机 → 发布候选。每一步记录操作系统、浏览器／来源版本、样本、复现步骤、结果与限制。

只有完成对应验收的具体组合，才能从“待验证”升级为“支持”。模拟器通过不等于 iPhone 真机通过；App Store 要求满足不等于审核通过；文件导入成功不等于外部双向同步通过。
