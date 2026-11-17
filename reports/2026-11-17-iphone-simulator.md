# iPhone 模拟器同步验收

2026-11-17，独立 iPhone 17 Pro Max 模拟器，iOS 26.5。初装与往返验证使用 Ver 5.0 (104)，修复后在 Ver 5.0 (109) 实际复验重启、前台补传、书签界面和 Safari 填充。Mac 端使用 PBsync 命令行与模拟器 App 连接同一个本机 WebDAV 服务，两种数据使用不同目录。全部使用合成数据。

- **收藏夹**：在模拟器打开远端目录，修改标题和排序。Mac 端下载并核对目录内顺序及空目录。Mac 新增的书签由模拟器自动读入，无需手点同步。[Mac 有序回读](../build/ios-sync-qa-20261117.erle8m/mac-bookmarks-readback.html) · [新版模拟器书签](../build/ios-sync-qa-20261117.erle8m/08-bookmark-order-109.png)
- **密码库**：在模拟器修改、删除、恢复同一合成账号，Mac 逐次读回。恢复保留修改后的密码，同站对照账号未变。Mac 新增账号可自动读入模拟器。[修改回读](../build/ios-sync-qa-20261117.erle8m/password-update-readback.json) · [删除回读](../build/ios-sync-qa-20261117.erle8m/password-delete-readback.json) · [恢复回读](../build/ios-sync-qa-20261117.erle8m/resume-setup-readback.json)
- **备份和锁定**：通过系统文件选择器恢复独立备份。12 条记录和历史逐字节一致，使用主密码独立打开核对。重启后需重新解锁，错误口令被拒；切换到设置应用后，同一进程返回时仍锁定。解锁后自动取得后台期间等待的远端版本。[备份回读](../build/ios-sync-qa-20261117.erle8m/backup-restore-readback.json) · [补传画面](../build/ios-sync-qa-20261117.erle8m/07-foreground-resume-109.png)
- **Safari 自动填充**：在模拟器启用 PBsync 系统提供器，从 Safari 调起扩展并独立解锁。扩展展示匹配站点的合成账号，选择后账号和密码均填入测试表单。到字段回读为止，未提交表单。[原生填充画面](../build/ios-sync-qa-20261117.erle8m/09-safari-autofill-109.png)
- **Safari 书签文件交换**：系统导入入口可选取 PBsync 的 ZIP。选取后 iOS 要求输入系统设备密码，本轮停在认证界面。Safari 端实际写入、导出往返及后台双向仍待完成。[认证画面](../build/ios-sync-qa-20261117.erle8m/06-safari-import-system-auth.png) · [Apple 导入流程](https://support.apple.com/en-ae/guide/iphone/iph63846804e/26/ios/26)

本轮修正窄屏操作栏、移动端 Safari 能力说明、单条删除提示和多个已锁定密码库的区分。最终候选 88 项自动化测试通过，Mac 包与 iPhone 模拟器包版本和签名回读通过。真机、系统签名分发和移动端外部库自动同步仍待单独验收。[自动化记录](../build/validation-20261117-163654-485138/summary.json) · [模拟器包回执](../build/product-ios-109.json)

Windows 和 Android 共用的 v1 加密备份样本在本机 .NET 10 与 JVM 分别通过解密、恢复密钥和篡改拒绝验证。Windows 浏览器宿主、Android 系统凭据和两端原生客户端验收已分列。[跨运行时日志](../build/ios-sync-qa-20261117.erle8m/windows-android-format-vectors.log) · [跨平台计划](../docs/05-development-plan.md#10-m7后续平台与官方云运营)
