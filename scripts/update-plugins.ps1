#Requires -Version 5.1

<#
.SYNOPSIS
    Refreshes the my-claude-skills marketplace, updates installed plugins, and installs the ones added to
    the marketplace since the last run, so plugins left out of a subset install or uninstalled stay out.
    The names it has seen are in plugins\my-claude-skills-known-plugins of the Claude config dir, one list
    per config (install.ps1 writes the first). With install.ps1 -Profile, the profiles it recorded in
    plugins\my-claude-skills-profiles limit that to new plugins of those profiles in profiles.json of the
    marketplace clone (the others are logged as available; plugins\my-claude-skills-profile-plugins is the
    snapshot of the profiles' plugins handled so far).
    Runs from a Claude Code SessionStart hook in the background; throttled to once per interval per config
    dir (the stamp plugins\my-claude-skills-last-run sits next to that list).
.PARAMETER Force
    Ignore the throttle and run now.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Log lines')]
param([switch] $Force)

$name = 'my-claude-skills'
$cache = Join-Path $env:LOCALAPPDATA $name
$log = Join-Path $cache 'update.log'
$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$pluginsDir = Join-Path $claudeDir 'plugins'
$knownFile = Join-Path $pluginsDir "$name-known-plugins"   # per config dir: each has its own plugins
# Per config dir too: with one shared stamp, a config that always starts within the interval after
# another one would never update.
$stamp = Join-Path $pluginsDir "$name-last-run"
# install.ps1 -Profile records the profiles this config dir follows; $pknownFile is what the updater has handled of their plugins
$profilesFile = Join-Path $pluginsDir "$name-profiles"
$pknownFile = Join-Path $pluginsDir "$name-profile-plugins"
$interval = if ($env:MY_CLAUDE_SKILLS_INTERVAL) { [int] $env:MY_CLAUDE_SKILLS_INTERVAL } else { 21600 }
New-Item -ItemType Directory -Path $cache, $pluginsDir -Force | Out-Null

if (-not $Force -and (Test-Path $stamp)) {
    $age = ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalSeconds
    if ($age -lt $interval) { exit 0 }
}
New-Item -ItemType File -Path $stamp -Force | Out-Null

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { exit 0 }
Start-Transcript -Path $log -Append | Out-Null
Write-Host "=== $((Get-Date).ToUniversalTime().ToString('s'))Z $claudeDir"   # the log is shared by every config dir

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

# install.ps1 copied this script once: refresh that copy from the marketplace clone so updater fixes
# reach this machine. PowerShell has already read the whole script, so the new copy runs next time.
# Not in a checkout of the repo (.claude-plugin\ next to scripts\): that would overwrite its working tree.
# The temp name is this process's own: runs of other config dirs refresh the same copy.
$selfNew = Join-Path $claudeDir "plugins\marketplaces\$name\scripts\update-plugins.ps1"
if ($PSCommandPath -and (Test-Path $selfNew) -and
    -not (Test-Path (Join-Path (Split-Path $PSCommandPath) '..\.claude-plugin\marketplace.json')) -and
    (Get-FileHash $selfNew).Hash -ne (Get-FileHash $PSCommandPath).Hash) {
    $selfTmp = "$PSCommandPath.$PID"
    try {
        Copy-Item $selfNew $selfTmp -Force -ErrorAction Stop
        Move-Item $selfTmp $PSCommandPath -Force -ErrorAction Stop
        Write-Host "refreshed $PSCommandPath from the marketplace (applies next run)"
    } catch {
        Remove-Item $selfTmp -Force -ErrorAction SilentlyContinue
        Write-Host "could not refresh $PSCommandPath"
    }
}

# Keep the attribution guard current (patterns and git hooks) from the marketplace clone, but only
# where it was installed and not opted out. Re-run install.ps1 to refresh the PreToolUse registration.
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
try {
    $available = @((Get-Content $mp -Raw | ConvertFrom-Json -ErrorAction Stop).plugins | ForEach-Object { $_.name } | Where-Object { $_ })
} catch {
    Write-Host "could not read the plugin names from $mp"; Stop-Transcript | Out-Null; exit 1
}

# Without a list of what is installed, only update: installing would bring back every plugin that
# was left out or uninstalled.
$listed = $false
$installed = @()
$json = (& claude plugin list --json 2>$null) | Out-String
if ($LASTEXITCODE -eq 0 -and $json.TrimStart().StartsWith('[')) {
    try {
        $installed = @(($json | ConvertFrom-Json -ErrorAction Stop) |
            Where-Object { $_.id -like "*@$name" } | ForEach-Object { $_.id -replace "@$name$", '' })
        $listed = $true
    } catch {
        $installed = @()
    }
}
if (-not $listed) { Write-Host 'claude plugin list --json failed or gave no JSON list: updating only, installing no new plugins' }

# Recorded profiles (install.ps1 -Profile): of the new plugins only those of these profiles are installed,
# the others are listed as available. profiles.json of the marketplace clone says which plugins they hold.
# No record: every new plugin is installed.
$recorded = @(if (Test-Path $profilesFile) { Get-Content $profilesFile | Where-Object { $_ -and $_.Trim() } })
$pmode = $recorded.Count -gt 0
$pjOk = $true
$members = @()
if ($pmode) {
    try {
        $pj = Get-Content (Join-Path $claudeDir "plugins\marketplaces\$name\profiles.json") -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $pj.profiles) { throw 'no profiles' }
        $gone = @($recorded | Where-Object { -not $pj.profiles.PSObject.Properties[$_] })
        if ($gone.Count -eq $recorded.Count) {
            $pjOk = $false   # none of them resolves: the same as no profiles.json
            Write-Host "recorded profile(s) not in profiles.json: $($gone -join ','): installing no new plugins"
        } elseif ($gone) {
            Write-Host "recorded profile(s) not in profiles.json: $($gone -join ',')"
        }
        $members = @($recorded | Where-Object { $pj.profiles.PSObject.Properties[$_] } | ForEach-Object { $pj.profiles.$_ })
    } catch {
        $pjOk = $false
        Write-Host "profiles.json of the marketplace clone is missing or unreadable: installing no new plugins (profiles: $($recorded -join ','))"
    }
}
$hasPknown = Test-Path $pknownFile   # an empty snapshot (install.ps1: every plugin of the profiles failed) is a snapshot
$pknown = @(if ($hasPknown) { Get-Content $pknownFile | Where-Object { $_ } })

