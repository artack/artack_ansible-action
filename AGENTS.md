# artack_ansible-action - Hinweise fuer Agents

CI-Baustein, der ein **bestehendes** Ansible-Playbook ausfuehrt. Remote:
`artack/artack_ansible-action`, oeffentlich, Default-Branch `main`.

**Der Anspruch, an dem sich jede Aenderung messen muss:** Ein beliebiges
Projekt - auch ein unbekanntes - gibt den Pfad zu seinem Playbook an, und es
laeuft wie von Hand. Nichts wird umgeschrieben, nichts erzwungen, keine
Namenskonvention verlangt.

- **Nichts hinzufuegen, was ueber "ein Playbook ausfuehren" hinausgeht.** Der
  Baustein hatte schon einmal eine Ziel-Pruefung mit Namenskonvention, einen
  Asset-Build und einen Token-Klon, der eine Playbook-Variable ueberschrieb.
  Alles drei ist bewusst entfernt worden, weil es projektspezifisch war und
  "out of the box" verhindert hat. Nicht wieder einbauen.
- **Keine weiteren Reusable Workflows.** Ein Rollback- und ein
  Preflight-Workflow gab es und sind entfernt: Der Rollback-Workflow machte aus
  Playbooks, die teils untailorierte dist-Vorlagen sind, einen CI-Knopf und
  widersprach damit der Hausregel; der Preflight war eine dritte versionierte
  Schnittstelle fuer einen `--syntax-check`, den der Deploy ohnehin macht. Ein
  Workflow rechtfertigt sich nur, wenn er eine Entscheidung an einer Stelle
  richtig haelt - so wie `cancel-in-progress: false` in `deploy.yaml`. Er
  rechtfertigt sich **nicht** damit, dass "nur ein Workflow Secrets annehmen
  darf": Das gilt fuer die `secrets:`-Schnittstelle, nicht fuer Secret-Werte -
  die gehen als normale Inputs in die Action.
- **Aufrufer brauchen `secrets: inherit`.** Ein Reusable Workflow bekommt nur,
  was der Aufrufer uebergibt; das job-level `environment` regelt nur den Vorrang
  bei Namensgleichheit und fuellt den secrets-Kontext nicht.
- **Kein `StrictHostKeyChecking=no`** und kein stiller Rueckfall, wenn
  `known_hosts` fehlt. Die Tests halten das fest.
- **`-e git_branch=<ref>` ist Pflicht** bei Playbooks mit `vars_prompt`: Bei
  geschlossenem stdin fragt Ansible nicht, sondern nimmt still
  `git_default_branch`.
- **`ForwardAgent=yes`** ist kein Detail: Der Zielserver klont selbst von
  GitHub und hat keine eigene Zugangsberechtigung. Voraussetzung ist ein
  read-only Deploy Key am Repo.
- **`pipx` nicht wieder einfuehren** - siehe Kommentar in `action.yml`.

## Kommandos auf einem Kundenserver

Aus diesem Repo laeuft auf dem Zielserver **nur, was das Playbook selbst tut**.
Kein `ssh`, kein `scp`, kein `ansible -m shell`, kein `mkdir`, kein `rm`, kein
`chmod`. Die `chmod`/`rm`-Zeilen in `src/run-playbook.sh` betreffen
ausschliesslich ein `mktemp -d` auf dem Runner.

**Das bleibt so.** Wer das aendern will, hat vorher diese fuenf Fragen zu
beantworten - sie stammen aus einem echten Fehler in diesem Repo
(`cd '~/pfad'` mit gequoteter Tilde, dessen Fehlschlag durch
`2>/dev/null || true` als `CHANGED | rc=0` erschien):

1. Expandiert eine Tilde oder Variable, die in Anfuehrungszeichen steht?
2. Wird ein Pfad aus Strings zusammengesetzt statt als Modul-Parameter
   uebergeben?
3. Werden Fehler geschluckt (`2>/dev/null`, `|| true`, `ignore_errors`)?
4. Wird Erfolg am Rueckgabewert gemessen statt am Zustand? (`mkdir -p '~/x'`
   liefert rc=0 und legt ein Verzeichnis namens `~` an.)
5. Waere dasselbe Muster mit `rm`, `chown` oder `rsync --delete` gefaehrlich?

Wenn rohes Shell unvermeidlich ist: Begruendung in den Code, warum kein
Ansible-Modul es kann.

- **Rollback-Playbooks der Projekte nie ausfuehren** - siehe
  `~/development/CLAUDE.md`. Befund vorlegen, Sam reviewt.
- Die Projekt-Playbooks werden von diesem Repo aus **nicht** geaendert.
- Tests: `bats tests`. Ohne Netz, ohne Server.
