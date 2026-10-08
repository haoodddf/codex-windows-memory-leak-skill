# Codex Windows Memory Leak Workaround Skill

English | [简体中文](README.md)

This skill inspects the Windows Store/MSIX Codex browser-data path and can replace
`%APPDATA%\Codex\web\Codex` with an ordinary directory whose file contents match the
original target. The author reports that this resolved the issue on their machine.

## Scope and evidence

Use this for Windows Store Codex when system nonpaged-pool usage keeps growing and
the path above is a directory `Junction` or `SymbolicLink`. It is not a general
process-memory fix and does not apply to CLI, WSL, macOS, or an ordinary directory.

The suspected `bindflt.sys` mechanism comes from community investigation, not a Microsoft
or OpenAI confirmation of Codex's root cause. The workaround is environment-specific,
not a guarantee for every Codex memory problem. See the [diagnosis and evidence reference (Chinese)](codex-windows-memory-leak/references/diagnosis.md).

The author's recorded environment on 2026-10-08 was (the exact repair-time build was not reconstructed):

| Component | Recorded value |
|---|---|
| Windows | Windows 11 Home, Chinese edition, 64-bit, 26H2 |
| OS build | 26300.9457 |
| Codex Store package | OpenAI.Codex 26.1002.7124.0 |
| `ntfs.sys` | 10.0.26100.8875 |
| `bindflt.sys` | 10.0.26100.9278 |

The author also reported a similar issue on Windows 11 25H2. Its full build, driver
versions, and Codex version were not recorded; this workaround was not separately retested on 25H2.

## Install

Clone this repository and copy `codex-windows-memory-leak` into `$CODEX_HOME/skills`.
When `CODEX_HOME` is unset, the usual Windows location is `%USERPROFILE%\.codex\skills`.
Compare or back up an existing same-named skill before copying; do not overwrite custom changes blindly.

Then ask Codex:

```text
Use $codex-windows-memory-leak to inspect my Windows Codex memory issue; start read-only.
```

Read [SKILL.md](codex-windows-memory-leak/SKILL.md) before any conversion.

## Commands

The production CLI accepts only `Inspect`, `Convert`, and `Rollback`; it always uses the
fixed `%APPDATA%\Codex\web\Codex` path. Set the script path in an independent PowerShell window:

```powershell
$repairScript = Join-Path $env:USERPROFILE '.codex\skills\codex-windows-memory-leak\scripts\repair-codex-web-link.ps1'
```

Adjust `$repairScript` if you use a custom `CODEX_HOME` or run the script directly from the repository.

Inspect is read-only and returns JSON with path, link, target, process, and MSIX package information:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript -Action Inspect
```

For `Convert` or `Rollback`, fully exit Codex and open a normal PowerShell from the Windows Start menu.
Do not run these actions from a Codex integrated terminal or use a script to kill the application. Preview first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript -Action Convert -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript -Action Convert
```

Rollback uses the saved state for that conversion:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript -Action Rollback -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript -Action Rollback
```

The script checks that Codex is closed and the `OpenAI.Codex` MSIX identity is available. It rejects unknown or
nested reparse points, broken targets, unsafe ancestors, and conflicting prior state. It stages an adjacent ordinary
copy, compares relative file paths, lengths, and SHA-256 hashes, retains the original link beside the new directory,
and never deletes the original target.

The comparison covers primary file data streams. It does not promise identical ACLs, alternate data streams,
timestamps, hard-link identity, EFS behavior, or other NTFS metadata. Evaluate custom permissions or browser data
with special metadata separately.

Rollback moves the current ordinary directory aside so new writes are retained, then restores the saved link. New
writes are not synchronized back to the old link target automatically. Keep the backup, state JSON, and retained
directory until the result is verified; do not upload them to a public repository.

The script never reboots the computer. Save work and use Windows **Restart** if you need to release previously
accumulated kernel-pool memory; shutting down and powering on may use Fast Startup and is not equivalent.

After conversion, reopen Codex and check browser, sign-in, and normal application behavior. Compare system nonpaged-pool growth under similar workloads over 10–15 minutes. A brief flat reading is insufficient; other drivers can affect the system-wide metric. If no pre-repair baseline exists, report only the post-repair observations and historical feedback.

See the [operation and recovery reference (Chinese)](codex-windows-memory-leak/references/operation.md) for failure states and recovery rules.

## Validation

The repository's isolated fixture suite passed 11 checks under both Windows PowerShell 5.1 and PowerShell 7,
including Unicode paths, hash comparison, ordinary-directory idempotence, rollback retention, WhatIf, nested-link
refusal, swap failure/collision recovery, state-write failure, ShouldProcess decline, and environment guards. No live
repair was rerun while this package was created.

Run from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\repair-codex-web-link.tests.ps1
pwsh -NoProfile -File .\tests\repair-codex-web-link.tests.ps1
```

Licensed under [MIT](LICENSE).
