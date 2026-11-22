#!/usr/bin/env bash
# Zabali maly (<1 MB) klientsky balicek pro Windows kamarady (bez 280 MB .jar modu,
# ktere si klient sam stahne a overi z GitHub Releases).
# Bezpecnost: GITHUB_READ_TOKEN a TAILSCALE_SHARE_URL se berou JEN z lokalniho
# server-ops/.env a vkladaji se pouze do kopie config.json uvnitr ZIPu (nikdy do Gitu!).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_DIR/dist"
OUT_ZIP="$OUT_DIR/Ja-to-vsechno-prcam-KLIENT-WINDOWS.zip"
ENV_FILE="$SCRIPT_DIR/.env"

ALLOW_EMPTY_SECRETS=0
if [[ "${1:-}" == "--allow-empty-secrets" ]]; then
    ALLOW_EMPTY_SECRETS=1
fi

# 1. Kontrola ze sledovany config.json v Gitu je cisty bez tokenu
python3 - "$REPO_DIR/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("github_read_token", "tailscale_share_url"):
    if str(cfg.get(key) or "").strip():
        raise SystemExit(
            f"BEZPECNOSTNI STOP: '{key}' nesmi byt vyplnen v repo config.json! "
            "Vypln ho pouze v server-ops/.env."
        )
PY

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
elif [[ $ALLOW_EMPTY_SECRETS -eq 0 ]]; then
    echo "CHYBA: Chybi $ENV_FILE! Vypln GITHUB_READ_TOKEN (read-only) a TAILSCALE_SHARE_URL." >&2
    exit 1
fi

GH_REPO="${GITHUB_REPO:-}"
GH_TAG="${GITHUB_RELEASE_TAG:-}"
GH_READ="${GITHUB_READ_TOKEN:-}"
GH_UPLOAD="${GITHUB_UPLOAD_TOKEN:-}"
TS_URL="${TAILSCALE_SHARE_URL:-}"

# 2. Kriticke bezpecnostni kontroly pred zabalenim ZIPu pro kamarady
if [[ -n "$GH_READ" && -n "$GH_UPLOAD" && "$GH_READ" == "$GH_UPLOAD" ]]; then
    echo "BEZPECNOSTNI STOP: GITHUB_READ_TOKEN je stejny jako GITHUB_UPLOAD_TOKEN!" >&2
    echo "Nikdy kamaradum neposilej token s pravem zapisu! Vygeneruj samostatny Read-only token." >&2
    exit 1
fi

if [[ -z "$GH_READ" && $ALLOW_EMPTY_SECRETS -eq 0 ]]; then
    echo "CHYBA: V server-ops/.env chybi GITHUB_READ_TOKEN (pro Private repo je nutny, aby klient mohl stahovat mody)." >&2
    echo "(Pro verejne/offline testovani lze pouzit parametr --allow-empty-secrets.)" >&2
    exit 1
fi

if [[ -z "$TS_URL" ]]; then
    echo "[WARN] TAILSCALE_SHARE_URL v server-ops/.env je prazdny — tlacitko Tailscale neotevre zvací odkaz automaticky." >&2
fi

mkdir -p "$OUT_DIR"
rm -f "$OUT_ZIP"

TMP_STAGE="$(mktemp -d)"
chmod 700 "$TMP_STAGE"
trap 'rm -rf "$TMP_STAGE"' EXIT

STAGE="$TMP_STAGE/Ja-to-vsechno-prcam"
mkdir -p "$STAGE/client-setup"
cp -a "$REPO_DIR/config.json" "$STAGE/"
cp -a "$REPO_DIR/modpack" "$STAGE/"
cp -a "$REPO_DIR/client-setup/windows" "$STAGE/client-setup/"

# Injektujeme pouze read-only udaje do docasne kopie config.json uvnitr ZIPu
export ZIP_GH_REPO="$GH_REPO"
export ZIP_GH_TAG="$GH_TAG"
export ZIP_GH_READ="$GH_READ"
export ZIP_TS_URL="$TS_URL"
python3 - "$STAGE/config.json" <<'PY'
import json, os, sys
cfg_path = sys.argv[1]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

if os.environ.get("ZIP_GH_REPO"):
    cfg["github_repo"] = os.environ["ZIP_GH_REPO"].strip()
if os.environ.get("ZIP_GH_TAG"):
    cfg["github_release_tag"] = os.environ["ZIP_GH_TAG"].strip()
cfg["github_read_token"] = os.environ.get("ZIP_GH_READ", "").strip()
cfg["tailscale_share_url"] = os.environ.get("ZIP_TS_URL", "").strip()

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

# Pro absolutni jednoduchost zkopirujeme HRAT.bat i primo do korene baliku
cat > "$STAGE/HRAT.bat" <<'EOF'
@echo off
cd /d "%~dp0"
call "%~dp0client-setup\windows\HRAT.bat"
EOF

python3 - "$TMP_STAGE" "$OUT_ZIP" <<'PY'
import os, sys, zipfile
root, out_zip = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for dirpath, _, filenames in os.walk(root):
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            zf.write(full, rel)
PY

chmod 600 "$OUT_ZIP"
ls -lh "$OUT_ZIP"
echo "Klientsky balicek pripraven: $OUT_ZIP"
echo "(POZOR: Tento ZIP obsahuje read-only token pro kamarady — posilej ho jen do soukromeho chatu, nikdy na verejny web.)"
