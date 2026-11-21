#!/usr/bin/env bash
# Jednoduchy spoustec pro Linux (Arch/CachyOS, Debian/Ubuntu, Fedora)
# Resi Tailscale kontrolu/instalaci, SHA256 sync modu, portablemc v5.0.6 a spusteni NeoForge 21.1.228.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CFG="$REPO_ROOT/config.json"

APP_BASE="${XDG_DATA_HOME:-$HOME/.local/share}/ja-to-vsechno-prcam"
MAIN_DIR="$APP_BASE/mc-data"
INSTANCE_DIR="$APP_BASE/instance"
BIN_DIR="$APP_BASE/bin"
PLAYER_FILE="$APP_BASE/player.json"

mkdir -p "$MAIN_DIR" "$INSTANCE_DIR" "$BIN_DIR"

read_cfg() {
    python3 -c "import json,sys; print(json.load(open(sys.argv[1], encoding='utf-8')).get(sys.argv[2], ''))" "$CFG" "$1"
}

SERVER_NAME="$(read_cfg server_name)"
SERVER_IP="$(read_cfg server_ip)"
SERVER_PORT="$(read_cfg server_port)"
MC_VER="$(read_cfg mc_version)"
NF_VER="$(read_cfg neoforge_version)"
PMC_VER="$(read_cfg portablemc_version)"
TS_SHARE_URL="$(read_cfg tailscale_share_url)"
PMC_VER="${PMC_VER:-5.0.6}"

LOCAL_MODS="${LOCAL_MODS_SOURCE:-}"
if [[ -z "$LOCAL_MODS" && -d "/home/kosh/Projects/confluence-server/mods" ]]; then
    LOCAL_MODS="/home/kosh/Projects/confluence-server"
fi

echo "============================================================"
echo "  $SERVER_NAME — Linux klient"
echo "  Minecraft $MC_VER | NeoForge $NF_VER | $SERVER_IP:$SERVER_PORT"
echo "============================================================"

# 1. Kontrola Tailscale
if ! command -v tailscale >/dev/null 2>&1; then
    echo "[TAILSCALE] Tailscale neni nainstalovany."
    read -rp "Chces nainstalovat oficialni Tailscale ted? [a/N]: " ans
    if [[ "${ans,,}" == "a" || "${ans,,}" == "y" ]]; then
        if command -v pacman >/dev/null 2>&1; then
            sudo pacman -S --needed tailscale
            sudo systemctl enable --now tailscaled
        else
            curl -fsSL https://tailscale.com/install.sh | sh
        fi
        sudo tailscale up
        if [[ -n "$TS_SHARE_URL" ]]; then
            echo "Otevri zvací odkaz v prohlizeci a klikni na Accept invite:"
            echo "  $TS_SHARE_URL"
            xdg-open "$TS_SHARE_URL" >/dev/null 2>&1 || true
        fi
    fi
else
    TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
    if [[ "$TS_IP" == 100.* ]]; then
        echo "[OK]   Tailscale pripojen ($TS_IP)"
    else
        echo "[WARN] Tailscale neni prihlasen/pripojen. Spust: sudo tailscale up"
    fi
fi

# Rychly test portu serveru
if python3 -c "import socket,sys; s=socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=1.5); s.close()" "$SERVER_IP" "$SERVER_PORT" 2>/dev/null; then
    echo "[OK]   Server ONLINE na $SERVER_IP:$SERVER_PORT"
else
    echo "[WARN] Server ted neodpovida na $SERVER_IP:$SERVER_PORT (over Tailscale nebo zda server bezi)."
fi

# 2. Profil hrace (prezdivka + RAM)
NICK=""
RAM_GB=""
USE_MS="false"
if [[ -f "$PLAYER_FILE" ]]; then
    NICK="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('username',''))" "$PLAYER_FILE" 2>/dev/null || true)"
    RAM_GB="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('ram_gb',''))" "$PLAYER_FILE" 2>/dev/null || true)"
    USE_MS="$(python3 -c "import json,sys; print(str(json.load(open(sys.argv[1])).get('use_ms_auth', False)).lower())" "$PLAYER_FILE" 2>/dev/null || true)"
