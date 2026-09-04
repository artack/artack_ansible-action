# artack_ansible-action

Gemeinsamer CI-Baustein fuer die **Ansible-Belange unserer Projekte: Deployment
und Rollback** - dazu ein Preflight, der die typischen Fallen ohne Serverkontakt
aufdeckt. Der Name traegt bewusst kein `deploy`: Das Repo deckt schon heute
Deployment *und* Rollback ab und ist der Ort fuer weitere Ansible-Belange.

Aufbau: **Reusable Workflows** als Einstiegspunkte, eine **Composite Action** als
Mechanik darunter.

Zielgruppe sind die zehn Projekte, die per Ansistrano deployen (btc,
ebook_manager, sibe, suissetec_checklist, suissetec_contractor-insurance,
suissetec_datasheet, suissetec_metaapp_legacy, suissetec_quality-compendium,
suissetec_shop, suissetec_website). Vorausgesetzt wird die Hauskonvention aus
dem Skill `artack-dev:deployment-setup`: `ansible.cfg`, `hosts.yaml` und
`deploy_<env>.yaml` im Projektwurzelverzeichnis, das Submodul
[artack/ansistrano-php](https://github.com/artack/ansistrano-php) unter
`deployment/`.

> **Nicht dazu gehoert die neue Portal-App.** Sie deployt ueber GitHub Actions
> nach **Azure** und hat mit diesem Baustein nichts zu tun. In der Ansible-Liste
> oben steht `suissetec_metaapp_legacy` - die *Legacy*-metaapp, ein anderes
> Projekt als das Portal. Wo hier "metaapp" steht, ist immer
> `suissetec_metaapp_legacy` gemeint.

> **Status:** Entwurf. Fachlich geprueft, YAML validiert, Shell gegen Stubs und
> die Ziel-Pruefung gegen die echten Playbooks getestet - aber **noch nie gegen
> einen echten Server gelaufen**. Pilot: btc **stag**.

## Inhalt

| Datei | Rolle |
| --- | --- |
| `.github/workflows/deploy.yaml` | Reusable Workflow - Deployment. Der Einstieg. |
| `.github/workflows/rollback.yaml` | Reusable Workflow - Rollback. Eigenes Environment, Tippbestaetigung. |
| `.github/workflows/preflight.yaml` | Reusable Workflow - Preflight. Ohne Serverkontakt, ohne Secrets. |
| `action.yml` | Composite Action - die Mechanik (ansible-core, ssh-agent, Host-Key, Galaxy, Pruefungen, Playbook-Lauf). |
| `src/run-playbook.sh` | Der Lauf selbst. |
| `src/check-playbook-target.sh` | Ziel-Pruefung (siehe unten). |
| `examples/` | Aufrufer-Vorlagen, inklusive `examples/btc/` fuer den Piloten. |

## Warum Reusable Workflow und nicht nur eine Action

Ein Deployment braucht vier Dinge, die es nur auf Job- bzw. Workflow-Ebene gibt:

| Bedarf | Schluessel | In einer Composite Action? |
| --- | --- | --- |
| Freigabe-Gate und gescopte Secrets | `environment` | nein - Actions haben keine Jobs |
| Schutz gegen parallele Deployments | `concurrency` | nein |
| Secrets ueberhaupt entgegennehmen | `secrets` | nein, laut GitHub-Doku koennen Composite Actions keine Secrets nutzen |
| Schritt-fuer-Schritt-Log in Echtzeit | - | nein, eine Action erscheint als **ein** Schritt |

Der letzte Punkt ist mehr als Kosmetik: Wer beim Deployment zuschaut, will sehen,
an welcher Ansistrano-Aufgabe es haengt. Als reine Action verschwindet das in
einem zusammengeklappten Schritt.

Darum die Zweiteilung: Die Workflows tragen Gate, Nebenlaeufigkeit, Rechte und
Secrets; die Action traegt die Mechanik. Die Action direkt einbinden nur, wenn
der Lauf in einen bestehenden Job muss - dann fehlen Gate und
Nebenlaeufigkeitsschutz und der Aufrufer muss sie selbst mitbringen.

Eine Docker Action waere die schlechteste der drei Formen: Build oder Pull bei
jedem Lauf, und ihr einziger Vorteil - eine feste Ansible-Version - ist mit
einer gepinnten `pipx install`-Zeile billiger zu haben.

## Versionierung: Tags, nie @main

**Aufrufer referenzieren einen festen Versions-Tag.** Nicht `@main`.

`artack/composer-license-audit` wird in btc mit `@main` referenziert - fuer einen
Lizenz-Check ist das vertretbar. Fuer einen Baustein, der auf **Produktions-
server** deployt, ist ein wandernder Branch-Ref die falsche Wahl: Ein Push auf
`main` wuerde still das Deployment-Verhalten aller neun Projekte aendern, ohne
Review im betroffenen Projekt und ohne dass jemand den Zusammenhang sieht, wenn
das naechste Deployment schiefgeht.

Deshalb:

- Default-Branch `main`, Freigaben als Tags (`v0.1.0`, `v0.2.0`, …).
- Aufrufer zeigen auf einen Tag: `@v0.1.1`.
- Schnittstellenbruch (`inputs`, Secret-Namen, Verhalten) = neuer Major-Tag.
- Wer das auf `@main` "vereinfacht", nimmt neun Projekten das Review vor einer
  Verhaltensaenderung an ihrem Produktions-Deployment. Bitte nicht.

Der Workflow holt die Action ueber `job.workflow_repository` /
`job.workflow_sha` - damit laufen Workflow und Action nie auseinander, auch nicht
zwischen zwei Tags.

## Sichtbarkeit

Dieses Repo ist **oeffentlich**, Default-Branch `main` - wie
`artack/composer-license-audit` und `artack/ansistrano-php`. Das ist auch
funktional richtig: Ein oeffentliches Repo laesst sich aus privaten Repos ohne
Token referenzieren; ein privates Workflow-Repo braeuchte eine ausdrueckliche
Zugriffsfreigabe. Der Baustein enthaelt keine Geheimnisse - Schluessel und
Host-Keys liegen ausschliesslich in den Environments der aufrufenden Projekte.

## Ein Host, viele Umgebungen

Erhoben am 2026-09-04, und die wichtigste Rahmenbedingung fuer alles Weitere:

**Fast alle suissetec-Umgebungen liegen auf derselben Maschine.**
`suissetec01.nine.ch` (217.150.245.152) traegt stag *und* prod von btc,
ebook_manager, sibe, checklist, contractor-insurance, datasheet,
metaapp_legacy, quality-compendium - und auch `suissetec.ch`,
`shop.suissetec.ch`, `staging-shop.suissetec.ch`, `test.suissetec.ch`. Belegt
durch identische IP und **identischen SSH-Host-Key** aller dieser Namen.

Ein CI-Schluessel ist damit **nicht** durch den Host begrenzt, sondern nur durch
den Unix-Benutzer. Daraus folgen zwei Dinge:

1. **Pro Projekt und Umgebung ein eigenes Schluesselpaar.** Ein Paar pro Projekt
   waere billiger zu verwalten, wuerde aber stag und prod verbinden.
2. **Projekte, in denen sich Umgebungen einen Benutzer teilen, sind nicht
   trennbar** - dort erreicht ein stag-Schluessel zwangslaeufig prod:

   | Projekt | Benutzer | Umgebungen |
   | --- | --- | --- |
   | `suissetec_shop` | `www-data` | stag **und** prod |
   | `suissetec_website` | `www-data` | artack, test **und** prod |

   Fuer diese beiden ist ein eigener Deploy-Benutzer serverseitig
   **Vorbedingung**, nicht Kosmetik. Alle uebrigen acht haben getrennte
   Benutzer (`www-btc-stag` / `www-btc-prod` usw.) und sind ohne Serverumbau
   einfuehrbar.

### Nachgemessen auf dem Host (btc, 2026-09-04)

Rein lesende Pruefung als `www-btc-stag`:

```
uid=1005(www-btc-stag) gid=1005(www-btc-stag) groups=1005(www-btc-stag)
drwxr-x--- 19 www-btc-prod www-data 4096 Jul 15 13:48 /home/www-btc-prod
drwxr-x--- 19 www-btc-stag www-data 4096 Jul  6 15:38 /home/www-btc-stag
sudo: a password is required
```

Die Trennung ist **sauber**: Die Homes sind Modus `750` mit Gruppe `www-data`,
und `www-btc-stag` ist **nur** in seiner eigenen Gruppe - fuer
`/home/www-btc-prod` faellt er also in "other" (`---`) und kommt nicht einmal
hinein. Passwortloses `sudo` gibt es nicht, und ein CI-Schluessel hat kein
Passwort.

**Daraus folgt die Schluesselpolitik:** Die Trennung traegt nur, solange
**jede Umgebung ihr eigenes Schluesselpaar** hat. Ein Paar pro *Projekt* wuerde
denselben oeffentlichen Schluessel in `authorized_keys` von `www-btc-stag`
**und** `www-btc-prod` legen - dann oeffnet der stag-Lauf die Produktion, und
das Environment-Gate schuetzt nichts mehr, weil beide Umgebungen dasselbe
Geheimnis halten. Ein Paar je Umgebung kostet zwei Zeilen und macht Widerruf,
Rotation und Zuordnung in `authorized_keys` pro Umgebung moeglich.

**Achtung bei `www-data`-Projekten:** Beide Homes tragen die Gruppe `www-data`
mit `r-x`. Der Deploy-Benutzer von `suissetec_shop` und `suissetec_website`
heisst `www-data`; ist er in dieser Gruppe, hat er Leserechte auf die Homes der
anderen Projekte - auch auf `/home/www-btc-prod`. Nicht nachgeprueft (kein
Stoebern auf dem Kundenserver), aber vor der Einfuehrung dieser beiden Projekte
zu klaeren.

## Die Ziel-Pruefung

`src/check-playbook-target.sh` laeuft **vor jedem** Playbook-Lauf und im
Preflight. Sie faengt die Falle, die am 2026-09-04 in den Projekten gefunden
wurde: `rollback_*.yaml`, die untailorierte dist-Vorlagen geblieben sind.

Geprueft wird:

1. **Platzhalter:** `ansistrano_deploy_to: /var/www/my-app` -> Abbruch.
2. **Mehr als ein Ziel:** Die Hostliste wird ueber
   `ansible-playbook --list-hosts` **aufgeloest**, nicht per grep gelesen -
   damit expandiert `hosts: all` zur tatsaechlichen Liste. Mehr als ein Host ->
   Abbruch.
3. **Abgleich mit dem Deploy-Playbook derselben Umgebung**
   (`rollback_prod.yaml` gegen `deploy_prod.yaml`): gleiche Hosts, gleiches
   `ansistrano_deploy_to`. Sonst Abbruch.

`--syntax-check` faengt diese Klasse **nicht** - er prueft Form, nicht Ziel.

Nachgemessen an den echten Playbooks:

| Playbook | Ergebnis |
| --- | --- |
| `btc/rollback_prod.yaml` | Abbruch - loest auf `btc-prod btc-stag` auf, Platzhalterpfad |
| `suissetec_website/rollback_prod.yaml` | Abbruch - loest auf `artack prod test` auf, Platzhalterpfad |
| `suissetec_metaapp_legacy/rollback_prod.yaml` | Abbruch - `…/www` gegen `…/public_html` im Deploy |
| `suissetec_checklist/rollback_prod.yaml` | OK |
| `btc/deploy_prod.yaml` | OK |

**Die bestehenden `rollback_*.yaml` bleiben unangetastet** (Sams Entscheid, siehe
`~/development/CLAUDE.md`): nicht auf Vorrat reparieren. Der Fix gehoert pro
Projekt in den Umbau - siehe Checkliste. Bis dahin laeuft dort kein Rollback,
und der Preflight wird mit `check-rollback: false` gefahren, damit ein bekannter,
in diesem Lauf nicht behebbarer Befund nicht bei jedem Push rot leuchtet.

## Konfiguration

### Aufruf

```yaml
jobs:
  deploy:
    uses: artack/artack_ansible-action/.github/workflows/deploy.yaml@v0.1.1
    with:
      environment: prod
      playbook: deploy_prod.yaml
      git-ref: ${{ inputs.git-ref }}
    secrets:
      ssh-private-key: ${{ secrets.DEPLOY_SSH_PRIVATE_KEY }}
      ssh-known-hosts: ${{ secrets.DEPLOY_SSH_KNOWN_HOSTS }}
```

Vollstaendige Vorlagen in [`examples/`](examples/), fuer den Piloten
[`examples/btc/`](examples/btc/).

### Eingaben `deploy.yaml`

| Eingabe | Pflicht | Default | Bedeutung |
| --- | --- | --- | --- |
| `environment` | ja | - | GitHub Environment. Traegt Freigabe-Regeln, Branch-Policy und die beiden Secrets. |
| `playbook` | ja | - | z.B. `deploy_prod.yaml`. Bewusst der Dateiname und kein aus der Umgebung abgeleiteter Wert - die Inventarnamen der Projekte sind nicht einheitlich (`prod` vs. `btc-prod`). |
| `git-ref` | ja | - | Branch, Tag oder SHA. Ein Tag ist vorzuziehen: er bewegt sich nicht zwischen Freigabe und Ausfuehrung. |
| `working-directory` | nein | `.` | Verzeichnis mit `ansible.cfg`. |
| `galaxy-requirements` | nein | `deployment/requirements.yml` | Leer setzen bei Projekten ohne Submodul (heute: `suissetec_shop`). |
| `ansible-version` | nein | `ansible-core~=2.16.14` | Spiegelt die lokal verwendete Fassung. Leer = vorinstalliertes ansible-core nehmen. |
| `runs-on` | nein | `ubuntu-latest` | |
| `timeout-minutes` | nein | `20` | |
| `extra-vars` | nein | `""` | Weitere Ansible-Variablen als `key=value`. |

`rollback.yaml` nimmt zusaetzlich `confirm` (muss `ROLLBACK` sein) und kein
`git-ref`. `preflight.yaml` nimmt `check-rollback`.

### Secrets

| Secret | Inhalt |
| --- | --- |
| `ssh-private-key` | Privater Deploy-Schluessel, CI -> Zielserver. |
| `ssh-known-hosts` | Ausgabe von `ssh-keyscan` fuer den Zielserver. Pflicht. |

Beide gehoeren als **Environment-Secrets** an die jeweilige Umgebung, nicht als
Repository-Secrets - sonst kann ein Lauf auf `stag` den prod-Schluessel lesen.
Auf einem geteilten Host (siehe oben) ist das der entscheidende Punkt.

### Ein Schluessel pro Umgebung

Die Secret-**Namen** sind in jeder Umgebung dieselben
(`DEPLOY_SSH_PRIVATE_KEY`, `DEPLOY_SSH_KNOWN_HOSTS`) - nur die **Werte**
unterscheiden sich. Genau daraus ergibt sich die Regel:

- **Je Umgebung ein eigener, neu erzeugter Schluessel.** Kein Kopieren des
  stag-Schluessels ins prod-Environment.
- Wird derselbe Schluessel in beiden Environments hinterlegt, ist das
  Environment-Scoping **wirkungslos**: Beide Umgebungen halten dann dasselbe
  Geheimnis, ein stag-Lauf traegt den Schluessel, der auch die Produktion
  oeffnet - und das Freigabe-Gate vor prod schuetzt nichts mehr am Zugang selbst.
- Weil die Namen gleich bleiben, muss die Aufrufer-Datei dafuer nicht angepasst
  werden: Sie referenziert immer `secrets.DEPLOY_SSH_PRIVATE_KEY`, und welches
  Geheimnis das ist, entscheidet das Environment des Laufs.

**Bei einer Einfuehrung wird nur die Umgebung eingerichtet, die als naechste
laeuft.** Fuer den btc-Piloten heisst das: **ein** Paar, fuer stag. prod folgt
nach dem erfolgreichen stag-Lauf mit einem eigenen Paar.

## SSH in der CI

**Wichtig zum Verstaendnis:** Die Playbooks laufen mit
`ansistrano_deploy_via: git` und `ansistrano_git_repo: ssh://git@github.com/…`,
und das `git`-Modul laeuft in der Ansistrano-Rolle ohne `delegate_to` - also
**auf dem Zielserver**. Der Server klont selbst von GitHub und kann das heute
schon. Der Runner transportiert keinen Projektquellcode; er dirigiert nur.
Praktische Folge: Der zu deployende Ref muss **gepusht** sein.

### Schluessel

Heute authentisiert sich der Deploy mit Sams persoenlichen Schluesseln aus dem
1Password-Agenten (`~/.ssh/config`, `Host *` -> `IdentityAgent` auf den
1Password-Socket). In der CI hat das nichts zu suchen. Pro Projekt und Umgebung
ein eigenes ed25519-Paar ohne Passphrase - ein Automat kann keine eingeben; der
Schutz kommt aus dem Environment-Scoping, nicht aus der Passphrase:

```bash
ssh-keygen -t ed25519 -C "github-actions btc stag" -f btc-stag -N ""
```

- **privater Teil** -> Environment-Secret `DEPLOY_SSH_PRIVATE_KEY` der Umgebung.
  Danach lokal loeschen.
- **oeffentlicher Teil** -> serverseitig in `~/.ssh/authorized_keys` des
  Deploy-Benutzers (z.B. `www-btc-stag`).

**Serverseitig noetig ist nur dieser eine Eintrag.** Insbesondere braucht der
Server **keinen** neuen GitHub-Zugang. Empfohlen zusaetzlich: den Eintrag in
`authorized_keys` mit `restrict` und einer `from=`-Einschraenkung versehen,
soweit die Runner-Adressen bekannt sind - bei GitHub-hosted Runnern ist das
praktisch nicht eingrenzbar, was fuer die Verwendung eigener Runner spricht,
falls das Thema aufkommt.

### Host-Key

Kein `StrictHostKeyChecking=no`. Der Host-Key wird einmal ausserhalb der CI
geholt, gesichtet und als Secret hinterlegt:

```bash
ssh-keyscan -t ed25519 suissetec01.nine.ch
```

Der Baustein schreibt ihn in eine private `known_hosts` und setzt
`ANSIBLE_HOST_KEY_CHECKING=True` sowie
`ANSIBLE_SSH_COMMON_ARGS="-o UserKnownHostsFile=… -o StrictHostKeyChecking=yes"`.
Ein leeres Secret ist ein harter Abbruch mit Klartextmeldung - nicht ein stiller
Rueckfall auf Vertrauen. Der Eintrag muss auf den Namen lauten, den `hosts.yaml`
als `ansible_host` fuehrt.

Ehrlich dazu: Das deckt die Strecke **Runner -> Zielserver**. Die Strecke
**Zielserver -> GitHub** benutzt `accept_hostkey: true` aus der Ansistrano-Rolle,
also Trust-on-first-use. Das ist heute schon so und wird durch den CI-Weg weder
besser noch schlechter.

### Vault

Keines der Projekte benutzt Ansible Vault (geprueft: keine `vault`-,
`ansible_ssh_pass`- oder `become_pass`-Vorkommen in den Deployment-Dateien). Es
braucht also **kein** Vault-Passwort in der CI. Kommt spaeter eines dazu:
Environment-Secret -> `ANSIBLE_VAULT_PASSWORD_FILE` auf eine Datei in einem
privaten temporaeren Verzeichnis.

## Schutz gegen Fehlbedienung

- `environment` -> **Required reviewers**, dann wartet jedes prod-Deployment auf
  eine menschliche Freigabe.
- `environment` -> **Deployment branch policy**. Das ist die wichtigste
  Absicherung: Der Workflow checkt den zu deployenden Ref aus und benutzt
  **dessen** Playbook. Ohne Branch-Policy koennte ein beliebiger Branch ein
  veraendertes `deploy_prod.yaml` gegen die Produktion laufen lassen.
- `concurrency` **pro Umgebung**:
  `artack-deploy-${{ github.repository }}-${{ inputs.environment }}` mit
  `cancel-in-progress: false`. Zwei Deployments auf dieselbe Umgebung ueberholen
  sich nicht, verschiedene Umgebungen blockieren sich nicht, und ein laufendes
  Deployment wird nicht mitten im Symlink-Wechsel abgeschossen. Rollback teilt
  die Gruppe mit dem Deploy derselben Umgebung.
- `permissions: contents: read` und `persist-credentials: false`.
- Fremde Actions auf einen SHA pinnen, sobald das hier ueber den Entwurf
  hinausgeht.
- Kein `pull_request_target`, kein automatischer Trigger auf Fremd-PRs.

## Einrichtungs-Checkliste pro Projekt

Diese Liste wird bei **jedem** der Projekte abgearbeitet. Punkt 3 ist der Grund,
warum sie existiert.

1. **Preflight zuerst.** `examples/preflight.yaml` einlegen und gruen bekommen.
   Deckt Submodul-Pin, Playbook-Syntax und Ziel-Abweichungen auf, ohne einen
   Server anzufassen. Bei Projekten mit bekannt untailorierten Rollbacks
   zunaechst mit `check-rollback: false`.
2. **Benutzertrennung pruefen.** `ansible_user` je Umgebung aus `hosts.yaml`
   vergleichen. Teilen sich zwei Umgebungen einen Benutzer (`suissetec_shop`,
   `suissetec_website`), ist ein eigener Deploy-Benutzer serverseitig
   **Vorbedingung** - sonst erreicht der stag-Schluessel die Produktion.
3. **Rollback-Playbook pruefen und den Befund Sam vorlegen.**
   `check-playbook-target.sh rollback_<env>.yaml` lokal laufen lassen.
   Bekannte Befunde: `btc` und `suissetec_website` (`hosts: all` +
   Platzhalterpfad), `suissetec_metaapp_legacy` (Pfad-Abweichung),
   `suissetec_shop` (kein Rollback-Playbook). **Ein Rollback-Playbook wird nie
   von einem Agenten ausgefuehrt und nie auf Vorrat repariert** - der Fix
   gehoert in diesen Umbau und laeuft nur nach Sams Review.
4. **Schluessel fuer die Umgebung erzeugen, die als naechste laeuft** - nicht
   auf Vorrat fuer alle. Oeffentlichen Teil in `authorized_keys` des
   Deploy-Benutzers legen, Zugang von Hand testen. Jede weitere Umgebung
   bekommt spaeter ihr **eigenes** Paar bei gleichen Secret-Namen (siehe
   "Ein Schluessel pro Umgebung").
5. **`ssh-keyscan`** fuer den Namen, der in `hosts.yaml` als `ansible_host`
   steht; Ausgabe sichten.
6. **GitHub Environments** anlegen, je die zwei Secrets; fuer `prod` Required
   reviewers und Deployment branch policy.
7. **Aufrufer einlegen** - als **eigene** Workflow-Datei
   (`.github/workflows/deploy.yaml`), nicht in `linter.yaml` hineingemischt:
   Pruefung und Deployment sind getrennte Anlaesse mit getrennten Rechten.
   Versions-Tag setzen, nicht `@main`.
8. **Erst auf stag deployen**, Log lesen, dann prod freigeben.
9. **Rollback-Aufrufer** erst einlegen, wenn Punkt 3 erledigt und reviewt ist.

### Projektspezifische Abweichungen

| Projekt | Was zusaetzlich noetig ist |
| --- | --- |
| `suissetec_shop` | Kein `deployment/`-Submodul - `deployment/` sind vier eingecheckte Hook-Dateien, keine `requirements.yml`. Entweder `galaxy-requirements: ""` und die Rollen anders bereitstellen, oder vorher auf die Hauskonvention heben. Ausserdem: stag und prod **derselbe Benutzer** `www-data` (Punkt 2 ist Vorbedingung), PHP 8.0, kein Rollback-Playbook. |
| `suissetec_website` | Drei Umgebungen (`prod`, `test`, `artack`), alle mit Benutzer `www-data` (Punkt 2 ist Vorbedingung). PHP 7.4. Rollback untailoriert. |
| `suissetec_contractor-insurance` | `deploy_stag.yaml` hat `default: "{{ git_current_branch }}"` - nirgends definiert. Nachgemessen: Der Default wird **auch mit** `-e git_branch=…` ausgewertet, das Playbook bricht mit `'git_current_branch' is undefined` ab. Einzeiler, aber ohne ihn laeuft das Projekt in der CI nicht. |
| `btc` | Rollback untailoriert. `git_default_branch` ist `master` (prod) bzw. `develop` (stag) - beim Dispatch beachten. |
| `suissetec_checklist` | Submodul-URL `https://github.com/ARTACK/ansistrano-php` (Grossschreibung, ohne `.git`). Funktioniert, faellt nur beim Vergleich auf. |
| `suissetec_metaapp_legacy` | Rollback-Pfad-Abweichung. **Nicht** die Portal-App - die deployt nach Azure und ist hier nicht Thema. |

## Was der CI-Weg besser macht - und was schlechter

**Besser:** Nachvollziehbarkeit (wer, welcher Ref, wann) · Freigabe-Gate mit
Namen und Zeitstempel · keine Produktionsschluessel auf Entwicklermaschinen ·
kein Deployment aus verschmutztem Arbeitsverzeichnis, es wird immer ein
**gepushter** Ref deployt · Nebenlaeufigkeitsschutz, den es heute gar nicht gibt
· die Ziel-Pruefung, die es heute gar nicht gibt · der Lauf erzwingt einen
erreichbaren Submodul-Pin.

**Schlechter:**

- Ein kompromittierter Workflow deployt auf Produktion. Gegenmittel:
  Environment-Freigabe, Deployment branch policy, SHA-Pinning, `contents: read`,
  Versions-Tags statt `@main`.
- Der Deploy-Schluessel ist eine dauerhafte Anmeldeinformation im
  GitHub-Secret-Store statt einer, die an einer 1Password-Sitzung haengt.
- **Ein kaputter Submodul-Pin blockiert dann jedes Deployment, auch ein
  dringendes.** Abfederung in dieser Reihenfolge: (1) der Preflight deckt es bei
  jedem Push auf, also lange vor dem dringenden Fall - der echte Schutz ist
  frueheres Aufdecken, nicht ein Notausgang; (2) der Fehler ist laut und in
  Minuten behoben; (3) **der Weg von Hand bleibt vollstaendig funktionsfaehig** -
  der Baustein legt nur Workflow-Dateien dazu und nimmt nichts weg.
- Zuschauen geht teilweise verloren (der Workflow loggt live, aber niemand sitzt
  mehr zwangslaeufig davor). Zusaetzliche Abhaengigkeit von GitHub Actions.

## Offene Punkte

- **Nie gegen einen echten Server gelaufen.** Der Pilot (btc stag) muss belegen:
  der ssh-agent-Weg traegt; `ANSIBLE_SSH_COMMON_ARGS` kollidiert nicht mit
  projekteigenen `ansible_ssh_common_args`; und
  `environment: name: ${{ inputs.environment }}` in einem Reusable Workflow loest
  die Environments des **aufrufenden** Repositories auf.
- `pipx install ansible-core` auf `ubuntu-latest` ist nicht verifiziert; falls
  pipx fehlt, `pip install --user` oder `setup-python`.

## Tests

```bash
bats tests
```

Die Tests ersetzen `ssh-agent`, `ssh-add`, `ansible-playbook` und
`ansible-galaxy` durch Stubs und pruefen die Schutzmechanismen: fehlendes
Playbook, leerer Schluessel, leere `known_hosts`, Ziel- und Syntaxpruefung vor
dem Lauf, `-e git_branch` beim Deploy und dessen Abwesenheit beim Rollback.
