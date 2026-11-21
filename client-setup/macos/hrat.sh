#!/usr/bin/env bash
# Jednoduchy spoustec pro macOS (Apple Silicon i Intel)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CFG="$REPO_ROOT/config.json"

APP_BASE="$HOME/Library/Application Support/JaToVsechnoPrcam"
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
NF_VER="$(read_cfg neoforge_version)"
PMC_VER="$(read_cfg portablemc_version)"
PMC_VER="${PMC_VER:-5.0.6}"

echo "============================================================"
echo "  $SERVER_NAME — macOS klient (NeoForge $NF_VER)"
echo "============================================================"

if [[ ! -d "/Applications/Tailscale.app" ]] && ! command -v tailscale >/dev/null 2>&1; then
    echo "[TAILSCALE] Nainstaluj Tailscale z App Store nebo https://tailscale.com/download/mac"
    open "https://tailscale.com/download/mac" >/dev/null 2>&1 || true
fi

NICK=""
RAM_GB="6"
if [[ -f "$PLAYER_FILE" ]]; then
    NICK="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('username',''))" "$PLAYER_FILE" 2>/dev/null || true)"
    RAM_GB="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('ram_gb','6'))" "$PLAYER_FILE" 2>/dev/null || true)"
fi
if [[ -z "$NICK" ]]; then
    read -rp "Zadej svou prezdivku ve hre: " NICK
    read -rp "Kolik GB RAM pridelit hre [6]: " input_ram
    RAM_GB="${input_ram:-6}"
    python3 -c "import json,sys; json.dump({'username':sys.argv[2],'ram_gb':int(sys.argv[3])}, open(sys.argv[1],'w'), indent=2)" "$PLAYER_FILE" "$NICK" "$RAM_GB"
fi

"$REPO_ROOT/client-setup/linux/sync-mods.sh" "$REPO_ROOT" "$INSTANCE_DIR"

ARCH="$(uname -m)"
case "$ARCH" in
    arm64|aarch64) PMC_TARGET="macos-aarch64" ;;
    x86_64) PMC_TARGET="macos-x86_64" ;;
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
fi

echo "[HRA] Spoustim Minecraft (neoforge::$NF_VER) jako '$NICK' (${RAM_GB} GB RAM)..."
exec "$PMC_BIN" --main-dir "$MAIN_DIR" start "neoforge::${NF_VER}" \
    --mc-dir "$INSTANCE_DIR" \
    --jvm-policy system-then-mojang \
    "--jvm-arg=-Xms2G,-Xmx${RAM_GB}G,-XX:+UseG1GC" \
    -u "$NICK"
