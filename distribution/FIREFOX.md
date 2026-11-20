# Firefox 常驻扩展准备与签名

2026-11-20。当前扩展为 2.1.6，Firefox 最低版本 142。默认日常接入只使用“PBsync 书签”，不需要完整保险库扩展的网页权限。

## 当前结果

- 两种 Firefox 扩展均通过 Mozilla `web-ext` 10.8.0 官方检查，0 错误、0 警告。最低版本调整覆盖 `data_collection_permissions` 的兼容要求。
- 归档包含 MIT 许可证。`build/extensions/package-receipts.json` 保存版本、权限、未签名状态和实际 ZIP 的 SHA-256；归档来自源码，不含本机配对密钥、浏览器资料或用户数据。
- `build/extensions/pbsync-firefox-bookmarks.zip` 是待签名包，不能当作已能在正式版 Firefox 常驻安装的成品。

Firefox 正式版要求 Mozilla 签名；自行分发的非公开扩展也要经 AMO 签名。临时加载只保持本次会话，不能用它代替重启验收。[Mozilla 签名与分发说明](https://extensionworkshop.com/documentation/publish/signing-and-distribution-overview/)

## 本机检查

使用 Node.js 22 LTS；本轮使用官方发行包 22.23.5，并核对官网 SHA-256。当前机器的 Node 24.14.0 在加载检查器时发生原生解析器崩溃，未将崩溃算作扩展检查通过。

```sh
python3 scripts/package-extension.py
npm install --prefix build/firefox-signing-tools --no-audit --no-fund --save-exact web-ext@10.8.0
node build/firefox-signing-tools/node_modules/web-ext/bin/web-ext.js lint \
  --source-dir build/extensions/firefox-bookmarks --self-hosted --warnings-as-errors
node build/firefox-signing-tools/node_modules/web-ext/bin/web-ext.js lint \
  --source-dir build/extensions/firefox --self-hosted --warnings-as-errors
```

`node` 应指向上述 Node.js 22。检查只在本机执行，不上传内容；工具命令依据见 [Mozilla web-ext 文档](https://extensionworkshop.com/documentation/develop/web-ext-command-reference/)。

## 等待账号后完成

1. 在 [AMO Developer Hub](https://addons.mozilla.org/developers/) 使用项目负责人账号登录；新账号的开发者协议由本人阅读与接受。
2. 选择自行分发（unlisted），上传仅书签 ZIP，许可证选择 MIT，核对数据收集声明及实际权限。此步骤会把扩展源码提交给 Mozilla 审核，当前没有执行。
3. 获得签名 XPI 后，记录 SHA-256、版本和签名结果；不能只把 ZIP 改成 `.xpi`。
4. 在独立 Firefox 测试资料安装签名包，验证合并、配对保留，以及正常退出、重启后的自动新增、改名、移动和删除；通过后再替换日常临时扩展。

仅书签扩展身份固定为 `pbsync-bookmarks@gcsa.local`，权限为 `bookmarks`、`storage`、`alarms`、`nativeMessaging`。现有日常配对仍使用这个身份；换成完整扩展 `pbsync@gcsa.local` 会改变身份与权限，不能混作同一个升级。

扩展通过认证加密消息向本机 PBsync 传递书签；App 再按用户选择的存储位置同步。包内当前数据声明为 `none`，正式提交时仍需按这条完整数据流核对 AMO 的采集声明，不能把本机检查通过当作隐私声明或人工审核已经通过。
