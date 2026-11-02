<#
.SYNOPSIS
Builds Double Commander and its Windows plug-ins with Lazarus.

.DESCRIPTION
PowerShell counterpart to build.bat. The script can be started from any
working directory, fails on the first unsuccessful lazbuild invocation, and
uses an isolated Lazarus profile by default.

The repository may be a sparse checkout without components/. In that case the
script first looks for the component sources used by RemoteThumbnailDCPlug at
..\RemoteThumbnailDCPlug\build-dc-host\source\components. Override that choice
with -ComponentsDirectory when necessary.

.PARAMETER Target
Build target: components, plugins, doublecmd, debugctl, release, beta,
darkwin, or debug. release is the default and matches build.bat: components,
plug-ins, and the Release application; it also builds dc-debugctl when that
project is present.

.PARAMETER OutputDirectory
Directory that receives the built executables, debug symbols, and plug-ins.
The default is the sibling ..\DoubleCmdRPC runtime directory. Existing runtime
files that are unrelated to the build are left untouched.

.PARAMETER Incremental
Do not pass --build-all when building the application and dc-debugctl.

.EXAMPLE
.\build.ps1

Build all release targets with the automatically discovered toolchain.

.EXAMPLE
.\build.ps1 debug -Incremental -SkipPlugins

Incrementally build the components, Debug application, and dc-debugctl.

.EXAMPLE
.\build.ps1 doublecmd -LazarusDirectory C:\Lazarus

Build only the Release Double Commander application.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('Mode')]
    [ValidateSet('components', 'plugins', 'doublecmd', 'debugctl', 'release', 'beta', 'darkwin', 'debug')]
    [string]$Target = 'release',

    [string]$LazarusDirectory = '',
    [string]$CompilerPath = '',
    [string]$ConfigDirectory = '',
    [string]$ComponentsDirectory = '',
    [string]$OutputDirectory = '',

    [string]$OsTarget = $env:OS_TARGET,
    [string]$CpuTarget = $env:CPU_TARGET,
    [string]$LclPlatform = $env:LCL_PLATFORM,

    [ValidateRange(1, 64)]
    [int]$MaxProcessCount = 1,

    [switch]$Incremental,
    [switch]$SkipPlugins,
    [switch]$SkipDebugCtl
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$workspaceRoot = Split-Path -Parent $projectRoot
$dcHostBuildRoot = Join-Path $workspaceRoot 'RemoteThumbnailDCPlug\build-dc-host'

function Resolve-BuildPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$BaseDirectory = $projectRoot
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }

    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $publishRoot = [IO.Path]::GetFullPath((Join-Path $workspaceRoot 'DoubleCmdRPC'))
} else {
    $publishRoot = Resolve-BuildPath $OutputDirectory
}

function Publish-BuildArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationRelativePath,
        [switch]$Optional
    )

    $resolvedSource = Resolve-BuildPath $SourcePath
    if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
        if ($Optional) {
            Write-Verbose "Optional build artifact was not produced: $resolvedSource"
            return
        }
        throw "Build artifact was not produced: $resolvedSource"
    }

    $destination = [IO.Path]::GetFullPath((Join-Path $publishRoot $DestinationRelativePath))
    $destinationDirectory = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null

    if (-not $resolvedSource.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $resolvedSource -Destination $destination -Force
    }

    $sourceItem = Get-Item -LiteralPath $resolvedSource
    $destinationItem = Get-Item -LiteralPath $destination
    if ($destinationItem.Length -ne $sourceItem.Length) {
        throw "Published artifact size mismatch: $destination"
    }

    Write-Host "  Published: $destination" -ForegroundColor DarkGreen
}

function Find-LazarusToolchain {
    if (-not [string]::IsNullOrWhiteSpace($LazarusDirectory)) {
        $directory = Resolve-BuildPath $LazarusDirectory
        $executable = Join-Path $directory 'lazbuild.exe'
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "lazbuild.exe was not found in LazarusDirectory: $directory"
        }

        return [pscustomobject]@{
            LazarusDirectory = $directory
            LazBuild          = $executable
        }
    }

    $directoryCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:LAZARUS_HOME)) {
        $directoryCandidates += (Resolve-BuildPath $env:LAZARUS_HOME)
    }
    $directoryCandidates += (Join-Path $dcHostBuildRoot 'lazarus-portable\app')

    foreach ($directory in @($directoryCandidates | Select-Object -Unique)) {
        $executable = Join-Path $directory 'lazbuild.exe'
        if (Test-Path -LiteralPath $executable -PathType Leaf) {
            return [pscustomobject]@{
                LazarusDirectory = [IO.Path]::GetFullPath($directory)
                LazBuild          = [IO.Path]::GetFullPath($executable)
            }
        }
    }

    $command = Get-Command 'lazbuild.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        $command = Get-Command 'lazbuild' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if ($null -eq $command) {
        throw 'Unable to find lazbuild.exe. Set -LazarusDirectory or LAZARUS_HOME.'
    }

    # A PATH entry may be a package-manager shim, so do not infer or pass a
    # Lazarus source directory from it.
    return [pscustomobject]@{
        LazarusDirectory = $null
        LazBuild          = $command.Source
    }
}

