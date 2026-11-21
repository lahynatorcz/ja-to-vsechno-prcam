#!/usr/bin/env bash
# Delta-synchronizace modu a konfiguraci podle modpack/mods-lock.json (Linux / macOS)
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Pouziti: $0 <REPO_ROOT> <INSTANCE_DIR> [LOCAL_MODS_SOURCE]" >&2
    exit 1
fi

REPO_ROOT="$(cd "$1" && pwd)"
INSTANCE_DIR="$2"
LOCAL_MODS_SOURCE="${3:-}"

mkdir -p "$INSTANCE_DIR/mods"

python3 - "$REPO_ROOT" "$INSTANCE_DIR" "$LOCAL_MODS_SOURCE" <<'PY'
import hashlib, json, os, shutil, sys, urllib.request, urllib.error

repo_root, instance_dir, local_src = sys.argv[1], sys.argv[2], sys.argv[3]
cfg_path = os.path.join(repo_root, "config.json")
lock_path = os.path.join(repo_root, "modpack", "mods-lock.json")

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

token = (cfg.get("gitlab_read_token") or "").strip()
proj_id = str(cfg.get("gitlab_project_id") or "").strip()
base = (cfg.get("gitlab_base_url") or "https://gitlab.com").rstrip("/")
headers = {"PRIVATE-TOKEN": token} if token else {}

# 1. Pokud je napojeny GitLab, stahneme nejnovejsi mods-lock.json
if proj_id:
    raw_url = f"{base}/api/v4/projects/{proj_id}/repository/files/modpack%2Fmods-lock.json/raw?ref=main"
    try:
        print("[SYNC] Kontroluji nejnovejsi seznam modu na GitLabu...")
        req = urllib.request.Request(raw_url, headers=headers)
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read()
        json.loads(raw.decode("utf-8"))
        with open(lock_path, "wb") as f:
            f.write(raw)
        print("[OK]   mods-lock.json aktualizovan z GitLabu.")
    except Exception as e:
        print(f"[WARN] Nepodarilo se stahnout mods-lock.json z GitLabu ({e}), pouzivam lokalni kopii.")

with open(lock_path, "r", encoding="utf-8") as f:
    lock = json.load(f)

if not local_src:
    cand = os.path.join(repo_root, "mods-bundle")
    if os.path.isdir(cand):
        local_src = cand

mods_dir = os.path.join(instance_dir, "mods")
os.makedirs(mods_dir, exist_ok=True)

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest().lower()

# 2. Odstraneni starych/vyrazenych .jar souboru
expected = {m["file"] for m in lock["mods"]}
removed = 0
for fname in os.listdir(mods_dir):
    if fname.endswith(".jar") and fname not in expected:
        print(f"[WARN] Odstranuji vyrazeny mod: {fname}")
        os.remove(os.path.join(mods_dir, fname))
        removed += 1

# 3. Delta-synchronizace modu
total = len(lock["mods"])
kept = 0
updated = 0

pkg = cfg.get("gitlab_package_name", "modpack-mods")
ver = cfg.get("gitlab_package_version", "1.0-bop")

for idx, m in enumerate(lock["mods"], 1):
    fname = m["file"]
    want_sha = m["sha256"].lower()
    dst = os.path.join(mods_dir, fname)

    if os.path.isfile(dst) and sha256_file(dst) == want_sha:
        kept += 1
        continue

    # Lokalni zdroj (napr. USB / LAN / serverova slozka)
    copied = False
    if local_src:
        for sub in ("", "mods", "mods_client_only"):
            cand = os.path.join(local_src, sub, fname) if sub else os.path.join(local_src, fname)
            if os.path.isfile(cand) and sha256_file(cand) == want_sha:
                print(f"[SYNC] [{idx}/{total}] Kopiruji lokalne: {fname}")
                shutil.copy2(cand, dst)
                updated += 1
                copied = True
                break
    if copied:
        continue

    if not proj_id:
        raise SystemExit(
            f"CHYBA: Chybi mod '{fname}' a neni nastaven gitlab_project_id v config.json (ani lokalni slozka modu)."
        )

    pkg_file = m.get("package_file") or fname
    dl_url = f"{base}/api/v4/projects/{proj_id}/packages/generic/{pkg}/{ver}/{pkg_file}"
    part = dst + ".part"
    print(f"[SYNC] [{idx}/{total}] Stahuji z GitLabu: {fname}")
    req = urllib.request.Request(dl_url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp, open(part, "wb") as out:
            shutil.copyfileobj(resp, out)
    except Exception as e:
        if os.path.exists(part):
            os.remove(part)
        raise SystemExit(f"CHYBA pri stahovani '{fname}' z {dl_url}: {e}")

    got_sha = sha256_file(part)
    if got_sha != want_sha:
        os.remove(part)
        raise SystemExit(f"CHYBA: SHA256 nesedi u '{fname}' (ocekavano {want_sha}, stazeno {got_sha}).")

    os.replace(part, dst)
    updated += 1

print(f"[OK]   Mody hotove: {kept} v poradku, {updated} stazeno/zkopirovano, {removed} smazano (celkem {total}).")

# 4. Synchronizace overrides (config/, datapacks/, kubejs/, vychozi servers.dat)
overrides = os.path.join(repo_root, "modpack", "overrides")
if os.path.isdir(overrides):
    for sub in ("config", "datapacks", "kubejs"):
        src_sub = os.path.join(overrides, sub)
        if os.path.isdir(src_sub):
            shutil.copytree(src_sub, os.path.join(instance_dir, sub), dirs_exist_ok=True)
    src_srv = os.path.join(overrides, "servers.dat")
    dst_srv = os.path.join(instance_dir, "servers.dat")
    if os.path.isfile(src_srv) and not os.path.isfile(dst_srv):
        shutil.copy2(src_srv, dst_srv)
        print("[OK]   Vytvoren vychozi servers.dat.")
PY
