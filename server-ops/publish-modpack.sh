#!/usr/bin/env bash
# Vygeneruje modpack/mods-lock.json z realnych souboru na serveru dell5290
# (nebo pouzije lokalni mods-bundle/) a s parametrem --upload nahraje mody
# do GitHub Releases (Private i Public repo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_DIR="${SERVER_DIR:-/home/kosh/Projects/confluence-server}"
LOCK_FILE="$REPO_DIR/modpack/mods-lock.json"
MODS_BUNDLE_DIR="$REPO_DIR/mods-bundle"

UPLOAD=0
FORCE_UPLOAD=0
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=1 ;;
        --force) FORCE_UPLOAD=1 ;;
        -h|--help)
            echo "Pouziti: $0 [--upload] [--force]"
            exit 0
            ;;
        *)
            echo "CHYBA: Neznamy parametr '$arg'. Pouziti: $0 [--upload] [--force]" >&2
            exit 1
            ;;
    esac
done

# Bezpecnostni kontrola: config.json v Gitu nesmi obsahovat tajne udaje
python3 - "$REPO_DIR/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("github_read_token", "tailscale_share_url"):
    if str(cfg.get(key) or "").strip():
        raise SystemExit(
            f"BEZPECNOSTNI STOP: '{key}' nesmi byt vyplnen primo v config.json! "
            "Patri pouze do server-ops/.env (ktery je v .gitignore)."
        )
PY

if [[ -d "$SERVER_DIR/mods" ]]; then
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
        # Bezpecny nazev prilohy pro GitHub Releases (bez mezer, '+' apod.)
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
elif [[ -d "$MODS_BUNDLE_DIR" && -f "$LOCK_FILE" ]]; then
    echo "[1/3] Pouzivam existujici $LOCK_FILE a lokalni slozku mods-bundle/ ($MODS_BUNDLE_DIR)."
    echo "[2/3] Preskakuji synchronizaci server-ops/ (nebezim na serveru dell5290)."
else
    echo "CHYBA: Nenalezena ani slozka serveru ($SERVER_DIR/mods), ani lokalni slozka ($MODS_BUNDLE_DIR)." >&2
    exit 1
fi

if [[ $UPLOAD -eq 0 ]]; then
    echo "[3/3] Preskakuji upload na GitHub Releases (spust s parametrem --upload po nastaveni server-ops/.env)."
    exit 0
fi

ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "CHYBA: Chybi $ENV_FILE! Zkopiruj server-ops/.env.example na server-ops/.env a vypln tokeny." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ -z "${GITHUB_REPO:-}" || -z "${GITHUB_UPLOAD_TOKEN:-}" ]]; then
    echo "CHYBA: V $ENV_FILE musi byt vyplnene GITHUB_REPO a GITHUB_UPLOAD_TOKEN." >&2
    exit 1
fi

TAG="${GITHUB_RELEASE_TAG:-mods-1.0-bop}"

echo "[3/3] Nahravam mody do GitHub Releases ($GITHUB_REPO, tag $TAG)..."
export GITHUB_UPLOAD_TOKEN
python3 - "$LOCK_FILE" "$SERVER_DIR" "$MODS_BUNDLE_DIR" "$GITHUB_REPO" "$TAG" "$FORCE_UPLOAD" <<'PY'
import json, os, subprocess, sys, urllib.error, urllib.parse, urllib.request

lock_file, server_dir, bundle_dir, repo, tag, force_flag = sys.argv[1:]
force = force_flag == "1"
token = os.environ["GITHUB_UPLOAD_TOKEN"].strip()

API_HEADERS = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "ja-to-vsechno-prcam-publisher",
}

def gh_json(method, url, payload=None):
    data = None
    headers = dict(API_HEADERS)
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read()
        return json.loads(body.decode("utf-8")) if body else None

with open(lock_file, "r", encoding="utf-8") as f:
    lock = json.load(f)

# 1. Najdeme nebo vytvorime Release pro dany tag
rel_url = f"https://api.github.com/repos/{repo}/releases/tags/{urllib.parse.quote(tag, safe='')}"
release = None
try:
    release = gh_json("GET", rel_url)
    print(f"  Nalezen existujici release '{tag}' (id={release['id']}).")
