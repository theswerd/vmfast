#!/usr/bin/env bash
# 6 Ubuntu microVMs in a tmux grid, each pane in its own color.
# Each pane cold-restores its own VM via mmap(MAP_PRIVATE) from the
# shared snapshot.ram (COW — they're isolated), shows resume time,
# drops into an interactive pty. Click a pane, type — keystrokes go
# through to the kernel and back.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

N=${1:-6}

if [ ! -f artifacts/snapshot.ram ] || [ ! -f artifacts/snapshot.state ]; then
    echo "no snapshot present — cold booting once to create one…"
    ./artifacts/vmfast-linux
fi

# Six highly distinct 256-color codes.
COLORS=(196 46 226 51 201 208)

SESSION="vmfast-demo-$$"
tmux new-session -d -s "$SESSION" -x 240 -y 60

# Per-pane border with the VM number, colored to match the pane.
tmux set-option -t "$SESSION" -g pane-border-status top
tmux set-option -t "$SESSION" -g pane-border-format " #{pane_title} "
tmux set-option -t "$SESSION" -g pane-border-style "fg=colour240"
tmux set-option -t "$SESSION" -g mouse on
tmux set-option -t "$SESSION" -g status-style "fg=white,bg=black"
tmux set-option -t "$SESSION" -g status-left "  vmfast — $N parallel Ubuntu microVMs (click a pane, then type) "
tmux set-option -t "$SESSION" -g status-right "  Hypervisor.framework + mmap-COW restore  "

setup_pane() {
    local target="$1" idx="$2" color="$3"
    # Per-pane border color + title.
    tmux select-pane -t "$target" -T " VM-$(printf %02d $idx) " -P "fg=colour${color}"
    # Same color carried into the banner inside the VM via env var.
    tmux send-keys  -t "$target" \
        "clear; exec env TERM=xterm-256color VMFAST_COLOR=${color} $HERE/artifacts/vmfast-linux restore" C-m
}

# Pane 0.
setup_pane "$SESSION:0.0" 1 "${COLORS[0]}"

# Add the rest.
for ((i = 1; i < N; i++)); do
    if (( i % 2 == 1 )); then
        tmux split-window -h -t "$SESSION"
    else
        tmux split-window -v -t "$SESSION"
    fi
    tmux select-layout -t "$SESSION" tiled >/dev/null
    color="${COLORS[$(( i % ${#COLORS[@]} ))]}"
    setup_pane "$SESSION" $((i+1)) "$color"
done

tmux select-layout -t "$SESSION" tiled

echo "attaching tmux session '$SESSION' — Ctrl-B then & to kill"
sleep 0.3
exec tmux attach -t "$SESSION"
