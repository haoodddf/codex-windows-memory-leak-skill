[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$helperPath = [IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\codex-windows-memory-leak\scripts\repair-codex-web-link.ps1'))
$helperText = [IO.File]::ReadAllText($helperPath)
try {
    [void][scriptblock]::Create($helperText)
}
catch {
    throw "Helper parser validation failed: $($_.Exception.Message)"
}

. $helperPath

$script:Passed = 0
$script:Failed = 0
$script:ScratchRoots = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)]
        [string]$MessagePattern,
        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )
    $thrown = $false
    try {
        & $ScriptBlock | Out-Null
    }
    catch {
        $thrown = $true
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "$FailureMessage Unexpected error: $($_.Exception.Message)"
        }
    }
    Assert-True -Condition $thrown -Message $FailureMessage
}

function New-ScratchFixture {
    $base = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('codex-memory-link-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $base -ErrorAction Stop | Out-Null
    $script:ScratchRoots.Add($base)
    $target = Join-Path -Path $base -ChildPath 'target'
    $root = Join-Path -Path $base -ChildPath 'Codex'
    New-Item -ItemType Directory -Path (Join-Path -Path $target -ChildPath 'nested') -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path (Join-Path -Path $target -ChildPath '中文目录') -Force -ErrorAction Stop | Out-Null
    Set-Content -Path (Join-Path -Path $target -ChildPath 'a.txt') -Value 'alpha' -Encoding UTF8 -NoNewline
    Set-Content -Path (Join-Path -Path $target -ChildPath 'nested\b.txt') -Value 'beta' -Encoding UTF8 -NoNewline
    Set-Content -Path (Join-Path -Path $target -ChildPath '中文目录\数据.txt') -Value 'unicode data' -Encoding UTF8 -NoNewline
    New-Item -ItemType Junction -Path $root -Target $target -ErrorAction Stop | Out-Null
    return [pscustomobject][ordered]@{
        Base = $base
        Target = $target
        Root = $root
    }
}

function New-NestedReparseFixture {
    $fixture = New-ScratchFixture
    $nestedTarget = Join-Path -Path $fixture.Base -ChildPath 'nested-target'
    $nestedLink = Join-Path -Path $fixture.Target -ChildPath 'nested-link'
    New-Item -ItemType Directory -Path $nestedTarget -ErrorAction Stop | Out-Null
    Set-Content -Path (Join-Path -Path $nestedTarget -ChildPath 'outside.txt') -Value 'outside' -NoNewline
    New-Item -ItemType Junction -Path $nestedLink -Target $nestedTarget -ErrorAction Stop | Out-Null
    return $fixture
}

function Invoke-Test {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )
    try {
        & $Body
        $script:Passed++
        Write-Output ("PASS {0}" -f $Name)
    }
    catch {
        $script:Failed++
        Write-Output ("FAIL {0}: {1}" -f $Name, $_.Exception.Message)
    }
}

Invoke-Test -Name 'parser validation' -Body {
    Assert-True -Condition ($helperText.Length -gt 0) -Message 'The helper script is empty.'
}

$primary = $null
Invoke-Test -Name 'convert copies hashes and preserves target' -Body {
    $primary = New-ScratchFixture
    $script:PrimaryFixture = $primary
    $before = @(Get-CodexFileManifest -DirectoryPath $primary.Target)
    $result = Invoke-CodexRepairAction -Action Convert -RootPath $primary.Root -SkipEnvironmentGuards
    Assert-True -Condition ($result.Status -eq 'Converted') -Message 'Conversion did not report Converted.'
    $rootInfo = Get-CodexLinkInfo -Path $primary.Root
    Assert-True -Condition (-not $rootInfo.IsReparsePoint) -Message 'Converted root is still a reparse point.'
    $after = @(Get-CodexFileManifest -DirectoryPath $primary.Target)
    Assert-True -Condition ((Compare-CodexManifests -Expected $before -Actual $after).Equal) -Message 'The original target changed during conversion.'
    $converted = @(Get-CodexFileManifest -DirectoryPath $primary.Root)
    $comparison = Compare-CodexManifests -Expected $before -Actual $converted
    Assert-True -Condition $comparison.Equal -Message 'Converted directory does not match target files, lengths, and hashes.'
    Assert-True -Condition (Test-Path -LiteralPath $result.BackupPath -PathType Container) -Message 'Saved link backup is missing.'
    Assert-True -Condition (Test-Path -LiteralPath $result.RollbackStatePath -PathType Leaf) -Message 'Rollback state is missing.'
}