function Find-Compiler {
    param(
        [AllowNull()]
        [string]$ResolvedLazarusDirectory
    )

    if (-not [string]::IsNullOrWhiteSpace($CompilerPath)) {
        $resolved = Resolve-BuildPath $CompilerPath
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "CompilerPath does not exist: $resolved"
        }
        return $resolved
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedLazarusDirectory)) {
        return $null
    }

    $compilerName = switch ($CpuTarget.ToLowerInvariant()) {
        { $_ -in @('x86_64', 'amd64') } { 'ppcx64.exe'; break }
        { $_ -in @('i386', 'i686', 'x86') } { 'ppc386.exe'; break }
        'aarch64' { 'ppca64.exe'; break }
        'arm' { 'ppcarm.exe'; break }
        default { "ppc$($CpuTarget.Replace('_', '')).exe" }
    }

    $fpcRoot = Join-Path $ResolvedLazarusDirectory 'fpc'
    if (-not (Test-Path -LiteralPath $fpcRoot -PathType Container)) {
        return $null
    }

    $matches = @(Get-ChildItem -Path (Join-Path $fpcRoot "*\bin\*\$compilerName") -File -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending)
    if ($matches.Count -gt 0) {
        return $matches[0].FullName
    }

    return $null
}

function Find-ComponentsDirectory {
    if (-not [string]::IsNullOrWhiteSpace($ComponentsDirectory)) {
        $resolved = Resolve-BuildPath $ComponentsDirectory
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            throw "ComponentsDirectory does not exist: $resolved"
        }
        return $resolved
    }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:DOUBLECMD_COMPONENTS)) {
        $candidates += (Resolve-BuildPath $env:DOUBLECMD_COMPONENTS)
    }
    $candidates += (Join-Path $projectRoot 'components')
    $candidates += (Join-Path $dcHostBuildRoot 'source\components')

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    throw 'Unable to find the Double Commander components directory. Use -ComponentsDirectory.'
}

if ([string]::IsNullOrWhiteSpace($OsTarget)) {
    $OsTarget = 'win64'
}
if ([string]::IsNullOrWhiteSpace($CpuTarget)) {
    $CpuTarget = 'x86_64'
}
if ([string]::IsNullOrWhiteSpace($LclPlatform)) {
    $LclPlatform = 'win32'
}

$toolchain = Find-LazarusToolchain
$lazbuild = $toolchain.LazBuild
$lazarus = $toolchain.LazarusDirectory
$compiler = Find-Compiler $lazarus

if ([string]::IsNullOrWhiteSpace($ConfigDirectory)) {
    # units/ is already ignored by the upstream repository and keeps this
    # checkout's package links separate from the user's normal Lazarus profile.
    $config = Join-Path $projectRoot 'units\lazarus-profile'
} else {
    $config = Resolve-BuildPath $ConfigDirectory
}
New-Item -ItemType Directory -Force -Path $config | Out-Null

$commonArguments = @(
    "--pcp=$config",
    "--scp=$config",
    '--language=en',
    '--no-write-project',
    "--max-process-count=$MaxProcessCount",
    "--os=$OsTarget",
    "--cpu=$CpuTarget",
    "--ws=$LclPlatform"
)
if (-not [string]::IsNullOrWhiteSpace($lazarus)) {
    $commonArguments += "--lazarusdir=$lazarus"
}
if (-not [string]::IsNullOrWhiteSpace($compiler)) {
    $commonArguments += "--compiler=$compiler"
}

