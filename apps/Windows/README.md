# PBsync Windows

Windows x64 客户端使用 C++ 和 Win32。编译器的 C++ 标准库与线程库静态链接，发布物是一个 `PBsync.exe`。程序使用 Windows 自带的 WinHTTP、CNG、系统控件和 Universal CRT API，用户可以直接启动 EXE。

## 构建和验收

在仓库根目录运行，构建机需要 MinGW-w64 x64 工具链和 Python 3。

```sh
python3 -B scripts/build-windows.py --tests
```

输出路径为 `build/windows/PBsync.exe`，构建号沿用仓库版本登记。编译用 JSON 头文件版本和摘要固定，MIT 许可作为资源随 EXE 保存。`build/windows/imports.txt` 记录 DLL 导入检查。交叉编译输出需在 Windows x64 上实测。

测试选项同时生成 `build/windows/VaultCheck.exe` 与供无桌面会话绘制截图的 `build/windows/WindowCheck.exe`。`tests/ui-check.ps1` 驱动 Windows 实际控件，`tests/fixture-dav.ps1` 只在回环地址提供隔离样本服务。两份脚本用于验收。`PBsync.exe` 可单独复制和启动。

## 数据与同步

收藏夹、密码库和同步状态各有独立页面。客户端复用 PBsync v1 备份、主密码、恢复密钥和 WebDAV 版本文件。保险库与设备标识位于 `%LOCALAPPDATA%\PBsync`。旧备份可直接打开，同一路径已有副本时恢复操作会提示保留当前副本。

解锁并连接后，已连接空间会轮流定时同步，保存修改后也会尝试上传。重开应用后需要再次解锁和连接。WebDAV 正常使用 HTTPS，HTTP 仅允许本机回环验证。浏览器、KeePass 和 1Password 来源适配需按各来源单独验收。

## 连接 Edge 收藏夹

1. 运行 `python3 -B scripts/package-extension.py` 生成书签扩展，或解压已生成的 `pbsync-chromium-bookmarks.zip`。在 `edge://extensions/` 开启开发人员模式，加载解包目录并复制扩展 ID。
2. 在当前 Windows 用户的 PowerShell 里运行一次注册脚本。

   ```powershell
   .\scripts\install-native-host-windows.ps1 -Browser Edge -Exe 'C:\PBsync\PBsync.exe' -ExtensionId '<扩展 ID>'
   ```

3. 解锁 Windows PBsync 收藏夹，在「同步与连接」中点击「复制配对密钥」。在扩展弹窗粘贴密钥，选择「连接并预览」后确认首次合并。

后续通过书签事件和定时任务同步。保持 PBsync 运行并解锁收藏夹，浏览器可后台读写；锁定收藏夹后连接暂停。Windows 配对密钥由已解锁的保险库和本机身份派生，授权记录独立保存。密码库数据仍通过 App 管理。

本机消息宿主由浏览器启动同一个 `PBsync.exe`，注册信息和扩展权限只包括需要接入的浏览器和扩展。卸载当前用户的 Edge 注册可运行 `install-native-host-windows.ps1 -Browser Edge -Remove`。扩展安装和首次确认使用浏览器自己的界面。[Microsoft Edge 本机消息](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/native-messaging)
