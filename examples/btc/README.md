# btc - Pilot

> **Diese Datei ist die Beschreibung, nicht die Einrichtung.** Sie richtet
> nichts ein und ersetzt keinen Schritt. Wirksam wird nur, was im **btc-Repo**
> unter `.github/workflows/` liegt; die Vorlagen daneben sind Kopierquellen.
> Ob der Pilot startbereit ist, entscheidet sich dort und an den Secrets im
> Environment `stag` - siehe [Was noch fehlt](#was-noch-fehlt).

Zwei Vorlagen fuer das btc-Repo (`artack/suissetec_building-technology-calculator`),
beide als **eigene** Workflow-Dateien - `linter.yaml` bleibt unberuehrt.

| Datei | Ziel im btc-Repo | Braucht Secrets? |
| --- | --- | --- |
| `preflight.yaml` | `.github/workflows/preflight.yaml` | nein |
| `deploy.yaml` | `.github/workflows/deploy.yaml` | ja, zwei Environment-Secrets |

## Erhobene Fakten (2026-09-04)

| | prod | stag |
| --- | --- | --- |
| Inventarhost | `btc-prod` | `btc-stag` |
| `ansible_host` | `btc.suissetec.ch.suissetec01.nine.ch` | `stag.btc.suissetec.ch.suissetec01.nine.ch` |
| `ansible_user` | `www-btc-prod` | `www-btc-stag` |
| `ansistrano_deploy_to` | `~/public_html` | `~/public_html` |
| `git_default_branch` | `master` | `develop` |
| PHP | `/usr/bin/php8.2` | `/usr/bin/php8.2` |

**Beide Umgebungen liegen auf derselben Maschine** (`suissetec01.nine.ch`,
217.150.245.152, identischer SSH-Host-Key), aber unter **verschiedenen
Unix-Benutzern**. Die Trennung von stag und prod ruht damit allein auf der
Benutzertrennung, nicht auf getrennten Hosts - siehe README, Abschnitt
"Ein Host, viele Umgebungen".

## Was noch fehlt

**Fuer den Piloten reicht ein Schluesselpaar - das fuer stag.** prod kommt erst,
wenn stag durchgelaufen ist, und bekommt dann sein **eigenes** Paar.

1. **Ein** Schluesselpaar fuer stag; oeffentlicher Teil in `authorized_keys` von
   `www-btc-stag`.
2. GitHub Environment `stag` im btc-Repo mit `DEPLOY_SSH_PRIVATE_KEY` und
   `DEPLOY_SSH_KNOWN_HOSTS`.
3. Den Versions-Tag in beiden Dateien auf den tatsaechlich veroeffentlichten
   Tag ziehen.

Spaeter fuer prod: eigenes Environment `prod` mit **denselben Secret-Namen** und
einem **eigenen, neu erzeugten** Schluessel - siehe README, Abschnitt
"Ein Schluessel pro Umgebung". Dazu Required reviewers und Deployment branch
policy.

## Kein Rollback-Aufrufer

Absichtlich nicht dabei. `btc/rollback_prod.yaml` und `rollback_stag.yaml` sind
untailorierte dist-Vorlagen: `hosts: all` loest auf `btc-prod btc-stag` auf -
ein Rollback wuerde **beide** Umgebungen treffen - und
`ansistrano_deploy_to: /var/www/my-app` zeigt an einen Pfad, den es dort nicht
gibt. Der Rollback-Aufrufer kommt erst nach dem Fix, und der Fix erst nach Sams
Review (siehe `~/development/CLAUDE.md`).
