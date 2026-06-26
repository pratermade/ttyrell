# ttyrell shell integration for fish
# Copy or symlink to ~/.config/fish/conf.d/ttyrell.fish
#
# Emits OSC 133 sequences so ttyrell can fire structured command events.

# Guard: only activate inside ttyrell
if not set -q TTYRELL
    exit
end

function __ttyrell_preexec --on-event fish_preexec
    printf '\033]133;C\007'
end

function __ttyrell_precmd --on-event fish_postexec
    printf '\033]133;D;%s\007' $status
    printf '\033]133;A\007'
end
