# Stappenplan: de historie van main opschonen

Doel: geen enkele commit op `main` (en op de branch met het lopende werk) bevat nog AI-attributie
(`Co-Authored-By: Claude …`, `Claude-Session:`-links, "Generated with Claude Code"), een
vendor-identiteit als author of committer, of een persoonlijk e-mailadres dat je niet openbaar wilt.

Wat het oplevert en wat niet:

- **Wel**: `git log` van elke branch is schoon, en nieuwe clones zien alleen de schone historie. De
  bestanden zelf blijven identiek: alleen commit-berichten en identiteiten veranderen, plus één
  e-mailadres in een testbestand als je dat meeneemt.
- **Niet vanzelf**: de oude commits blijven op GitHub bereikbaar via `refs/pull/N/head` van elke PR
  en via `/commit/<sha>`-pagina's, en PR-beschrijvingen, commentaar en workflow-runs tonen de oude
  teksten. Die ruim je op met stap 11–13; alleen GitHub Support kan oude SHA's echt laten verdwijnen.
- **Kosten**: alle commit-SHA's veranderen, dus elke clone moet opnieuw (stap 10). De 11 door GitHub
  ondertekende squash-commits verliezen hun "Verified"-badge (herschrijven verwijdert handtekeningen).
  De repo heeft geen forks en geen tags, dus daar hoef je niets mee.

Voer de stappen uit **vóór** je de guard-PR merget en **vóór** `scripts/github-hardening.sh`: die
zet de `Default`-ruleset aan, en die weigert force-pushes voor iedereen, jij ook.

`scripts/clean-history.sh` doet het herschrijven en controleert daarna alles. Het pusht nooit zelf:
het drukt de push-commando's af. `tests/bats/clean-history.bats` test het op een kunstmatige repo.

## 0. Beslissingen vooraf

1. **E-mailadressen.** Op main staan twee van je eigen adressen als author/committer (`OLD1` op 19
   commits, `OLD2` op 1). Het bericht van #9 noemt `OLD2` en een derde adres (`OLD3`) als
   `Co-authored-by`. Op de werkbranch staat `OLD3` in de historie van
   `tools/attribution-guard/tests/run-tests.sh` (in de laatste versie al vervangen). Aanbevolen: alles
   naar je noreply-adres (`73317412+lucas4790@users.noreply.github.com`) en de `Co-authored-by`-regels
   van jezelf weg. Je herschrijft toch al, dus het kost niets extra. `git log --format='%ae %ce' main | sort -u`
   laat zien welke adressen het zijn.
2. **De werkbranch** `claude/setup-analyse-optimalisatie-1gy14n` meenemen en onder een eigen naam
   (`setup-analyse`) terugzetten. De committer `Claude <noreply@anthropic.com>` wordt dan jij, dus
   `scripts/adopt-branch.sh` is voor die branch niet meer nodig. Aanbevolen: ja.
3. **Tijdstip**: kies een moment zonder open PR's en zonder lopend werk; start in die tijd geen
   cloud-sessie op deze repo.

## 1. Benodigdheden (op je eigen machine)

- git ≥ 2.36, python3, `git-filter-repo` (`sudo apt install git-filter-repo`, `brew install git-filter-repo`
  of `pipx install git-filter-repo`), `gh` ingelogd als admin van de repo.
- De attribution guard als git-hook mag aan blijven: bij de push controleert hij de herschreven commits
  nog een keer. **Omzeil hem niet**; weigert hij, dan is er iets niet schoon.

## 2. Bevriezen

```bash
R=lucas4790/my-claude-skills
gh pr list -R "$R" --state open                    # moet leeg zijn
gh workflow disable sync-upstream.yml -R "$R"      # de dagelijkse sync mag nu geen branches pushen
```

## 3. Kopieën maken

