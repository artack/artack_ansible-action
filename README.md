# artack_ansible-action

Fuehrt ein **bestehendes** Ansible-Playbook eines artack-Projekts in GitHub
Actions aus. Der Aufrufer gibt den Pfad zum Playbook an, sonst nichts; alles
Projektspezifische steht im Playbook und wird nicht angefasst. Der Baustein
installiert ansible, laedt den Deploy-Schluessel in einen eigenen ssh-agent,
prueft den Host-Key gegen ein hinterlegtes `known_hosts` und ruft
`ansible-playbook` auf. Das Verzeichnis des Playbooks ist das
Arbeitsverzeichnis - dort liegen `ansible.cfg` und `hosts.yaml`. Das Projekt
bindet die Action als Step in einen eigenen Job ein; einen Reusable Workflow
stellt dieses Repo bewusst nicht bereit.

## Einbinden

Ein Job im Projekt, der die Action als Step aufruft. Das ist der Weg - dieses
Repo stellt keinen Reusable Workflow bereit, damit das Projekt eigene Steps
(z.B. einen Frontend-Build) in denselben Job legen kann.

```yaml
# .github/workflows/deploy.yaml
name: deploy

on:
  workflow_dispatch:
    inputs:
      environment: {required: true, type: choice, options: [stag, prod]}
      git-ref: {required: true, type: string}

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    # Traegt die Secrets und das Freigabe-Gate.
    environment: ${{ inputs.environment }}
    # Zwei Deployments auf dieselbe Umgebung duerfen sich nicht ueberholen.
    # cancel-in-progress MUSS false bleiben: Ein Abbruch mitten im
    # Symlink-Wechsel hinterlaesst ein halbes Deployment - neuer Code live,
    # after_symlink-Hooks (opcache, Messenger) nicht gelaufen.
    concurrency:
      group: deploy-${{ github.repository }}-${{ inputs.environment }}
      cancel-in-progress: false
    steps:
      # submodules: recursive ist Pflicht. Ohne das ist deployment/ leer und die
      # Hooks fehlen, auf die die Playbooks per playbook_dir verweisen - die
      # haeufigste Fehlerquelle beim Einrichten.
      - uses: actions/checkout@v6
        with:
          ref: ${{ inputs.git-ref }}
          submodules: recursive
          persist-credentials: false

      - uses: artack/artack_ansible-action@v1.0.0
        with:
          playbook: deploy_${{ inputs.environment }}.yaml
          git-ref: ${{ inputs.git-ref }}
          ssh-private-key: ${{ secrets.DEPLOY_SSH_PRIVATE_KEY }}
          ssh-known-hosts: ${{ secrets.DEPLOY_SSH_KNOWN_HOSTS }}
```

