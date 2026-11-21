#!/usr/bin/env bash
set -uo pipefail

SERVER_DIR="/home/kosh/Projects/confluence-server"
cd "$SERVER_DIR"

MAX_STARTUP_RETRIES=1
attempt=0

run_once() {
    if command -v systemd-inhibit >/dev/null 2>&1 && systemd-inhibit --list >/dev/null 2>&1; then
        systemd-inhibit \
            --what=sleep:idle:handle-lid-switch \
            --who="Minecraft Server (Confluence)" \
            --why="Minecraft server bezi" \
            --mode=block \
            sh ./run.sh nogui
    else
        sh ./run.sh nogui
    fi
}

while true; do
    start_ts=$(date +%s)
    run_once
    rc=$?
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))

    if [[ $rc -eq 0 ]]; then
        echo "[start-server] Server skoncil ciste (exit 0)."
        exit 0
    fi

    # Automaticky retry POUZE pri casnem FML startup crashi (napr. race-condition v terra_entity RegisterEvent)
    if [[ $attempt -lt $MAX_STARTUP_RETRIES && $elapsed -lt 120 ]]; then
        if ! grep -q "Done (" "$SERVER_DIR/logs/latest.log" 2>/dev/null; then
            attempt=$((attempt + 1))
            echo "[start-server] Detekovan startup crash po ${elapsed}s (exit $rc). Zkousim automaticky restart ($attempt/$MAX_STARTUP_RETRIES) za 3s..."
            sleep 3
            continue
        fi
    fi

    echo "[start-server] Server skoncil s chybou (exit $rc, beh ${elapsed}s)."
    exit "$rc"
done
