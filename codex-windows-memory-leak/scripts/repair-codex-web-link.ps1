[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Inspect', 'Convert', 'Rollback')]
    [string]$Action = 'Inspect'
)

Set-StrictMode -Version 2.0

$script:CodexRollbackSchemaVersion = 1
$script:CodexPostRepairWritePolicy = 'Writes made after conversion remain in the ordinary data directory and are not synchronized back to the original target automatically.'
# These hooks stay null in production. Fixture tests use them for bounded failure injection.
$script:CodexStateWriteFailureMode = $null
$script:CodexSwapFailureStage = $null
$script:CodexSwapFailureCollision = $false
$script:CodexMutationGuardFailure = $null

function ConvertTo-CodexFullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$BaseDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A path is required.'
    }

    $candidate = $Path
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        if ([string]::IsNullOrWhiteSpace($BaseDirectory)) {
            $BaseDirectory = (Get-Location).Path
        }
        $candidate = Join-Path -Path $BaseDirectory -ChildPath $candidate
    }

    $full = [IO.Path]::GetFullPath($candidate)
    if ($full.Length -gt 3) {
        $trimChars = [char[]]([string]::Concat([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
        $full = $full.TrimEnd($trimChars)
    }
    return $full
}

function Get-CodexDefaultPath {
    $appData = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    }
    if ([string]::IsNullOrWhiteSpace($appData)) {
        throw 'The Windows roaming AppData path could not be determined.'
    }
    return (ConvertTo-CodexFullPath -Path (Join-Path -Path $appData -ChildPath 'Codex\web\Codex'))
}

function Get-CodexObjectProperty {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-CodexReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    if ($null -eq $Item) {
        return $false
    }
    $attributes = Get-CodexObjectProperty -Object $Item -Name 'Attributes'
    if ($null -eq $attributes) {
        return $false
    }
    return (([IO.FileAttributes]$attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-CodexLinkInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = ConvertTo-CodexFullPath -Path $Path
    $item = $null
    $itemError = $null
    try {
        # Get-Item exposes the reparse-point itself and does not require resolving a target.
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    }
    catch {
        $itemError = $_.Exception.Message
    }

    if ($null -eq $item) {
        return [pscustomobject][ordered]@{
            Path = $fullPath
            Exists = $false
            Status = 'MissingOrBroken'
            IsDirectory = $false
            IsReparsePoint = $false
            LinkType = $null
            TargetPath = $null
            TargetExists = $false
            TargetIsDirectory = $false
            TargetIsReparsePoint = $false
            Error = $itemError
        }
    }

    $isReparse = Test-CodexReparsePoint -Item $item
    $isDirectory = [bool](Get-CodexObjectProperty -Object $item -Name 'PSIsContainer')
    $rawLinkType = Get-CodexObjectProperty -Object $item -Name 'LinkType'
    $linkType = $null
    if ($null -ne $rawLinkType) {
        $linkType = [string]$rawLinkType
    }

    $targetPath = $null
    if ($isReparse -and $null -ne $rawLinkType) {
        $targetValue = Get-CodexObjectProperty -Object $item -Name 'Target'
        $targetValues = @($targetValue)
        if ($targetValues.Count -gt 0 -and $null -ne $targetValues[0]) {
            $targetCandidate = $targetValues[0]
            if ($targetCandidate -is [IO.FileSystemInfo]) {
                $targetCandidate = $targetCandidate.FullName
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$targetCandidate)) {
                $targetPath = ConvertTo-CodexFullPath -Path ([string]$targetCandidate) -BaseDirectory (Split-Path -Parent $fullPath)
            }
        }
    }

    $targetItem = $null
    $targetError = $null
    if ($null -ne $targetPath) {
        try {
            $targetItem = Get-Item -LiteralPath $targetPath -Force -ErrorAction Stop
        }
        catch {
            $targetError = $_.Exception.Message
        }
    }

    $status = 'Ordinary'
    if ($isReparse) {
        if ($linkType -in @('Junction', 'SymbolicLink')) {
            if ($null -eq $targetPath -or $null -eq $targetItem) {
                $status = 'Broken'
            }
            else {
                $status = 'KnownLink'
            }
        }
        else {
            $status = 'UnknownReparsePoint'
        }
    }

    return [pscustomobject][ordered]@{
        Path = $fullPath
        Exists = $true
        Status = $status
        IsDirectory = $isDirectory
        IsReparsePoint = $isReparse
        LinkType = $linkType
        TargetPath = $targetPath
        TargetExists = ($null -ne $targetItem)
        TargetIsDirectory = if ($null -ne $targetItem) { [bool](Get-CodexObjectProperty -Object $targetItem -Name 'PSIsContainer') } else { $false }
        TargetIsReparsePoint = if ($null -ne $targetItem) { Test-CodexReparsePoint -Item $targetItem } else { $false }
        Error = if ($null -ne $targetError) { $targetError } else { $itemError }
    }
}

function Get-CodexAncestorReparsePoints {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = ConvertTo-CodexFullPath -Path $Path
    $parent = [IO.DirectoryInfo]$fullPath
    $parent = $parent.Parent
    $found = New-Object 'System.Collections.Generic.List[object]'

    while ($null -ne $parent) {
        $parentItem = Get-Item -LiteralPath $parent.FullName -Force -ErrorAction Stop
        if (Test-CodexReparsePoint -Item $parentItem) {
            $found.Add([pscustomobject][ordered]@{
                Path = $parent.FullName
                LinkType = Get-CodexObjectProperty -Object $parentItem -Name 'LinkType'
            })
        }
        $parent = $parent.Parent
    }

    return $found.ToArray()
}

function Get-CodexNestedReparsePoints {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    $root = ConvertTo-CodexFullPath -Path $DirectoryPath
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($root)
    $found = New-Object 'System.Collections.Generic.List[object]'

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
        foreach ($child in $children) {
            if (Test-CodexReparsePoint -Item $child) {
                $found.Add([pscustomobject][ordered]@{
                    Path = $child.FullName
                    LinkType = Get-CodexObjectProperty -Object $child -Name 'LinkType'
                    IsDirectory = [bool](Get-CodexObjectProperty -Object $child -Name 'PSIsContainer')
                })
                continue
            }
            if ([bool](Get-CodexObjectProperty -Object $child -Name 'PSIsContainer')) {
                $queue.Enqueue($child.FullName)
            }
        }
    }

    return $found.ToArray()
}

function Get-CodexFileManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    $root = ConvertTo-CodexFullPath -Path $DirectoryPath
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not [bool](Get-CodexObjectProperty -Object $rootItem -Name 'PSIsContainer')) {
        throw "Manifest root is not a directory: $root"
    }
    if (Test-CodexReparsePoint -Item $rootItem) {
        throw "Manifest root is a reparse point: $root"
    }

    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($root)
    $manifest = @{}
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)
        foreach ($child in $children) {
            if (Test-CodexReparsePoint -Item $child) {
                throw "A reparse point was found while building a manifest: $($child.FullName)"
            }
            if ([bool](Get-CodexObjectProperty -Object $child -Name 'PSIsContainer')) {
                $queue.Enqueue($child.FullName)
                continue
            }

            $relativePath = $child.FullName.Substring($root.Length)
            $relativePath = $relativePath.TrimStart([char[]]([string]::Concat([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)))
            $key = $relativePath.ToLowerInvariant()
            if ($manifest.ContainsKey($key)) {
                throw "The directory contains duplicate case-insensitive file paths: $relativePath"
            }
            $hash = (Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
            $manifest[$key] = [pscustomobject][ordered]@{
                RelativePath = $relativePath
                Length = [int64]$child.Length
                Sha256 = $hash
            }
        }
    }

    return @($manifest.Values | Sort-Object -Property RelativePath)
}

