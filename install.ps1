#Requires -Version 5.1

<#
.SYNOPSIS
    Installs Claude Code if missing, adds the my-claude-skills marketplace, installs its plugins,
    and installs the tools some plugins depend on (git, Node.js, agent-browser, uv, PowerShell 7, .NET 10 SDK,
    pyright, yaml-language-server, yamllint).
.DESCRIPTION
    Parameter (it belongs to the script block inside, which keeps irm | iex out of the caller's session,
    so Get-Help shows only the common parameters under PARAMETERS):
      -Plugin NAME, ...    install only these plugins; also positional (.\install.ps1 dotnet, powershell).
                           Default: every plugin in the marketplace.
.EXAMPLE
    .\install.ps1                      # every plugin in the marketplace
    .\install.ps1 dotnet, powershell   # only these
    irm https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install.ps1 | iex
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive installer; progress lines are for the console')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '', Justification = 'Official Claude Code and uv installers are distributed as irm | iex')]
param()   # the parameters are the scriptblock's below: here, irm | iex would set them in the caller's session

# Everything runs in its own scope and never calls `exit` under `irm | iex`, which would close the user's
# window: the parameters, variables, functions and $ErrorActionPreference set here stay out of the caller's
# session. Run as a file (.\install.ps1), it exits 1 when a plugin failed.
& {
    [CmdletBinding()]
    param([string[]] $Plugin)
    $ErrorActionPreference = 'Stop'
    $repo = 'lucas4790/my-claude-skills'
    $name = 'my-claude-skills'
    $manifestUrl = "https://raw.githubusercontent.com/$repo/main/.claude-plugin/marketplace.json"
    $minYamllint = [version] '1.30'   # the yaml-hooks hook needs the anchors rule and --list-files
    # The path of this script when it runs as a file (from a clone); $null under `irm | iex`
    $scriptFile = {}.File
    $here = if ($scriptFile) { Split-Path -Parent $scriptFile } else { $null }

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
    # Runs $Command, a native call with 2>$null. Under Stop, Windows PowerShell 5.1 turns redirected stderr
    # into a terminating error, so the preference is Continue for this call only.
    function Invoke-Quiet([scriptblock] $Command) { $ErrorActionPreference = 'Continue'; & $Command }
    # An optional tool install: a failure only warns, so the hook and attribution steps below still run.
    function Invoke-ToolStep([string] $label, [scriptblock] $step) {
        try { & $step } catch { Write-Warning "$label install failed ($($_.Exception.Message))" }
    }
    function Get-YamllintVersion {
        if (-not (Test-Cmd yamllint)) { return $null }
        if ("$(Invoke-Quiet { & yamllint --version 2>$null })" -match '(\d+\.\d+(\.\d+)?)') { [version] $Matches[1] }
    }
    function Test-DesktopClaude { [bool](Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue) }
    # settings.json with comments or trailing commas (JSONC): PowerShell 7 parses it, but rewriting it with
    # ConvertTo-Json would drop the comments. Such a file is left alone, as install.sh does.
    function Test-PlainJson([string] $raw) {
        $noStrings = [regex]::Replace($raw, '"(?:[^"\\]|\\.)*"', '""')
        return -not ($noStrings -match '//|/\*|,\s*[}\]]')
    }
    # UTF-8 without BOM on both Windows PowerShell 5.1 and PowerShell 7
    function Write-Utf8([string] $path, [string] $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)) }

    # --- base dependencies ------------------------------------------------------
    if (-not (Test-Cmd git))  { Install-Winget 'Git.Git' 'Git' }
    if (-not (Test-Cmd node)) { Install-Winget 'OpenJS.NodeJS.LTS' 'Node.js LTS' }
    foreach ($c in 'git', 'node') {
        if (-not (Test-Cmd $c)) { throw "$c not found; install it manually (or open a new terminal after its install), then re-run" }
    }
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
            if ($reply -notmatch '^[yY]') { Write-Host "Aborted at your request."; return }
        }
    }

    # --- Claude Code --------------------------------------------------------------
    if (-not (Test-Cmd claude)) {
        Write-Host "==> Claude Code not found, installing"
        Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
        Initialize-Path
        if (-not (Test-Cmd claude)) { throw "claude still not on PATH after install; open a new terminal and re-run" }
    }
    Write-Host "==> claude $(Invoke-Quiet { & claude --version 2>$null } | Select-Object -First 1)"

    # --- plugin list ----------------------------------------------------------------
    if (-not $Plugin) { $Plugin = (Invoke-RestMethod -Uri $manifestUrl).plugins.name }

    # --- marketplace + plugins ------------------------------------------------------
    $existing = Invoke-Quiet { & claude plugin marketplace list 2>$null }
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

    # The updater's list of known plugins for this Claude config dir (see update-plugins.ps1). A first
    # install records every plugin in the marketplace but the failed ones: plugins left out stay out,
    # and the next update retries a failed one. A re-run adds the plugins it installed and takes the
    # failed ones out.
    $claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    $knownFile = Join-Path (Join-Path $claudeDir 'plugins') "$name-known-plugins"
    $cloneManifest = Join-Path $claudeDir "plugins\marketplaces\$name\.claude-plugin\marketplace.json"
    try {
        $known = if (Test-Path $knownFile) { @(Get-Content $knownFile) + @($Plugin) }
                 elseif (Test-Path $cloneManifest) { (Get-Content $cloneManifest -Raw | ConvertFrom-Json).plugins.name }
        $known = @($known | Where-Object { $_ -and $failed -notcontains $_ } | Select-Object -Unique)
        if ($known) { Write-Utf8 $knownFile (($known -join "`n") + "`n") }
    } catch {
        Write-Warning "could not write $knownFile ($($_.Exception.Message)); the updater's first run records the plugins instead"
    }

    # --- tools ------------------------------------------------------------------------
    # npm.cmd and agent-browser.cmd, not their .ps1 shims: those do not run under the Restricted execution policy.
    if ($Plugin -contains 'agent-browser') {
        Invoke-ToolStep 'agent-browser' {
            if (Test-Cmd agent-browser) {
                Write-Host "==> agent-browser present"
            } else {
                Write-Host "==> installing agent-browser"
                & npm.cmd install -g agent-browser
                Initialize-Path
                if ($LASTEXITCODE -eq 0) { & agent-browser.cmd install }
                if ($LASTEXITCODE -ne 0) { Write-Warning "agent-browser install failed; run: npm i -g agent-browser; agent-browser install" }
            }
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
        Invoke-ToolStep 'PowerShell 7' {
            if (-not (Test-Cmd pwsh)) { Install-Winget 'Microsoft.PowerShell' 'PowerShell 7' }
            if (Test-Cmd pwsh) {
                Write-Host "==> pwsh present ($(& pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'))"
                # Pester 6: Windows ships Pester 3.4, which is signed with another certificate (-SkipPublisherCheck).
                # No double quotes in the command: Windows PowerShell 5.1 drops them when it starts pwsh.
                & pwsh -NoProfile -Command 'if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Install-Module PSScriptAnalyzer -Scope CurrentUser -Force }; if (-not (Get-Module -ListAvailable Pester | Where-Object Version -ge 6.0.0)) { Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser -Force -SkipPublisherCheck }'
                if ($LASTEXITCODE -ne 0) { Write-Warning "PSScriptAnalyzer/Pester install failed; run Install-Module manually" }
            }
        }
    }

    if ($Plugin -contains 'dotnet') {
        Invoke-ToolStep '.NET 10 SDK' {
            $sdks = if (Test-Cmd dotnet) { Invoke-Quiet { & dotnet --list-sdks 2>$null } } else { @() }
            if ($sdks -match '^10\.') {
                Write-Host "==> .NET 10 SDK present ($(& dotnet --version))"
            } else {
                Install-Winget 'Microsoft.DotNet.SDK.10' '.NET 10 SDK'
            }
        }
    }

    if ($Plugin -contains 'pyright-lsp') {
        Invoke-ToolStep 'pyright' {
            if (Test-Cmd pyright-langserver) {
                Write-Host "==> pyright present"
            } else {
                Write-Host "==> installing pyright"
                & npm.cmd install -g pyright
                if ($LASTEXITCODE -ne 0) { Write-Warning "pyright install failed; run: npm i -g pyright" }
                Initialize-Path
            }
        }
    }

    if ($Plugin -contains 'yaml-lsp') {
        Invoke-ToolStep 'yaml-language-server' {
            if (Test-Cmd yaml-language-server) {
                Write-Host "==> yaml-language-server present"
            } else {
                Write-Host "==> installing yaml-language-server"
                & npm.cmd install -g yaml-language-server
                if ($LASTEXITCODE -ne 0) { Write-Warning "yaml-language-server install failed; run: npm i -g yaml-language-server" }
                Initialize-Path
            }
        }
    }

    if ($Plugin -contains 'yaml-hooks') {
        # winget has no yamllint package; uv installs or upgrades it as a tool (and uv itself comes from winget
        # when missing). With a yamllint older than $minYamllint the yaml-hooks hook does not lint (it only
        # reports that it is inactive).
        Invoke-ToolStep 'yamllint' {
            $version = Get-YamllintVersion
            if ($version -ge $minYamllint) { Write-Host "==> yamllint present ($version)"; return }
            if (-not (Test-Cmd uv)) { Install-Winget 'astral-sh.uv' 'uv' }
            if (-not (Test-Cmd uv)) {
                Write-Warning "uv not found; install yamllint $minYamllint or newer for the yaml-hooks plugin: uv tool install yamllint (or pipx install yamllint)"
                return
            }
            if ((Invoke-Quiet { & uv tool list 2>$null }) -match '^yamllint ') {
                Write-Host "==> upgrading yamllint $version via uv tool (yaml-hooks needs $minYamllint or newer)"
                & uv tool upgrade yamllint
            } else {
                Write-Host "==> installing yamllint via uv tool"
                & uv tool install yamllint
            }
            if ($LASTEXITCODE -ne 0) { Write-Warning "yamllint install failed; run: uv tool install yamllint" }
            & uv tool update-shell   # puts uv's tool directory on the user PATH (no 2>$null: with Stop, PS 5.1 would throw on its stderr)
            Initialize-Path
            $version = Get-YamllintVersion
            if ($version -and $version -lt $minYamllint) {
                Write-Warning "yamllint $version ($((Get-Command yamllint).Source)) comes first on PATH and is older than $minYamllint; the yaml-hooks hook does not lint with it (it only reports that it is inactive). Upgrade or remove it (pip install -U yamllint, pipx upgrade yamllint)"
            }
        }
    }

    # --- startup auto-update hook ------------------------------------------------------
    $data = Join-Path $env:LOCALAPPDATA $name
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    $updater = Join-Path $data 'update-plugins.ps1'
    $localUpdater = if ($here) { Join-Path $here 'scripts\update-plugins.ps1' } else { $null }
    try {
        if ($localUpdater -and (Test-Path $localUpdater)) { Copy-Item $localUpdater $updater -Force }
        else { Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$repo/main/scripts/update-plugins.ps1" -OutFile $updater }
    } catch {
        Write-Warning "could not fetch update-plugins.ps1 ($($_.Exception.Message)); startup auto-update hook not installed"
        $updater = $null
    }
    $settingsPath = Join-Path $claudeDir 'settings.json'
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
    # A missing, empty or blank settings.json starts as {}, as in install.sh.
    if (-not (Test-Path $settingsPath) -or -not "$(Get-Content $settingsPath -Raw -Encoding UTF8)".Trim()) { Write-Utf8 $settingsPath '{}' }
    $raw = Get-Content $settingsPath -Raw -Encoding UTF8
    if ($updater -and -not (Test-PlainJson $raw) -and $raw -match "$([regex]::Escape($name))[\\/]+update-plugins\.ps1") {
        # comments or trailing commas, and our hook added by hand (as the warning below asks), as install.sh sees it
        Write-Host '==> startup auto-update hook already registered'
    } elseif ($updater) {
        $hookCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$updater`""
        try {
            if (-not (Test-PlainJson $raw)) { throw 'not plain JSON (comments or trailing commas)' }
            $settings = $raw | ConvertFrom-Json
            if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
            # Replace an earlier registration (any path to update-plugins.ps1 in a my-claude-skills directory)
            # instead of adding another one; other hooks in the same group stay.
            $start = @()
            if ($settings.hooks.PSObject.Properties['SessionStart']) {
                $start = @(foreach ($g in @($settings.hooks.SessionStart)) {
                    $kept = @($g.hooks | Where-Object { "$($_.command)" -notmatch "$([regex]::Escape($name))[\\/]update-plugins\.ps1" })
                    if ($kept.Count -gt 0) { $g | Add-Member -NotePropertyName hooks -NotePropertyValue $kept -Force; $g }
                })
            }
            $start += [pscustomobject]@{
                matcher = 'startup'
                hooks   = @([pscustomobject]@{ type = 'command'; shell = 'powershell'; command = $hookCmd; async = $true })
            }
            $settings.hooks | Add-Member -NotePropertyName SessionStart -NotePropertyValue $start -Force
            Write-Utf8 $settingsPath ($settings | ConvertTo-Json -Depth 20)
            Write-Host "==> SessionStart auto-update hook registered in $settingsPath"
        } catch {
            Write-Warning "could not register the startup auto-update hook in $settingsPath ($($_.Exception.Message)); add a SessionStart hook (matcher startup, async) that runs: $hookCmd"
        }
    }

    # --- no AI attribution -----------------------------------------------------------------
    # Claude Code: no co-author trailers, PR footers or session links; git: a global commit-msg/pre-push
    # guard for every repository, run by Git for Windows' sh.exe. See docs/ATTRIBUTION.md.
    # $env:MY_CLAUDE_SKILLS_ATTRIBUTION = 'keep' skips this.
    if ($env:MY_CLAUDE_SKILLS_ATTRIBUTION -ne 'keep') {
        try {
            if (-not (Test-PlainJson (Get-Content $settingsPath -Raw -Encoding UTF8))) { throw 'not plain JSON (comments or trailing commas)' }
            $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $settings | Add-Member -NotePropertyName attribution -NotePropertyValue ([pscustomobject]@{ commit = ''; pr = ''; sessionUrl = $false }) -Force
            Write-Utf8 $settingsPath ($settings | ConvertTo-Json -Depth 20)
            Write-Host "==> AI attribution off in $settingsPath"
        } catch {
            Write-Warning "could not update $settingsPath; add `"attribution`": {`"commit`": `"`", `"pr`": `"`", `"sessionUrl`": false} by hand"
        }
        # Git for Windows' sh.exe: <root>\bin\sh.exe, with <root> three levels above `git --exec-path`
        # (<root>\mingw64\libexec\git-core; also for Scoop), else whatever sh.exe is on PATH.
        $sh = $null
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $execPath = Invoke-Quiet { & git --exec-path 2>$null }
            if ($execPath) {
                $candidate = Join-Path (Split-Path (Split-Path (Split-Path ($execPath -replace '/', '\')))) 'bin\sh.exe'
                if (Test-Path $candidate) { $sh = $candidate }
            }
        }
        if (-not $sh) { $sh = (Get-Command sh.exe -ErrorAction SilentlyContinue).Source }
        if ($sh -and (Test-Path $sh)) {
            try {
                $guardDir = if ($here) { Join-Path $here 'tools\attribution-guard' } else { $null }
                if (-not ($guardDir -and (Test-Path (Join-Path $guardDir 'install.sh')))) {
                    $guardDir = Join-Path ([IO.Path]::GetTempPath()) "attribution-guard-$PID"
                    New-Item -ItemType Directory -Path $guardDir -Force | Out-Null
                    foreach ($f in 'attribution-guard.sh', 'patterns.ere', 'claude-pretooluse.sh', 'dispatch', 'install.sh') {
                        Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$repo/main/tools/attribution-guard/$f" -OutFile (Join-Path $guardDir $f)
                    }
                }
                # Only for this call: left in the session, it would make a later guard install skip the Claude hook.
                $skipBefore = $env:ATTRIBUTION_GUARD_SKIP_CLAUDE
                $env:ATTRIBUTION_GUARD_SKIP_CLAUDE = '1'
                try { & $sh (Join-Path $guardDir 'install.sh') }
                finally { $env:ATTRIBUTION_GUARD_SKIP_CLAUDE = $skipBefore }
                if ($LASTEXITCODE -ne 0) { Write-Warning 'git attribution guard not installed; run: sh tools/attribution-guard/install.sh from Git Bash' }
                # Claude Code PreToolUse hook for every repository (hooks run in Git Bash on Windows).
                # Replace an earlier registration so matcher and command stay current.
                if (-not (Test-PlainJson (Get-Content $settingsPath -Raw -Encoding UTF8))) { throw "$settingsPath is not plain JSON; add the PreToolUse hook by hand (docs/ATTRIBUTION.md)" }
                $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $settings.PSObject.Properties['hooks']) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
                $pre = @()
                if ($settings.hooks.PSObject.Properties['PreToolUse']) {
                    # Remove only our own hook entries; other hooks in the same group stay.
                    $pre = @(foreach ($g in @($settings.hooks.PreToolUse)) {
                        $kept = @($g.hooks | Where-Object { "$($_.command)" -notmatch 'attribution-guard/claude-pretooluse\.sh' })
                        if ($kept.Count -gt 0) { $g | Add-Member -NotePropertyName hooks -NotePropertyValue $kept -Force; $g }
                    })
                }
                # bash expands XDG_CONFIG_HOME at hook time, the same way install.sh chose the directory.
                $cmd = 'f="${XDG_CONFIG_HOME:-$HOME/.config}/git/attribution-guard/claude-pretooluse.sh"; [ ! -f "$f" ] || sh "$f"'
                $pre += [pscustomobject]@{ matcher = 'Bash|PowerShell|Monitor|Write|Edit|MultiEdit|NotebookEdit|mcp__.*([Gg]it[Hh]ub|[Aa]do|[Aa]zure|[Dd]ev[Oo]ps).*'; hooks = @([pscustomobject]@{ type = 'command'; shell = 'bash'; command = $cmd }) }
                $settings.hooks | Add-Member -NotePropertyName PreToolUse -NotePropertyValue $pre -Force
                Write-Utf8 $settingsPath ($settings | ConvertTo-Json -Depth 20)
                Write-Host "==> Claude Code attribution hook registered in $settingsPath"
            } catch {
                Write-Warning "could not install the git attribution guard ($($_.Exception.Message)); run: sh tools/attribution-guard/install.sh from Git Bash"
            }
        } else {
            Write-Warning 'Git for Windows sh.exe not found; install the git attribution guard from Git Bash: sh tools/attribution-guard/install.sh'
        }
    }

    Write-Host ""
    Write-Host "Done. Restart Claude Code to load the plugins."
    if ($failed) {
        Write-Warning "failed plugins: $($failed -join ', ') (see above)"
        if ($scriptFile) { exit 1 }
    }
} @args   # the script's arguments (.\install.ps1 a, b or -Plugin a, b); none under irm | iex
