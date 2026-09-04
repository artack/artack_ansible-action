# artack_ansible-action

Fuehrt ein **bestehendes** Ansible-Playbook eines artack-Projekts in GitHub
Actions aus. Der Aufrufer gibt den Pfad zum Playbook an, sonst nichts; alles
Projektspezifische steht im Playbook und wird nicht angefasst. Der Baustein
installiert ansible, laedt den Deploy-Schluessel in einen eigenen ssh-agent,
prueft den Host-Key gegen ein hinterlegtes `known_hosts` und ruft
`ansible-playbook` auf. Das Verzeichnis des Playbooks ist das
Arbeitsverzeichnis - dort liegen `ansible.cfg` und `hosts.yaml`. Ein Reusable
Workflow fuer den Deploy liegt bei; er fuegt keine Faehigkeit hinzu, sondern
haelt die `concurrency`-Entscheidung an einer Stelle richtig.

## Aufrufer

```yaml
# .github/workflows/deploy.yaml
name: deploy
on:
  workflow_dispatch:
    inputs:
      environment: {required: true, type: choice, options: [stag, prod]}
      git-ref: {required: true, type: string}

jobs:
  deploy:
    uses: artack/artack_ansible-action/.github/workflows/deploy.yaml@<tag>
    with:
      environment: ${{ inputs.environment }}
      playbook: deploy_${{ inputs.environment }}.yaml
      git-ref: ${{ inputs.git-ref }}
    secrets: inherit
```

`secrets: inherit` ist Pflicht - ein Reusable Workflow bekommt nur, was der
Aufrufer uebergibt, und ein aufrufender Job darf kein `environment` setzen.

Weitere Vorlagen in [`examples/`](examples/), darunter der automatische
stag-Deploy per `needs` an allen Pruef-Jobs.

## Inputs

| Name | Pflicht | Default | Bedeutung |
| --- | --- | --- | --- |
| `environment` | ja | - | GitHub Environment; traegt Secrets und Freigabe-Regeln |
| `playbook` | ja | - | Pfad im Repository, z.B. `deploy_stag.yaml` |
| `git-ref` | ja | - | Branch, Tag oder SHA; wird als `-e git_branch=` gesetzt |
| `ansible-version` | nein | `ansible~=9.13.0` | volle Distribution, nicht `ansible-core` - die Playbooks brauchen `community.general` |
| `galaxy-requirements-inline` | nein | eingebaute Pins | Requirements-YAML als Text, Override |
| `galaxy-requirements` | nein | `""` | Pfad zu einer Requirements-Datei; nur setzen, wenn sie Versionen pinnt |
| `extra-vars` | nein | `""` | weitere Ansible-Variablen als `key=value` |
| `runs-on` / `timeout-minutes` | nein | `ubuntu-latest` / `20` | |

Wer die Action direkt in einen bestehenden Job einbindet, verliert nichts -
`environment` und `concurrency` kann dieser Job selbst setzen, und die
Secret-Werte gehen als normale Inputs hinein.

## Secrets

| Name | Inhalt | Wo |
| --- | --- | --- |
| `DEPLOY_SSH_PRIVATE_KEY` | privater Deploy-Schluessel | **Environment**, nicht Repo |
| `DEPLOY_SSH_KNOWN_HOSTS` | `ssh-keyscan`-Ausgabe, ohne `#`-Zeilen | **Environment**, nicht Repo |

Je Umgebung ein eigener Schluessel: Namen gleich, Werte verschieden. Derselbe
Schluessel in zwei Environments hebt das Scoping auf.

## Einrichtung pro Umgebung

Der Zielserver klont selbst (`ansistrano_deploy_via: git`,
`ssh://git@github.com/...`). Der Baustein leitet den Deploy-Schluessel per
`ForwardAgent=yes` weiter, so wie es eine `~/.ssh/config` mit `ForwardAgent`
beim Deploy von Hand tut. **Darum muss die oeffentliche Haelfte des Schluessels
am Repository als read-only Deploy Key haengen** - sonst kann der Server nicht
klonen.

```bash
REPO=artack/<projekt>
ENV=stag
HOST=<ansible_host aus hosts.yaml>
USER=<ansible_user aus hosts.yaml>

# 1. Schluessel erzeugen (ohne Passphrase - ein Automat kann keine eingeben)
ssh-keygen -t ed25519 -C "github-actions ${REPO##*/} $ENV" -f ./ci_$ENV -N ""

# 2. Oeffentlicher Teil: auf den Server UND als read-only Deploy Key ans Repo
ssh-copy-id -i ./ci_$ENV.pub $USER@$HOST
ssh -i ./ci_$ENV $USER@$HOST true   # muss ohne Rueckfrage durchlaufen
gh repo deploy-key add ./ci_$ENV.pub --repo $REPO --title "github-actions $ENV"

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

Aufrufer pinnen einen Tag, nie einen Branch - ein Push auf `main` wuerde sonst
still das Verhalten aller Aufrufer aendern. Schnittstellenbruch = neuer
Major-Tag.

## Tests

`bats tests` - stubbt `ssh-agent`, `ssh-add`, `ansible-playbook` und
`ansible-galaxy`, braucht kein Netz und keinen Server.
