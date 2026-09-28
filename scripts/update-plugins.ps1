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

# Copilot CLI copies (install-copilot.ps1; VS Code reads the same ones): update only what is
# installed there. New plugins are never added, so a Copilot profile stays a profile.
if (Get-Command copilot -ErrorAction SilentlyContinue) {
    & copilot plugin marketplace update $name
    $copilotPlugins = (& copilot plugin list --json 2>$null | ConvertFrom-Json) | Where-Object { $_.marketplace -eq $name }
    foreach ($cp in $copilotPlugins) {
        & copilot plugin update "$($cp.name)@$name"
        if ($LASTEXITCODE -ne 0) { Write-Host "copilot update failed: $($cp.name)" }
    }
}

& claude plugin marketplace update $name
if ($LASTEXITCODE -ne 0) { Write-Host 'marketplace update failed'; Stop-Transcript | Out-Null; exit 1 }

# Keep the attribution guard current (patterns and git hooks) from the marketplace clone, but only
# where it was installed and not opted out. Re-run install.ps1 to refresh the PreToolUse registration.
$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$guard = Join-Path $claudeDir "plugins\marketplaces\$name\tools\attribution-guard\install.sh"
$guardHome = Join-Path $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }) 'git\attribution-guard'
if ($env:MY_CLAUDE_SKILLS_ATTRIBUTION -ne 'keep' -and (Test-Path $guard) -and (Test-Path $guardHome)) {
    $sh = $null
    $execPath = & git --exec-path 2>$null
    if ($execPath) {
        $candidate = Join-Path (Split-Path (Split-Path (Split-Path ($execPath -replace '/', '\')))) 'bin\sh.exe'
        if (Test-Path $candidate) { $sh = $candidate }
    }
    if (-not $sh) { $sh = (Get-Command sh.exe -ErrorAction SilentlyContinue).Source }
    if ($sh) {
        # install.sh keeps the mode and an opted-in global hooks path by itself.
        $env:ATTRIBUTION_GUARD_SKIP_CLAUDE = '1'
        & $sh $guard
        if ($LASTEXITCODE -ne 0) { Write-Host 'attribution guard refresh failed' }
    }
}

$mp = Join-Path $claudeDir "plugins\marketplaces\$name\.claude-plugin\marketplace.json"
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