function Compare-CodexManifests {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Expected,
        [Parameter(Mandatory = $true)]
        [object[]]$Actual
    )

    $expectedMap = @{}
    foreach ($entry in @($Expected)) {
        if ($null -ne $entry) {
            $expectedMap[[string]$entry.RelativePath.ToLowerInvariant()] = $entry
        }
    }
    $actualMap = @{}
    foreach ($entry in @($Actual)) {
        if ($null -ne $entry) {
            $actualMap[[string]$entry.RelativePath.ToLowerInvariant()] = $entry
        }
    }

    $missing = New-Object 'System.Collections.Generic.List[string]'
    $unexpected = New-Object 'System.Collections.Generic.List[string]'
    $changed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $expectedMap.Keys) {
        if (-not $actualMap.ContainsKey($key)) {
            $missing.Add([string]$expectedMap[$key].RelativePath)
            continue
        }
        $expectedEntry = $expectedMap[$key]
        $actualEntry = $actualMap[$key]
        if ([int64]$expectedEntry.Length -ne [int64]$actualEntry.Length -or [string]$expectedEntry.Sha256 -ne [string]$actualEntry.Sha256) {
            $changed.Add([string]$expectedEntry.RelativePath)
        }
    }
    foreach ($key in $actualMap.Keys) {
        if (-not $expectedMap.ContainsKey($key)) {
            $unexpected.Add([string]$actualMap[$key].RelativePath)
        }
    }

    return [pscustomobject][ordered]@{
        Equal = ($missing.Count -eq 0 -and $unexpected.Count -eq 0 -and $changed.Count -eq 0)
        Missing = @($missing.ToArray())
        Unexpected = @($unexpected.ToArray())
        Changed = @($changed.ToArray())
    }
}

