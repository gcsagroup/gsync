# Windows 原生客户端验收

## 产物

- **PBsync Windows x64 5.0 (117)**，路径为 `build/windows/PBsync.exe`，大小 1,454,592 字节。远程机文件与本机产物的 SHA-256 一致，为 `46751d28cd6443eafb7b51a1ba2bd777031781d84597f312e37815b6a24ba215`。
- Windows 文件用 C++ 和 Win32 构建，编译器的 C++ 标准库及线程库已静态链接。PE 导入表只含 Windows 系统组件，远程启动后读回 36 个模块，全部来自系统目录或主 EXE。Windows 10 和 Windows 11 提供程序所用的 Universal CRT。实测机为 Windows 11 x64，系统构建 26200。[Microsoft Universal CRT 部署说明](https://learn.microsoft.com/en-us/cpp/windows/universal-crt-deployment?view=msvc-170)
- 当前 Windows 构建入口见 [构建说明](../apps/Windows/README.md)。原 Swing 测试源代码移到 `build/windows/legacy-swing-source`，Gradle 中保留 Android 构建入口。

## 界面

按此前确认的效果图实现浅色侧栏、绿色选中态、目录与内容分栏、搜索和密码详情。同步页显示两类数据空间的连接状态和操作，浏览器与外部密码管理器接入仍待单独实现。

- [收藏夹](../build/windows/qa-20261117.ioiJ3m/windows-bookmarks.png)
- [密码库](../build/windows/qa-20261117.ioiJ3m/windows-passwords.png)
- [同步与连接](../build/windows/qa-20261117.ioiJ3m/windows-sync.png)

远程机验收操作在 WinRM 会话 0 通过成品窗口完成。三张图由同一 Win32 绘制代码在远程机离屏生成；用户登录桌面、不同分辨率和 DPI 的视觉验收待补。

## 功能验证

- 成品窗口通过搜索和二次筛选、目录切换、新增收藏和登录条目、显示与隐藏密码，保存后上传到隔离的 WebDAV。
- 原生数据层通过恢复密钥、拒绝错误密码与篡改、保留既有本机副本、目录排序、删除、恢复及重复同步检查。在 Windows 读到 macOS 写入的收藏版本，在 macOS 读回 Windows 创建的目录、恢复的收藏及修改后的密码。
- 原有 88 项自动检查通过。全部跨端数据为合成样本，Windows 测试应用未签名。
- 远程机验收使用 `%LOCALAPPDATA%\PBsyncQA\20261117\native-117\PBsync.exe`。原始记录位于 `build/windows/qa-20261117.ioiJ3m`，包括 `windows-ui-style.json`、`windows-core.json`、`windows-capture.json` 及三张图片。详细回归结果见 `build/validation-20261117-193804-367397/summary.json`。