except urllib.error.HTTPError as e:
    if e.code == 404:
        print(f"  Release '{tag}' zatim neexistuje, vytvarim novy...")
        try:
            release = gh_json(
                "POST",
                f"https://api.github.com/repos/{repo}/releases",
                {
                    "tag_name": tag,
                    "target_commitish": "main",
                    "name": f"Modpack ({tag})",
                    "body": "Automaticky spravovany balik .jar modu podle modpack/mods-lock.json.",
                    "draft": False,
                    "prerelease": False,
                },
            )
            print(f"  Vytvoren release '{tag}' (id={release['id']}).")
        except urllib.error.HTTPError as ce:
            err_txt = ce.read().decode("utf-8", errors="replace")
            if ce.code in (404, 422):
                raise SystemExit(
                    f"CHYBA pri vytvareni release '{tag}' (HTTP {ce.code}): {err_txt}\n"
                    "Tip: Pokud je repo na GitHubu jeste prazdne, nejdriv spust ./server-ops/git-push.sh "
                    "a pak znovu ./server-ops/publish-modpack.sh --upload."
                )
            raise SystemExit(f"CHYBA pri vytvareni release (HTTP {ce.code}): {err_txt}")
    elif e.code in (401, 403):
        raise SystemExit(
            f"CHYBA autorizace (HTTP {e.code}): Zkontroluj GITHUB_UPLOAD_TOKEN v server-ops/.env "
            "(musi mit pravo Contents: Read and write na toto repo)."
        )
    else:
        raise SystemExit(f"CHYBA pri cteni release (HTTP {e.code}): {e.read().decode('utf-8', errors='replace')}")

release_id = release["id"]

# 2. Nacteme vsechny existujici prilohy release (strankovane)
existing_assets = {}
page = 1
while True:
    assets_url = f"https://api.github.com/repos/{repo}/releases/{release_id}/assets?per_page=100&page={page}"
    batch = gh_json("GET", assets_url) or []
    if not batch:
        break
    for a in batch:
        existing_assets[a["name"]] = a
    if len(batch) < 100:
        break
    page += 1

print(f"  Aktualne v release: {len(existing_assets)} souboru.")

# 3. Nahrajeme nove / zmenene mody (token predavame curlu jen pres stdin, nikdy v cmdline!)
uploaded = 0
skipped = 0
replaced = 0
total = len(lock["mods"])
expected_names = set()

for idx, m in enumerate(lock["mods"], 1):
    fname = m["file"]
    asset_name = m.get("package_file") or fname
    want_sha = m["sha256"].lower()
    want_size = int(m["size"])
    expected_names.add(asset_name)

    existing = existing_assets.get(asset_name)
    if existing and not force:
        digest = (existing.get("digest") or "").lower()
        if digest == f"sha256:{want_sha}":
            skipped += 1
            continue
        if not digest and int(existing.get("size", -1)) == want_size:
            skipped += 1
            continue

    src = os.path.join(server_dir, "mods" if m["side"] == "both" else "mods_client_only", fname)
    if not os.path.isfile(src):
        src = os.path.join(bundle_dir, fname)
    if not os.path.isfile(src):
        raise SystemExit(f"CHYBA: Nenalezen soubor {fname} ani v {server_dir}, ani v {bundle_dir}!")

    if existing:
        print(f"  [{idx}/{total}] Nahrazuji zmeneny asset: {asset_name}")
        gh_json("DELETE", f"https://api.github.com/repos/{repo}/releases/assets/{existing['id']}")
        replaced += 1
    else:
        print(f"  [{idx}/{total}] Upload: {fname} -> {asset_name}")

    upload_url = (
        f"https://uploads.github.com/repos/{repo}/releases/{release_id}/assets"
        f"?name={urllib.parse.quote(asset_name, safe='')}"
    )
    curl_cfg = (
        f'header = "Authorization: Bearer {token}"\n'
        'header = "Accept: application/vnd.github+json"\n'
        'header = "X-GitHub-Api-Version: 2022-11-28"\n'
        'header = "User-Agent: ja-to-vsechno-prcam-publisher"\n'
        'header = "Content-Type: application/java-archive"\n'
    )
    res = subprocess.run(
        [
            "curl", "-fsS", "--retry", "3", "--retry-delay", "2",
            "-K", "-", "-X", "POST", "--data-binary", f"@{src}", upload_url,
        ],
        input=curl_cfg,
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        raise SystemExit(f"CHYBA pri uploadu {fname}: {res.stderr.strip()}")

    try:
        up_meta = json.loads(res.stdout)
        got_name = up_meta.get("name", "")
        if got_name and got_name != asset_name:
            raise SystemExit(f"CHYBA: GitHub prejmenoval asset '{asset_name}' na '{got_name}'!")
        got_digest = (up_meta.get("digest") or "").lower()
        if got_digest and got_digest != f"sha256:{want_sha}":
            raise SystemExit(f"CHYBA: SHA256 po uploadu nesedi u {asset_name}: {got_digest} != sha256:{want_sha}")
    except json.JSONDecodeError:
        pass

    uploaded += 1

# 4. Odstranime z release vyrazene .jar soubory, ktere uz nejsou v mods-lock.json
removed = 0
for name, asset in list(existing_assets.items()):
    if name.endswith(".jar") and name not in expected_names:
        print(f"  [CLEAN] Mazu vyrazeny mod z release: {name}")
        gh_json("DELETE", f"https://api.github.com/repos/{repo}/releases/assets/{asset['id']}")
        removed += 1

print(
    f"Hotovo! Nahrano: {uploaded} (z toho nahrazeno: {replaced}), "
    f"beze zmeny (preskoceno): {skipped}, smazano vyrazenych: {removed}."
)
PY