function Get-CodexStorePackageInfo {
    $command = Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return [pscustomobject][ordered]@{
            Available = $false
            Query = 'OpenAI.Codex'
            Packages = @()
            Error = 'Get-AppxPackage is unavailable in this PowerShell session.'
        }
    }

    try {
        $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)
        $records = @($packages | ForEach-Object {
            [pscustomobject][ordered]@{
                Name = [string](Get-CodexObjectProperty -Object $_ -Name 'Name')
                PackageFullName = [string](Get-CodexObjectProperty -Object $_ -Name 'PackageFullName')
                Version = [string](Get-CodexObjectProperty -Object $_ -Name 'Version')
                InstallLocation = [string](Get-CodexObjectProperty -Object $_ -Name 'InstallLocation')
                Status = [string](Get-CodexObjectProperty -Object $_ -Name 'Status')
                Architecture = [string](Get-CodexObjectProperty -Object $_ -Name 'Architecture')
            }
        })
        return [pscustomobject][ordered]@{
            Available = $true
            Query = 'OpenAI.Codex'
            Packages = $records
            Error = $null
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            Available = $true
            Query = 'OpenAI.Codex'
            Packages = @()
            Error = $_.Exception.Message
        }
    }
}

function Get-CodexRunningProcessInfo {
    $records = New-Object 'System.Collections.Generic.List[object]'
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '^(?i:Codex|CodexDesktop|ChatGPT)$'
    })
    foreach ($process in $processes) {
        $records.Add([pscustomobject][ordered]@{
            Id = [int]$process.Id
            Name = [string]$process.ProcessName
        })
    }
    return $records.ToArray()
}

function Test-CodexIsDefaultPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    return ((ConvertTo-CodexFullPath -Path $Path) -ieq (Get-CodexDefaultPath))
}

function Assert-CodexMutationEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    if ($null -ne $script:CodexMutationGuardFailure) {
        throw "Injected mutation environment guard refusal: $script:CodexMutationGuardFailure"
    }
    if (-not (Test-CodexIsDefaultPath -Path $RootPath)) {
        return
    }

    $running = @(Get-CodexRunningProcessInfo)
    if ($running.Count -gt 0) {
        $names = ($running | ForEach-Object { "$($_.Name)#$($_.Id)" }) -join ', '
        throw "The Codex desktop process must be fully closed before conversion or rollback. Running: $names"
    }

    $packageInfo = Get-CodexStorePackageInfo
    if (-not $packageInfo.Available -or @($packageInfo.Packages).Count -eq 0) {
        throw 'The OpenAI.Codex MSIX package identity could not be verified; refusing to mutate the live path.'
    }
}

function New-CodexSiblingPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$Suffix
    )

    $parent = Split-Path -Parent (ConvertTo-CodexFullPath -Path $RootPath)
    $leaf = Split-Path -Leaf (ConvertTo-CodexFullPath -Path $RootPath)
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $candidate = Join-Path -Path $parent -ChildPath ("{0}.{1}-{2}" -f $leaf, $Suffix, ([guid]::NewGuid().ToString('N')))
        if (-not (Test-Path -LiteralPath $candidate -PathType Any)) {
            return $candidate
        }
    }
    throw "Could not allocate a unique sibling path next to $RootPath."
}

function Get-CodexRollbackStatePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )
    return ((ConvertTo-CodexFullPath -Path $RootPath) + '.codex-memory-repair.rollback.json')
}

function Write-CodexRollbackState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [hashtable]$State,
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [switch]$CreateOnly
    )

    $stateFullPath = ConvertTo-CodexFullPath -Path $Path
    $rootFullPath = ConvertTo-CodexFullPath -Path $RootPath
    $stateParent = ConvertTo-CodexFullPath -Path (Split-Path -Parent $stateFullPath)
    $rootParent = ConvertTo-CodexFullPath -Path (Split-Path -Parent $rootFullPath)
    if ($stateParent -ine $rootParent) {
        throw 'Rollback state must remain in the validated parent directory of the Codex path.'
    }
    $expectedLeaf = (Split-Path -Leaf $rootFullPath) + '.codex-memory-repair.rollback.json'
    if ((Split-Path -Leaf $stateFullPath) -ine $expectedLeaf) {
        throw 'Rollback state filename is outside the fixed state-file contract.'
    }
    $parentItem = Get-Item -LiteralPath $stateParent -Force -ErrorAction Stop
    if (Test-CodexReparsePoint -Item $parentItem) {
        throw "Rollback state parent is a reparse point; refusing traversal: $stateParent"
    }
    $ancestorReparsePoints = @(Get-CodexAncestorReparsePoints -Path $rootFullPath)
    if ($ancestorReparsePoints.Count -gt 0) {
        throw 'A reparse-point ancestor was found above the rollback state parent; refusing traversal.'
    }

    $json = $State | ConvertTo-Json -Depth 10
    $destinationItem = $null
    try {
        $destinationItem = Get-Item -LiteralPath $stateFullPath -Force -ErrorAction Stop
    }
    catch {
        $destinationItem = $null
    }
    if ($null -ne $destinationItem -and (Test-CodexReparsePoint -Item $destinationItem)) {
        throw "Rollback state path is a reparse point; refusing overwrite: $stateFullPath"
    }
    if ($CreateOnly -and $null -ne $destinationItem) {
        throw "Rollback state already exists; refusing to overwrite it: $stateFullPath"
    }
    if (-not $CreateOnly -and ($null -eq $destinationItem -or [bool](Get-CodexObjectProperty -Object $destinationItem -Name 'PSIsContainer'))) {
        throw "Rollback state update requires an existing ordinary file: $stateFullPath"
    }

    $tempPath = $null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $candidate = Join-Path -Path $stateParent -ChildPath ("{0}.tmp-{1}" -f (Split-Path -Leaf $stateFullPath), ([guid]::NewGuid().ToString('N')))
        if (-not (Test-Path -LiteralPath $candidate -PathType Any)) {
            $tempPath = $candidate
            break
        }
    }
    if ($null -eq $tempPath) {
        throw "Could not allocate a diagnostic rollback-state temp path beside $stateFullPath."
    }

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
        if (-not $CreateOnly -and $script:CodexStateWriteFailureMode -eq 'Update') {
            throw "Injected rollback-state update failure. Diagnostic temp: $tempPath"
        }
        if ($CreateOnly) {
            [IO.File]::Move($tempPath, $stateFullPath)
        }
        else {
            $previousPath = $null
            for ($previousAttempt = 0; $previousAttempt -lt 100; $previousAttempt++) {
                $previousCandidate = Join-Path -Path $stateParent -ChildPath ("{0}.previous-{1}" -f (Split-Path -Leaf $stateFullPath), ([guid]::NewGuid().ToString('N')))
                if (-not (Test-Path -LiteralPath $previousCandidate -PathType Any)) {
                    $previousPath = $previousCandidate
                    break
                }
            }
            if ($null -eq $previousPath) {
                throw "Could not allocate a previous-state audit path beside $stateFullPath."
            }
            # File.Replace is atomic on the same NTFS volume. The previous JSON is retained as a recovery audit copy.
            [IO.File]::Replace($tempPath, $stateFullPath, $previousPath)
        }
    }
    catch {
        throw "Rollback state write failed; any previous valid JSON was retained. Diagnostic temp: $tempPath. $($_.Exception.Message)"
    }
}