```bash
mkdir -p ~/history-cleanup && cd ~/history-cleanup
git clone --bare   https://github.com/$R.git repo.git      # wordt herschreven
git clone --mirror https://github.com/$R.git backup.git    # blijft onaangeroerd: je terugweg
git clone -q --branch claude/setup-analyse-optimalisatie-1gy14n https://github.com/$R.git werkbranch   # script + guard
# de sync-branches zijn al gemerged (hun inhoud staat via squash op main): niet meenemen
git -C repo.git branch -D sync/high-trust sync/low-trust
```

## 4. Invoerbestanden (lokaal houden, nooit committen)

Vul je eigen adressen in (zie stap 0):

```bash
NOREPLY='73317412+lucas4790@users.noreply.github.com'
OLD1='...'   # author/committer van de meeste commits op main
OLD2='...'   # author/committer van één commit, en co-author in #9
OLD3='...'   # co-author in #9, en in de historie van het guard-testbestand
printf 'lucas4790 <%s> <%s>\n' "$NOREPLY" "$OLD1" "$NOREPLY" "$OLD2" > mailmap.txt
printf '%s==>lucas@example.com\n' "$OLD3" > replace.txt
```

## 5. Herschrijven en verifiëren

```bash
bash werkbranch/scripts/clean-history.sh \
  --owner "lucas4790 <$NOREPLY>" \
  --mailmap mailmap.txt --replace-text replace.txt \
  --drop-coauthor "$OLD2" --drop-coauthor "$OLD3" \
  --forbid "$OLD1" --forbid "$OLD2" --forbid "$OLD3" \
  repo.git
```

Het script:

- noteert vooraf de commits met attributie in `repo.git.clean-history/attribution-commits.txt`
  (die lijst heb je in stap 13 nodig);
- haalt met de strip-modus van de guard (`tools/attribution-guard/patterns.ere`, dezelfde patronen als de
  verplichte check) de attributieregels uit elk bericht en verwijdert een losse `---------` die overblijft;
- zet via de mailmap de vendor-identiteit en je oude adressen om naar jou, en vervangt het adres in het
  testbestand;
- controleert daarna: geen attributie meer in een bericht (alle branches), geen `@anthropic.com`-identiteit,
  geen van de `--forbid`-teksten in berichten, identiteiten of bestanden, hetzelfde aantal commits, en
  zonder `--replace-text` exact dezelfde bestanden per commit.

Het stopt met "verification FAILED; do not push" als er iets niet klopt. Een treffer in een
onderwerpregel breekt het herschrijven af; herformuleer zo'n commit dan eerst met de hand.

Kijk zelf nog even:

```bash
git -C repo.git log --format='%h %an <%ae> | %cn <%ce>%n%B' main | less
git -C repo.git rev-parse main^{tree}; git -C backup.git rev-parse main^{tree}   # gelijk: bestanden op main ongewijzigd
```

## 6. Bescherming van main tijdelijk uit

Kijk eerst wat er aan staat:

```bash
gh api repos/$R/rulesets --jq '.[] | "\(.id) \(.name) \(.enforcement)"'
gh api repos/$R/branches/main/protection --jq '{force_pushes: .allow_force_pushes.enabled, admins: .enforce_admins.enabled}'
```

- **Ruleset** (bestaat pas na `github-hardening.sh`): `gh api -X PUT repos/$R/rulesets/<id> -f enforcement=disabled`
- **Klassieke branch protection**: Settings → Branches → regel voor `main` → Edit → *Allow force pushes*
  → *Specify who can force push* → jezelf → Save. Verwijder de regel niet: dan ben je de instellingen kwijt.

## 7. Pushen

`clean-history.sh` drukte de commando's af; voor deze repo komen ze hierop neer:

```bash
git -C repo.git remote add origin https://github.com/$R.git          # filter-repo haalde origin weg
git -C repo.git push --force-with-lease='refs/heads/main:<oude main-SHA uit de uitvoer>' origin refs/heads/main:refs/heads/main
git -C repo.git push origin refs/heads/claude/setup-analyse-optimalisatie-1gy14n:refs/heads/setup-analyse
git -C repo.git push origin --delete claude/setup-analyse-optimalisatie-1gy14n sync/high-trust sync/low-trust
```

