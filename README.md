# Já to všechno prcám — Minecraft 1.21.1 (NeoForge 21.1.228)

Centrální soukromý repozitář pro náš modovaný Minecraft server (**Confluence: Otherworld + Biomes O' Plenty**).
Obsahuje konfigurace, SHA256 lockfile všech 66 klientských modů, multiplatformní klienty (Windows / Linux / macOS) a správu serveru.

> **Architektura a bezpečnost (Zero-Leak):**
> - **V Gitu (< 1 MB):** jen skripty, konfigurace (`modpack/overrides/`), čistý `config.json` (bez tokenů a bez Tailscale odkazu) a `modpack/mods-lock.json` (seznam modů + SHA256).
> - **V GitHub Releases (~280 MB):** všech 66 `.jar` modů jako přílohy release `mods-1.0-bop` v **Private** repu `lahynatorcz/ja-to-vsechno-prcam`.
> - **Žádné tajné údaje v Gitu:** oba Fine-grained PAT tokeny i Tailscale share odkaz žijí výhradně v lokálním `server-ops/.env` (v `.gitignore`, chráněno i git `pre-commit` hookem). Do klientského ZIPu se při balení injektuje jen **Read-only** token a Tailscale share link.

---

## Pro hráče (Windows 10 / 11) — 1 dvojklik

1. Rozbal poslaný malý balíček **`Ja-to-vsechno-prcam-KLIENT-WINDOWS.zip`** (třeba do `Dokumenty\Minecraft`).
2. Dvakrát klikni na **`HRAT.bat`**.
3. V okně **„Já to všechno prcám“**:
   - **Poprvé (síť):** Klikni na **`Nastavit Tailscale`** -> samo nainstaluje Tailscale, přihlásíš se Google/MS účtem a potvrdíš pozvánku na server (`Accept invite`). Stav nahoře zezelená.
   - Zadej svou **přezdívku** (funguje i bez koupeného Minecraftu; pokud máš originálku, můžeš zaškrtnout Microsoft účet).
   - Klikni na **`AKTUALIZOVAT MODY & HRÁT`**.
     *(Poprvé se automaticky stáhne Java 21, Minecraft 1.21.1, NeoForge 21.1.228 a všechny mody — zabere 1–2 minuty. Příště hra naběhne hned a případné nové mody se samy dostáhnou.)*
   - Volitelně klikni na **`Vytvořit ikonu na Plochu`**, ať to příště spouštíš jedním klikem z Plochy.

## Pro hráče (Linux / macOS)

```bash
# Linux (Arch/CachyOS, Ubuntu/Debian, Fedora)
./client-setup/linux/hrat.sh

# macOS
./client-setup/macos/hrat.sh
```
*(Chceš-li později změnit přezdívku nebo RAM, spusť `./client-setup/linux/hrat.sh --setup`.)*

---

## Pro majitele serveru (`dell5290`) — napojení na GitHub (Private repo)

1. Na [github.com/new](https://github.com/new) založ prázdný **Private** repozitář **`lahynatorcz/ja-to-vsechno-prcam`** (bez README, bez `.gitignore`, bez License).
2. V **GitHub Settings → Developer settings → Personal access tokens → Fine-grained tokens** vytvoř **2 samostatné tokeny** omezené **výhradně** na repozitář `ja-to-vsechno-prcam`:
   - **`ja-to-vsechno-prcam-upload`** (jen pro tebe): `Repository permissions → Contents: Read and write`.
   - **`ja-to-vsechno-prcam-players-ro`** (jen pro kamarády): `Repository permissions → Contents: Read-only` (platnost max 1 rok).
3. Zkopíruj `server-ops/.env.example` na `server-ops/.env` (`chmod 600 server-ops/.env`) a vyplň:
   - `GITHUB_UPLOAD_TOKEN` (tvůj **Read and write** token)
   - `GITHUB_READ_TOKEN` (**Read-only** token pro kamarády)
   - `TAILSCALE_SHARE_URL` (tvůj Reusable Share Link na `dell5290` z [Tailscale Admin](https://login.tailscale.com/admin/machines))
4. Pushni repozitář na GitHub (bez uložení tokenu do `.git/config`), nahraj všech 66 modů do GitHub Release a zabal klientský ZIP:
   ```bash
   ./server-ops/git-push.sh
   ./server-ops/publish-modpack.sh --upload
   ./server-ops/pack-client-zip.sh
   ```
5. Výsledný soubor `dist/Ja-to-vsechno-prcam-KLIENT-WINDOWS.zip` (< 1 MB) pošli kamarádům do soukromého chatu (nikdy veřejně — obsahuje read-only token pro Private repo).

### Jak v budoucnu přidat nebo upravit mod?
1. Přidej/odstraň `.jar` na serveru (`confluence-server/mods/` nebo `mods_client_only/`).
2. Spusť:
   ```bash
   ./server-ops/publish-modpack.sh --upload
   git add modpack/mods-lock.json && git commit -m "Update modu"
   ./server-ops/git-push.sh
   ```
3. Kamarádi nic nového nestahují — příště jen kliknou na ikonu na Plochu a klient si sám stáhne jen ten nový/změněný `.jar` a vyřazené smaže!
