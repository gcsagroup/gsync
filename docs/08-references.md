# 参考资料与证据边界

文档版本：0.1  
整理截至：2026-11-06（北京时间）  
状态：本轮讨论及文档整理中查阅的官方资料；不构成产品实测结果

来源页面可能更新，M0 与发布候选阶段应复核版本和行为。此处只保留支持本项目决策的要点，不以搜索摘要、论坛猜测或其他产品宣传代替官方能力证明。

<a id="s01"></a>
## S01：Chrome 收藏夹接口

[Chrome bookmarks API](https://developer.chrome.com/docs/extensions/reference/api/bookmarks)

证明扩展有收藏夹读写和事件接口，需相应权限。不能证明密码访问、移动端兼容或 Aegis 的具体实现。

<a id="s02"></a>
## S02：浏览器收藏夹接口兼容性

[MDN bookmarks 文档](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/bookmarks)；[MDN 兼容性原始数据](https://raw.githubusercontent.com/mdn/browser-compat-data/main/webextensions/api/bookmarks.json)

核查时桌面 Chrome、Edge、Firefox 有支持记录；Safari 与 Firefox Android 对该接口未支持。iOS Firefox 扩展情况另见 S03。兼容性表不是本项目运行结果。

<a id="s03"></a>
## S03：Firefox iOS 扩展

[Mozilla：Add-ons in Firefox for iOS](https://support.mozilla.org/en-US/kb/add-ons-firefox-ios)

Firefox iOS 不能使用桌面和 Android Firefox 扩展。该限制不等于 Firefox 桌面缺少收藏夹接口。

<a id="s04"></a>
## S04：Safari Mac 导入

[Apple：Import data from another browser into Safari on Mac](https://support.apple.com/en-mide/guide/safari/ibrw9ffa6d10/mac)

用户从文件或文件夹导入浏览数据的官方入口；不证明自动监听、全量替换或同步删除。

<a id="s05"></a>
## S05：Safari Mac 导出

[Apple：Export Safari data to another browser in Safari on Mac](https://support.apple.com/en-lamr/guide/safari/ibrwebf10132/mac)

用户可选择数据导出。导出文件可能包含明文敏感内容，产品应选择需要的数据并说明文件性质。

<a id="s06"></a>
## S06：Safari iPhone 导入

[Apple：Import data from another browser into Safari on iPhone](https://support.apple.com/en-ie/guide/iphone/iph63846804e/ios)

官方提供由用户选择文件的导入流程；其中密码进入系统密码 App。具体设备入口和文件行为需真机核对。

<a id="s07"></a>
## S07：Safari iPhone 导出

[Apple：Export Safari data to another browser on iPhone](https://support.apple.com/en-kw/guide/iphone/iph1852764a6/ios)

用户可从 Safari 设置导出选定数据到文件；不能作为后台持续同步能力的证明。

<a id="s08"></a>
## S08：BrowserKit 数据转移

[Apple：Transferring browsing data to another browser](https://developer.apple.com/documentation/browserkit/transferring-browsing-data-to-another-browser)；[BrowserKit](https://developer.apple.com/documentation/browserkit)

用户通过系统面板发起浏览器间数据转移，支持收藏夹及层级等内容。该机制要求接入应用符合浏览器相关条件，不能推断为长期读写 Safari 的权限。

<a id="s09"></a>
## S09：默认浏览器资格

[Apple：Preparing your app to be the default web browser](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser)

说明浏览器能力、资格与受管理权限申请。未从该文档找到授予第三方持续访问 Safari 全量收藏夹的权限。

<a id="s10"></a>
## S10：App Store 发布要求

[Apple：App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/#software-requirements)

关注公开 API、允许的数据访问范围和后台用途。实际审核结论由提交时的规则和审核结果决定；本项目尚未提交。

<a id="s11"></a>
## S11：Apple 凭据提供器

[Apple：Credential provider extensions](https://support.apple.com/en-gb/guide/security/sec6319ac7b9/1/web/1)

第三方密码管理器可提供自有凭据用于自动填充。该权限不等于取得 Apple 自带保险库的全部读写权限。

<a id="s12"></a>
## S12：Apple 凭据交换

[Apple：ASCredentialImportManager](https://developer.apple.com/documentation/AuthenticationServices/ASCredentialImportManager)

参与的凭据提供器可交换密码和 Passkey 等凭据，并需声明支持的交换能力及格式版本。需要验证实际系统、源应用和目标应用组合，不能当作持续同步接口。

<a id="s13"></a>
## S13：1Password 导出

[1Password：How to export your data](https://support.1password.com/export/)

桌面提供 1PUX 与字段受限的 CSV；手机官方凭据交换可覆盖可迁移 Passkey。文件导出与应用间交换的安全特性不同，不能把桌面 CSV 解释为完整保险库导出。

<a id="s14"></a>
## S14：1Password CLI 条目操作

[1Password CLI：item](https://www.1password.dev/cli/reference/management-commands/item)

存在读取、创建和编辑条目的入口。后台运行、附件、自定义字段往返、删除与版本冲突仍需连接器原型。

<a id="s15"></a>
## S15：1Password CLI 授权

[1Password：App integration security](https://www.1password.dev/cli/app-integration-security)

集成受账户授权、会话有效期和锁定撤销约束。不保证长期无人值守，不能用循环弹窗或规避验证代替授权设计。

<a id="s16"></a>
## S16：KDBX 格式

[KeePass：KDBX File Format Specification](https://keepass.info/help/kb/kdbx.html)

说明加密数据库结构、扩展字段和附件等。文档公开不代表本项目已具备兼容解析器；未知版本和字段写回必须验证。

<a id="s17"></a>
## S17：KeePass 合并

[KeePass：Synchronization](https://keepass.info/help/v2/sync.html)

数据库合并按对象处理并保留相关历史。借鉴其对象合并思路，不能以覆盖整个 KDBX 文件代替经过验证的同步。

<a id="s18"></a>
## S18：Google 密码管理工具迁移

[Google：Import or export passwords and passkeys with Chrome](https://support.google.com/chrome/answer/13068232)

官方页面包含迁移说明，桌面密码步骤以 CSV 为主。页面标题涉及 Passkey 不足以证明所有系统和来源支持统一交换；需按实际平台逐项验证。

<a id="s19"></a>
## S19：Firefox 密码迁移

[Mozilla：Export login data from Firefox](https://support.mozilla.org/en-US/kb/export-login-data-firefox)

桌面可导出账号密码为 CSV，并有导入路径。此文件为明文，接口范围与收藏夹扩展权限不同。

<a id="s20"></a>
## S20：Edge 密码迁移

[Microsoft：Export passwords in Microsoft Edge](https://support.microsoft.com/en-us/edge/export-passwords-in-microsoft-edge)

官方说明桌面 CSV 导出，并明确手机端导出限制。不能据此承诺手机密码库持续双向接入。

<a id="s21"></a>
## S21：Android 凭据提供器

[Android：Integrate Credential Manager with your credential provider solution](https://developer.android.com/identity/sign-in/credential-provider)

自有密码库可研究作为系统凭据提供器接入。须分别处理系统版本、Autofill、Passkey 和目标应用差异。

<a id="s22"></a>
## S22：iOS 后台运行

[Apple：Choosing Background Strategies for Your App](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)

后台任务执行时间由系统调度。独立同步不等于永久后台在线，前台补传与状态提示需纳入设计。

<a id="s23"></a>
## S23：iOS 目录授权

[Apple：Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)

用户选择目录后可获得受限访问 URL，读写需要权限管理和文件协调。文件提供器的实际行为需要逐个测试。

<a id="s24"></a>
## S24：WebDAV

[RFC 4918](https://www.rfc-editor.org/rfc/rfc4918.html)

用于条件写入、资源版本和服务器行为设计参考。某服务器实现 WebDAV 不等于具备本产品所需的全部并发保证。

<a id="s25"></a>
## S25：Apple 邮件测试场景

[Apple：Use your Internet accounts on Mac](https://support.apple.com/en-gb/guide/mac-help/mh35565/mac)

普通账号设置可出现账号密码输入；不同提供商可能使用其他授权方式。它是待测场景，不是填充兼容证明。

<a id="s26"></a>
## S26：Outlook 测试场景

[Microsoft：Add an email account to Outlook for Mac](https://support.microsoft.com/en-us/outlook/add-an-email-account-to-outlook-for-mac)

支持添加邮箱，具体流程可能跳转外部授权。测试应分开记录 App 输入框与浏览器授权。

<a id="s27"></a>
## S27：Steam 测试场景

[Steam：Steam Guard Mobile Authenticator](https://help.steampowered.com/en/faqs/view/7EFD-3CAE-64D3-1C31)

官方说明客户端登录与扫码等方式。首轮验证账号密码入口，不把扫码成功当作密码填充成功。

<a id="s28"></a>
## S28：Slack 测试场景

[Slack：Sign in to Slack](https://slack.com/help/articles/212681477-Sign-in-to-Slack-Sign-in-to-Slack)

桌面登录会进入浏览器，适合验证跳转和返回。邮箱验证码、SSO 等流程不能冒充桌面原生密码框填充。

<a id="s29"></a>
## S29：Safari Services

[Apple：Safari Services](https://developer.apple.com/documentation/safariservices)

提供网页、扩展、阅读列表添加和迁移相关入口。阅读列表、主屏幕书签与完整收藏夹树的访问不是同一种能力。