function Copy-CodexDirectoryContents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -ErrorAction Stop | Out-Null
    $children = @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)
    foreach ($child in $children) {
        $destinationChild = Join-Path -Path $Destination -ChildPath $child.Name
        Copy-Item -LiteralPath $child.FullName -Destination $destinationChild -Recurse -Force -ErrorAction Stop
    }
}

function Get-CodexConversionPreflight {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $rootInfo = Get-CodexLinkInfo -Path $RootPath
    if (-not $rootInfo.Exists) {
        throw "Codex web path does not exist: $($rootInfo.Path)"
    }
    if (-not $rootInfo.IsDirectory) {
        throw "Codex web path is not a directory: $($rootInfo.Path)"
    }
    if (-not $rootInfo.IsReparsePoint) {
        return [pscustomobject][ordered]@{
            Status = 'OrdinaryNoOp'
            Root = $rootInfo
            Target = $null
            Ancestors = @()
            Nested = @()
            TargetManifest = @()
        }
    }
    if ($rootInfo.Status -eq 'UnknownReparsePoint' -or $rootInfo.LinkType -notin @('Junction', 'SymbolicLink')) {
        throw "The Codex web path is an unknown reparse point; refusing conversion. LinkType=$($rootInfo.LinkType)"
    }
    if ($rootInfo.Status -eq 'Broken' -or -not $rootInfo.TargetExists) {
        throw "The Codex web link target is missing or broken: $($rootInfo.TargetPath)"
    }
    if (-not $rootInfo.TargetIsDirectory) {
        throw "The Codex web link target is not a directory: $($rootInfo.TargetPath)"
    }
    if ($rootInfo.TargetIsReparsePoint) {
        throw "The Codex web link target is itself a reparse point; refusing traversal: $($rootInfo.TargetPath)"
    }

    $ancestors = @(Get-CodexAncestorReparsePoints -Path $rootInfo.Path)
    $targetAncestors = @(Get-CodexAncestorReparsePoints -Path $rootInfo.TargetPath)
    if ($ancestors.Count -gt 0 -or $targetAncestors.Count -gt 0) {
        $ancestorPaths = @($ancestors + $targetAncestors | ForEach-Object { $_.Path })
        throw "A reparse-point ancestor was found; refusing conversion: $($ancestorPaths -join ', ')"
    }
    $nested = @(Get-CodexNestedReparsePoints -DirectoryPath $rootInfo.TargetPath)
    if ($nested.Count -gt 0) {
        throw "The link target contains nested reparse points; refusing to clone it: $(($nested | ForEach-Object { $_.Path }) -join ', ')"
    }

    $targetManifest = @(Get-CodexFileManifest -DirectoryPath $rootInfo.TargetPath)
    return [pscustomobject][ordered]@{
        Status = 'Ready'
        Root = $rootInfo
        Target = Get-CodexLinkInfo -Path $rootInfo.TargetPath
            Ancestors = @($ancestors + $targetAncestors)
        Nested = $nested
        TargetManifest = $targetManifest
    }
}

