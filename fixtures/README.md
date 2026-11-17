# 合成测试数据

这些文件由 scripts/make-fixtures.py 生成，全部是虚构账号与 example.com 网址，不含个人数据。30 个收藏、7 个目录（三层嵌套）、12 条 CSV 登录项。synthetic.1pux 用于格式与范围测试，不是 1Password 实际客户端导出证据。

F07—F09 回归样本包括专用中文 iOS 模拟器通过 Safari 导出的空收藏目录包，以及 KeePassXC 2.8.0 CLI 建立的 KDBX 3.1 合成库。库口令为 `Synthetic-KeePass-Only-2026`，用于复测候选头部摘要与附件。
