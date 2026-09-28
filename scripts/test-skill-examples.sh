#!/usr/bin/env bash
# Runs the ```powershell examples of SKILL.md files as Pester 6 tests.
#
#   test-skill-examples.sh                 test the built-in list (default_skills below)
#   test-skill-examples.sh SKILL.md ...    test the given files
#
# Every ```powershell block becomes <tmp>/Tests/example-NN.Tests.ps1 after these generic, AST-based transforms:
#   - a block with a top-level It is wrapped in a Describe (Pester refuses tests directly in the root);
#   - top-level Invoke-Pester statements are removed (the file would otherwise run the suite again);
#   - a Mock / Should -Invoke snippet without an It becomes a Describe/It that calls the mocked command
#     (arguments derived from the -ParameterFilter) before the Should -Invoke;
#   - the block that calls New-PesterConfiguration is the runner configuration instead of a test
#     (Run.Path, PassThru, Exit and the result file are redirected to the temp dir);
#   - a block that does not parse is written unchanged, so Pester reports its container as failed.
# Stubs, fixture files and expectations per skill live in $SkillSettings in the driver below, keyed by
# the skill folder name. The examples are executed: only run this on SKILL.md files you trust.
#
# Exit status: 0 every example passed; 1 a test, block or container failed, no test ran, a test was
# skipped or not run unexpectedly, or an expected test is missing; 2 usage or environment error
# (pwsh missing, file missing, Pester 6 not installable).
# TEST_SKILL_EXAMPLES_KEEP=1 keeps the generated files and prints where they are.
set -euo pipefail

default_skills=(
  plugins/powershell/skills/pester/SKILL.md
)

usage() {
  echo "usage: $(basename "$0") [SKILL.md ...]"
  echo "Runs the powershell examples of each SKILL.md as Pester 6 tests (default: ${default_skills[*]})."
}

for arg in "$@"; do
  case "$arg" in
    -h | --help) usage; exit 0 ;;
    -*) echo "test-skill-examples: unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if ! command -v pwsh >/dev/null 2>&1; then
  echo "test-skill-examples: pwsh (PowerShell 7) is required but was not found on PATH." >&2
  echo "Install it (https://aka.ms/powershell) or add it to PATH, then re-run." >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [ "$#" -eq 0 ]; then
  set -- "${default_skills[@]/#/$repo_root/}"
fi
skills=()
for skill in "$@"; do
  if [ ! -f "$skill" ]; then
    echo "test-skill-examples: no such file: $skill" >&2
    exit 2
  fi
  # Absolute paths, so pwsh never reads an argument as a parameter name.
  skills+=("$(cd -- "$(dirname -- "$skill")" && pwd)/$(basename -- "$skill")")
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-skill-examples.XXXXXX")
tmp=$(cd -- "$tmp" && pwd)
if [ "${TEST_SKILL_EXAMPLES_KEEP:-}" = 1 ]; then
  trap 'echo "test-skill-examples: kept the generated files in $tmp" >&2' EXIT
else
  trap 'rm -rf -- "$tmp"' EXIT
fi

