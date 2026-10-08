# 操作与恢复

脚本：`scripts/repair-codex-web-link.ps1`，支持 Windows PowerShell 5.1 和 PowerShell 7。CLI 只处理 `%APPDATA%\Codex\web\Codex`，不接受任意数据路径；默认 Inspect。脚本的内部函数用于临时目录测试，不是面向用户的路径绕过接口。

## 只读检查

在 PowerShell 设置脚本的实际路径。若安装在默认技能目录：

```powershell
$repairScript = Join-Path $env:USERPROFILE '.codex\skills\codex-windows-memory-leak\scripts\repair-codex-web-link.ps1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript -Action Inspect
```

如果设置了 `CODEX_HOME` 或从仓库直接使用，调整 `$repairScript` 指向实际脚本。`ExecutionPolicy Bypass` 只用于该次启动，不修改系统执行策略。

输出为 JSON，包含目录状态、链接类型、目标与环境信息。读取结果中的错误/警告，不要仅凭命令启动成功判断安全。`Ordinary` 或转换的 `OrdinaryNoOp` 表示已经是普通目录；不应重新创建链接。

## 转换

保存工作，完全退出 Codex，**从 Windows 开始菜单重新打开独立 PowerShell**。不要使用 Codex 内的终端。脚本检查正在运行的 Codex 和已安装的 MSIX 包，不会自动杀进程。

在独立 PowerShell 重新设置 `$repairScript` 后先预览：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript -Action Convert -WhatIf
```

预览验证路径和复制计划，不创建暂存目录、备份或状态文件。确认检查适用、备份空间足够，再执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript -Action Convert
```

浏览器数据可能包含登录状态等隐私。暂存副本会占用约一份数据目录的磁盘空间，原目标不被删除；备份和状态 JSON 也不要上传到 GitHub或发到公开聊天。

转换顺序：检查父目录/目标/内部 reparse points → 复制到相邻普通目录 → 对比相对路径、文件长度与 SHA-256，重新核对源内容 → 记录恢复信息 → 将原链接改名保留 → 将暂存目录改名到原路径 → 验证转换结果。拒绝套娃链接、特殊重解析点、无法读取的文件和存在旧恢复状态的冲突。

校验覆盖文件的主数据流内容，不承诺 NTFS ACL、备用数据流、时间戳、硬链接身份或其他目录元数据一致。若目录依赖自定义权限、EFS 或备用数据流，应先单独评估，不能把内容复制当作完整文件系统克隆。Windows PowerShell 5.1 若无法识别链接类型/目标，脚本会安全拒绝，不猜测目标。

成功输出 `Status: Converted`，同时给出 `BackupPath` 和 `RollbackStatePath`。原链接备份为相邻的 `Codex.codex-memory-repair-backup-<随机值>`，状态文件为：

```text
%APPDATA%\Codex\web\Codex.codex-memory-repair.rollback.json
```

保留这两项和原链接目标。重新打开 Codex 验证功能，再按 [诊断](diagnosis.md) 观察内存。需要释放旧泄漏内存时，由用户保存工作后手动 Windows“重启”；脚本不自动重启。

## 回滚

同样先退出 Codex，在独立 PowerShell 执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript -Action Rollback -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript -Action Rollback
```

Rollback 使用固定的本次状态文件验证备份链接和目标。它将当前普通目录保留为相邻的 `Codex.codex-memory-repair-current-data-<随机值>`，再恢复原链接，不删除任何数据。以 JSON 的 `CurrentDataBackupPath` 为准。

**修复后新增数据仍在保留的普通目录里，旧链接目标不会自动得到这些更新。** 如果需要保留新增数据，关闭应用后先比较两侧内容；数据库/浏览器配置有冲突时不要直接混拷。恢复链接也可能恢复原来的泄漏触发条件。

## 中途失败

不要删除暂存目录、备份或原目标，也不要手工把 JSON 状态改成“成功”。记录脚本输出，检查原路径、备份路径、暂存路径和 JSON 的 Status。`Prepared` 或读不到完整状态时，自动 Rollback 可能拒绝执行；需先明确替换实际完成到哪一步，由代理或熟悉 PowerShell 的人检查后恢复。

若替换失败且原链接已恢复，状态会记录为 `Aborted`，并保存 `FailureStage`、`RecoveryStatus` 等诊断字段。先用 Inspect 确认原链接及目标仍正确；这时无需再次 Rollback。若决定重试，确认恢复无误后，把旧状态文件改名归档，再重新预览；不要删除它来掩盖未解决的失败。

状态更新使用同目录临时文件与原子替换，保留上一版 JSON 为相邻审计副本。异常时也可能留下诊断临时文件；保留到恢复完成。`Prepared` 且实际已经换成普通目录时，Rollback 会尝试基于现存链接备份恢复；它仍会拒绝不一致或缺失的备份。

错误处理以保留可恢复数据为优先，不保证断电/磁盘故障下的事务一致性。单次失败后停止盲目重试。状态文件已存在时，先判断上次转换/恢复的真实状态，不能用删除状态文件来绕过冲突检查。
