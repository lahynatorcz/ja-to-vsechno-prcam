#!/usr/bin/env bash
set -euo pipefail
cd /home/kosh/Projects/confluence-server

SESSION="mc-confluence"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Server už běží v tmux relaci '$SESSION'."
    echo "Připojení ke konzoli: tmux attach -t $SESSION  (odpojení bez vypnutí: Ctrl+B a pak D)"
    exit 0
fi

echo "Spouštím Confluence Albino server v tmux relaci '$SESSION' (se systemd-inhibit + 1x FML startup retry)..."
tmux new-session -d -s "$SESSION" "/home/kosh/Projects/confluence-server/_run-loop.sh"
echo "Spuštěno! Logy: tail -f /home/kosh/Projects/confluence-server/logs/latest.log"
echo "Konzole serveru: tmux attach -t $SESSION"