function Invoke-LazBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [string[]]$AdditionalArguments = @(),
        [switch]$FullBuild
    )

    if (-not (Test-Path -LiteralPath $Project -PathType Leaf)) {
        throw "Missing Lazarus project for ${Label}: $Project"
    }

    $arguments = @($commonArguments)
    if ($FullBuild) {
        $arguments += '--build-all'
    }
    $arguments += $AdditionalArguments
    $arguments += [IO.Path]::GetFullPath($Project)

    Write-Host "`n==> $Label" -ForegroundColor Cyan
    Push-Location ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Project)))
    try {
        & $lazbuild @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "lazbuild failed with exit code $LASTEXITCODE while building $Label"
        }
    } finally {
        Pop-Location
    }
}

function Build-Components {
    $root = Find-ComponentsDirectory
    $packages = @(
        'chsdet\chsdet.lpk',
        'multithreadprocs\multithreadprocslaz.lpk',
        'kascrypt\kascrypt.lpk',
        'doublecmd\doublecmd_common.lpk',
        'Image32\Image32.lpk',
        'KASToolBar\kascomp.lpk',
        'viewer\viewerpackage.lpk',
        'gifview\gifview.lpk',
        'synunihighlighter\synuni.lpk',
        'virtualterminal\virtualterminal.lpk'
    )

    foreach ($package in $packages) {
        Invoke-LazBuild -Label "component $package" -Project (Join-Path $root $package)
    }
}

function Build-Plugins {
    # Keep this list aligned with the Windows section of plugins\build.bat.
    $plugins = @(
        [pscustomobject]@{ Project = 'plugins\wcx\base64\src\base64wcx.lpi'; Artifact = 'plugins\wcx\base64\base64.wcx' },
        [pscustomobject]@{ Project = 'plugins\wcx\deb\src\deb.lpi'; Artifact = 'plugins\wcx\deb\deb.wcx' },
        [pscustomobject]@{ Project = 'plugins\wcx\rpm\src\rpm.lpi'; Artifact = 'plugins\wcx\rpm\rpm.wcx' },
        [pscustomobject]@{ Project = 'plugins\wcx\sevenzip\src\sevenzipwcx.lpi'; Artifact = 'plugins\wcx\sevenzip\sevenzip.wcx' },
        [pscustomobject]@{ Project = 'plugins\wcx\unrar\src\unrar.lpi'; Artifact = 'plugins\wcx\unrar\unrar.wcx' },
        [pscustomobject]@{ Project = 'plugins\wcx\zip\src\zip.lpi'; Artifact = 'plugins\wcx\zip\zip.wcx' },
        [pscustomobject]@{ Project = 'plugins\wdx\rpm_wdx\src\rpm_wdx.lpi'; Artifact = 'plugins\wdx\rpm_wdx\rpm_wdx.wdx' },
        [pscustomobject]@{ Project = 'plugins\wdx\deb_wdx\src\deb_wdx.lpi'; Artifact = 'plugins\wdx\deb_wdx\deb_wdx.wdx' },
        [pscustomobject]@{ Project = 'plugins\wdx\audioinfo\src\AudioInfo.lpi'; Artifact = 'plugins\wdx\audioinfo\audioinfo.wdx' },
        [pscustomobject]@{ Project = 'plugins\wfx\ftp\src\ftp.lpi'; Artifact = 'plugins\wfx\ftp\ftp.wfx' },
        [pscustomobject]@{ Project = 'plugins\wlx\wmp\src\wmp.lpi'; Artifact = 'plugins\wlx\wmp\wmp.wlx' },
        [pscustomobject]@{ Project = 'plugins\wlx\preview\src\preview.lpi'; Artifact = 'plugins\wlx\preview\preview.wlx' },
        [pscustomobject]@{ Project = 'plugins\wlx\richview\src\richview.lpi'; Artifact = 'plugins\wlx\richview\richview.wlx' }
    )

    foreach ($plugin in $plugins) {
        Invoke-LazBuild -Label "plug-in $($plugin.Project)" `
            -Project (Join-Path $projectRoot $plugin.Project)
    }

    foreach ($plugin in $plugins) {
        Publish-BuildArtifact -SourcePath $plugin.Artifact `
            -DestinationRelativePath $plugin.Artifact
    }
}

