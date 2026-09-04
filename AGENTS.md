# artack_ansible-action - Hinweise fuer Agents

Dieses Repository ist ein CI-Baustein fuer die Ansible-Belange unserer Projekte
(Deployment und Rollback), kein Anwendungsprojekt. Remote:
`artack/artack_ansible-action`, oeffentlich, Default-Branch `main`.

- `action.yml` ist die Mechanik-Schicht (Composite Action); die Einstiegspunkte
  sind die Reusable Workflows unter `.github/workflows/` (`deploy`, `rollback`,
  `preflight`). Aenderungen an der Mechanik gehoeren in `src/`, nicht in die
  Workflow-YAML.
- **Aufrufer referenzieren einen Versions-Tag, nie `@main`.** Ein Push auf
  `main` darf nicht still das Deployment-Verhalten der Projekte im
  Geltungsbereich aendern.
  Schnittstellenbruch = neuer Major-Tag. Begruendung im README.
- Die beiden Geheimnisse duerfen **nie** in einem `run:`-Body interpoliert
  werden - das schriebe sie in ein Shell-Skript auf die Platte. Immer ueber
  `env:` (siehe `action.yml`).
- Kein `StrictHostKeyChecking=no` und kein stiller Rueckfall, wenn
  `known_hosts` fehlt. Das ist eine Zusicherung, kein Detail; die Tests halten
  sie fest.
- `-e git_branch=<ref>` ist Pflicht bei Deployments: ohne die Extra-Variable
  nimmt das `vars_prompt` der Projekt-Playbooks bei geschlossenem stdin
  stillschweigend `git_default_branch`.
- **Die Ziel-Pruefung (`src/check-playbook-target.sh`) laeuft vor jedem
  Playbook-Lauf.** Sie darf nicht "wegoptimiert" werden: `--syntax-check` prueft
  Form, nicht Ziel, und mehrere `rollback_*.yaml` unserer Projekte sind
  untailorierte dist-Vorlagen mit `hosts: all`.
- **Rollback-Playbooks der Projekte nie ausfuehren** und nie auf Vorrat
  reparieren - siehe `~/development/CLAUDE.md`. Befund vorlegen, Sam reviewt.
- **Geltungsbereich: die Liste im README** - sie ist abschliessend. Dort steht
  auch, dass die Zugehoerigkeit von `suissetec_metaapp_legacy` noch offen ist.
  Keine Gesamtzahl erfinden, solange das nicht entschieden ist, und keine
  Projekte ergaenzen, die nicht in der Liste stehen.
- **Aufrufer brauchen `secrets: inherit`.** Ein Reusable Workflow bekommt nur,
  was der Aufrufer uebergibt - kein impliziter Zugriff auf dessen
  Secret-Speicher. Das job-level `environment` regelt nur den Vorrang bei
  Namensgleichheit, es fuellt den secrets-Kontext nicht. Diese Zeile nicht als
  "unnoetig" entfernen; ohne sie sind die Secrets leer.
- **`pipx install` braucht `--force`**, sonst bleibt die auf dem Runner
  vorinstallierte ansible-core-Version stehen und der Pin ist still unwirksam.
- Die Projekt-Playbooks werden von diesem Repo aus **nicht** geaendert.
- Tests: `bats tests`. Sie laufen ohne Netz und ohne Server, weil die externen
  Werkzeuge gestubbt sind. Neue Zusicherungen dort ergaenzen.