function Get-CodexInspection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [switch]$IncludeEnvironment
    )

    $rootInfo = Get-CodexLinkInfo -Path $RootPath
    $ancestors = @()
    $nested = @()
    $targetInfo = $null
    $targetError = $null
    if ($rootInfo.Exists) {
        try {
            $ancestors = @(Get-CodexAncestorReparsePoints -Path $rootInfo.Path)
        }
        catch {
            $targetError = $_.Exception.Message
        }
        if ($null -ne $rootInfo.TargetPath) {
            try {
                $targetInfo = Get-CodexLinkInfo -Path $rootInfo.TargetPath
                if ($targetInfo.TargetExists -and $targetInfo.TargetIsDirectory -and -not $targetInfo.TargetIsReparsePoint) {
                    $nested = @(Get-CodexNestedReparsePoints -DirectoryPath $rootInfo.TargetPath)
                }
            }
            catch {
                $targetError = $_.Exception.Message
            }
        }
    }

    $result = [ordered]@{
        Ok = $true
        Action = 'Inspect'
        Path = $rootInfo.Path
        Status = $rootInfo.Status
        Exists = $rootInfo.Exists
        IsDirectory = $rootInfo.IsDirectory
        IsReparsePoint = $rootInfo.IsReparsePoint
        LinkType = $rootInfo.LinkType
        TargetPath = $rootInfo.TargetPath
        TargetExists = $rootInfo.TargetExists
        TargetIsDirectory = $rootInfo.TargetIsDirectory
        TargetIsReparsePoint = $rootInfo.TargetIsReparsePoint
        AncestorReparsePoints = @($ancestors)
        NestedTargetReparsePoints = @($nested)
        TargetInspectionError = $targetError
    }
    if ($IncludeEnvironment) {
        $result['RunningDesktopProcesses'] = @(Get-CodexRunningProcessInfo)
        $result['StorePackage'] = Get-CodexStorePackageInfo
    }
    return [pscustomobject]$result
}