function Build-DoubleCommander {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Release', 'Debug', 'DarkWin')]
        [string]$BuildMode
    )

    if ($BuildMode -eq 'DarkWin') {
        $detours = Join-Path $projectRoot 'components\DDetours\Source'
        if (-not (Test-Path -LiteralPath $detours -PathType Container)) {
            throw 'DarkWin requires components\DDetours\Source inside this checkout.'
        }
    }

    $project = Join-Path $projectRoot 'src\doublecmd.lpi'
    Invoke-LazBuild -Label "Double Commander ($BuildMode)" -Project $project `
        -AdditionalArguments @("--bm=$BuildMode") -FullBuild:(-not $Incremental)

    $executable = Join-Path $projectRoot 'doublecmd.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "The build completed without producing $executable"
    }

    Publish-BuildArtifact -SourcePath $executable -DestinationRelativePath 'doublecmd.exe'
    if ($BuildMode -in @('Release', 'DarkWin')) {
        Publish-BuildArtifact -SourcePath (Join-Path $projectRoot 'doublecmd.dbg') `
            -DestinationRelativePath 'doublecmd.dbg' -Optional
    }
}

function Build-DebugCtl {
    param(
        [ValidateSet('Release', 'Debug')]
        [string]$BuildMode = 'Release'
    )

    $project = Join-Path $projectRoot 'tools\dc-debugctl\dc-debugctl.lpi'
    if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
        Write-Verbose 'tools\dc-debugctl is not present; skipping it.'
        return
    }

    Invoke-LazBuild -Label "dc-debugctl ($BuildMode)" -Project $project `
        -AdditionalArguments @("--bm=$BuildMode") -FullBuild:(-not $Incremental)

    $executable = Join-Path $projectRoot 'tools\dc-debugctl\dc-debugctl.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "The build completed without producing $executable"
    }

    Publish-BuildArtifact -SourcePath $executable -DestinationRelativePath 'dc-debugctl.exe'
}

Write-Host 'Double Commander build configuration' -ForegroundColor Green
Write-Host "  Root:       $projectRoot"
Write-Host "  Output:     $publishRoot"
Write-Host "  Target:     $Target"
Write-Host "  lazbuild:   $lazbuild"
if (-not [string]::IsNullOrWhiteSpace($compiler)) {
    Write-Host "  Compiler:   $compiler"
} else {
    Write-Host '  Compiler:   Lazarus profile/default'
}
Write-Host "  Platform:   $OsTarget / $CpuTarget / $LclPlatform"
Write-Host "  Profile:    $config"
Write-Host "  Full build: $(-not $Incremental)"

$originalPath = $env:PATH
if (-not [string]::IsNullOrWhiteSpace($compiler)) {
    $compilerDirectory = Split-Path -Parent $compiler
    $env:PATH = "$compilerDirectory;$env:PATH"
}

Push-Location $projectRoot
try {
    switch ($Target.ToLowerInvariant()) {
        'components' {
            Build-Components
        }
        'plugins' {
            Build-Plugins
        }
        'doublecmd' {
            Build-DoubleCommander -BuildMode 'Release'
        }
        'debugctl' {
            Build-DebugCtl -BuildMode 'Release'
        }
        { $_ -in @('release', 'beta') } {
            Build-Components
            if (-not $SkipPlugins) {
                Build-Plugins
            }
            Build-DoubleCommander -BuildMode 'Release'
            if (-not $SkipDebugCtl) {
                Build-DebugCtl -BuildMode 'Release'
            }
        }
        'darkwin' {
            Build-Components
            if (-not $SkipPlugins) {
                Build-Plugins
            }
            Build-DoubleCommander -BuildMode 'DarkWin'
            if (-not $SkipDebugCtl) {
                Build-DebugCtl -BuildMode 'Release'
            }
        }
        'debug' {
            Build-Components
            if (-not $SkipPlugins) {
                Build-Plugins
            }
            Build-DoubleCommander -BuildMode 'Debug'
            if (-not $SkipDebugCtl) {
                Build-DebugCtl -BuildMode 'Debug'
            }
        }
    }
} finally {
    Pop-Location
    $env:PATH = $originalPath
}

Write-Host "`nBuild completed successfully." -ForegroundColor Green

$hostExecutable = Join-Path $publishRoot 'doublecmd.exe'
$debugCtlExecutable = Join-Path $publishRoot 'dc-debugctl.exe'
[pscustomobject]@{
    Target                   = $Target.ToLowerInvariant()
    OutputDirectory          = $publishRoot
    DoubleCommander          = if (Test-Path -LiteralPath $hostExecutable -PathType Leaf) { $hostExecutable } else { $null }
    DebugCtl                 = if (Test-Path -LiteralPath $debugCtlExecutable -PathType Leaf) { $debugCtlExecutable } else { $null }
    LazarusProfile           = $config
    Incremental              = [bool]$Incremental
    MaximumParallelProcesses = $MaxProcessCount
}