**Achtung bei `concurrency` auf Workflow-Ebene.** Steht dort
`cancel-in-progress: true`, wird der **ganze Lauf** abgebrochen, wenn ein neuer
Push dieselbe Gruppe trifft - der Deploy-Job stirbt mit, mitten im
`ansible-playbook`. Die Job-Einstellung oben schuetzt davor **nicht**. Wer
Deployment und Pruefung in einem Workflow hat, schliesst den Deploy-Branch aus:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/develop' }}
```

**Automatisch, sobald alle Checks gruen sind:** denselben Job in den bestehenden
Pruef-Workflow legen, mit `needs: [<alle Pruef-Jobs>]` und
`if: github.event_name == 'push' && github.ref == 'refs/heads/develop'`, und
`git-ref: ${{ github.sha }}` - der exakte Commit, weil ein Branch zwischen
Trigger und Ausfuehrung weiterwandern kann. Wird ein Pruef-Job ergaenzt, muss er
in `needs` nachgetragen werden, sonst deployt der Job daran vorbei.

## Inputs

| Name | Pflicht | Default | Bedeutung |
| --- | --- | --- | --- |
| `playbook` | ja | - | Pfad im Repository, z.B. `deploy_stag.yaml` |
| `git-ref` | nein | `""` | Branch, Tag oder SHA; wird als `-e git_branch=` gesetzt |
| `ssh-private-key` | ja | - | privater Deploy-Schluessel, aus einem Secret |
| `ssh-known-hosts` | ja | - | `ssh-keyscan`-Ausgabe des Zielservers |
| `ansible-version` | nein | `ansible~=9.13.0` | volle Distribution, nicht `ansible-core` - die Playbooks brauchen `community.general` |
| `galaxy-requirements-inline` | nein | eingebaute Pins | Requirements-YAML als Text, Override |
| `galaxy-requirements` | nein | `""` | Pfad zu einer Requirements-Datei; nur setzen, wenn sie Versionen pinnt |
| `extra-vars` | nein | `""` | weitere Ansible-Variablen als `key=value` |
| `clone-with-github-token` | nein | `true` | Zielserver klont mit dem Lauf-Token; `false` fuer Repos ausserhalb github.com |
| `github-token` | nein | `""` | leer lassen - die Action nimmt `github.token` |

`runs-on`, `timeout-minutes`, `environment` und `concurrency` setzt der Job des
Projekts selbst - siehe Block oben.

## Secrets

| Name | Inhalt | Wo |
| --- | --- | --- |
| `DEPLOY_SSH_PRIVATE_KEY` | privater Deploy-Schluessel | **Environment**, nicht Repo |
| `DEPLOY_SSH_KNOWN_HOSTS` | `ssh-keyscan`-Ausgabe, ohne `#`-Zeilen | **Environment**, nicht Repo |

Je Umgebung ein eigener Schluessel: Namen gleich, Werte verschieden. Derselbe
Schluessel in zwei Environments hebt das Scoping auf.

## Einrichtung pro Umgebung


```bash
REPO=artack/<projekt>
ENV=stag
HOST=<ansible_host aus hosts.yaml>
USER=<ansible_user aus hosts.yaml>

# 1. Schluessel erzeugen (ohne Passphrase - ein Automat kann keine eingeben)
ssh-keygen -t ed25519 -C "github-actions ${REPO##*/} $ENV" -f ./ci_$ENV -N ""

# 2. Oeffentlicher Teil in authorized_keys des Deploy-Nutzers
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
Baustein benutzt das Playbook **des deployten Refs**.

Waehrend der Einrichtung den Baustein per **Commit-SHA** referenzieren, nicht
per Tag; auf einen Tag umstellen, sobald das Projekt gruen deployt.

Setzt ein Projekt in `hosts.yaml` eigene `ansible_ssh_common_args`, gewinnt das
Inventar - dann muss `ForwardAgent=yes` dort mit hinein.

## Wie der Zielserver an das Repository kommt

`ansistrano_deploy_via: git` heisst: **der Zielserver** klont, nicht der Runner.
Er hat dort keine eigene Zugangsberechtigung - von Hand klappt es nur, weil der
SSH-Agent des Menschen weitergeleitet wird.

Der Baustein nimmt dafuer das `GITHUB_TOKEN` des Laufs, laut GitHub-Doku
*"scoped to the invoking repository and expires after job completion"*. Er setzt
fuer den Lauf per `-e`

```
ansistrano_git_repo=https://x-access-token:<token>@github.com/<owner>/<repo>.git
```

und setzt die Remote-URL danach auf den Wert aus dem Playbook zurueck - per
`community.general.git_config`, auch wenn das Playbook gescheitert ist, mit
Gegenprobe am zurueckgelesenen Wert. Das Playbook bleibt auf `ssh://`, manuelle
Deployments sind unberuehrt. `permissions: contents: read` genuegt, und der
Aufrufer muss den Token nicht durchreichen.

