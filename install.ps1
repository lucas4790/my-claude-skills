#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Claude Code if missing, adds the my-claude-skills marketplace, installs its plugins,
    and installs the tools some plugins depend on (git, Node.js, agent-browser, uv, PowerShell 7, .NET 10 SDK).
.EXAMPLE
    .\install.ps1                      # every plugin in the marketplace
    .\install.ps1 dotnet, powershell   # only these
    irm https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install.ps1 | iex
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive installer; progress lines are for the console')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'Official Claude Code and uv installers are distributed as irm | iex')]
param([string[]] $Plugin)

$ErrorActionPreference = 'Stop'
$repo = 'lucas4790/my-claude-skills'
$name = 'my-claude-skills'
$manifestUrl = "https://raw.githubusercontent.com/$repo/main/.claude-plugin/marketplace.json"

function Test-Cmd([string] $cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Initialize-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Install-Winget([string] $id, [string] $label) {
    if (-not (Test-Cmd winget)) { Write-Warning "winget not found; install $label manually"; return }
    Write-Host "==> installing $label via winget"
    & winget install --id $id -e --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -notin 0, -1978335189) { Write-Warning "$label install returned $LASTEXITCODE" }
    Initialize-Path
}
function Test-DesktopClaude { [bool](Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue) }

# --- base dependencies ------------------------------------------------------
if (-not (Test-Cmd git))  { Install-Winget 'Git.Git' 'Git' }
if (-not (Test-Cmd node)) { Install-Winget 'OpenJS.NodeJS.LTS' 'Node.js LTS' }
Write-Host "==> base deps: git $(& git --version), node $(& node --version)"

# --- desktop app check ---------------------------------------------------------
# Plugins live in ~/.claude/plugins, which both the desktop app and the CLI read, so
# installing via the CLI here also reaches the desktop app (after it is restarted).
# The desktop app has no plugin-install command of its own, so the CLI is still needed
# either way; this just makes sure that's not a surprise when only the desktop app is around.
if (Test-DesktopClaude) {
    if (Test-Cmd claude) {
        Write-Host "==> found both the Claude desktop app and the claude CLI"
    } else {
        Write-Host "==> found the Claude desktop app (no claude CLI yet)"
    }
    if (-not $env:MY_CLAUDE_SKILLS_YES) {
        $reply = Read-Host "    Continue installing/updating plugins via the CLI, shared with the desktop app? [y/N]"
        if ($reply -notmatch '^[yY]') { Write-Host "Aborted at your request."; exit 0 }
    }
}

# --- Claude Code --------------------------------------------------------------
if (-not (Test-Cmd claude)) {
    Write-Host "==> Claude Code not found, installing"
    Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    Initialize-Path
    if (-not (Test-Cmd claude)) { throw "claude still not on PATH after install; open a new terminal and re-run" }
}
Write-Host "==> claude $(& claude --version 2>$null | Select-Object -First 1)"

# --- plugin list ----------------------------------------------------------------
if (-not $Plugin) { $Plugin = (Invoke-RestMethod -Uri $manifestUrl).plugins.name }

# --- marketplace + plugins ------------------------------------------------------
$existing = & claude plugin marketplace list 2>$null
if ($existing -match $name) {
    Write-Host "==> updating marketplace $name"
    & claude plugin marketplace update $name
} else {
    Write-Host "==> adding marketplace $name"
    & claude plugin marketplace add $repo
}

$failed = @()
foreach ($p in $Plugin) {
    Write-Host "==> installing $p"
    & claude plugin install "$p@$name"
    if ($LASTEXITCODE -ne 0) { $failed += $p }
}
Write-Host "Installed $($Plugin.Count) plugin(s) from $name."
if ($failed) { Write-Warning "failed plugins: $($failed -join ', ')" }

# --- tools ------------------------------------------------------------------------
if ($Plugin -contains 'agent-browser') {
    if (Test-Cmd agent-browser) {
        Write-Host "==> agent-browser present"
    } else {
        Write-Host "==> installing agent-browser"
        & npm install -g agent-browser
        Initialize-Path
        if ($LASTEXITCODE -eq 0) { & agent-browser install }
        if ($LASTEXITCODE -ne 0) { Write-Warning "agent-browser install failed; run: npm i -g agent-browser; agent-browser install" }
    }
}

if ($Plugin -contains 'spec-kit') {
    if (Test-Cmd uv) {
        Write-Host "==> uv present ($(& uv --version))"
    } else {
        Write-Host "==> installing uv"
        try { Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression; Initialize-Path }
        catch { Write-Warning "uv install failed; see https://docs.astral.sh/uv/" }
    }
}

if ($Plugin -contains 'powershell') {
    if (-not (Test-Cmd pwsh)) { Install-Winget 'Microsoft.PowerShell' 'PowerShell 7' }
    if (Test-Cmd pwsh) {
        Write-Host "==> pwsh present ($(& pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'))"
        & pwsh -NoProfile -Command 'foreach ($m in "PSScriptAnalyzer","Pester") { if (-not (Get-Module -ListAvailable $m)) { Install-Module $m -Scope CurrentUser -Force } }'
        if ($LASTEXITCODE -ne 0) { Write-Warning "PSScriptAnalyzer/Pester install failed; run Install-Module manually" }
    }
}

