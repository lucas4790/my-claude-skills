---
name: powershell-agent-skills
description: >-
  Comprehensive PowerShell development skill — scripts, modules, MCP services,
  AI agents, GUIs, CI/CD, and enterprise automation. Amalgamates patterns from
  18 top PowerShell agent skills across the ecosystem.
license: MIT
compatibility: opencode, claude-code, codex-cli, copilot-cli, gemini-cli, cursor
---

# PowerShell Agent Skill Pack

Develop production-quality PowerShell across the full spectrum: scripts, modules, MCP services, AI/agent orchestration, GUIs, CI/CD, and cross-platform automation.

## Quick Reference

### Script Template (advanced)

```powershell
#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

<#
.SYNOPSIS
    Brief description
.DESCRIPTION
    Detailed description
.PARAMETER Name
    Parameter description
.EXAMPLE
    Verb-Noun -Name 'Value'
.NOTES
    Author:    Name
    Requires:  PowerShell 7.4+
    Module:    ModuleName
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
    [ValidateNotNullOrEmpty()]
    [SupportsWildcards()]
    [string[]]$Name,

    [Parameter(ValueFromPipelineByPropertyName)]
    [Alias('CN')]
    [string]$ComputerName = $env:COMPUTERNAME,

    [Parameter()]
    [ValidateSet('Basic', 'Detailed', 'Full')]
    [string]$Level = 'Basic',

    [Parameter()]
    [securestring]$Credential,

    [switch]$Force,
    [switch]$PassThru
)

begin {
    Write-Verbose "Starting $($MyInvocation.MyCommand)"
    $results = [System.Collections.Generic.List[object]]::new()
}

process {
    if ($Force -or $PSCmdlet.ShouldProcess($Name, 'Action')) {
        try {
            # Implementation
            if ($PassThru) { $results.Add($result) }
        } catch {
            Write-Error -Message "Failed on $Name: $_" -Category InvalidOperation
            continue
        }
    }
}

end {
    Write-Verbose "Completed $($MyInvocation.MyCommand)"
    if ($PassThru -and $results.Count) { $results }
}
```

### Module Template

```powershell
# Module: Your.Module.Name
# Requires -Version 7.4

using module .\path\to\helper.psm1

enum Status {
    Pending
    Running
    Completed
    Failed
}

class Result {
    [string]$Id
    [Status]$Status
    [datetime]$Timestamp
    [string]$Message
}

function Get-TargetResource {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$Name
    )
    @{
        Name   = $Name
        Ensure = 'Present'
        Status = 'Running'
    }
}

function Set-TargetResource {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [ValidateSet('Present', 'Absent')] [string]$Ensure = 'Present'
    )
}

Export-ModuleMember -Function @(
    'Get-TargetResource'
    'Set-TargetResource'
)
```

### MCP Service Template

```powershell
#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'PowerShell.MCP'; ModuleVersion = '1.3' }

# MCP tool function — registered automatically by PowerShell.MCP
function Invoke-McpTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ToolName,
        [Parameter()] [hashtable]$Arguments = @{}
    )

    switch ($ToolName) {
        'system_info' {
            Get-ComputerInfo | Select-Object OsName, OsVersion, TotalPhysicalMemory
        }
        'process_list' {
            Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet |
                Sort-Object WorkingSet -Descending
        }
        'disk_usage' {
            Get-PSDrive -PSProvider FileSystem |
                Select-Object Name, @{N='Used(GB)';E={[math]::Round(($_.Used/1GB),2)}},
                    @{N='Free(GB)';E={[math]::Round(($_.Free/1GB),2)}}
        }
        default { throw "Unknown tool: $ToolName" }
    }
}
```

### AI Agent Function Template

```powershell
#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'PSAI'; ModuleVersion = '1.0' }
#Requires -Version 7.1

function Invoke-AiAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter()] [string]$Model = 'gpt-4',
        [Parameter()] [int]$MaxTokens = 2000,
        [Parameter()] [string[]]$Tools
    )

    $messages = @(
        @{ role = 'system'; content = 'You are a PowerShell automation assistant.' }
        @{ role = 'user'; content = $Prompt }
    )

    $response = Invoke-OpenAIChat -Model $Model -Messages $messages -MaxTokens $MaxTokens
    $response.choices[0].message.content
}
```

## Workflow

### 1. Script Development

**Naming** — Use approved verbs (`Get-Verb`), singular PascalCase nouns, full cmdlet names (no aliases in scripts).

