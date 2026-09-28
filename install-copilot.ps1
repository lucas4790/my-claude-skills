#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the my-claude-skills marketplace for GitHub Copilot: Copilot CLI, and through it VS Code
    (VS Code discovers plugins installed by Copilot CLI in %USERPROFILE%\.copilot\installed-plugins).
    Claude Code keeps using install.ps1; both read the same .claude-plugin/marketplace.json.
.EXAMPLE
    .\install-copilot.ps1                              # profiles in profiles.json "copilotDefault" (cloud)
    .\install-copilot.ps1 -Profile cloud, dotnet
    .\install-copilot.ps1 -Plugin terraform, pyright-lsp
    irm https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install-copilot.ps1 | iex
    $env:MY_CLAUDE_SKILLS_PROFILE = 'cloud,dotnet'; irm .../install-copilot.ps1 | iex
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive installer; progress lines are for the console')]
param([Alias('Profile')] [string[]] $Profiles, [string[]] $Plugin)

# Everything lives in a function and never calls `exit`: under `irm | iex` that would close the user's shell.
function Install-MyClaudeSkillsForCopilot([string[]] $Profiles, [string[]] $Plugin) {
    $ErrorActionPreference = 'Stop'
    $repo = 'lucas4790/my-claude-skills'
    $name = 'my-claude-skills'
    $raw = "https://raw.githubusercontent.com/$repo/main"
    $minCopilot = [version] '1.0.70'   # first release that honours the sha pin on url sources (caveman)

    function Test-Cmd([string] $cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
    function Initialize-Path {
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }

    # --- Copilot CLI ------------------------------------------------------------------
    if (-not (Test-Cmd copilot)) {
        if (Test-Cmd winget) {
            Write-Host '==> installing GitHub Copilot CLI via winget'
            & winget install --id GitHub.Copilot -e --accept-source-agreements --accept-package-agreements --silent
            Initialize-Path
        }
        if (-not (Test-Cmd copilot) -and (Test-Cmd npm.cmd)) {
            Write-Host '==> installing GitHub Copilot CLI (npm -g @github/copilot)'
            & npm.cmd install -g '@github/copilot'   # npm.cmd, not npm.ps1: works under the Restricted execution policy
            Initialize-Path
        }
        if (-not (Test-Cmd copilot)) {
            Write-Warning 'Copilot CLI not found; install it (winget install GitHub.Copilot, or npm i -g @github/copilot) and re-run'
            return $false
        }
    }
    $verText = (& copilot --version 2>$null | Select-Object -First 1)
    Write-Host "==> $verText"
    if ($verText -match '(\d+\.\d+\.\d+)' -and [version] $Matches[1] -lt $minCopilot) {
        Write-Warning "Copilot CLI $($Matches[1]) is older than $minCopilot (sha-pinned sources such as caveman need it); run: copilot update"
    }

    # --- plugin list --------------------------------------------------------------------
    $localProfiles = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'profiles.json' } else { $null }
    $pj = if ($localProfiles -and (Test-Path $localProfiles)) { Get-Content $localProfiles -Raw | ConvertFrom-Json }
          else { Invoke-RestMethod -Uri "$raw/profiles.json" }
    if (-not $Plugin) {
        if (-not $Profiles) {
            $Profiles = if ($env:MY_CLAUDE_SKILLS_PROFILE) { $env:MY_CLAUDE_SKILLS_PROFILE -split ',' } else { $pj.copilotDefault }
        }
        $Profiles = @($Profiles | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $unknown = @($Profiles | Where-Object { -not $pj.profiles.PSObject.Properties[$_] })
        if ($unknown) { Write-Warning "unknown profile(s): $($unknown -join ', ') (see profiles.json)"; return $false }
        if ($Profiles -contains 'claude-only') {
            Write-Warning 'skipping profile claude-only (needs Claude Code); name its plugins with -Plugin to install them anyway'
        }
        $Plugin = @($Profiles | Where-Object { $_ -ne 'claude-only' } | ForEach-Object { $pj.profiles.$_ })
        # caveman's hooks are POSIX shell only; on native Windows they would fail at every session start
        if ($Plugin -contains 'caveman' -and ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows)) {
            Write-Warning 'skipping caveman on Windows (POSIX-only hooks); use it from WSL or name it with -Plugin'
            $Plugin = @($Plugin | Where-Object { $_ -ne 'caveman' })
        }
    }
    if (-not $Plugin) { Write-Warning 'no plugins selected'; return $false }

    # --- marketplace + plugins ------------------------------------------------------------
    $existing = & copilot plugin marketplace list 2>$null
    if ($existing -match $name) {
        Write-Host "==> updating marketplace $name"
        & copilot plugin marketplace update $name
    } else {
        Write-Host "==> adding marketplace $name"
        & copilot plugin marketplace add $repo
        if ($LASTEXITCODE -ne 0) { Write-Warning 'could not add the marketplace'; return $false }
    }

    $failed = @()
    foreach ($p in $Plugin) {
        Write-Host "==> installing $p"
        & copilot plugin install "$p@$name"
        if ($LASTEXITCODE -ne 0) { $failed += $p }
    }
    Write-Host "Installed $($Plugin.Count) plugin(s) from $name into Copilot CLI."
    if ($failed) { Write-Warning "failed plugins: $($failed -join ', ')" }

    # --- auto-update -------------------------------------------------------------------------
    # Copilot CLI refreshes a user-added marketplace at session start only with autoUpdate: true.
    $home_ = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
    $cfg = Join-Path $home_ 'settings.json'
    try {
        $settings = Get-Content $cfg -Raw | ConvertFrom-Json
        if (-not $settings.PSObject.Properties['extraKnownMarketplaces']) {
            $settings | Add-Member -NotePropertyName extraKnownMarketplaces -NotePropertyValue ([pscustomobject]@{})
        }
        $entry = $settings.extraKnownMarketplaces.PSObject.Properties[$name]
        if (-not $entry) {
            $settings.extraKnownMarketplaces | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{
                source = [pscustomobject]@{ source = 'github'; repo = $repo } })
        }
        $settings.extraKnownMarketplaces.$name | Add-Member -NotePropertyName autoUpdate -NotePropertyValue $true -Force
        # No AI co-author trailers on commits made by Copilot CLI (docs/ATTRIBUTION.md).
        $settings | Add-Member -NotePropertyName includeCoAuthoredBy -NotePropertyValue $false -Force
        # UTF-8 without BOM on both Windows PowerShell 5.1 and PowerShell 7
        [IO.File]::WriteAllText($cfg, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
        Write-Host "==> enabled autoUpdate for $name and turned off AI co-author trailers (includeCoAuthoredBy) in $cfg"
    } catch {
        Write-Warning "could not update $cfg ($($_.Exception.Message)); set extraKnownMarketplaces.$name.autoUpdate = true by hand"
    }

    Write-Host @"

Done. Copilot CLI: start a new session, then check with 'copilot plugin list' and 'copilot skill list'.

VS Code (GitHub Copilot Chat, VS Code 1.110+) picks these plugins up automatically. Once:
  1. Settings: make sure "chat.plugins.enabled" is on (locked if your organisation manages it).
  2. Settings: "chat.plugins.marketplaces" -> Add Item -> $repo  (keep the default entries).
  3. Developer: Reload Window, then Extensions view -> @agentPlugins to see and manage them.
  Template with the other useful settings: settings/vscode-settings.jsonc in $repo.
"@
    return (-not $failed)
}

$ok = Install-MyClaudeSkillsForCopilot -Profiles $Profiles -Plugin $Plugin
if (-not $ok) { Write-Warning 'install-copilot finished with problems (see above)' }
