# ttyrell shell integration for PowerShell
# Add to your $PROFILE (run `notepad $PROFILE` to open it):
#
#   $env:TTYRELL = "1"
#   . /path/to/ttyrell/shell/integration.ps1
#
# Note: PowerShell has no equivalent of bash's PS0, so command_start events
# are not emitted. command_exit and prompt_start work correctly.

# Guard: only activate inside ttyrell
if (-not $env:TTYRELL) { return }

# ESC and BEL constants — compatible with PowerShell 5.1 and 7+
$ESC = [char]27
$BEL = [char]7

function global:prompt {
    # Capture exit code before any other expressions change it
    $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }

    # command_exit with last exit code
    [Console]::Write("${ESC}]133;D;${code}${BEL}")
    # cwd (OSC 7) so ttyrell resolves @file references and edits against the
    # actual working directory. Only report real filesystem locations.
    $loc = $ExecutionContext.SessionState.Path.CurrentLocation
    if ($loc.Provider.Name -eq 'FileSystem') {
        $p = $loc.ProviderPath -replace '\\', '/'
        [Console]::Write("${ESC}]7;file://${env:COMPUTERNAME}/${p}${BEL}")
    }
    # prompt_start
    [Console]::Write("${ESC}]133;A${BEL}")

    # Preserve the default prompt appearance
    "PS $($ExecutionContext.SessionState.Path.CurrentLocation)$('>' * ($NestedPromptLevel + 1)) "
}
