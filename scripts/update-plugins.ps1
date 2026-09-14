#Requires -Version 5.1
<#
.SYNOPSIS
    Refreshes the my-claude-skills marketplace, installs plugins added upstream, updates installed ones.
    Runs from a Claude Code SessionStart hook in the background; throttled to once per interval.
.PARAMETER Force
    Ignore the throttle and run now.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Log lines')]
param([switch] $Force)

$name = 'my-claude-skills'
$cache = Join-Path $env:LOCALAPPDATA $name
$stamp = Join-Path $cache 'last-run'
$log = Join-Path $cache 'update.log'
$interval = if ($env:MY_CLAUDE_SKILLS_INTERVAL) { [int] $env:MY_CLAUDE_SKILLS_INTERVAL } else { 21600 }
New-Item -ItemType Directory -Path $cache -Force | Out-Null

if (-not $Force -and (Test-Path $stamp)) {
    $age = ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalSeconds
    if ($age -lt $interval) { exit 0 }
}
New-Item -ItemType File -Path $stamp -Force | Out-Null

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { exit 0 }
Start-Transcript -Path $log -Append | Out-Null
Write-Host "=== $((Get-Date).ToUniversalTime().ToString('s'))Z"

& claude plugin marketplace update $name
if ($LASTEXITCODE -ne 0) { Write-Host 'marketplace update failed'; Stop-Transcript | Out-Null; exit 1 }

$mp = Join-Path $HOME ".claude\plugins\marketplaces\$name\.claude-plugin\marketplace.json"
if (-not (Test-Path $mp)) { Write-Host "marketplace manifest not found at $mp"; Stop-Transcript | Out-Null; exit 1 }
$available = (Get-Content $mp -Raw | ConvertFrom-Json).plugins.name
$installed = (& claude plugin list --json 2>$null | ConvertFrom-Json) |
    Where-Object { $_.id -like "*@$name" } | ForEach-Object { $_.id -replace "@$name$", '' }

foreach ($p in $available) {
    if ($installed -contains $p) {
        & claude plugin update "$p@$name" 2>&1 | Where-Object { $_ -notmatch 'already' }
    } else {
        Write-Host "new plugin: $p"
        & claude plugin install "$p@$name"
    }
}
Write-Host 'done'
Stop-Transcript | Out-Null
