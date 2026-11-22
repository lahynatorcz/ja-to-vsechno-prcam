#!/usr/bin/env bash
# Delta-synchronizace modu a konfiguraci podle modpack/mods-lock.json (Linux / macOS)
# Podporuje Private i Public GitHub repozitare (GitHub Releases).
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Pouziti: $0 <REPO_ROOT> <INSTANCE_DIR> [LOCAL_MODS_SOURCE]" >&2
    exit 1
fi

REPO_ROOT="$(cd "$1" && pwd)"
INSTANCE_DIR="$2"
LOCAL_MODS_SOURCE="${3:-}"

mkdir -p "$INSTANCE_DIR/mods"

# Pokud bezime lokalne z naklonovaneho repa a existuje server-ops/.env, muzeme z nej bezpecne vzit read-only token
if [[ -z "${GITHUB_READ_TOKEN:-}" && -f "$REPO_ROOT/server-ops/.env" ]]; then
    GITHUB_READ_TOKEN="$(bash -c 'source "$1" >/dev/null 2>&1 && printf "%s" "${GITHUB_READ_TOKEN:-}"' _ "$REPO_ROOT/server-ops/.env" || true)"
    export GITHUB_READ_TOKEN
fi

python3 - "$REPO_ROOT" "$INSTANCE_DIR" "$LOCAL_MODS_SOURCE" <<'PY'
import hashlib, json, os, shutil, sys, urllib.error, urllib.parse, urllib.request

repo_root, instance_dir, local_src = sys.argv[1], sys.argv[2], sys.argv[3]
cfg_path = os.path.join(repo_root, "config.json")
lock_path = os.path.join(repo_root, "modpack", "mods-lock.json")

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

gh_repo = (cfg.get("github_repo") or "").strip()
gh_tag = (cfg.get("github_release_tag") or "mods-1.0-bop").strip()
token = (cfg.get("github_read_token") or os.environ.get("GITHUB_READ_TOKEN") or "").strip()

base_headers = {
    "User-Agent": "ja-to-vsechno-prcam-client",
    "X-GitHub-Api-Version": "2022-11-28",
}
if token:
    base_headers["Authorization"] = f"Bearer {token}"

api_headers = {**base_headers, "Accept": "application/vnd.github+json"}
raw_headers = {**base_headers, "Accept": "application/vnd.github.raw+json"}

class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

no_redirect_opener = urllib.request.build_opener(NoRedirectHandler)

def download_github_asset(asset_api_url, dst_part):
    req = urllib.request.Request(
        asset_api_url,
        headers={**base_headers, "Accept": "application/octet-stream"},
    )
    try:
        with no_redirect_opener.open(req, timeout=120) as resp, open(dst_part, "wb") as out:
            shutil.copyfileobj(resp, out)
            return
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 303, 307, 308):
            redirect_url = e.headers.get("Location")
            if not redirect_url:
                raise RuntimeError(f"GitHub vratil presmerovani ({e.code}) bez Location.")
            # Podepsana URL (Azure/S3) nesmi dostat GitHub Authorization hlavicku!
            dl_req = urllib.request.Request(redirect_url, headers={"User-Agent": "ja-to-vsechno-prcam-client"})
            with urllib.request.urlopen(dl_req, timeout=180) as resp, open(dst_part, "wb") as out:
                shutil.copyfileobj(resp, out)
                return
        raise

# 1. Pokud je napojeny GitHub, stahneme nejnovejsi mods-lock.json
if gh_repo:
    raw_url = f"https://api.github.com/repos/{gh_repo}/contents/modpack/mods-lock.json?ref=main"
    try:
        print("[SYNC] Kontroluji nejnovejsi seznam modu na GitHubu...")
        req = urllib.request.Request(raw_url, headers=raw_headers)
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read()
        json.loads(raw.decode("utf-8"))
        with open(lock_path, "wb") as f:
            f.write(raw)
        print("[OK]   mods-lock.json aktualizovan z GitHubu.")
    except Exception as e:
        print(f"[WARN] Nepodarilo se stahnout mods-lock.json z GitHubu ({e}), pouzivam lokalni kopii.")

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
asset_map = None

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

    if not gh_repo:
        raise SystemExit(
            f"CHYBA: Chybi mod '{fname}' a neni nastaven github_repo v config.json (ani lokalni slozka modu)."
        )

    # Lazy nacteni seznamu assetu z GitHub Release
    if asset_map is None:
        print(f"[SYNC] Nacitam seznam modu z GitHub Release ({gh_repo} @ {gh_tag})...")
        rel_url = f"https://api.github.com/repos/{gh_repo}/releases/tags/{urllib.parse.quote(gh_tag, safe='')}"
        try:
            with urllib.request.urlopen(urllib.request.Request(rel_url, headers=api_headers), timeout=30) as resp:
                release = json.loads(resp.read().decode("utf-8"))
        except Exception as e:
            raise SystemExit(f"CHYBA pri nacitani GitHub Release '{gh_tag}' z '{gh_repo}': {e}")

        asset_map = {}
        page = 1
        while True:
            aurl = f"https://api.github.com/repos/{gh_repo}/releases/{release['id']}/assets?per_page=100&page={page}"
            with urllib.request.urlopen(urllib.request.Request(aurl, headers=api_headers), timeout=30) as resp:
                batch = json.loads(resp.read().decode("utf-8"))
            if not batch:
                break
            for a in batch:
                asset_map[a["name"]] = a["url"]
            if len(batch) < 100:
                break
            page += 1

    pkg_file = m.get("package_file") or fname
    asset_url = asset_map.get(pkg_file) or asset_map.get(fname)
    if not asset_url:
        raise SystemExit(f"CHYBA: Mod '{fname}' ({pkg_file}) nebyl nalezen v GitHub Release '{gh_tag}'!")

    part = dst + ".part"
    print(f"[SYNC] [{idx}/{total}] Stahuji z GitHubu: {fname}")
    try:
        download_github_asset(asset_url, part)
    except Exception as e:
        if os.path.exists(part):
            os.remove(part)
        raise SystemExit(f"CHYBA pri stahovani '{fname}' z GitHub Release: {e}")

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
