# Já to všechno prcám — Minecraft 1.21.1 (NeoForge 21.1.228)

Centrální repozitář pro náš soukromý modovaný Minecraft server (**Confluence: Otherworld + Biomes O' Plenty**).
Obsahuje konfigurace, SHA256 lockfile všech 66 klientských modů, multiplatformní klienty (Windows / Linux / macOS) a správu serveru.

> **Architektura bez nafukování Gitu:**
> - **V Gitu (< 1 MB):** skripty, konfigurace (`modpack/overrides/`), `config.json` a `modpack/mods-lock.json` (seznam modů + SHA256).
> - **V GitLab Generic Package Registry (~280 MB):** samotné `.jar` mody. Klientský spouštěč při každém zapnutí porovná SHA256, stáhne jen nové/změněné mody a smaže vyřazené.

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

## Pro majitele serveru (`dell5290`) — napojení na GitLab.com (3 minuty)

1. Na [gitlab.com](https://gitlab.com) založ nový **soukromý (Private)** projekt (např. `ja-to-vsechno-prcam`) **bez** README.
2. V projektu zkopíruj **Project ID** (číslo pod názvem projektu) a v `Settings -> Access Tokens` vytvoř **2 Project Access Tokeny**:
   - **`upload-bot`** (role *Maintainer*, scope **`api`**) -> jen pro tebe na `dell5290` do `server-ops/.env` (nikdy se necommituje!).
   - **`hraci-readonly`** (role *Reporter*, scopy **`read_api` + `read_repository`**) -> jen pro čtení, patří do `config.json` (`gitlab_read_token`), takže si kamarádi nemusí zakládat účet na GitLabu.
3. Vyplň do `config.json`:
   - `gitlab_project_id`
   - `gitlab_read_token` (ten **read-only** token!)
   - `tailscale_share_url` (tvůj Reusable Share Link na `dell5290` z [Tailscale Admin](https://login.tailscale.com/admin/machines))
4. Zkopíruj `server-ops/.env.example` na `server-ops/.env` a vyplň `GITLAB_PROJECT_ID` + `GITLAB_UPLOAD_TOKEN`.
5. Nahraj mody do GitLab Package Registry, pushni repo a zabal balíček pro kamarády:
   ```bash
   ./server-ops/publish-modpack.sh --upload
   git add -A && git commit -m "Napojeni na GitLab a Tailscale share link"
   git remote add origin https://gitlab.com/<TVUJ_UCET>/ja-to-vsechno-prcam.git
   git push -u origin main
   ./server-ops/pack-client-zip.sh
   ```
6. Výsledný soubor `dist/Ja-to-vsechno-prcam-KLIENT-WINDOWS.zip` (< 1 MB!) hoď kamarádům na Discord.

### Jak v budoucnu přidat nebo upravit mod?
1. Přidej/odstraň `.jar` na serveru (`confluence-server/mods/` nebo `mods_client_only/`).
2. Spusť:
   ```bash
   ./server-ops/publish-modpack.sh --upload
   git add modpack/mods-lock.json && git commit -m "Update modu" && git push
   ```
3. Kamarádi nic nového nestahují — příště jen kliknou na svou ikonu na Plochu a klient si sám stáhne jen ten jeden nový `.jar`!