function Invoke-CodexConvert {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [switch]$WhatIf,
        [switch]$SkipEnvironmentGuards,
        [scriptblock]$ShouldProcessCallback
    )

    $root = ConvertTo-CodexFullPath -Path $RootPath
    $preflight = Get-CodexConversionPreflight -RootPath $root
    if ($preflight.Status -eq 'OrdinaryNoOp') {
        return [pscustomobject][ordered]@{
            Ok = $true
            Action = 'Convert'
            Path = $root
            Status = 'OrdinaryNoOp'
            Changed = $false
            WhatIf = [bool]$WhatIf
            Message = 'The Codex web path is already an ordinary directory; no action was needed.'
        }
    }

    $statePath = Get-CodexRollbackStatePath -RootPath $root
    if (Test-Path -LiteralPath $statePath -PathType Any) {
        throw "A rollback state file already exists; run Rollback or move it aside after review: $statePath"
    }
    if (-not $SkipEnvironmentGuards) {
        Assert-CodexMutationEnvironment -RootPath $root
    }

    $stagingPath = New-CodexSiblingPath -RootPath $root -Suffix 'codex-memory-repair-staging'
    $backupPath = New-CodexSiblingPath -RootPath $root -Suffix 'codex-memory-repair-backup'
    if ($WhatIf) {
        return [pscustomobject][ordered]@{
            Ok = $true
            Action = 'Convert'
            Path = $root
            Status = 'WhatIf'
            Changed = $false
            WhatIf = $true
            LinkType = $preflight.Root.LinkType
            TargetPath = $preflight.Root.TargetPath
            PlannedStagingPath = $stagingPath
            PlannedBackupPath = $backupPath
            RollbackStatePath = $statePath
            SourceFileCount = @($preflight.TargetManifest).Count
            Message = 'Validation passed; no staging directory, rename, or rollback state was written.'
        }
    }
    if ($null -ne $ShouldProcessCallback) {
        $approved = & $ShouldProcessCallback $root 'Replace the Codex web link with an ordinary directory'
        if (-not $approved) {
            return [pscustomobject][ordered]@{
                Ok = $true
                Action = 'Convert'
                Path = $root
                Status = 'Declined'
                Changed = $false
                WhatIf = $false
                Message = 'The requested conversion was declined by ShouldProcess; no path was changed.'
            }
        }
    }
    $sourceManifest = @($preflight.TargetManifest)
    try {
        Copy-CodexDirectoryContents -Source $preflight.Root.TargetPath -Destination $stagingPath
        $stagingManifest = @(Get-CodexFileManifest -DirectoryPath $stagingPath)
        $copyComparison = Compare-CodexManifests -Expected $sourceManifest -Actual $stagingManifest
        if (-not $copyComparison.Equal) {
            throw ("Staging copy did not match the target. Missing={0}; Unexpected={1}; Changed={2}" -f (($copyComparison.Missing) -join ','), (($copyComparison.Unexpected) -join ','), (($copyComparison.Changed) -join ','))
        }

        # Re-read the source after copying so a concurrent writer cannot be silently disconnected.
        $sourceAfterCopy = @(Get-CodexFileManifest -DirectoryPath $preflight.Root.TargetPath)
        $sourceComparison = Compare-CodexManifests -Expected $sourceManifest -Actual $sourceAfterCopy
        if (-not $sourceComparison.Equal) {
            throw 'The original target changed while it was being staged; refusing to swap the link.'
        }

        $state = [ordered]@{
            SchemaVersion = $script:CodexRollbackSchemaVersion
            Status = 'Prepared'
            RootPath = $root
            LinkType = $preflight.Root.LinkType
            TargetPath = $preflight.Root.TargetPath
            BackupPath = $backupPath
            StagingPath = $stagingPath
            RollbackStatePath = $statePath
            PreparedAtUtc = [DateTime]::UtcNow.ToString('o')
            ConvertedAtUtc = $null
            RestoredAtUtc = $null
            CurrentDataBackupPath = $null
            TargetFileCount = $sourceManifest.Count
            PostRepairWritePolicy = $script:CodexPostRepairWritePolicy
        }
        Write-CodexRollbackState -Path $statePath -State $state -RootPath $root -CreateOnly

        $backupMoved = $false
        try {
            Rename-Item -LiteralPath $root -NewName (Split-Path -Leaf $backupPath) -ErrorAction Stop
            $backupMoved = $true
            if ($script:CodexSwapFailureStage -eq 'AfterBackupRename') {
                if ($script:CodexSwapFailureCollision) {
                    # Test-only collision injection: production leaves this hook false.
                    New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
                }
                throw 'Injected staging swap failure after the original link was moved to backup.'
            }
            Rename-Item -LiteralPath $stagingPath -NewName (Split-Path -Leaf $root) -ErrorAction Stop
        }
        catch {
            $swapError = $_.Exception.Message
            $restoreError = $null
            $originalRestored = $false
            if ($backupMoved) {
                try {
                    if (Test-Path -LiteralPath $root -PathType Any) {
                        throw "The original path is occupied during recovery; refusing to overwrite it: $root"
                    }
                    if (-not (Test-Path -LiteralPath $backupPath -PathType Any)) {
                        throw "The saved link backup is missing during recovery: $backupPath"
                    }
                    Rename-Item -LiteralPath $backupPath -NewName (Split-Path -Leaf $root) -ErrorAction Stop
                    $restoredInfo = Get-CodexLinkInfo -Path $root
                    if (-not $restoredInfo.IsReparsePoint -or $restoredInfo.LinkType -ne $preflight.Root.LinkType -or $null -eq $restoredInfo.TargetPath -or (ConvertTo-CodexFullPath -Path $restoredInfo.TargetPath) -ine (ConvertTo-CodexFullPath -Path $preflight.Root.TargetPath)) {
                        throw 'The recovered path did not validate as the original link type and target.'
                    }
                    $originalRestored = $true
                }
                catch {
                    $restoreError = $_.Exception.Message
                }
            }

            $state.Status = 'Aborted'
            $state.AbortedAtUtc = [DateTime]::UtcNow.ToString('o')
            $state.FailureStage = if ($backupMoved) { 'StagingSwap' } else { 'BackupRename' }
            $state.RecoveryStatus = if ($restoreError) { 'RestoreFailed' } elseif ($backupMoved) { 'OriginalLinkRestored' } else { 'OriginalLinkUnchanged' }
            $state.FailureMessage = $swapError
            $state.RestoreError = $restoreError
            $stateWriteError = $null
            try {
                Write-CodexRollbackState -Path $statePath -State $state -RootPath $root
            }
            catch {
                $stateWriteError = $_.Exception.Message
            }

            if ($null -ne $stateWriteError) {
                throw "Swap failed; no data was deleted. The original link recovery status is $($state.RecoveryStatus), but the state could not be marked Aborted. Staging=$stagingPath; State=$statePath; StateWriteError=$stateWriteError"
            }
            if ($null -ne $restoreError) {
                throw "Swap failed and restoring the original link also failed. No data was deleted. Backup=$backupPath; Staging=$stagingPath; State status=Aborted; RestoreError=$restoreError; OriginalError=$swapError"
            }
            if ($originalRestored -or -not $backupMoved) {
                $restoreDescription = 'unchanged'
                if ($originalRestored) {
                    $restoreDescription = 'restored'
                }
                throw "Swap failed; no data was deleted. The original link is $restoreDescription. Staging=$stagingPath; State status=Aborted; review or archive the retained staging/state files before retrying. Error=$swapError"
            }
            throw "Swap failed; no data was deleted. State status=Aborted; review retained paths before retrying. Error=$swapError"
        }

        $convertedInfo = Get-CodexLinkInfo -Path $root
        if ($convertedInfo.IsReparsePoint) {
            throw 'The new Codex path unexpectedly became a reparse point after staging.'
        }
        $convertedManifest = @(Get-CodexFileManifest -DirectoryPath $root)
        $finalComparison = Compare-CodexManifests -Expected $sourceManifest -Actual $convertedManifest
        if (-not $finalComparison.Equal) {
            throw 'The swapped ordinary directory did not match the staged target.'
        }

        $state.Status = 'Converted'
        $state.ConvertedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-CodexRollbackState -Path $statePath -State $state -RootPath $root
        return [pscustomobject][ordered]@{
            Ok = $true
            Action = 'Convert'
            Path = $root
            Status = 'Converted'
            Changed = $true
            WhatIf = $false
            LinkType = $preflight.Root.LinkType
            TargetPath = $preflight.Root.TargetPath
            BackupPath = $backupPath
            RollbackStatePath = $statePath
            FileCount = $sourceManifest.Count
            PostRepairWritePolicy = $script:CodexPostRepairWritePolicy
            Message = 'The link was replaced with an ordinary directory. The original link was retained beside it for Rollback.'
        }
    }
    catch {
        # Staging, backup, and the recovery state are intentionally retained for review and recovery.
        throw
    }
}