Invoke-Test -Name 'ordinary path is idempotent' -Body {
    $result = Invoke-CodexRepairAction -Action Convert -RootPath $script:PrimaryFixture.Root -SkipEnvironmentGuards
    Assert-True -Condition ($result.Status -eq 'OrdinaryNoOp' -and -not $result.Changed) -Message 'Ordinary path conversion was not a no-op.'
}

Invoke-Test -Name 'rollback retains post-repair writes' -Body {
    $newFile = Join-Path -Path $script:PrimaryFixture.Root -ChildPath 'written-after-conversion.txt'
    Set-Content -Path $newFile -Value 'new data' -NoNewline
    # Simulate an interruption after the swap but before the final state update.
    $statePath = Get-CodexRollbackStatePath -RootPath $script:PrimaryFixture.Root
    $state = Get-Content -Path $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $state.Status = 'Prepared'
    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding UTF8
    $result = Invoke-CodexRepairAction -Action Rollback -RootPath $script:PrimaryFixture.Root -SkipEnvironmentGuards
    Assert-True -Condition ($result.Status -eq 'RolledBack') -Message 'Rollback did not report RolledBack.'
    $rootInfo = Get-CodexLinkInfo -Path $script:PrimaryFixture.Root
    Assert-True -Condition ($rootInfo.Status -eq 'KnownLink') -Message 'Rollback did not restore the saved link.'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($result.RetainedCurrentDataPath)) -Message 'Rollback did not report the retained current data path.'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $result.RetainedCurrentDataPath -ChildPath 'written-after-conversion.txt') -PathType Leaf) -Message 'Post-repair write was not retained.'
}

Invoke-Test -Name 'WhatIf performs no change' -Body {
    $fixture = New-ScratchFixture
    $beforeInfo = Get-CodexLinkInfo -Path $fixture.Root
    $result = Invoke-CodexRepairAction -Action Convert -RootPath $fixture.Root -WhatIf -SkipEnvironmentGuards
    $afterInfo = Get-CodexLinkInfo -Path $fixture.Root
    Assert-True -Condition ($result.Status -eq 'WhatIf' -and $result.Changed -eq $false) -Message 'WhatIf did not report a dry run.'
    Assert-True -Condition ($beforeInfo.Status -eq $afterInfo.Status -and $beforeInfo.TargetPath -eq $afterInfo.TargetPath) -Message 'WhatIf changed the link.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $result.RollbackStatePath -PathType Any)) -Message 'WhatIf wrote rollback state.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $result.PlannedStagingPath -PathType Any)) -Message 'WhatIf wrote staging data.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $result.PlannedBackupPath -PathType Any)) -Message 'WhatIf wrote a backup.'
}

Invoke-Test -Name 'nested reparse point is refused' -Body {
    $fixture = New-NestedReparseFixture
    $beforeInfo = Get-CodexLinkInfo -Path $fixture.Root
    Assert-Throws -ScriptBlock {
        Invoke-CodexRepairAction -Action Convert -RootPath $fixture.Root -SkipEnvironmentGuards
    } -MessagePattern 'nested reparse' -FailureMessage 'Nested reparse target was not refused.'
    $afterInfo = Get-CodexLinkInfo -Path $fixture.Root
    Assert-True -Condition ($afterInfo.Status -eq 'KnownLink' -and $afterInfo.TargetPath -eq $beforeInfo.TargetPath) -Message 'Nested reparse refusal changed the root link.'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $fixture.Target -ChildPath 'nested-link') -PathType Container) -Message 'Nested link fixture was unexpectedly changed.'
}

