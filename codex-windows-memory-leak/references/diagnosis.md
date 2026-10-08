# 诊断与证据

## 已知事实与适用边界

- 2026-10-08，作者明确反馈：自己的 Codex 内存泄漏已通过将浏览器数据目录链接改成普通目录解决。
- 同日只读检查：已安装 `OpenAI.Codex` 商店包；`%APPDATA%\Codex\web\Codex` 的属性是普通 Directory，没有 ReparsePoint。没有在本次制作中重跑修复或重启后内存采样。
- 这证明本机现状与用户反馈一致，不能替代其他机器的测量，也不能证明所有 Codex 内存问题同源。

相关社区调查：[anthropics/claude-code #96870](https://github.com/anthropics/claude-code/issues/96870)。报告者通过复现和池跟踪，将 Windows MSIX 上经 AppData 目录链接的文件访问与 `NtFC` 非分页池泄漏联系起来，并提出 `bindflt.sys` 的缺陷解释；其报告包含移除相关链接访问后的改善。该调查针对 Claude Desktop，为本方案提供机制线索，不是 Microsoft/OpenAI 对 Codex 的官方结论。

微软文档用于理解平台行为：[打包桌面应用的文件与注册表虚拟化](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes)、[重解析点](https://learn.microsoft.com/en-us/windows/win32/fileio/reparse-points)、[快速启动和休眠](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/distinguishing-fast-startup-from-wake-from-hibernation)。这些文档说明平台机制，不宣称验证了本规避方案。

[OpenAI 故障排查](https://learn.chatgpt.com/docs/reference/troubleshooting) 提供通用反馈/日志建议；制作时查阅的页面没有确认此具体根因或规避方案。不要根据截图中的“微软没有修复”推断当前系统状态，必要时重新查阅针对实际 Windows 版本的官方更新记录。

## 作者 Windows 版本记录

2026-10-08 本机只读读取：Windows 11 家庭版 中文版（64 位），DisplayVersion **26H2**，完整 OS 构建 **26300.9457**；OpenAI.Codex 商店包 **26.1002.7124.0**；`ntfs.sys` 文件版本 **10.0.26100.8875**，`bindflt.sys` 文件版本 **10.0.26100.9278**。

2026-10-08 作者补充反馈：此前使用 **Windows 11 25H2** 时也发生过同类 Codex 内存泄漏。此前完整 OS 构建号、驱动版本、Codex 版本及测量记录未知；这是作者的历史问题反馈，本次没有单独复测 25H2 上的修复效果，也不能将社区报告中的 25H2 构建号当成作者的版本。

当前 26H2 环境的版本来源：注册表 `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` 的 DisplayVersion/CurrentBuildNumber/UBR、`Win32_OperatingSystem`、`Get-AppxPackage` 和系统驱动文件 VersionInfo。没有公开用户名、设备名、序列号或原始日志。

截图记载的 `ntfs.sys 10.0.26100.9444` 与本次实读不同。不能据此推断当时的 Windows 构建或更新状态；本次读取的数据记为制作时环境，而不是经过追溯的修复当日环境。

## 只读采样

使用语言无关的 CIM 类，避免英文性能计数器路径在中文 Windows 上失效：

```powershell
$m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
[pscustomobject]@{
    Time = (Get-Date).ToString('o')
    NonpagedPoolMB = [math]::Round([double]$m.PoolNonpagedBytes / 1MB, 2)
    PagedPoolMB = [math]::Round([double]$m.PoolPagedBytes / 1MB, 2)
    CommittedMB = [math]::Round([double]$m.CommittedBytes / 1MB, 2)
}
Get-Process -Name Codex -ErrorAction SilentlyContinue |
    Select-Object Id, ProcessName,
        @{Name='PrivateMB';Expression={[math]::Round($_.PrivateMemorySize64 / 1MB,2)}},
        @{Name='WorkingSetMB';Expression={[math]::Round($_.WorkingSet64 / 1MB,2)}}
```

在空闲基线和代表性操作下分别重复采样，记录时间与负载；例如每分钟一次，观察 10–15 分钟。池指标是全系统数据，其上涨也可能来自别的驱动/程序；单次峰值或短时间变平不能确认根因。若 CIM 不可用，可在任务管理器“性能 → 内存”记录非分页池。

比较相同持续时间/类似操作的趋势：`(末次非分页池 MB - 首次非分页池 MB) / 分钟`。修复后不再持续、近似单调增长且应用功能正常，才可报告“本负载下改善”。不要把某台机器曾出现的每分钟 200–340 MB 写成通用判定阈值。

若仍持续增长：保留数据与备份，不扩大为全 AppData 扫描/转换；检查是否为另一个路径或另一类进程/驱动问题。需要深入归因时，单独开展 PoolMon/WPR 调查；不要为了验证主动大量重复打开链接制造泄漏。