**Ehrlich dazu:** Waehrend des Laufs steht der Token in
`<deploy_to>/repo/.git/config` auf dem Zielserver - ein Verzeichnis, das das
Release ueberlebt. Er verfaellt mit dem Job und wird danach ueberschrieben, aber
er steht kurzzeitig dort. Das ist der bewusst eingegangene Handel gegenueber
einem dauerhaften Deploy Key: kurzlebiges Geheimnis mit Fussabdruck statt
dauerhaftes ohne.

Liegt ein Repo nicht auf github.com, `clone-with-github-token: false` setzen -
dann braucht der Server eine eigene Zugangsberechtigung.

## Galaxy-Rollen: eingebaute Pins

Der Baustein installiert feste Versionen von `ansistrano.deploy`,
`ansistrano.rollback` und `cbrunnkvist.ansistrano-symfony-deploy`. Der Aufrufer
setzt dafuer nichts.

Grund: `deployment/requirements.yml` der Projekte pinnt keine Versionen, und
`ansible-galaxy install` aktualisiert eine vorhandene Rolle nicht. Auf einer
Entwicklermaschine liegt darum, was dort vor Jahren installiert wurde, ein
frischer Runner holt die neuesten. `ansistrano.deploy` 4.4.0 setzt
`ansistrano_release_path` als String, bis 4.3.0 war es ein registriertes
Ergebnis mit `.stdout` - und `.stdout` war die dokumentierte Schnittstelle, auf
die alle artack-Playbooks und -Hooks zugreifen. Mit 4.4.0 bricht jedes davon.

**Das ist eine Frist, kein Zustand.** `cbrunnkvist.ansistrano-symfony-deploy`
hat seit September 2024 keinen Commit. Der Ausweg ist, die `.stdout`-Zugriffe in
`artack/ansistrano-php` und in den Projekt-Playbooks auf
`ansistrano_release_path.stdout | default(ansistrano_release_path)`
umzustellen - das laeuft in beiden Generationen. Bis dahin gilt das Pinning.

## Rollback: bewusst kein Baustein

Es gibt hier **kein** Rollback-Werkzeug, und das ist Absicht. Mehrere Projekte
tragen in `rollback_*.yaml` noch die unveraenderte dist-Vorlage: `hosts: all`
loest auf **alle** Umgebungen des Inventars auf, und
`ansistrano_deploy_to: /var/www/my-app` zeigt an einen Pfad, den es dort nicht
gibt. `--syntax-check` faengt das nicht - er prueft Form, nicht Ziel.

Ein Baustein, der ausfuehrt was dasteht, wuerde daraus einen Knopf in der CI
machen. Regel im Haus: Ein Rollback-Playbook wird nie von einem Agenten
ausgefuehrt; es wird vorher gegen das Deploy-Playbook derselben Umgebung
geprueft (`hosts`, `ansistrano_deploy_to`) und der Befund Sam vorgelegt.

Ein Rollback laeuft von Hand:

```bash
ansible-playbook rollback_stag.yaml
```

## Submodul-Pin pruefen

Ein `deployment/`-Pin auf einen Commit, den das Remote nicht kennt, faellt lokal
nicht auf - das Arbeitsverzeichnis stimmt ja. Ein Checkout mit rekursiven
Submodulen scheitert daran, und zwar erst beim Deployment. Als eigener Job in
die CI des Projekts, kostet Sekunden und beruehrt keinen Server:

```yaml
  submodules:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          submodules: recursive
          persist-credentials: false
```

## Versionierung

Aktuell: **`v1.0.0`**.

Aufrufer pinnen eine unveraenderliche Version, nie einen Branch und **kein
mitwanderndes `v1`** - beides wuerde das Verhalten aller Aufrufer aendern, ohne
dass jemand im betroffenen Projekt etwas sieht. Schnittstellenbruch = neuer
Major-Tag.

## Tests

`bats tests` - stubbt `ssh-agent`, `ssh-add`, `ansible-playbook` und
`ansible-galaxy`, braucht kein Netz und keinen Server.
