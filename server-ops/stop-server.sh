#!/usr/bin/env bash
set -euo pipefail
SESSION="mc-confluence"

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Server v tmux relaci '$SESSION' aktuálně neběží."
    exit 0
fi

echo "Odesílám příkaz 'save-all' a 'stop' do Minecraft konzole..."
tmux send-keys -t "$SESSION" "save-all" Enter
sleep 2
tmux send-keys -t "$SESSION" "stop" Enter
echo "Příkaz k bezpečnému uložení a vypnutí byl odeslán."
