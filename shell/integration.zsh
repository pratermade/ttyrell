# ttyrell shell integration for zsh
# Source this in ~/.zshrc:
#   source /path/to/ttyrell/shell/integration.zsh
#
# Emits OSC 133 sequences so ttyrell can fire structured command events:
#   command_start  — just before a command executes
#   command_exit   — after a command finishes (with exit code)
#   prompt_start   — just before the prompt is displayed

# Guard: only activate inside ttyrell
[[ -z "$TTYRELL" ]] && return

PS0=$'\033]133;C\007'

__ttyrell_precmd() {
    local code=$?
    printf '\033]133;D;%s\007' "$code"
    printf '\033]133;A\007'
}

# Add to precmd_functions without clobbering existing hooks
autoload -Uz add-zsh-hook
add-zsh-hook precmd __ttyrell_precmd
