#Requires -Version 5.1
<#
.SYNOPSIS
    Adds the my-claude-skills marketplace to Claude Code and installs its plugins.
.EXAMPLE
    .\install.ps1                      # every plugin in the marketplace
    .\install.ps1 dotnet powershell    # only these
    irm https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install.ps1 | iex
#>
[CmdletBinding()]
param([string[]] $Plugin)

$ErrorActionPreference = 'Stop'
$repo = 'lucas4790/my-claude-skills'
$name = 'my-claude-skills'
$manifestUrl = "https://raw.githubusercontent.com/$repo/main/.claude-plugin/marketplace.json"

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    throw "'claude' CLI not found - install Claude Code first: https://code.claude.com/docs"
}

if (-not $Plugin) {
    $Plugin = (Invoke-RestMethod -Uri $manifestUrl).plugins.name
}

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

Write-Host ""
Write-Host "Installed $($Plugin.Count) plugin(s) from $name."
if ($failed) { Write-Warning "Failed: $($failed -join ', ')" }
Write-Host @'

Restart Claude Code to load them. Optional tooling some plugins rely on:
  .NET 10 SDK            (dotnet C# language server)   https://dot.net
  agent-browser          npm i -g agent-browser; agent-browser install
  uv                     (spec-kit)                     https://docs.astral.sh/uv/
  PSScriptAnalyzer + Pester   Install-Module PSScriptAnalyzer, Pester -Scope CurrentUser
'@
if ($failed) { exit 1 }
