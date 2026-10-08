# Codex Windows 内存泄漏规避 Skill

将 Windows 商店版 Codex 的 `%APPDATA%\Codex\web\Codex` 目录链接安全替换成内容一致的普通文件夹，规避与该链接访问相关的内存泄漏。作者已在自己的机器上确认有效。

**适用范围：** Windows MSIX Codex、该路径为 Junction/SymbolicLink，并出现系统非分页池持续增长。一般进程内存占用或已经是普通目录，不应直接使用转换操作。社区提出的 `bindflt.sys` 机制尚不能视为 Codex 官方根因确认，详见 [证据与诊断](codex-windows-memory-leak/references/diagnosis.md)。

## 作者实测环境

2026-10-08 从本机读取：

| 项目 | 版本 |
|---|---|
| Windows | Microsoft Windows 11 家庭版 中文版，64 位 |
| 显示版本 | 26H2 |
| OS 完整构建号 | 26300.9457 |
| Codex 商店包 | OpenAI.Codex 26.1002.7124.0，Store 签名 |
| ntfs.sys 文件版本 | 10.0.26100.8875 |
| bindflt.sys 文件版本 | 10.0.26100.9278 |

**历史版本（作者反馈）：Windows 11 25H2 也出现过同类 Codex 内存泄漏问题。** 当时的完整 OS 构建号、驱动版本和 Codex 版本未记录，不能沿用上表的 26H2 环境数据。本次没有单独复测 25H2 上的修复效果。

上表是制作时的本机环境记录，未追溯修复当日是否为同一构建，也不表示只支持此版本。截图里的 `ntfs.sys 10.0.26100.9444` 与本次读取不同；这里以本次实读为准，未用截图覆盖本机信息。

## 安装

克隆仓库，将 `codex-windows-memory-leak` 文件夹复制到你的 `$CODEX_HOME/skills`；未设置 `CODEX_HOME` 时通常为 `%USERPROFILE%\.codex\skills`。保留原文件夹结构。若已有同名 skill，先比较/备份，避免覆盖自定义内容。

在 Codex 中调用：

```text
使用 $codex-windows-memory-leak 检查我的 Windows Codex 内存泄漏，先只检查是否适用。
```

## 使用

阅读 [SKILL.md](codex-windows-memory-leak/SKILL.md)。默认 Inspect 只读；Convert/Rollback 支持 WhatIf，必须在完全退出 Codex 后通过独立 PowerShell 执行。脚本保留原目标、原链接及修复后数据，拒绝不安全路径，不自动重启电脑。

完整命令和恢复流程见 [操作说明](codex-windows-memory-leak/references/operation.md)。后续用户的真实内存改善需要按自己的版本和负载验证。

## 开发验证

`tests` 中的隔离测试只操作临时数据，不操作真实 Codex 浏览器目录。制作过程中已确认作者的目录为普通文件夹，未重复执行其已完成的修复。

PowerShell 5.1 和 PowerShell 7 均通过 11 项检查，覆盖内容校验、Unicode 路径、普通目录重复执行、回滚保留新写入、WhatIf 无改动、内部链接拒绝、替换失败恢复、路径冲突保护、状态写入失败、取消执行和环境保护。该验证不替代其他电脑上的功能/内存实测。

在仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\repair-codex-web-link.tests.ps1
pwsh -NoProfile -File .\tests\repair-codex-web-link.tests.ps1
```

本项目采用 [MIT 许可证](LICENSE)。
