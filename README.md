# artack_ansible-action

Reusable Workflows und eine Composite Action, die die Ansistrano-Deployments
unserer Symfony-Projekte in GitHub Actions ausfuehren: Deployment, Rollback und
ein Preflight ohne Serverkontakt. Erwartet die Hauskonvention aus
`artack-dev:deployment-setup` - `ansible.cfg`, `hosts.yaml` und
`deploy_<env>.yaml` im Projektwurzelverzeichnis, Submodul
[artack/ansistrano-php](https://github.com/artack/ansistrano-php) unter
`deployment/`. Der Lauf installiert `ansible-core`, holt die Galaxy-Rollen aus
`deployment/requirements.yml`, haelt den Deploy-Schluessel in einem ssh-agent und
prueft den Host-Key gegen ein hinterlegtes `known_hosts`; den Git-Klon macht der
Zielserver, deployt wird also ein gepushter Ref. Ist `assets-build-command` gesetzt, baut der Lauf zuerst die Frontend-Assets und
liefert sie mit demselben Schluessel per `scp` aus - vor dem Symlink-Wechsel.
Danach laeuft das Playbook als **Ziel-Pruefung** (genau eine Umgebung, gleiches
`ansistrano_deploy_to` wie das Deploy-Playbook derselben Umgebung) ->
**`--syntax-check`** -> **`ansible-playbook`**.

## Aufrufer

Manuell - `.github/workflows/deploy.yaml`:

```yaml
name: deploy
on:
  workflow_dispatch:
    inputs:
      environment: {required: true, type: choice, options: [stag, prod]}
      git-ref: {required: true, type: string}

jobs:
  deploy:
    uses: artack/artack_ansible-action/.github/workflows/deploy.yaml@v0.3.1
    with:
      environment: ${{ inputs.environment }}
      playbook: deploy_${{ inputs.environment }}.yaml
      git-ref: ${{ inputs.git-ref }}
    secrets: inherit
```

`secrets: inherit` ist **Pflicht**. Ein Reusable Workflow bekommt nur, was der
Aufrufer ihm uebergibt; `inherit` fuellt den Kontext, das `environment` im
Baustein zieht dann die Environment-Secrets in den Scope. Ohne die Zeile sind
sie leer und der Lauf bricht ab.

Automatisch bei gruenen Checks: Job in den Pruef-Workflow legen, per `needs` an
**alle** Pruef-Jobs haengen.

```yaml
  deploy-stag:
    needs: [checker, linter]
    if: github.event_name == 'push' && github.ref == 'refs/heads/develop'
    uses: artack/artack_ansible-action/.github/workflows/deploy.yaml@v0.3.1
    with:
      environment: stag
      playbook: deploy_stag.yaml
      git-ref: ${{ github.sha }}
      # nur bei Projekten mit Frontend-Build:
      assets-build-command: yarn build:prod
      assets-target: www-btc-stag@suissetec01.nine.ch:~/public_html/shared/public/build
    secrets: inherit
```

## Inputs (`deploy.yaml`)

| Name | Pflicht | Default | Bedeutung |
| --- | --- | --- | --- |
| `environment` | ja | - | GitHub Environment; traegt Secrets und Freigabe-Regeln |
| `playbook` | ja | - | z.B. `deploy_prod.yaml` |
| `git-ref` | ja | - | Branch, Tag oder SHA; wird als `-e git_branch=` gesetzt |
| `working-directory` | nein | `.` | Verzeichnis mit `ansible.cfg` |
| `galaxy-requirements` | nein | `deployment/requirements.yml` | leer = Galaxy-Schritt ueberspringen |
| `ansible-version` | nein | `ansible~=9.13.0` | volle Distribution, nicht `ansible-core` - die Hooks brauchen `community.general` |
| `extra-vars` | nein | `""` | weitere Ansible-Variablen als `key=value` |
| `check-target` | nein | `true` | Ziel-Pruefung |
| `assets-build-command` | nein | `""` | z.B. `yarn build:prod`; leer = kein Asset-Build |
| `assets-source` | nein | `public/build` | Verzeichnis mit den gebauten Assets |
| `assets-target` | nein | `""` | `user@host:/pfad`; Pflicht, wenn `assets-build-command` gesetzt ist |
| `node-version` | nein | `20` | fuer den Asset-Build |
| `clone-with-github-token` | nein | `false` | Zielserver klont per HTTPS mit dem Lauf-Token statt per `ssh://` |
| `runs-on` / `timeout-minutes` | nein | `ubuntu-latest` / `20` | |

`rollback.yaml`: wie oben, aber ohne `git-ref`, mit `confirm` (muss `ROLLBACK`
sein) und `reference-playbook`; `check-target` nicht abschaltbar.
`preflight.yaml`: `working-directory`, `galaxy-requirements`, `ansible-version`,
`runs-on`, `check-rollback`.

## Secrets

| Name | Inhalt | Wo |
| --- | --- | --- |
| `DEPLOY_SSH_PRIVATE_KEY` | privater Deploy-Schluessel, CI -> Zielserver | **Environment**, nicht Repo |
| `DEPLOY_SSH_KNOWN_HOSTS` | `ssh-keyscan`-Ausgabe, ohne `#`-Zeilen | **Environment**, nicht Repo |

Je Umgebung ein eigener Schluessel: Namen gleich, Werte verschieden. Derselbe
Schluessel in zwei Environments hebt das Scoping auf. Der Aufrufer braucht
`secrets: inherit`, sonst erreichen sie den Baustein nicht.

## Wie der Zielserver an das Repository kommt

`ansistrano_deploy_via: git` heisst: **der Zielserver** klont, nicht der Runner.
Bei einem manuellen Deploy authentisiert er sich mit dem weitergeleiteten
SSH-Agenten des Menschen - in der CI gibt es den nicht.

`clone-with-github-token: true` loest das mit dem `GITHUB_TOKEN` des Laufs, laut
GitHub-Doku *"scoped to the invoking repository and expires after job
completion"* und dort als bevorzugte Methode vor Deploy Keys und PATs genannt.
Der Baustein setzt fuer den Lauf per `-e`

```
ansistrano_git_repo=https://x-access-token:<token>@github.com/<owner>/<repo>.git
```

und setzt die Remote-URL danach auf den Wert aus dem Playbook zurueck, damit im
`.git/config` des Servers kein Token liegenbleibt. **Das Playbook bleibt auf
`ssh://`** - manuelle Deployments ueber die Agent-Weiterleitung sind unberuehrt.

Voraussetzung ist `contents: read`. Der aufrufende Job kann die Rechte nur
einschraenken, nicht erweitern; der Baustein setzt selbst
`permissions: contents: read`.

## Einrichtung pro Umgebung

```bash
REPO=artack/<projekt>
ENV=stag
HOST=<ansible_host aus hosts.yaml>
USER=<ansible_user aus hosts.yaml>

# 1. Schluessel erzeugen (ohne Passphrase - ein Automat kann keine eingeben)
ssh-keygen -t ed25519 -C "github-actions ${REPO##*/} $ENV" -f ./ci_$ENV -N ""

# 2. Oeffentlichen Teil auf den Server, in authorized_keys des Deploy-Nutzers
ssh-copy-id -i ./ci_$ENV.pub $USER@$HOST
ssh -i ./ci_$ENV $USER@$HOST true   # muss ohne Rueckfrage durchlaufen

# 3. Host-Key holen und sichten
ssh-keyscan "$HOST" | grep -v '^#' > known_hosts.txt

# 4. Environment und Secrets
gh api -X PUT repos/$REPO/environments/$ENV
gh secret set DEPLOY_SSH_PRIVATE_KEY --env $ENV --repo $REPO < ./ci_$ENV
gh secret set DEPLOY_SSH_KNOWN_HOSTS --env $ENV --repo $REPO < known_hosts.txt

# 5. Lokal loeschen und nachpruefen
rm -f ./ci_$ENV ./ci_$ENV.pub
gh secret list --env $ENV --repo $REPO
```

Fuer prod zusaetzlich Required reviewers und eine Deployment branch policy - der
Baustein benutzt das Playbook **des deployten Refs**. Vor dem ersten Deployment
`preflight.yaml` einlegen und gruen bekommen (Submodul-Pin, Syntax, Ziele, ohne
Serverkontakt); bei untailorierten `rollback_*.yaml` mit
`check-rollback: false` starten.

Reihenfolge bei der Einrichtung, jeweils eine Variable pro Lauf:

1. Baustein per **Commit-SHA** referenzieren, nicht per Tag.
2. **Ohne** `assets-build-command` deployen - beweist Secrets, SSH-Zugang und
   Ansistrano.
3. Danach den Asset-Build einschalten.
4. Beides gruen: auf einen Tag umstellen.

## Rollback

Eigener Workflow, nur `workflow_dispatch`, eigenes Environment (z.B.
`prod-rollback`) mit eigenen Freigebern, `confirm: ROLLBACK` erforderlich; teilt
die `concurrency`-Gruppe mit dem Deploy derselben Umgebung. Die **Ziel-Pruefung
ist hier nicht abschaltbar**: Sie loest die Hostliste per
`ansible-playbook --list-hosts` auf und bricht ab, wenn das Playbook mehr als
eine Umgebung trifft oder ein anderes `ansistrano_deploy_to` hat als das
Deploy-Playbook - `--syntax-check` faengt das nicht.

## Versionierung

**Im Betrieb** pinnen Aufrufer einen Tag, nie einen Branch - ein Push auf `main`
wuerde sonst still das Deployment-Verhalten aller Aufrufer aendern.
Schnittstellenbruch = neuer Major-Tag.

**Waehrend der Einrichtung** pinnen sie einen **Commit-SHA**:

```yaml
uses: artack/artack_ansible-action/.github/workflows/deploy.yaml@8c143ebd1bc5431af71c646601699b9ae0ee6099
```

Ein SHA ist genauso unveraenderlich wie ein Tag, verbraucht aber keine
Versionsnummer, solange noch iteriert wird. Umstellen auf den Tag, sobald das
Projekt gruen deployt.


## Tests

`bats tests` - stubbt `ssh-agent`, `ssh-add`, `ansible-playbook` und
`ansible-galaxy`, braucht kein Netz und keinen Server.