`--force-with-lease` weigert als main intussen toch veranderd is; begin dan opnieuw bij stap 3.

## 8. Bescherming en sync weer aan

- Ruleset: `gh api -X PUT repos/$R/rulesets/<id> -f enforcement=active`; klassiek: *Allow force pushes* weer uit.
- `gh workflow enable sync-upstream.yml -R "$R"`

## 9. Controleren op GitHub

```bash
git clone -q https://github.com/$R.git verify
git -C verify log --all --format='%B' | sh werkbranch/tools/attribution-guard/attribution-guard.sh check && echo "berichten schoon"
git -C verify log --all --format='%an <%ae>%n%cn <%ce>' | sort -u   # alleen jij, GitHub en github-actions[bot]
```

Op GitHub staat bij de commits van `setup-analyse` nu jouw naam als committer, niet meer "Claude committed".

## 10. Clones bijwerken op elke machine

- **Werk-clones** van deze repo: eigen werk eerst veiligstellen, dan
  `git fetch origin && git checkout main && git reset --hard origin/main`, of opnieuw clonen.
- **Marketplace-clone van Claude Code**:
  ```bash
  m="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/marketplaces/my-claude-skills"
  git -C "$m" fetch origin && git -C "$m" reset --hard origin/main
  claude plugin marketplace update my-claude-skills
  ```
  Op Windows: hetzelfde pad onder `%USERPROFILE%\.claude`.
- **Copilot CLI / VS Code**: `copilot plugin marketplace update my-claude-skills`. Geeft dat een fout over
  uiteenlopende historie, verwijder de marketplace, voeg hem opnieuw toe en draai `install-copilot.sh`
  (of `.ps1`) opnieuw voor je profielen.

## 11. Daarna de gewone eenmalige stappen

Volg [ATTRIBUTION.md, "One-time steps"](ATTRIBUTION.md#one-time-steps-in-this-order) vanaf stap 1:

1. Open de PR vanaf `setup-analyse` (`https://github.com/lucas4790/my-claude-skills/compare/main...setup-analyse`)
   met een titel en beschrijving die je zelf schrijft, en merge met squash. `adopt-branch.sh` is niet
   nodig: de branch is al herschreven.
2. `bash scripts/github-hardening.sh`.
3. **Actions → Attribution audit → Run workflow** met *delete runs* aan. Dat haalt de "Generated with
   Claude Code"-voetteksten en sessielinks uit de beschrijvingen van #5–#9, #12 en #13 en uit het
   commentaar, en verwijdert workflow-runs waarvan het oude commit-bericht attributie bevat. Verwijder
   daarna per PR de oude revisies uit de edit-geschiedenis ("edited" → revisie → *Delete revision*).

## 12. Terugdraaien (alleen vóór stap 11)

```bash
git -C backup.git push --force origin refs/heads/main:refs/heads/main \
  refs/heads/claude/setup-analyse-optimalisatie-1gy14n:refs/heads/claude/setup-analyse-optimalisatie-1gy14n
```

Doe dit met de bescherming uit, zoals in stap 6.

## 13. GitHub Support (optioneel, voor de oude SHA's)

Via <https://support.github.com/request>, onderwerp "Remove sensitive data", met:

- de repo, de lijst oude SHA's uit `repo.git.clean-history/attribution-commits.txt` en de PR's die ze nog
  bevatten (#5, #6, #8, #9, #12, #13);
- de reden: persoonsgegevens (e-mailadressen) en sessielinks in commit-berichten, historie is al
  herschreven en geforce-pusht;
- de vraag om cached views en de verwijzingen vanuit pull requests te verwijderen, en de dangling commits
  op te ruimen. Of ze PR's #12 en #13 (met de app-badge) willen verwijderen, beslissen zij.

Support helpt bij gevoelige gegevens; bij alleen tekst in commit-berichten is het aan hen.
