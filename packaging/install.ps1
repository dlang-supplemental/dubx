#Requires -Version 5.1
<#
.SYNOPSIS
  Install dubx to a Programs folder and add it to User or Machine PATH.

.DESCRIPTION
  Default install root: %LOCALAPPDATA%\Programs\dlang-supplemental\dubx
  Copies dubx.exe (and LICENSE if present), updates PATH, refreshes
  the current session Path. Backends (redub, dub-publish) are separate installs.

.PARAMETER Prefix
  Install directory (contains dubx.exe).

.PARAMETER SkipPath
  Install files only; do not modify PATH.

.PARAMETER Scope
  PATH target: User/Local (default) or System/Machine (requires elevation).
#>
[CmdletBinding()]
param(
    [string] $Prefix = $(Join-Path $env:LOCALAPPDATA "Programs\dlang-supplemental\dubx"),
    [switch] $SkipPath,
    [ValidateSet("User", "Local", "System", "Machine")]
    [string] $Scope = "User"
)

$ErrorActionPreference = "Stop"

$pathTarget = if ($Scope -in @("System", "Machine")) { "Machine" } else { "User" }

function Get-SourceExe {
    $here = $PSScriptRoot
    $candidates = @(
        (Join-Path $here "dubx.exe"),
        (Join-Path (Split-Path $here -Parent) "dubx.exe"),
        (Join-Path (Get-Location) "dubx.exe")
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path $c).Path }
    }
    throw "dubx.exe not found next to this script, repo root, or cwd."
}

$exeSrc = Get-SourceExe
New-Item -ItemType Directory -Force -Path $Prefix | Out-Null
Copy-Item -LiteralPath $exeSrc -Destination (Join-Path $Prefix "dubx.exe") -Force

$licenseSrc = Join-Path (Split-Path $exeSrc -Parent) "LICENSE"
if (Test-Path -LiteralPath $licenseSrc) {
    Copy-Item -LiteralPath $licenseSrc -Destination (Join-Path $Prefix "LICENSE") -Force
}

$uninstall = Join-Path $Prefix "uninstall.ps1"
$uninstallBody = @(
    "#Requires -Version 5.1",
    '$ErrorActionPreference = "Stop"',
    '$Prefix = Split-Path -Parent $MyInvocation.MyCommand.Path',
    "`$pathTarget = '$pathTarget'",
    '$cur = [Environment]::GetEnvironmentVariable("Path", $pathTarget)',
    'if ($null -eq $cur) { $cur = "" }',
    '$parts = $cur -split ";" | Where-Object { $_ -and ($_ -ne $Prefix) }',
    '[Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), $pathTarget)',
    "Remove-Item -LiteralPath `$Prefix -Recurse -Force",
    'Write-Host "Removed $Prefix and $pathTarget PATH entry."',
    'Write-Host "Open a new shell (or refresh Path) so dubx disappears from PATH."'
) -join "`n"
Set-Content -LiteralPath $uninstall -Value $uninstallBody -Encoding UTF8

if (-not $SkipPath) {
    $cur = [Environment]::GetEnvironmentVariable("Path", $pathTarget)
    if ($null -eq $cur) { $cur = "" }
    $parts = @($cur -split ";" | Where-Object { $_ })
    if ($parts -notcontains $Prefix) {
        $parts += $Prefix
        [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), $pathTarget)
        Write-Host "Added to $pathTarget PATH: $Prefix"
    } else {
        Write-Host "$pathTarget PATH already contains: $Prefix"
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
        [Environment]::GetEnvironmentVariable("Path", "User")
}

$installed = Join-Path $Prefix "dubx.exe"
Write-Host "Installed: $installed"
try {
    & $installed version
} catch {
    Write-Host "(version check skipped: $_)"
}

Write-Host ""
Write-Host "dubx routes to backends on PATH:"
Write-Host "  - redub (or dub) for builds"
Write-Host "  - dub-publish for registry ops - install from"
Write-Host "    https://github.com/dlang-supplemental/dub-publish/releases"
Write-Host "Check: dubx which"
Write-Host ""
Write-Host "Refresh PATH in other open shells:"
Write-Host "  PowerShell:  `$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')"
Write-Host ('  nushell:     $env.PATH = ($env.PATH | prepend ''' + $Prefix + ''')')
Write-Host ('  bash/zsh:    export PATH="' + $Prefix + ':$PATH"')
Write-Host ""
Write-Host "Uninstall: powershell -File $uninstall"
Write-Host ('Or from nushell:  nu -c "powershell -File ''' + $uninstall + '''"')
