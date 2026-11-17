# PBsync Android

Android 客户端使用 Java 和 Android 原生控件，可打开既有 `.pbsync` 备份，或连接已经初始化的 WebDAV 空间。收藏夹与密码库各自使用一个同步目录。

- 底部导航包含收藏夹、密码库和同步。收藏夹可按标题或网址搜索，密码库也可按用户名搜索。条目菜单提供移动、回收站和恢复操作。
- 同步页显示两类空间的连接状态，以及当前运行期间各空间最近一次成功同步的时间。
- 收藏夹和密码库支持新建、编辑及恢复，密码库可以单项显示密码。
- 保存后尝试同步。解锁并连接后，也会在界面打开期间定时同步。重新打开应用后需要解锁和连接。
- 浏览器和密码管理器的来源接入、Android 系统级后台任务需要单独验证。

## 构建

在仓库根目录使用 Gradle 9.6.1、JDK 17 或更高版本和 Android SDK Platform 35。

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
python3 -B -c 'import sys; sys.path.insert(0,"scripts"); import build; print(build.bump("android-debug"))'
gradle -p apps/Portable :android:assembleDebug
```

调试安装包位于 `build/portable/android/outputs/apk/debug/android-debug.apk`。调试版可通过回环地址连接隔离 WebDAV，正式配置要求 HTTPS。

界面图标使用 Google Material Icons 4.0.0，Apache 2.0 许可随 Android 安装包保留。[上游图标](https://github.com/google/material-design-icons/tree/4.0.0)

Windows 构建说明见 [PBsync Windows](../Windows/README.md)。