driver="$tmp/driver.ps1"
cat >"$driver" <<'PWSH'
using namespace System.Collections.Generic
using namespace System.Management.Automation.Language
# Arguments: SKILL.md path, work directory. pwsh -File runs a script in the global scope, which the examples
# can see, so everything below lives in a script block and the examples run from a separate module (see $sandbox).
# The try/catch turns an unexpected driver error into exit 1 (at the top level it would not stop the script).
try { & {
    param([Parameter(Mandatory)] [string] $SkillPath, [Parameter(Mandatory)] [string] $WorkDir)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    # Per-skill settings, keyed by the skill folder name.
    #   Stubs            defines the commands the examples call or mock, as global functions in this session
    #                    (Pester only mocks commands that exist, and a test file may have only one top-level BeforeAll)
    #   Files            fixtures written next to the generated tests, because the examples load them from $PSScriptRoot
    #   AllowedSkips     tests that may be skipped, and when (When is evaluated here; a skip outside it is a failure)
    #   RequiredPassing  test names that must exist and pass (proves that data-driven examples bind their data)
    $SkillSettings = @{
        'pester' = @{
            Stubs           = {
                function global:Get-ADUser {
                    [CmdletBinding()]
                    param([Parameter(Position = 0)] $Identity, $Filter, $Properties)
                    throw 'Get-ADUser stub: the example should have mocked this command.'
                }
                function global:Get-Service {
                    [CmdletBinding()]
                    param([Parameter(Position = 0)] [string[]] $Name)
                    throw 'Get-Service stub: the example should have mocked this command.'
                }
                function global:Get-Function {
                    param([Parameter(Position = 0)] $Value)
                    $map = @{ value1 = 'result1'; value2 = 'result2'; test1 = 'result1'; test2 = 'result2' }
                    # "$Value" turns anything unexpected (such as the $Input enumerator) into a key the map lacks.
                    $map["$Value"]
                }
                function global:Get-Collection { 'item1', 'item2' }
            }
            Files           = [ordered]@{
                'Get-UserInfo.ps1' = @'
function Get-UserInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Username)
    Get-ADUser -Identity $Username
}
'@
                'cases.json'       = '[{"Name":"a"},{"Name":"b"}]'
                'MyModule.psm1'    = @'
function Invoke-Thing {
    [CmdletBinding()]
    # Mandatory, so a $null name (the vacuous-$Name bug) fails instead of passing.
    param([Parameter(Mandatory, Position = 0)] [string] $Name)
    'ok'
}
Export-ModuleMember -Function Invoke-Thing
'@
            }
            AllowedSkips    = @(
                @{ Name = 'Should work on Windows'; When = { -not $IsWindows }; Reason = 'Windows-only example on a non-Windows host' }
            )
            RequiredPassing = @('handles a', 'handles b')
        }
    }

    $summaryFile = Join-Path $WorkDir 'summary.txt'
    $testsDir = Join-Path $WorkDir 'Tests'
    $resultFile = Join-Path $WorkDir 'testResults.xml'
    $origin = @{}                        # generated file name -> "example-NN, SKILL.md line L"
    # Invoke-Pester runs the tests in its caller's scope chain. Calling it (and the runner example) from a dynamic
    # module makes that chain module -> global, so the examples cannot see this driver's variables ($name, $config,
    # ...), which would hide an undefined variable in an example (the vacuous-$Name bug), nor its preferences.
    $sandbox = New-Module -ScriptBlock { }
    $problems = [List[string]]::new()
    $notes = [List[string]]::new()

    function Write-Summary([string] $Verdict, [string] $Counts) {
        $lines = @("$skillName ($SkillPath): $Verdict$(if ($Counts) { " - $Counts" })")
        $lines += @($notes | ForEach-Object { "    note: $_" })
        $lines += @($problems | ForEach-Object { "    FAIL: $_" })
        Set-Content -LiteralPath $summaryFile -Value $lines
    }

    function Get-FirstLine([string] $Text) {
        $line = (($Text -split '\r?\n') | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($line.Length -gt 240) { $line = $line.Substring(0, 240) + '...' }
        $line
    }

    # Code blocks fenced as ```powershell (fences of other languages are skipped, including their content).
    function Get-PowerShellBlock([string] $Path) {
        $lines = [System.IO.File]::ReadAllLines($Path)
        $fence = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($null -eq $fence) {
                if ($line -match '^\s*(`{3,}|~{3,})\s*([^\s`]*)') {
                    $fence = $Matches[1]; $lang = $Matches[2]; $start = $i + 1; $body = [List[string]]::new()
                }
            }
            elseif ($line -match '^\s*(`{3,}|~{3,})\s*$' -and $Matches[1][0] -eq $fence[0] -and $Matches[1].Length -ge $fence.Length) {
                if ($lang -eq 'powershell') { [pscustomobject]@{ Line = $start; Text = $body -join "`n" } }
                $fence = $null
            }
            else { $body.Add($line) }
        }
        if ($null -ne $fence -and $lang -eq 'powershell') { [pscustomobject]@{ Line = $start; Text = $body -join "`n" } }
    }

    function ConvertTo-Ast([string] $Text) {
        $tokens = $null; $errors = $null
        $ast = [Parser]::ParseInput($Text, [ref] $tokens, [ref] $errors)
        [pscustomobject]@{ Ast = $ast; Tokens = $tokens; Errors = $errors }
    }

    function Get-TopStatement([ScriptBlockAst] $Ast) {
        foreach ($named in $Ast.BeginBlock, $Ast.ProcessBlock, $Ast.EndBlock) { if ($named) { $named.Statements } }
    }

    function Get-StatementCommand($Statement) {
        if ($Statement -is [PipelineAst] -and $Statement.PipelineElements[0] -is [CommandAst]) { $Statement.PipelineElements[0] }
    }

    function Get-StatementName($Statement) {
        $command = Get-StatementCommand $Statement
        if ($command) { $command.GetCommandName() }
    }

    function Test-CommandUse([Ast] $Ast, [string] $Name) {
        $null -ne $Ast.Find({ param($n) $n -is [CommandAst] -and $n.GetCommandName() -eq $Name }, $true)
    }

    function Test-ShouldInvoke($Statement) {
        $command = Get-StatementCommand $Statement
        if (-not $command) { return $false }
        $name = $command.GetCommandName()
        if ($name -like 'Should-Invoke*') { return $true }
        $name -eq 'Should' -and $null -ne ($command.CommandElements |
            Where-Object { $_ -is [CommandParameterAst] -and $_.ParameterName -in 'Invoke', 'InvokeVerifiable' } | Select-Object -First 1)
    }

    # Named and positional arguments of a command; $ValueParameters take a value, every other parameter is a switch.
    # Positional arguments fill the $ValueParameters that were not named, in order.
    function Get-BoundArgument([CommandAst] $Command, [string[]] $ValueParameters) {
        $bound = @{}; $positional = [List[object]]::new()
        $elements = $Command.CommandElements
        for ($i = 1; $i -lt $elements.Count; $i++) {
            $e = $elements[$i]
            if ($e -is [CommandParameterAst]) {
                $full = @($ValueParameters | Where-Object { $_.StartsWith($e.ParameterName, [StringComparison]::OrdinalIgnoreCase) })
                if ($full.Count -ne 1) { continue }
                if ($e.Argument) { $bound[$full[0]] = $e.Argument }
                elseif ($i + 1 -lt $elements.Count) { $i++; $bound[$full[0]] = $elements[$i] }
            }
            else { $positional.Add($e) }
        }
        foreach ($name in $ValueParameters) {
            if (-not $bound.ContainsKey($name) -and $positional.Count) { $bound[$name] = $positional[0]; $positional.RemoveAt(0) }
        }
        $bound
    }

    # 'Mock Get-Service {...} -ParameterFilter { $Name -eq 'TestService' }' -> "Get-Service -Name 'TestService'".
    # Only -eq comparisons between a parameter variable and a constant (or $true/$false) are turned into arguments.
    function Get-MockedCall([CommandAst] $Mock) {
        $bound = Get-BoundArgument $Mock 'CommandName', 'MockWith', 'ParameterFilter', 'ModuleName', 'RemoveParameterType', 'RemoveParameterValidation'
        if ($bound['CommandName'] -isnot [StringConstantExpressionAst]) { return }
        $call = @($bound['CommandName'].Value)
        if ($bound['ParameterFilter'] -is [ScriptBlockExpressionAst]) {
            $comparisons = $bound['ParameterFilter'].ScriptBlock.FindAll({
                    param($n) $n -is [BinaryExpressionAst] -and $n.Operator.ToString() -in 'Ieq', 'Ceq' }, $true)
            foreach ($c in $comparisons) {
                $var, $value = $c.Left, $c.Right
                if ($var -isnot [VariableExpressionAst]) { $var, $value = $c.Right, $c.Left }
                if ($var -isnot [VariableExpressionAst] -or -not $var.VariablePath.IsUnqualified) { continue }
                $parameter = $var.VariablePath.UserPath
                if ($parameter -in '_', 'PSItem', 'true', 'false', 'null', 'args', 'PSBoundParameters') { continue }
                if ($value -is [ConstantExpressionAst]) { $call += "-$parameter $($value.Extent.Text)" }
                elseif ($value -is [VariableExpressionAst] -and $value.VariablePath.UserPath -in 'true', 'false') {
                    $call += "-${parameter}:$($value.Extent.Text)"
                }
            }
        }
        $call -join ' '
    }

    function Remove-Statement([string] $Text, $Statements) {
        foreach ($s in @($Statements) | Sort-Object { $_.Extent.StartOffset } -Descending) {
            $Text = $Text.Remove($s.Extent.StartOffset, $s.Extent.EndOffset - $s.Extent.StartOffset)
        }
        $Text
    }

    function Add-Indent([string] $Text, [int] $Depth, [bool] $Enabled) {
        if (-not $Enabled) { return $Text }
        $pad = ' ' * (4 * $Depth)
        ($Text -split "`n" | ForEach-Object { if ($_) { $pad + $_ } else { $_ } }) -join "`n"
    }

    # Returns the test-file text for one parsed example and the list of transforms applied.
    function Convert-Example([string] $Text, [string] $Title) {
        $applied = [List[string]]::new()
        $parsed = ConvertTo-Ast $Text
        $invokes = @(Get-TopStatement $parsed.Ast | Where-Object { (Get-StatementName $_) -eq 'Invoke-Pester' })
        if ($invokes) {
            $Text = Remove-Statement $Text $invokes
            $applied.Add('removed top-level Invoke-Pester')
            $parsed = ConvertTo-Ast $Text
        }
        # Indenting would move a here-string terminator off column 0.
        $indent = -not ($parsed.Tokens | Where-Object { $_.Kind.ToString() -in 'HereStringLiteral', 'HereStringExpandable' })
        $top = @(Get-TopStatement $parsed.Ast)
        $mocks = @($top | Where-Object { (Get-StatementName $_) -eq 'Mock' })
        $asserts = @($top | Where-Object { Test-ShouldInvoke $_ })
        if (($mocks -or $asserts) -and -not (Test-CommandUse $parsed.Ast 'It')) {
            $calls = @($mocks | ForEach-Object { Get-MockedCall (Get-StatementCommand $_) } | Where-Object { $_ } | Select-Object -Unique)
            $at = if ($asserts) { $asserts[0].Extent.StartOffset } else { $mocks[-1].Extent.EndOffset }
            $body = $Text.Substring(0, $at) + "`n" + (@($calls | ForEach-Object { "`$null = $_" }) -join "`n") + "`n" + $Text.Substring($at)
            $Text = "Describe '$Title' {`n    It 'runs the Mock example' {`n$(Add-Indent $body 2 $indent)`n    }`n}`n"
            $applied.Add("Mock snippet wrapped in Describe/It, calling: $($calls -join '; ')")
        }
        elseif ($top | Where-Object { (Get-StatementName $_) -eq 'It' }) {
            $Text = "Describe '$Title' {`n$(Add-Indent $Text 1 $indent)`n}`n"
            $applied.Add('top-level It wrapped in Describe')
        }
        [pscustomobject]@{ Text = $Text; Applied = $applied }
    }

    # Runs the New-PesterConfiguration example without its Invoke-Pester and returns the configuration it built.
    function Get-RunnerConfiguration($Runner) {
        $invokes = @(Get-TopStatement $Runner.Ast | Where-Object { (Get-StatementName $_) -eq 'Invoke-Pester' })
        $name = $null
        foreach ($s in $invokes) {
            $arg = (Get-BoundArgument (Get-StatementCommand $s) 'Configuration')['Configuration']
            if ($arg -is [VariableExpressionAst]) { $name = $arg.VariablePath.UserPath }
        }
        if (-not $name) {
            $assignment = $Runner.Ast.Find({
                    param($n) $n -is [AssignmentStatementAst] -and $n.Left -is [VariableExpressionAst] -and
                    (Test-CommandUse $n.Right 'New-PesterConfiguration') }, $true)
            if ($assignment) { $name = $assignment.Left.VariablePath.UserPath }
        }
        if (-not $name) { throw 'cannot tell which variable holds the configuration' }
        $code = Remove-Statement $Runner.Text $invokes
        $config = & $sandbox {
            param($__code, $__name)
            $null = . ([scriptblock]::Create($__code))
            Get-Variable -Name $__name -Scope 0 -ValueOnly
        } $code $name
        if ($config -is [System.Collections.IDictionary]) { $config = New-PesterConfiguration -Hashtable $config }
        if ($null -eq $config -or $config.GetType().Name -ne 'PesterConfiguration') {
            throw "`$$name does not hold a PesterConfiguration"
        }
        $config
    }

    try {
        $SkillPath = (Resolve-Path -LiteralPath $SkillPath).ProviderPath
        $skillName = Split-Path -Leaf (Split-Path -Parent $SkillPath)
        $null = New-Item -ItemType Directory -Force -Path $testsDir

        $pester = Get-Module -ListAvailable -Name Pester | Where-Object Version -GE ([version] '6.0.0') | Select-Object -First 1
        if (-not $pester) {
            Write-Host 'test-skill-examples: installing the latest stable Pester for the current user...'
            # -SkipPublisherCheck: Windows ships Pester 3 signed with a different certificate than current Pester
            # releases, and without it Install-Module refuses to install a module whose publisher changed.
            Install-Module -Name Pester -Repository PSGallery -Scope CurrentUser -Force -SkipPublisherCheck
        }
        Import-Module -Name Pester -MinimumVersion 6.0.0 -Force
    }
    catch {
        $skillName = if ($skillName) { $skillName } else { $SkillPath }
        $problems.Add("environment: $($_.Exception.Message)")
        Write-Summary 'ERROR' ''
        exit 2
    }

    $settings = $SkillSettings[$skillName]
    if (-not $settings) {
        $settings = @{ Stubs = $null; Files = @{}; AllowedSkips = @(); RequiredPassing = @() }
        $notes.Add("no settings for skill '$skillName' in the driver: no stubs, fixtures or extra expectations")
    }

    Write-Host "test-skill-examples: $skillName ($SkillPath) with Pester $((Get-Module Pester).Version)"
    $runner = $null
    $n = 0
    foreach ($block in @(Get-PowerShellBlock $SkillPath)) {
        $n++
        $id = 'example-{0:d2}' -f $n
        $file = "$id.Tests.ps1"
        $where = "$id, SKILL.md line $($block.Line)"
        $parsed = ConvertTo-Ast $block.Text
        if ($parsed.Errors.Count) {
            [System.IO.File]::WriteAllText((Join-Path $testsDir $file), $block.Text + "`n")
            $origin[$file] = $where
            Write-Host "  $where -> $file (does not parse, written unchanged: $($parsed.Errors[0].Message))"
            continue
        }
        if (-not $runner -and (Test-CommandUse $parsed.Ast 'New-PesterConfiguration')) {
            $runner = [pscustomobject]@{ Id = $id; Where = $where; Ast = $parsed.Ast; Text = $block.Text }
            Write-Host "  $where -> runner configuration"
            continue
        }
        $converted = Convert-Example $block.Text "SKILL.md $id (line $($block.Line))"
        [System.IO.File]::WriteAllText((Join-Path $testsDir $file), $converted.Text)
        $origin[$file] = $where
        Write-Host "  $where -> $file$(if ($converted.Applied.Count) { " ($($converted.Applied -join '; '))" })"
    }
    if ($n -eq 0) { $problems.Add('no ```powershell blocks found') }

    foreach ($name in $settings.Files.Keys) {
        [System.IO.File]::WriteAllText((Join-Path $testsDir $name), $settings.Files[$name])
    }
    if ($settings.Stubs) { . $settings.Stubs }

    $config = $null
    if ($runner) {
        Push-Location -LiteralPath $WorkDir
        try { $config = Get-RunnerConfiguration $runner }
        catch { $problems.Add("runner configuration ($($runner.Where)) failed, using the default: $($_.Exception.Message)") }
        finally { Pop-Location }
    }
    if (-not $config) {
        $config = New-PesterConfiguration
        $config.Output.Verbosity = 'Detailed'
    }
    $config.Run.Path = $testsDir
    $config.Run.PassThru = $true
    $config.Run.Exit = $false
    $config.Run.Throw = $false                      # a throw would lose the result object
    $config.Run.SkipRun = $false
    if ($config.Run.PSObject.Properties['Parallel']) {
        $config.Run.Parallel = $false               # the stubs exist only in this runspace
    }
    $config.TestResult.OutputPath = $resultFile

    $result = $null
    Push-Location -LiteralPath $WorkDir
    try { $result = & $sandbox { Invoke-Pester -Configuration $args[0] } $config }
    catch { $problems.Add("Invoke-Pester failed: $($_.Exception.Message)") }
    finally { Pop-Location }

    if (-not $result) {
        if (-not ($problems -like 'Invoke-Pester failed:*')) { $problems.Add('Invoke-Pester returned no result') }
        Write-Summary 'FAIL' ''
        exit 1
    }

    function Get-Origin($Item) {
        $leaf = Split-Path -Leaf "$Item"
        if ($origin[$leaf]) { $origin[$leaf] } else { $leaf }
    }
    function Get-ErrorText($Object) {
        $e = @($Object.ErrorRecord)[0]
        if (-not $e) { return '' }
        if ($e.Exception -is [System.Management.Automation.ParseException]) {
            $p = $e.Exception.Errors[0]
            return "does not parse (line $($p.Extent.StartLineNumber) of the example): $($p.Message)"
        }
        $message = if ($e.PSObject.Properties['DisplayErrorMessage']) { $e.DisplayErrorMessage } else { $e.Exception.Message }
        Get-FirstLine $message
    }

    foreach ($t in $result.Failed) {
        $problems.Add("test '$($t.ExpandedPath)' ($(Get-Origin $t.Block.BlockContainer.Item)): $(Get-ErrorText $t)")
    }
    foreach ($b in $result.FailedBlocks) {
        $problems.Add("block '$($b.ExpandedPath)' ($(Get-Origin $b.BlockContainer.Item)): $(Get-ErrorText $b)")
    }
    foreach ($c in $result.FailedContainers) {
        $problems.Add("container $(Get-Origin $c.Item): $(Get-ErrorText $c)")
    }
    $expectedSkips = 0
    foreach ($t in $result.Skipped) {
        $allowed = $settings.AllowedSkips | Where-Object { $_.Name -eq $t.ExpandedName -and (& $_.When) } | Select-Object -First 1
        if ($allowed) { $expectedSkips++; $notes.Add("skipped as expected: '$($t.ExpandedPath)' ($($allowed.Reason))") }
        else { $problems.Add("unexpected skip: '$($t.ExpandedPath)' ($(Get-Origin $t.Block.BlockContainer.Item))") }
    }
    foreach ($t in @($result.Inconclusive) + @($result.NotRun)) {
        if ($t) { $problems.Add("$($t.Result.ToLower()) test: '$($t.ExpandedPath)' ($(Get-Origin $t.Block.BlockContainer.Item))") }
    }
    if ($result.PassedCount + $result.FailedCount -eq 0) { $problems.Add('no tests ran') }
    foreach ($name in $settings.RequiredPassing) {
        if (-not ($result.Passed | Where-Object ExpandedName -EQ $name)) {
            $problems.Add("expected a passing test named '$name' (skill settings), found none")
        }
    }
    if ($result.Result -ne 'Passed' -and -not $problems.Count) { $problems.Add("Pester reported the run as $($result.Result)") }

    $counts = "$($result.PassedCount) passed, $($result.FailedCount) failed, $($result.SkippedCount) skipped " +
    "($expectedSkips expected), $($result.InconclusiveCount + $result.NotRunCount) inconclusive/not run, " +
    "$($result.FailedBlocksCount) failed blocks, $($result.FailedContainersCount) failed containers"
    if ($problems.Count) { Write-Summary 'FAIL' $counts; exit 1 }
    Write-Summary 'PASS' $counts
    exit 0
} @args }
catch {
    Write-Host "test-skill-examples: driver error: $($_ | Out-String)"
    exit 1
}
PWSH

status=0
work_dirs=()
i=0
for skill in "${skills[@]}"; do
  i=$((i + 1))
  work="$tmp/$i"
  mkdir -p -- "$work"
  work_dirs+=("$work")
  rc=0
  pwsh -NoLogo -NoProfile -NonInteractive -File "$driver" "$skill" "$work" || rc=$?
  if [ ! -s "$work/summary.txt" ]; then
    echo "$skill: ERROR - the pwsh driver exited $rc without a summary" >"$work/summary.txt"
    if [ "$rc" -eq 0 ]; then rc=1; fi
  fi
  if [ "$rc" -eq 2 ]; then
    status=2
  elif [ "$rc" -ne 0 ] && [ "$status" -eq 0 ]; then
    status=1
  fi
done

echo
echo "== test-skill-examples summary =="
for work in "${work_dirs[@]}"; do
  cat -- "$work/summary.txt"
done
exit "$status"
