#!/usr/bin/env bash
# Vygeneruje modpack/mods-lock.json z realnych souboru na serveru dell5290,
# zaktualizuje modpack/overrides/ a (pokud je vyplnen server-ops/.env)
# nahraje mody do GitLab Generic Package Registry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_DIR="${SERVER_DIR:-/home/kosh/Projects/confluence-server}"
LOCK_FILE="$REPO_DIR/modpack/mods-lock.json"

UPLOAD=0
if [[ "${1:-}" == "--upload" ]]; then
    UPLOAD=1
fi

if [[ ! -d "$SERVER_DIR/mods" ]]; then
    echo "CHYBA: Nenalezena slozka serveru: $SERVER_DIR/mods" >&2
    exit 1
fi

echo "[1/3] Generuji $LOCK_FILE ze slozek serveru ($SERVER_DIR)..."
python3 - "$SERVER_DIR" "$LOCK_FILE" <<'PY'
import hashlib, json, os, re, sys
from datetime import datetime, timezone

server_dir, lock_file = sys.argv[1], sys.argv[2]
sources = [
    (os.path.join(server_dir, "mods"), "both"),
    (os.path.join(server_dir, "mods_client_only"), "client"),
]

entries = []
seen = set()
for folder, side in sources:
    if not os.path.isdir(folder):
        continue
    for fname in sorted(os.listdir(folder)):
        if not fname.endswith(".jar"):
            continue
        if fname in seen:
            continue
        seen.add(fname)
        full = os.path.join(folder, fname)
        h = hashlib.sha256()
        with open(full, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        # GitLab Generic Package Registry neprijima znak '+' v nazvu souboru
        pkg_file = re.sub(r"[^A-Za-z0-9._-]", "_", fname)
        entries.append({
            "file": fname,
            "package_file": pkg_file,
            "sha256": h.hexdigest(),
            "size": os.path.getsize(full),
            "side": side,
        })

entries.sort(key=lambda x: x["file"].lower())
total_bytes = sum(e["size"] for e in entries)
data = {
    "schema_version": 1,
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mod_count": len(entries),
    "total_bytes": total_bytes,
    "mods": entries,
}

with open(lock_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"Hotovo: {len(entries)} modu, celkem {total_bytes / (1024*1024):.1f} MiB.")
PY

echo "[2/3] Synchronizuji serverove skripty do server-ops/..."
cp -a "$SERVER_DIR/start-server.sh" "$SERVER_DIR/_run-loop.sh" "$SERVER_DIR/stop-server.sh" "$SERVER_DIR/user_jvm_args.txt" "$REPO_DIR/server-ops/"
cp -a "$SERVER_DIR/server.properties" "$REPO_DIR/server-ops/server.properties.template"

if [[ $UPLOAD -eq 0 ]]; then
    echo "[3/3] Preskakuji upload na GitLab (spust s parametrem --upload po nastaveni server-ops/.env)."
    exit 0
fi

ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "CHYBA: Chybi $ENV_FILE! Zkopiruj server-ops/.env.example na server-ops/.env a vypln token." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ -z "${GITLAB_PROJECT_ID:-}" || -z "${GITLAB_UPLOAD_TOKEN:-}" ]]; then
    echo "CHYBA: V $ENV_FILE musi byt vyplnene GITLAB_PROJECT_ID a GITLAB_UPLOAD_TOKEN." >&2
    exit 1
fi

BASE="${GITLAB_BASE_URL:-https://gitlab.com}"
PKG="${GITLAB_PACKAGE_NAME:-modpack-mods}"
VER="${GITLAB_PACKAGE_VERSION:-1.0-bop}"

echo "[3/3] Nahravam mody do GitLab Generic Package Registry ($BASE, projekt $GITLAB_PROJECT_ID, balik $PKG/$VER)..."
python3 - "$LOCK_FILE" "$SERVER_DIR" "$BASE" "$GITLAB_PROJECT_ID" "$PKG" "$VER" "$GITLAB_UPLOAD_TOKEN" <<'PY'
import json, os, subprocess, sys, urllib.request, urllib.error

lock_file, server_dir, base, proj_id, pkg, ver, token = sys.argv[1:]
with open(lock_file, "r", encoding="utf-8") as f:
    lock = json.load(f)

# Zjistime, ktere soubory uz v baliku na GitLabu jsou (se stejnym SHA256), at je nenahravame zbytecne
existing_sha = {}
try:
    url = f"{base}/api/v4/projects/{proj_id}/packages?package_name={pkg}&package_version={ver}"
    req = urllib.request.Request(url, headers={"PRIVATE-TOKEN": token})
    with urllib.request.urlopen(req, timeout=20) as resp:
        pkgs = json.loads(resp.read().decode())
    for p in pkgs:
        if p.get("name") == pkg and p.get("version") == ver:
            pid = p["id"]
            page = 1
            while True:
                furl = f"{base}/api/v4/projects/{proj_id}/packages/{pid}/package_files?per_page=100&page={page}"
                freq = urllib.request.Request(furl, headers={"PRIVATE-TOKEN": token})
                with urllib.request.urlopen(freq, timeout=20) as fresp:
                    files = json.loads(fresp.read().decode())
                if not files:
                    break
                for pf in files:
                    existing_sha[pf["file_name"]] = pf.get("file_sha256", "")
                page += 1
except Exception as e:
    print(f"Poznamka: nepodarilo se nacist existujici soubory baliku ({e}), nahravam vse.")

uploaded = 0
skipped = 0
total = len(lock["mods"])
for idx, m in enumerate(lock["mods"], 1):
    fname = m["file"]
    pkg_file = m["package_file"]
    sha = m["sha256"]
    if existing_sha.get(pkg_file) == sha:
        skipped += 1
        continue
    src = os.path.join(server_dir, "mods" if m["side"] == "both" else "mods_client_only", fname)
    upload_url = f"{base}/api/v4/projects/{proj_id}/packages/generic/{pkg}/{ver}/{pkg_file}"
    print(f"  [{idx}/{total}] Upload: {fname} -> {pkg_file}")
    res = subprocess.run(
        ["curl", "-fsS", "--header", f"PRIVATE-TOKEN: {token}", "--upload-file", src, upload_url],
        capture_output=True, text=True
    )
    if res.returncode != 0:
        print(f"CHYBA pri uploadu {fname}: {res.stderr}", file=sys.stderr)
        sys.exit(1)
    uploaded += 1

print(f"Hotovo! Nahrano novych/zmenenych: {uploaded}, beze zmeny (preskoceno): {skipped}.")
PY
