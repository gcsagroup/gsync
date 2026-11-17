# Android 模拟器与 Windows 远程机验收

2026-11-17，测试构建 **5.0 (112)**。Android 用项目专用模拟器 PBsync_QA，Android 15 / API 35、ARM64。Windows 用专用远程测试机，Windows 11 x64，系统构建 26200。两端沿用 PBsync v1 加密备份与 WebDAV 版本文件。

## 实测结果

- **Android** 从 Windows 远程机的隔离 WebDAV 打开合成收藏夹和包含 12 条内容的密码库。用模拟器界面上移收藏、创建收藏和登录条目，保存后读回上传结果。断开测试存储后，确认拒绝错误主密码，并用恢复密钥重开本机加密副本。
- **Windows** 通过 WinRM 在远程机组装、启动并确认 `PBsync.exe` 的版本。Windows 会话 0 中的界面控件通过了主密码解锁和列表检查。随后在同机运行客户端同步逻辑，读到 Android 新增的两项内容，编辑并回传，收藏还经过删除、恢复和重开本机副本。
- **双向读回** 使用 Windows 回环上的同一个 WebDAV 服务。Android 经 ADB 和 WinRM 中转访问测试服务，在打开的密码库中自动收到 Windows 密码修改，重新连接收藏夹后读到 Windows 改名。macOS 原有命令行工具也从同一存储读到收藏排序、改名和密码修改。
- **回归** 原有 88 项自动检查通过，独立 JVM 和 .NET 加密向量检查通过。全部端到端数据为合成样本。

## 产物与证据

- Android APK：`build/portable/android/outputs/apk/debug/android-debug.apk`，SHA-256 为 `6b3116d041b6dae2fc34149bec40e63b3fc796345dc9e60c52b0d368e5a286f5`。
- Windows 应用目录：远程机上的 `%LOCALAPPDATA%\PBsyncQA\20261117\candidate-112\package\PBsync\`，其中包含 `PBsync.exe` 和运行时。本机 Gradle 输出可用 `build/portable/windows/install/PBsync/bin/PBsync.bat` 在 Windows JDK 环境启动。构建说明见 [Android 与 Windows](../apps/Portable/README.md)。
- 界面及同步记录：`build/android-windows-qa-20261117.kdEnw6/`。重点文件为 `android-bookmark-verified.png`、`windows-interface.png`、`android-readback.log`、`android-recovery.log`、`windows-cross.json` 和 `windows-launch.json`。88 项回归结果在 `build/validation-20261117-180203-530000/summary.json`。

## 下一轮验收范围

Android 定时任务在界面打开且保险库已解锁、已连接时运行，Windows 定时任务在应用运行且保险库已连接时运行。退出重开后需要解锁和连接。隔离中转延迟较高时，Android 在同步请求完成前会阻止锁定和编辑一类操作。Android 系统级后台同步、Windows 登录桌面交互、浏览器收藏及密码接入、KeePass 和 1Password 接入、Android 真机和正式签名包需要单独验收。
