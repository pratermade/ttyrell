#!/usr/bin/env bash
# ttyrell shell integration for bash
# Source this in ~/.bashrc:
#   source /path/to/ttyrell/shell/integration.bash
#
# Emits OSC 133 sequences so ttyrell can fire structured command events:
#   command_start  — just before a command executes
#   command_exit   — after a command finishes (with exit code)
#   prompt_start   — just before the prompt is displayed

# Guard: only activate inside ttyrell
[[ -z "$TTYRELL" ]] && return

PS0=$'\033]133;C\007'

__ttyrell_precmd() {
    local code=$?   # capture before anything else changes it
    printf '\033]133;D;%s\007' "$code"
    printf '\033]133;A\007'
}

# Prepend to PROMPT_COMMAND without clobbering existing hooks
if [[ -z "$PROMPT_COMMAND" ]]; then
    PROMPT_COMMAND="__ttyrell_precmd"
else
    PROMPT_COMMAND="__ttyrell_precmd;$PROMPT_COMMAND"
fi