**Parameters** — Strong typing with validation attributes (`[ValidateNotNullOrEmpty()]`, `[ValidateSet()]`, `[ValidateRange()]`, `[SupportsWildcards()]`). Pipeline support via `ValueFromPipeline` and `ValueFromPipelineByPropertyName`. Use `[switch]` for boolean flags (never `[bool]`).

**Error handling** — Use `try/catch` with specific exception types. `$ErrorActionPreference = 'Stop'` for critical sections. `Write-Error` for non-terminating, `throw` for terminating. Include `-Category` on `Write-Error`.

**Security** — Avoid `Invoke-Expression`. Use `SecureString` for credentials. Validate input paths. Prefer `-WhatIf`/`-Confirm` (`SupportsShouldProcess`) for destructive ops.

**Cross-platform** — Use `[System.IO.Path]::Combine()` or `Join-Path` over string concatenation. Check `$IsWindows`/`$IsLinux`/`$IsMacOS` for platform-specific blocks. Use environment-agnostic newlines (`[Environment]::NewLine`).

**Performance** — Use `System.Collections.Generic.List[object]` for result accumulation. Pipeline for streaming, `ForEach-Object -Parallel` (PS 7+) for CPU-bound work. Use `-Filter` over `-Include` for filesystem queries.

### 2. Module Development

**Structure** — One `.psd1` manifest + one or more `.psm1` root modules. Private functions in `internal/` or `Private/`. Public exports declared explicitly via `Export-ModuleMember`.

**Versioning** — Semantic versioning in the manifest. `ModuleVersion` must match git tag. Update `ReleaseNotes` on each publish.

**Testing** — Pester v5 tests in `Tests/`. One `.tests.ps1` per function. Use `BeforeAll`/`AfterAll` for module import/cleanup. Mock external dependencies with `Mock`.

**Publishing** — `Publish-Module -Path . -NuGetApiKey $key`. Use `PSResourceGet` (PowerShellGet v3) for modern workflows. Include `-LicenseUri`, `-ProjectUri`, `-Tags` in the manifest.

### 3. MCP Service Development

**Recommended: use `mcp/pwsh-mcp-server.ps1`** — a unified MCP server that replaces all four approaches below in a single file. No external module deps.

```powershell
.\mcp\pwsh-mcp-server.ps1           # Run as MCP server (stdio)
.\mcp\pwsh-mcp-server.ps1 -Test     # Self-test (17 tools)
.\mcp\pwsh-mcp-server.ps1 -Install  # Register with Claude Desktop
```

**17 built-in tools** covering: system info, disk, processes, services (Win), environment, file read/write/search/list, script execution, native commands, session state.

Merges capabilities from:

| Source | Tools |
|--------|-------|
| **PowerShell.MCP** (yotsuda) | `file_read`, `file_write`, `file_search`, `file_list` |
| **PSMCP** (dfinke) | `run_script`, `run_command` |
| **powershell-mcp** (gunjanjp) | `session_get/set/list/clear` |
| **Custom MCP SDK** | `system_info`, `disk_usage`, `process_list/kill`, `service_list/control`, `environment_get` |

Legacy approaches (deprecated — kept for reference):

| Approach | Install | Use if... |
|----------|---------|-----------|
| **PowerShell.MCP** | `Install-Module PowerShell.MCP` | Need PS ecosystem MCP with file ops |
| **PSMCP** | `Install-Module PSMCP` | Need script→MCP bridge |
| **powershell-mcp** (gunjanjp) | `npm install -g powershell-mcp` | Need Claude Code MCP |

**Pattern** — Each tool function takes typed params, returns structured content with `type: "text"`. Maintain persistent session state via module-level variables.

### 4. AI Agent Building

**Frameworks**:

| Framework | Stars | Use Case |
|-----------|-------|----------|
| **PSAI** (dfinke) | 266★ | Multi-agent orchestration, function calling, MCP |
| **PSClaudeCode** (dfinke) | 82★ | Claude Code concepts in PS — file ops, agent loop |
| **PowerShellAI** (StartAutomating) | 35★ | OpenAI GPT/DALL-E integration |
| **Metro.AI.PowerShell** (Azure) | 11★ | Azure AI Agent/Assistant API management |

**Pattern** — Use OpenAI function calling or PSAI's `Invoke-AiAgent` for structured tool use. Define tools as PowerShell functions with typed params. Stream responses with `Invoke-OpenAIChat -Stream`. Handle rate limiting with exponential backoff.

### 5. GUI Development