fi

if [[ -z "$NICK" || "${1:-}" == "--setup" ]]; then
    read -rp "Zadej svou prezdivku ve hre [${NICK:-Hrac}]: " input_nick
    NICK="${input_nick:-${NICK:-Hrac}}"
    TOTAL_RAM_GB="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)"
    DEF_RAM=4
    if [[ "$TOTAL_RAM_GB" -ge 20 ]]; then DEF_RAM=8
    elif [[ "$TOTAL_RAM_GB" -ge 12 ]]; then DEF_RAM=6
    fi
    read -rp "Kolik GB RAM pridelit hre (PC ma ${TOTAL_RAM_GB} GB) [${RAM_GB:-$DEF_RAM}]: " input_ram
    RAM_GB="${input_ram:-${RAM_GB:-$DEF_RAM}}"
    read -rp "Pouzit originalni Microsoft ucet misto offline prezdivky? [a/N]: " ms_ans
    if [[ "${ms_ans,,}" == "a" || "${ms_ans,,}" == "y" ]]; then USE_MS="true"; else USE_MS="false"; fi

    python3 - "$PLAYER_FILE" "$NICK" "$RAM_GB" "$USE_MS" <<'PY'
import json, sys
path, nick, ram, ms = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == "true"
with open(path, "w", encoding="utf-8") as f:
    json.dump({"username": nick, "ram_gb": ram, "use_ms_auth": ms}, f, indent=2)
PY
fi

# 3. Synchronizace modu a konfiguraci
"$SCRIPT_DIR/sync-mods.sh" "$REPO_ROOT" "$INSTANCE_DIR" "$LOCAL_MODS"

# 4. Stazeni portablemc v5.0.6 (pokud chybi)
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) PMC_TARGET="linux-x86_64-gnu" ;;
    aarch64|arm64) PMC_TARGET="linux-aarch64-gnu" ;;
    *) echo "CHYBA: Nepodporovana architektura $ARCH" >&2; exit 1 ;;
esac

PMC_BIN="$BIN_DIR/portablemc"
PMC_VER_FILE="$BIN_DIR/portablemc.version"
if [[ ! -x "$PMC_BIN" || "$(cat "$PMC_VER_FILE" 2>/dev/null || true)" != "$PMC_VER" ]]; then
    URL="https://github.com/theorzr/portablemc/releases/download/v${PMC_VER}/portablemc-${PMC_VER}-${PMC_TARGET}.tar.gz"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    echo "[PMC] Stahuji portablemc v$PMC_VER ($PMC_TARGET)..."
    curl -fsSL "$URL" | tar -xz -C "$TMP_DIR"
    FOUND="$(find "$TMP_DIR" -name portablemc -type f | head -n1)"
    cp -f "$FOUND" "$PMC_BIN"
    chmod +x "$PMC_BIN"
    printf '%s' "$PMC_VER" > "$PMC_VER_FILE"
    echo "[OK]  portablemc v$PMC_VER pripraven."
fi

# 5. Volitelna Microsoft autentizace
ARGS=(
    --main-dir "$MAIN_DIR"
    start "neoforge::${NF_VER}"
    --mc-dir "$INSTANCE_DIR"
    --jvm-policy system-then-mojang
    "--jvm-arg=-Xms2G,-Xmx${RAM_GB}G,-XX:+UseG1GC"
    -u "$NICK"
)

if [[ "$USE_MS" == "true" ]]; then
    if ! "$PMC_BIN" --main-dir "$MAIN_DIR" auth list 2>/dev/null | grep -Fq "$NICK"; then
        "$PMC_BIN" --main-dir "$MAIN_DIR" auth login
    fi
    ARGS+=(-a)
fi

if [[ "${1:-}" == "--join" ]]; then
    ARGS+=(--join-server "$SERVER_IP" --join-server-port "$SERVER_PORT")
fi

echo ""
echo "[HRA] Spoustim Minecraft (neoforge::$NF_VER) jako '$NICK' (${RAM_GB} GB RAM)..."
exec "$PMC_BIN" "${ARGS[@]}"