function Get-CodexStateValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    return (Get-CodexObjectProperty -Object $State -Name $Name)
}

function Assert-CodexRollbackState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $statePath = Get-CodexRollbackStatePath -RootPath $RootPath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "Rollback state was not found: $statePath"
    }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Rollback state is not valid JSON: $statePath. $($_.Exception.Message)"
    }

    $schemaVersion = [int](Get-CodexStateValue -State $state -Name 'SchemaVersion')
    $status = [string](Get-CodexStateValue -State $state -Name 'Status')
    $savedRoot = [string](Get-CodexStateValue -State $state -Name 'RootPath')
    if ($schemaVersion -ne $script:CodexRollbackSchemaVersion) {
        throw "Unsupported rollback state schema version: $schemaVersion"
    }
    if ($status -notin @('Converted', 'Prepared')) {
        throw "Rollback state is not ready for Rollback; current status is $status. No data was changed."
    }
    if ((ConvertTo-CodexFullPath -Path $savedRoot) -ine (ConvertTo-CodexFullPath -Path $RootPath)) {
        throw 'Rollback state does not belong to the requested Codex path.'
    }

    $backupPath = [string](Get-CodexStateValue -State $state -Name 'BackupPath')
    $targetPath = [string](Get-CodexStateValue -State $state -Name 'TargetPath')
    $linkType = [string](Get-CodexStateValue -State $state -Name 'LinkType')
    if ([string]::IsNullOrWhiteSpace($backupPath) -or [string]::IsNullOrWhiteSpace($targetPath) -or $linkType -notin @('Junction', 'SymbolicLink')) {
        throw 'Rollback state is missing a valid backup path, target path, or link type.'
    }

    $backupInfo = Get-CodexLinkInfo -Path $backupPath
    if (-not $backupInfo.Exists -or -not $backupInfo.IsDirectory -or -not $backupInfo.IsReparsePoint -or $backupInfo.LinkType -ne $linkType) {
        throw "The saved link backup is missing or does not match the recorded link type: $backupPath"
    }
    if ($null -eq $backupInfo.TargetPath -or (ConvertTo-CodexFullPath -Path $backupInfo.TargetPath) -ine (ConvertTo-CodexFullPath -Path $targetPath)) {
        throw 'The saved link backup target does not match rollback state; refusing restore.'
    }
    $targetInfo = Get-CodexLinkInfo -Path $targetPath
    if (-not $targetInfo.Exists -or -not $targetInfo.IsDirectory -or $targetInfo.IsReparsePoint) {
        throw 'The saved link target is missing, not a directory, or has become a reparse point; refusing restore.'
    }

    $rootInfo = Get-CodexLinkInfo -Path $RootPath
    if ($rootInfo.Exists -and (-not $rootInfo.IsDirectory -or $rootInfo.IsReparsePoint)) {
        throw 'The current Codex path is not an ordinary directory; refusing to overwrite it during rollback.'
    }
    return [pscustomobject][ordered]@{
        StatePath = $statePath
        State = $state
        RootInfo = $rootInfo
        BackupInfo = $backupInfo
        TargetInfo = $targetInfo
        BackupPath = (ConvertTo-CodexFullPath -Path $backupPath)
        TargetPath = (ConvertTo-CodexFullPath -Path $targetPath)
        LinkType = $linkType
    }
}

