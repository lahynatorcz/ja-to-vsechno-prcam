#!/usr/bin/env bash
# Bezpecny git push na GitHub bez ukladani tokenu do .git/config nebo historie shellu.
# Pred pushem zkontroluje, ze v repu nejsou zadne unikle tokeny ani soukrome odkazy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "CHYBA: Chybi $ENV_FILE! Vypln GITHUB_REPO a GITHUB_UPLOAD_TOKEN." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ -z "${GITHUB_REPO:-}" || -z "${GITHUB_UPLOAD_TOKEN:-}" ]]; then
    echo "CHYBA: V $ENV_FILE musi byt vyplnene GITHUB_REPO a GITHUB_UPLOAD_TOKEN." >&2
    exit 1
fi

cd "$REPO_DIR"

echo "[1/3] Bezpecnostni audit repozitare pred pushem..."
# a) .env nesmi byt sledovany Gitem
if [[ -n "$(git ls-files .env server-ops/.env '*.env' config.local.json)" ]]; then
    echo "BEZPECNOSTNI STOP: Nektery .env soubor je sledovany Gitem!" >&2
    exit 1
fi

# b) config.json v HEAD nesmi obsahovat token ani Tailscale share link
python3 - "$REPO_DIR" <<'PY'
import json, subprocess, sys
repo_dir = sys.argv[1]
raw = subprocess.check_output(["git", "-C", repo_dir, "show", "HEAD:config.json"], text=True)
cfg = json.loads(raw)
for key in ("github_read_token", "tailscale_share_url"):
    if str(cfg.get(key) or "").strip():
        raise SystemExit(f"BEZPECNOSTNI STOP: HEAD:config.json obsahuje '{key}'!")
PY

# c) Sken vsech sledovanych souboru v HEAD na vzory tokenu / tajnych odkazu
if git grep -n -E '(github_pat_[A-Za-z0-9_]+|ghp_[A-Za-z0-9]+|gho_[A-Za-z0-9]+|glpat-[A-Za-z0-9_-]+|tailscale\.com/s/)' HEAD >/dev/null 2>&1; then
    echo "BEZPECNOSTNI STOP: V historii/HEAD byl nalezen potencialni tajny token nebo Tailscale share link!" >&2
    git grep -n -E '(github_pat_[A-Za-z0-9_]+|ghp_[A-Za-z0-9]+|gho_[A-Za-z0-9]+|glpat-[A-Za-z0-9_-]+|tailscale\.com/s/)' HEAD | sed -E 's/(github_pat_|ghp_|gho_|glpat-)[^"[:space:]]+/\1***REDACTED***/g' >&2
    exit 1
fi
echo "  [OK] Zadny unikly token ani .env v repu."

# 2. Nastaveni cisteho remote origin (NIKDY nevkladat token do URL v .git/config!)
CLEAN_URL="https://github.com/${GITHUB_REPO}.git"
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$CLEAN_URL"
else
    git remote add origin "$CLEAN_URL"
fi
echo "[2/3] Remote origin: $CLEAN_URL"

# 3. Push pres docasny GIT_ASKPASS (token zije jen v pameti po dobu prikazu)
ASKPASS="$(mktemp)"
chmod 700 "$ASKPASS"
trap 'rm -f "$ASKPASS"' EXIT

cat > "$ASKPASS" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    *Username*) printf '%s\n' "x-access-token" ;;
    *Password*) printf '%s\n' "${GH_PUSH_TOKEN_MEM}" ;;
esac
EOF

echo "[3/3] Pushuji vetev main na GitHub..."
GH_PUSH_TOKEN_MEM="$GITHUB_UPLOAD_TOKEN" \
GIT_ASKPASS="$ASKPASS" \
GIT_TERMINAL_PROMPT=0 \
git push -u origin main "$@"

echo "[OK] Push na GitHub dokonceny bez ulozeni tokenu do .git/config."
