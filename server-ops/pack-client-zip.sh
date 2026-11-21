#!/usr/bin/env bash
# Zabali maly (<1 MB) klientsky balicek pro Windows kamarady (bez 280 MB .jar modu,
# ktere si klient sam stahne a overi z GitLab Generic Package Registry).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_DIR/dist"
OUT_ZIP="$OUT_DIR/Ja-to-vsechno-prcam-KLIENT-WINDOWS.zip"

mkdir -p "$OUT_DIR"
rm -f "$OUT_ZIP"

TMP_STAGE="$(mktemp -d)"
trap 'rm -rf "$TMP_STAGE"' EXIT

STAGE="$TMP_STAGE/Ja-to-vsechno-prcam"
mkdir -p "$STAGE/client-setup"
cp -a "$REPO_DIR/config.json" "$STAGE/"
cp -a "$REPO_DIR/modpack" "$STAGE/"
cp -a "$REPO_DIR/client-setup/windows" "$STAGE/client-setup/"

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
ls -lh "$OUT_ZIP"
echo "Klientsky balicek pripraven: $OUT_ZIP"