Invoke-Test -Name 'staging swap failure restores original link and marks Aborted' -Body {
    $fixture = New-ScratchFixture
    $before = @(Get-CodexFileManifest -DirectoryPath $fixture.Target)
    $script:CodexSwapFailureStage = 'AfterBackupRename'
    try {
        Assert-Throws -ScriptBlock {
            Invoke-CodexRepairAction -Action Convert -RootPath $fixture.Root -SkipEnvironmentGuards
        } -MessagePattern 'State status=Aborted' -FailureMessage 'Injected staging swap failure did not produce an Aborted recovery outcome.'
    }
    finally {
        $script:CodexSwapFailureStage = $null
    }
    $rootInfo = Get-CodexLinkInfo -Path $fixture.Root
    Assert-True -Condition ($rootInfo.Status -eq 'KnownLink') -Message 'Swap failure did not restore the original link.'
    $statePath = Get-CodexRollbackStatePath -RootPath $fixture.Root
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($state.Status -eq 'Aborted' -and $state.RecoveryStatus -eq 'OriginalLinkRestored') -Message 'Swap failure state did not record recoverable restoration.'
    Assert-True -Condition (Test-Path -LiteralPath $state.StagingPath -PathType Container) -Message 'Swap failure did not retain staging data for review.'
    Assert-True -Condition ((Compare-CodexManifests -Expected $before -Actual (Get-CodexFileManifest -DirectoryPath $fixture.Target)).Equal) -Message 'Swap failure changed the original target.'
}

Invoke-Test -Name 'swap recovery collision retains backup and marks RestoreFailed' -Body {
    $fixture = New-ScratchFixture
    $before = @(Get-CodexFileManifest -DirectoryPath $fixture.Target)
    $script:CodexSwapFailureStage = 'AfterBackupRename'
    $script:CodexSwapFailureCollision = $true
    $failureMessage = $null
    try {
        try {
            Invoke-CodexRepairAction -Action Convert -RootPath $fixture.Root -SkipEnvironmentGuards | Out-Null
        }
        catch {
            $failureMessage = $_.Exception.Message
        }
    }
    finally {
        $script:CodexSwapFailureStage = $null
        $script:CodexSwapFailureCollision = $false
    }
    Assert-True -Condition ($failureMessage -match 'occupied during recovery') -Message 'Recovery collision did not refuse overwriting the unexpected root object.'
    $statePath = Get-CodexRollbackStatePath -RootPath $fixture.Root
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($state.Status -eq 'Aborted' -and $state.RecoveryStatus -eq 'RestoreFailed') -Message 'Recovery collision did not persist RestoreFailed state.'
    Assert-True -Condition ((Get-CodexLinkInfo -Path $fixture.Root).Status -eq 'Ordinary') -Message 'Recovery collision unexpectedly replaced the occupied root object.'
    Assert-True -Condition (Test-Path -LiteralPath $state.BackupPath -PathType Container) -Message 'Recovery collision did not retain the saved link backup.'
    Assert-True -Condition (Test-Path -LiteralPath $state.StagingPath -PathType Container) -Message 'Recovery collision did not retain staging data.'
    Assert-True -Condition ((Compare-CodexManifests -Expected $before -Actual (Get-CodexFileManifest -DirectoryPath $fixture.Target)).Equal) -Message 'Recovery collision changed the original target.'
}

Invoke-Test -Name 'state update failure preserves previous valid JSON and diagnostic temp' -Body {
    $fixture = New-ScratchFixture
    $script:CodexStateWriteFailureMode = 'Update'
    $failureMessage = $null
    try {
        try {
            Invoke-CodexRepairAction -Action Convert -RootPath $fixture.Root -SkipEnvironmentGuards | Out-Null
        }
        catch {
            $failureMessage = $_.Exception.Message
        }
    }
    finally {
        $script:CodexStateWriteFailureMode = $null
    }
    Assert-True -Condition ($failureMessage -match 'previous valid JSON was retained') -Message 'Injected state update failure did not preserve the old-state diagnostic.'
    $diagnosticTemp = ($failureMessage -split 'Diagnostic temp: ')[-1]
    Assert-True -Condition (Test-Path -LiteralPath $diagnosticTemp -PathType Leaf) -Message 'Atomic state writer did not preserve the diagnostic temp file.'
    $statePath = Get-CodexRollbackStatePath -RootPath $fixture.Root
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Condition ($state.Status -eq 'Prepared') -Message 'Previous valid rollback JSON was not retained after state update failure.'
    Assert-True -Condition ((Get-CodexLinkInfo -Path $fixture.Root).Status -eq 'Ordinary') -Message 'State update failure did not leave the completed ordinary swap intact.'
}

Invoke-Test -Name 'ShouldProcess decline performs no change' -Body {
    $fixture = New-ScratchFixture
    $decline = {
        param([string]$Target, [string]$Operation)
        return $false
    }
    $result = Invoke-CodexRepairAction -Action Convert -RootPath $fixture.Root -ShouldProcessCallback:$decline
    Assert-True -Condition ($result.Status -eq 'Declined' -and -not $result.Changed) -Message 'ShouldProcess decline was not reported.'
    Assert-True -Condition ((Get-CodexLinkInfo -Path $fixture.Root).Status -eq 'KnownLink') -Message 'ShouldProcess decline changed the link.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Get-CodexRollbackStatePath -RootPath $fixture.Root) -PathType Any)) -Message 'ShouldProcess decline wrote rollback state.'
}