# New plugins are the ones in the marketplace but not in the snapshot of the earlier runs. Without a
# snapshot yet for this config dir (installed before install.ps1 wrote one), record one and install nothing.
$known = @(if (Test-Path $knownFile) { Get-Content $knownFile | Where-Object { $_ } })
if ($listed -and $known.Count -eq 0) {
    Write-Host "no plugin snapshot yet: recording the marketplace's $($available.Count) plugins, installing none"
}
$record = @()
$precord = @()
$offered = @()
foreach ($p in $available) {
    $member = $pmode -and ($members -contains $p)
    if (-not $listed -or $installed -contains $p) {
        & claude plugin update "$p@$name" 2>&1 | Where-Object { $_ -notmatch 'already' }
    } elseif ($pmode -and -not $pjOk) {
        continue   # cannot tell which plugins the profiles hold: leave this one as it is, decide next run
    } elseif ($member) {
        # a plugin of a recorded profile that the snapshot of those plugins lacks: new, or moved into the profile
        if ($hasPknown -and $pknown -notcontains $p) {
            Write-Host "new plugin: $p"
            & claude plugin install "$p@$name"
            if ($LASTEXITCODE -ne 0) { Write-Host "install failed: $p (retried next run)"; continue }
        }
    } elseif ($known.Count -gt 0 -and $known -notcontains $p) {
        if ($pmode) {
            $offered += $p
        } else {
            Write-Host "new plugin: $p"
            & claude plugin install "$p@$name"
            if ($LASTEXITCODE -ne 0) { Write-Host "install failed: $p (retried next run)"; continue }
        }
    }
    $record += $p
    if ($member) { $precord += $p }
}
if ($offered) { Write-Host "available (outside profiles $($recorded -join ',')): $($offered -join ', ')" }
if ($listed -and $pmode -and $pjOk -and -not $hasPknown) {
    Write-Host "no profile snapshot yet: recording the $($precord.Count) plugins of profiles $($recorded -join ','), installing none"
}

# Only after a pass that saw what is installed. The snapshots keep the names of earlier runs, so a
# plugin that leaves the marketplace and comes back later is not new again. A failed install was not
# in them and is not added, so it is retried.
if ($listed -and $record.Count -gt 0) {
    $record = @(@($record) + @($known) | Select-Object -Unique)
    Set-Content -Path "$knownFile.new" -Value $record
    Move-Item "$knownFile.new" $knownFile -Force
}
if ($listed -and $precord.Count -gt 0) {
    $precord = @(@($precord) + @($pknown) | Select-Object -Unique)
    Set-Content -Path "$pknownFile.new" -Value $precord
    Move-Item "$pknownFile.new" $pknownFile -Force
}
Write-Host 'done'
Stop-Transcript | Out-Null