| Approach | Use Case | Complexity |
|----------|----------|------------|
| **Windows Forms** | Simple dialogs, quick tools | Low |
| **WPF/XAML** | Rich interfaces, data binding | Medium |
| **Terminal GUI** (Spectre.Console) | Cross-platform TUI | Low |
| **Universal Dashboard** (PSU) | Web dashboards | Medium |

**Windows Forms** — `Add-Type -AssemblyName System.Windows.Forms`. Use `ShowDialog()` for modal, `Show()` for modeless.

**WPF** — Define XAML in a here-string or separate file. Load with `[Windows.Markup.XamlReader]::Load()`.

### 6. CI/CD Integration

**Azure DevOps** — Use `pwsh` task with `pwsh: true`. Store secrets in variable groups or Azure Key Vault. Publish test results with `PublishTestResults@2`.

**GitHub Actions** — Use `actions/setup-powershell@v1`. Matrix across Windows/Linux/macOS. Cache `~/.local/share/powershell/Modules` with `actions/cache`.

**Script Analysis** — Run `Invoke-ScriptAnalyzer -Path .\src -Severity Error` in CI. Enforce `-ExcludeRule` for approved suppressions. Gate PRs on analyzer pass.

### 7. PowerShell Gallery Publishing

```powershell
# Ensure module manifest is complete
Test-ModuleManifest .\*.psd1

# Publish (PSResourceGet v3)
Publish-PSResource -Path .\ -ApiKey $env:NUGET_API_KEY

# Or legacy (PowerShellGet v2)
Publish-Module -Path .\ -NuGetApiKey $env:NUGET_API_KEY
```

**Manifest essentials**: `ModuleVersion`, `Description`, `Author`, `CompanyName`, `Copyright`, `LicenseUri`, `ProjectUri`, `Tags`, `ReleaseNotes`, `RequireLicenseAcceptance` (if applicable).

### 8. Cross-Version Compatibility

| PS Version | Status | Guidance |
|------------|--------|----------|
| PowerShell 7.4+ | Current | Target for new development |
| PowerShell 7.0-7.3 | Maintenance | Avoid new features |
| Windows PowerShell 5.1 | Legacy | Polyfill with `#Requires -Version 5.1` |

**Polyfill pattern**:
```powershell
if ($PSVersionTable.PSVersion.Major -lt 7) {
    # PowerShell 5.1 fallback
} else {
    # PowerShell 7+ native
}
```

### 9. DSC (Desired State Configuration)

**Structure** — Configuration blocks with `Node`, `Resource` definitions. Separate `.psd1` config data from `.ps1` config scripts. Use `ConfigurationData` for parameterized deployments.

**Pattern**:
```powershell
Configuration WebServerConfig {
    param([string[]]$NodeName = 'localhost')
    Node $NodeName {
        WindowsFeature IIS {
            Ensure = 'Present'
            Name   = 'Web-Server'
        }
    }
}
```

**Testing** — Validate with `Test-DscConfiguration` after apply. Use `Update-DscConfiguration` for incremental changes.

### 10. Testing with Pester

**Structure** — Pester v5 in `Tests/`. One `.tests.ps1` per function. Use `Describe`/`It` blocks.

**Pattern**:
```powershell
BeforeAll {
    $module = Join-Path $PSScriptRoot '..\src\MyModule.psm1'
    Import-Module $module -Force
}

Describe 'Get-Something' {
    It 'returns valid output' {
        $result = Get-Something -Name 'test'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles missing input' {
        { Get-Something -Name '' } | Should -Throw
    }
}
```

**Mocking** — `Mock Get-ExternalCommand { return $fakeData }`. Use `ParameterFilter` for selective mocking. Verify calls with `Assert-MockCalled`.

## Reference

- [PowerShell.MCP](https://github.com/yotsuda/PowerShell.MCP) — Universal MCP server
- [PSAI](https://github.com/dfinke/PSAI) — Multi-agent AI framework
- [PSClaudeCode](https://github.com/dfinke/PSClaudeCode) — Claude Code in PowerShell
- [PSMCP](https://github.com/dfinke/PSMCP) — Script-to-MCP bridge
- [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) — Static analysis
- [Pester](https://github.com/pester/Pester) — Testing framework
- [PSResourceGet](https://github.com/PowerShell/PSResourceGet) — Package management v3
- [PowerShell Universal](https://www.powershelluniversal.com/) — Enterprise web dashboard
- [Microsoft.Graph](https://learn.microsoft.com/powershell/microsoftgraph/overview) — Microsoft Graph PS SDK
- [DSC](https://learn.microsoft.com/powershell/dsc/overview) — Desired State Configuration
- [Pester](https://pester.dev) — Testing and mocking framework