if ($Plugin -contains 'dotnet') {
    $sdks = if (Test-Cmd dotnet) { & dotnet --list-sdks 2>$null } else { @() }
    if ($sdks -match '^10\.') {
        Write-Host "==> .NET 10 SDK present ($(& dotnet --version))"
    } else {
        Install-Winget 'Microsoft.DotNet.SDK.10' '.NET 10 SDK'
    }
}

# --- startup auto-update hook ------------------------------------------------------
$data = Join-Path $env:LOCALAPPDATA $name
New-Item -ItemType Directory -Path $data -Force | Out-Null
$updater = Join-Path $data 'update-plugins.ps1'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$repo/main/scripts/update-plugins.ps1" -OutFile $updater
$settingsPath = Join-Path $HOME '.claude\settings.json'
if (-not (Test-Path $settingsPath)) { New-Item -ItemType Directory -Path (Split-Path $settingsPath) -Force | Out-Null; Set-Content $settingsPath '{}' }
$raw = Get-Content $settingsPath -Raw
if ($raw -match [regex]::Escape("$name\update-plugins.ps1")) {
    Write-Host "==> startup auto-update hook already registered"
} else {
    Write-Host "==> registering SessionStart auto-update hook in $settingsPath"
    $settings = $raw | ConvertFrom-Json
    if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    $hook = [pscustomobject]@{
        matcher = 'startup'
        hooks   = @([pscustomobject]@{ type = 'command'; shell = 'powershell'; command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$updater`""; async = $true })
    }
    $existing = @()
    if ($settings.hooks.PSObject.Properties['SessionStart']) { $existing = @($settings.hooks.SessionStart) }
    $settings.hooks | Add-Member -NotePropertyName SessionStart -NotePropertyValue (@($existing) + @($hook)) -Force
    $settings | ConvertTo-Json -Depth 20 | Set-Content $settingsPath -Encoding utf8
}

# --- no AI attribution -----------------------------------------------------------------
# Claude Code: no co-author trailers, PR footers or session links; git: a global commit-msg/pre-push
# guard for every repository, run by Git for Windows' sh.exe. See docs/ATTRIBUTION.md.
# $env:MY_CLAUDE_SKILLS_ATTRIBUTION = 'keep' skips this.
if ($env:MY_CLAUDE_SKILLS_ATTRIBUTION -ne 'keep') {
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $settings | Add-Member -NotePropertyName attribution -NotePropertyValue ([pscustomobject]@{ commit = ''; pr = ''; sessionUrl = $false }) -Force
        [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
        Write-Host "==> AI attribution off in $settingsPath"
    } catch {
        Write-Warning "could not update $settingsPath; add `"attribution`": {`"commit`": `"`", `"pr`": `"`", `"sessionUrl`": false} by hand"
    }
    $git = Get-Command git -ErrorAction SilentlyContinue
    $sh = if ($git) { Join-Path (Split-Path (Split-Path $git.Source)) 'bin\sh.exe' } else { $null }
    if ($sh -and (Test-Path $sh)) {
        $guardDir = Join-Path ([IO.Path]::GetTempPath()) "attribution-guard-$PID"
        New-Item -ItemType Directory -Path $guardDir -Force | Out-Null
        try {
            foreach ($f in 'attribution-guard.sh', 'patterns.ere', 'claude-pretooluse.sh', 'dispatch', 'install.sh') {
                Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$repo/main/tools/attribution-guard/$f" -OutFile (Join-Path $guardDir $f)
            }
            $env:ATTRIBUTION_GUARD_SKIP_CLAUDE = '1'
            & $sh (Join-Path $guardDir 'install.sh')
            if ($LASTEXITCODE -ne 0) { Write-Warning 'git attribution guard not installed; run: sh tools/attribution-guard/install.sh from Git Bash' }
            # Claude Code PreToolUse hook for every repository (hooks run in Git Bash on Windows).
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ((Get-Content $settingsPath -Raw) -notmatch 'attribution-guard/claude-pretooluse\.sh') {
                if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
                $pre = @()
                if ($settings.hooks.PSObject.Properties['PreToolUse']) { $pre = @($settings.hooks.PreToolUse) }
                $cmd = 'f="$HOME/.config/git/attribution-guard/claude-pretooluse.sh"; [ ! -f "$f" ] || sh "$f"'
                $pre += [pscustomobject]@{ matcher = 'Bash|PowerShell|mcp__.*(github|ado|azure|devops).*'; hooks = @([pscustomobject]@{ type = 'command'; command = $cmd }) }
                $settings.hooks | Add-Member -NotePropertyName PreToolUse -NotePropertyValue $pre -Force
                [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
                Write-Host "==> Claude Code attribution hook registered in $settingsPath"
            }
        } catch {
            Write-Warning "could not install the git attribution guard ($($_.Exception.Message)); run: sh tools/attribution-guard/install.sh from Git Bash"
        }
    } else {
        Write-Warning 'Git for Windows sh.exe not found; install the git attribution guard from Git Bash: sh tools/attribution-guard/install.sh'
    }
}

Write-Host ""
Write-Host "Done. Restart Claude Code to load the plugins."
if ($failed) { exit 1 }