Invoke-Test -Name 'environment guard refusal blocks Convert and WhatIf' -Body {
    $fixture = New-ScratchFixture
    $script:CodexMutationGuardFailure = 'fixture guard refusal'
    try {
        Assert-Throws -ScriptBlock {
            Invoke-CodexRepairAction -Action Convert -RootPath $fixture.Root
        } -MessagePattern 'environment guard refusal' -FailureMessage 'Environment guard refusal did not block Convert.'
        Assert-Throws -ScriptBlock {
            Invoke-CodexRepairAction -Action Convert -RootPath $fixture.Root -WhatIf
        } -MessagePattern 'environment guard refusal' -FailureMessage 'Environment guard refusal did not run before WhatIf.'
    }
    finally {
        $script:CodexMutationGuardFailure = $null
    }
    Assert-True -Condition ((Get-CodexLinkInfo -Path $fixture.Root).Status -eq 'KnownLink') -Message 'Environment guard refusal changed the link.'
}

try {
    # Remove only these uniquely named scratch fixtures. Reparse links are removed first so a recursive cleanup cannot traverse their targets.
    $resolvedTempRoot = ConvertTo-CodexFullPath -Path ([IO.Path]::GetTempPath())
    $tempRootItem = Get-Item -LiteralPath $resolvedTempRoot -Force -ErrorAction Stop
    if (Test-CodexReparsePoint -Item $tempRootItem) {
        throw "Refusing scratch cleanup because TEMP is a reparse point: $resolvedTempRoot"
    }
    foreach ($base in @($script:ScratchRoots)) {
        $resolvedBase = ConvertTo-CodexFullPath -Path $base
        if ((Split-Path -Parent $resolvedBase) -ine $resolvedTempRoot -or (Split-Path -Leaf $resolvedBase) -notmatch '^codex-memory-link-test-[0-9a-f]{32}$') {
            throw "Refusing scratch cleanup outside the expected TEMP fixture naming contract: $resolvedBase"
        }
        if (-not (Test-Path -LiteralPath $resolvedBase -PathType Container)) {
            continue
        }
        $pending = New-Object 'System.Collections.Generic.Queue[string]'
        $pending.Enqueue($resolvedBase)
        while ($pending.Count -gt 0) {
            $current = $pending.Dequeue()
            $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
            foreach ($item in $children) {
                if (Test-CodexReparsePoint -Item $item) {
                    $itemPath = Get-CodexObjectProperty -Object $item -Name 'FullName'
                    if ([string]::IsNullOrWhiteSpace([string]$itemPath)) {
                        throw 'Refusing scratch cleanup because a reparse entry had no inspectable path.'
                    }
                    # Directory.Delete(..., false) removes the reparse entry itself without traversing its target.
                    [IO.Directory]::Delete([string]$itemPath, $false)
                }
                elseif ([bool](Get-CodexObjectProperty -Object $item -Name 'PSIsContainer')) {
                    $itemPath = Get-CodexObjectProperty -Object $item -Name 'FullName'
                    if ([string]::IsNullOrWhiteSpace([string]$itemPath)) {
                        throw 'Refusing scratch cleanup because a directory entry had no inspectable path.'
                    }
                    $pending.Enqueue([string]$itemPath)
                }
            }
        }
        $remainingReparse = @(Get-CodexNestedReparsePoints -DirectoryPath $resolvedBase)
        if ($remainingReparse.Count -gt 0) {
            throw "Refusing recursive scratch cleanup while reparse entries remain: $(($remainingReparse | ForEach-Object { $_.Path }) -join ', ')"
        }
        if ((Get-CodexLinkInfo -Path $resolvedBase).IsReparsePoint) {
            throw "Refusing recursive scratch cleanup because the fixture root is a reparse point: $resolvedBase"
        }
        [IO.Directory]::Delete($resolvedBase, $true)
    }
}
catch {
    # A failed containment/reparse check preserves the fixture for manual review.
}

Write-Output ("SUMMARY passed={0} failed={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) {
    exit 1
}