function Invoke-CodexRollback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [switch]$WhatIf,
        [switch]$SkipEnvironmentGuards,
        [scriptblock]$ShouldProcessCallback
    )

    $root = ConvertTo-CodexFullPath -Path $RootPath
    $preflight = Assert-CodexRollbackState -RootPath $root
    if (-not $SkipEnvironmentGuards) {
        Assert-CodexMutationEnvironment -RootPath $root
    }

    $currentDataBackupPath = $null
    if ($preflight.RootInfo.Exists) {
        $currentDataBackupPath = New-CodexSiblingPath -RootPath $root -Suffix 'codex-memory-repair-current-data'
    }
    if ($WhatIf) {
        return [pscustomobject][ordered]@{
            Ok = $true
            Action = 'Rollback'
            Path = $root
            Status = 'WhatIf'
            Changed = $false
            WhatIf = $true
            RestoreLinkPath = $preflight.BackupPath
            RetainedCurrentDataPath = $currentDataBackupPath
            RollbackStatePath = $preflight.StatePath
            Message = 'Validation passed; no rename or rollback state update was written.'
        }
    }
    if ($null -ne $ShouldProcessCallback) {
        $approved = & $ShouldProcessCallback $root 'Restore the saved Codex web link and retain current ordinary data beside it'
        if (-not $approved) {
            return [pscustomobject][ordered]@{
                Ok = $true
                Action = 'Rollback'
                Path = $root
                Status = 'Declined'
                Changed = $false
                WhatIf = $false
                Message = 'The requested rollback was declined by ShouldProcess; no path was changed.'
            }
        }
    }
    $currentMoved = $false
    try {
        if ($null -ne $currentDataBackupPath) {
            Rename-Item -LiteralPath $root -NewName (Split-Path -Leaf $currentDataBackupPath) -ErrorAction Stop
            $currentMoved = $true
        }
        Rename-Item -LiteralPath $preflight.BackupPath -NewName (Split-Path -Leaf $root) -ErrorAction Stop
    }
    catch {
        if ($currentMoved) {
            try {
                if (-not (Test-Path -LiteralPath $root -PathType Any) -and (Test-Path -LiteralPath $currentDataBackupPath -PathType Any)) {
                    Rename-Item -LiteralPath $currentDataBackupPath -NewName (Split-Path -Leaf $root) -ErrorAction Stop
                }
            }
            catch {
                throw ("Rollback failed and retaining current data could not restore its original path. CurrentData=$currentDataBackupPath; OriginalError={0}; RestoreError=$($_.Exception.Message)" -f $_.Exception.Message)
            }
        }
        throw
    }

    $restoredInfo = Get-CodexLinkInfo -Path $root
    if (-not $restoredInfo.IsReparsePoint -or $restoredInfo.LinkType -ne $preflight.LinkType -or (ConvertTo-CodexFullPath -Path $restoredInfo.TargetPath) -ine $preflight.TargetPath) {
        throw 'The restored Codex path did not validate as the saved link; retained paths were left untouched.'
    }

    $state = [ordered]@{}
    foreach ($property in $preflight.State.PSObject.Properties) {
        $state[$property.Name] = $property.Value
    }
    $state.Status = 'RolledBack'
    $state.RestoredAtUtc = [DateTime]::UtcNow.ToString('o')
    $state.CurrentDataBackupPath = $currentDataBackupPath
    Write-CodexRollbackState -Path $preflight.StatePath -State $state -RootPath $root
    return [pscustomobject][ordered]@{
        Ok = $true
        Action = 'Rollback'
        Path = $root
        Status = 'RolledBack'
        Changed = $true
        WhatIf = $false
        RestoredLinkPath = $root
        TargetPath = $preflight.TargetPath
        RetainedCurrentDataPath = $currentDataBackupPath
        RollbackStatePath = $preflight.StatePath
        Message = 'The saved link was restored. The current ordinary directory was retained beside it; no data was deleted.'
    }
}

function Invoke-CodexRepairAction {
    [CmdletBinding()]
    param(
        [ValidateSet('Inspect', 'Convert', 'Rollback')]
        [string]$Action = 'Inspect',
        [string]$RootPath,
        [switch]$WhatIf,
        [switch]$SkipEnvironmentGuards,
        [scriptblock]$ShouldProcessCallback
    )

    if ([string]::IsNullOrWhiteSpace($RootPath)) {
        $RootPath = Get-CodexDefaultPath
    }
    $root = ConvertTo-CodexFullPath -Path $RootPath
    switch ($Action) {
        'Inspect' {
            return (Get-CodexInspection -RootPath $root -IncludeEnvironment:(Test-CodexIsDefaultPath -Path $root))
        }
        'Convert' {
            return (Invoke-CodexConvert -RootPath $root -WhatIf:$WhatIf -SkipEnvironmentGuards:$SkipEnvironmentGuards -ShouldProcessCallback:$ShouldProcessCallback)
        }
        'Rollback' {
            return (Invoke-CodexRollback -RootPath $root -WhatIf:$WhatIf -SkipEnvironmentGuards:$SkipEnvironmentGuards -ShouldProcessCallback:$ShouldProcessCallback)
        }
    }
}

# Dot-sourcing exposes the test hook without executing the production action.
$script:CodexRepairDotSourced = ($MyInvocation.InvocationName -eq '.')
if (-not $script:CodexRepairDotSourced) {
    try {
        $rootPath = Get-CodexDefaultPath
        $shouldProcessCallback = $null
        if ($Action -in @('Convert', 'Rollback')) {
            $shouldProcessCallback = {
                param(
                    [string]$Target,
                    [string]$Operation
                )
                return $PSCmdlet.ShouldProcess($Target, $Operation)
            }
        }
        $result = Invoke-CodexRepairAction -Action $Action -RootPath $rootPath -WhatIf:([bool]$WhatIfPreference) -ShouldProcessCallback:$shouldProcessCallback
        $result | ConvertTo-Json -Depth 12 -Compress
    }
    catch {
        $errorPath = $null
        try {
            $errorPath = Get-CodexDefaultPath
        }
        catch {
            $errorPath = $null
        }
        $errorResult = [ordered]@{
            Ok = $false
            Action = $Action
            Path = $errorPath
            Error = $_.Exception.Message
        }
        $errorResult | ConvertTo-Json -Depth 8 -Compress
        exit 1
    }
}
