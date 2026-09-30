using namespace System.Collections.Generic
using namespace System.Management.Automation.Language
# Runs the powershell blocks of one SKILL.md as Pester 6 tests, for skills whose powershell runner is 'pester'
# in tests/skill-examples.json (called by skill_examples.py). The examples are executed: trusted SKILL.md files only.
#
# Arguments: input JSON file, work directory. The input holds the blocks (index, SKILL.md line, text; blocks that
# the config skips are already left out) and the skill's settings:
#   stubs             .ps1 file dot-sourced before the run; it defines the commands the examples call or mock as
#                     `function global:Name` (Pester only mocks commands that exist, and a test file may have only
#                     one top-level BeforeAll, so the examples cannot define them themselves)
#   fixtures          directory whose files are copied next to the generated tests (examples load them from $PSScriptRoot)
#   allowed_skips     [{ test, when, reason }]: tests that may be skipped, and when (always, windows, not-windows,
#                     linux, not-linux, macos, not-macos); any other skip is a failure
#   required_passing  test names that must exist and pass (proves that data-driven examples bind their data)
#   install           install Pester 6 from the PowerShell Gallery for the current user when it is missing
# Writes <work>/result.json: { status: pass|fail|missing|error, counts, problems, notes, failed_blocks }.
#
# Every block becomes <work>/Tests/block-NN.Tests.ps1 after these generic, AST-based transforms:
#   - a block with a top-level It is wrapped in a Describe (Pester refuses tests directly in the root);
#   - top-level Invoke-Pester statements are removed (the file would otherwise run the suite again);
#   - a Mock / Should -Invoke snippet without an It becomes a Describe/It that calls the mocked command
#     (arguments derived from the -ParameterFilter) before the Should -Invoke;
#   - the block that calls New-PesterConfiguration is the runner configuration instead of a test
#     (Run.Path, PassThru, Exit and the result file are redirected to the work directory);
#   - a block that does not parse is written unchanged, so Pester reports its container as failed.
#
# pwsh -File runs a script in the global scope, which the examples can see, so everything below lives in a script
# block and the examples run from a separate module (see $sandbox). The try/catch turns an unexpected driver error
# into exit 1 (at the top level it would not stop the script).
try { & {
        param([Parameter(Mandatory)] [string] $InputFile, [Parameter(Mandatory)] [string] $WorkDir)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'

        $settings = Get-Content -Raw -Encoding utf8 -LiteralPath $InputFile | ConvertFrom-Json
        $resultJson = Join-Path $WorkDir 'result.json'
        $testsDir = Join-Path $WorkDir 'Tests'
        $resultFile = Join-Path $WorkDir 'testResults.xml'
        $origin = @{}                        # generated file name -> @{ Where = 'block N, SKILL.md line L'; Index = N }
        # Invoke-Pester runs the tests in its caller's scope chain. Calling it (and the runner example) from a dynamic
        # module makes that chain module -> global, so the examples cannot see this driver's variables ($name, $config,
        # ...), which would hide an undefined variable in an example (the vacuous-$Name bug), nor its preferences.
        $sandbox = New-Module -ScriptBlock { }
        $problems = [List[string]]::new()
        $notes = [List[string]]::new()
        $failedBlocks = [HashSet[int]]::new()

        function Write-Result([string] $Status, [string] $Counts) {
            $out = [ordered]@{
                status        = $Status
                counts        = $Counts
                problems      = @($problems)
                notes         = @($notes)
                failed_blocks = @($failedBlocks)
            }
            [System.IO.File]::WriteAllText($resultJson, (ConvertTo-Json -InputObject $out -Depth 5))
        }

        function Get-FirstLine([string] $Text) {
            $line = (($Text -split '\r?\n') | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($line.Length -gt 240) { $line = $line.Substring(0, 240) + '...' }
            $line
        }

        function Test-When([string] $When) {
            switch ($When) {
                'always' { return $true }
                'windows' { return [bool] $IsWindows }
                'not-windows' { return -not $IsWindows }
                'linux' { return [bool] $IsLinux }
                'not-linux' { return -not $IsLinux }
                'macos' { return [bool] $IsMacOS }
                'not-macos' { return -not $IsMacOS }
            }
            throw "unknown 'when' value: $When"
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
            $null = New-Item -ItemType Directory -Force -Path $testsDir
            $pester = Get-Module -ListAvailable -Name Pester | Where-Object Version -GE ([version] '6.0.0') | Select-Object -First 1
            if (-not $pester) {
                if (-not $settings.install) {
                    $problems.Add('Pester 6 is not installed and SKILL_EXAMPLES_NO_INSTALL is set; install it with ' +
                        'Install-Module Pester -MinimumVersion 6.0.0 -Scope CurrentUser -Force -SkipPublisherCheck')
                    Write-Result 'missing' ''
                    exit 2
                }
                Write-Host 'test-skill-examples: installing the latest stable Pester for the current user...'
                # -SkipPublisherCheck: Windows ships Pester 3 signed with a different certificate than current Pester
                # releases, and without it Install-Module refuses to install a module whose publisher changed.
                try { Install-Module -Name Pester -Repository PSGallery -Scope CurrentUser -Force -SkipPublisherCheck }
                catch {
                    $problems.Add("Pester 6 is not installed and installing it failed: $($_.Exception.Message)")
                    Write-Result 'missing' ''
                    exit 2
                }
            }
            Import-Module -Name Pester -MinimumVersion 6.0.0 -Force
        }
        catch {
            $problems.Add("environment: $($_.Exception.Message)")
            Write-Result 'error' ''
            exit 2
        }

        Write-Host "test-skill-examples: Pester $((Get-Module Pester).Version) for $($settings.skill)"
        $runner = $null
        foreach ($block in @($settings.blocks)) {
            $file = 'block-{0:d2}.Tests.ps1' -f [int] $block.index
            $where = "block $($block.index), SKILL.md line $($block.line)"
            $text = [string] $block.text
            $parsed = ConvertTo-Ast $text
            if ($parsed.Errors.Count) {
                [System.IO.File]::WriteAllText((Join-Path $testsDir $file), $text + "`n")
                $origin[$file] = @{ Where = $where; Index = [int] $block.index }
                Write-Host "  $where -> $file (does not parse, written unchanged: $($parsed.Errors[0].Message))"
                continue
            }
            if (-not $runner -and (Test-CommandUse $parsed.Ast 'New-PesterConfiguration')) {
                $runner = [pscustomobject]@{ Index = [int] $block.index; Where = $where; Ast = $parsed.Ast; Text = $text }
                Write-Host "  $where -> runner configuration"
                continue
            }
            $converted = Convert-Example $text "SKILL.md block $($block.index) (line $($block.line))"
            [System.IO.File]::WriteAllText((Join-Path $testsDir $file), $converted.Text)
            $origin[$file] = @{ Where = $where; Index = [int] $block.index }
            Write-Host "  $where -> $file$(if ($converted.Applied.Count) { " ($($converted.Applied -join '; '))" })"
        }

        if ($settings.fixtures) {
            Get-ChildItem -LiteralPath $settings.fixtures -Force | Copy-Item -Destination $testsDir -Recurse -Force
        }
        if ($settings.stubs) {
            $stubs = [string] $settings.stubs
            . $stubs
        }

        $config = $null
        if ($runner) {
            Push-Location -LiteralPath $WorkDir
            try { $config = Get-RunnerConfiguration $runner }
            catch {
                $problems.Add("runner configuration ($($runner.Where)) failed, using the default: $($_.Exception.Message)")
                $null = $failedBlocks.Add($runner.Index)
            }
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
            Write-Result 'fail' ''
            exit 1
        }

        # "block N, SKILL.md line L" for a generated test file; records the block as failed when -Failed is given.
        function Get-Origin($Item, [switch] $Failed) {
            $leaf = Split-Path -Leaf "$Item"
            $o = $origin[$leaf]
            if (-not $o) { return $leaf }
            if ($Failed) { $null = $failedBlocks.Add($o.Index) }
            $o.Where
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
            $problems.Add("test '$($t.ExpandedPath)' ($(Get-Origin $t.Block.BlockContainer.Item -Failed)): $(Get-ErrorText $t)")
        }
        foreach ($b in $result.FailedBlocks) {
            $problems.Add("block '$($b.ExpandedPath)' ($(Get-Origin $b.BlockContainer.Item -Failed)): $(Get-ErrorText $b)")
        }
        foreach ($c in $result.FailedContainers) {
            $problems.Add("container $(Get-Origin $c.Item -Failed): $(Get-ErrorText $c)")
        }
        $expectedSkips = 0
        foreach ($t in $result.Skipped) {
            $allowed = @($settings.allowed_skips) | Where-Object { $_ -and $_.test -eq $t.ExpandedName -and (Test-When $_.when) } |
                Select-Object -First 1
            if ($allowed) { $expectedSkips++; $notes.Add("skipped as expected: '$($t.ExpandedPath)' ($($allowed.reason))") }
            else { $problems.Add("unexpected skip: '$($t.ExpandedPath)' ($(Get-Origin $t.Block.BlockContainer.Item -Failed))") }
        }
        foreach ($t in @($result.Inconclusive) + @($result.NotRun)) {
            if ($t) { $problems.Add("$($t.Result.ToLower()) test: '$($t.ExpandedPath)' ($(Get-Origin $t.Block.BlockContainer.Item -Failed))") }
        }
        if ($result.PassedCount + $result.FailedCount -eq 0) { $problems.Add('no tests ran') }
        foreach ($name in @($settings.required_passing)) {
            if ($name -and -not ($result.Passed | Where-Object ExpandedName -EQ $name)) {
                $problems.Add("expected a passing test named '$name' (powershell.required_passing), found none")
            }
        }
        if ($result.Result -ne 'Passed' -and -not $problems.Count) { $problems.Add("Pester reported the run as $($result.Result)") }

        $counts = "$($result.PassedCount) passed, $($result.FailedCount) failed, $($result.SkippedCount) skipped " +
        "($expectedSkips expected), $($result.InconclusiveCount + $result.NotRunCount) inconclusive/not run, " +
        "$($result.FailedBlocksCount) failed blocks, $($result.FailedContainersCount) failed containers"
        if ($problems.Count) { Write-Result 'fail' $counts; exit 1 }
        Write-Result 'pass' $counts
        exit 0
    } @args }
catch {
    Write-Host "test-skill-examples: driver error: $($_ | Out-String)"
    exit 1
}
