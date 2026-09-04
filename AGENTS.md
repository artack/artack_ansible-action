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
- **Dieses Repo stellt Aufrufern GAR KEINE Reusable Workflows bereit.** Nur die
  Action und die eigene CI (`test.yml`). Es gab einmal drei
  (`deploy`, `rollback`, `preflight`), alle entfernt. Die Regel gilt, damit sie
  nicht als "Komfort" zurueckkommt - hier sind die Gruende, damit sie nicht neu
  erfunden werden muessen:
  - **Kein Faehigkeitsgewinn.** `environment`, `concurrency` und `permissions`
    setzt der Job des Projekts genauso. Secret-**Werte** gehen als normale
    Inputs in die Action; "composite actions cannot use secrets" meint die
    `secrets:`-Schnittstelle, nicht die Werte.
  - **Ein Job mit `uses:` kann keine eigenen `steps` haben.** Erlaubt sind laut
    Doku nur `name, uses, with, secrets, strategy, needs, if, concurrency,
    permissions`. Ein Projekt koennte seinen Frontend-Build also nicht in
    denselben Job legen - genau das braucht btc (yarn build, dann deployen).
  - **`environment` fehlt in derselben Liste.** Darum brauchte der
    Workflow-Weg `secrets: inherit`; daran ist Pilotlauf 1 gescheitert. Direkt
    eingebunden setzt der Job sein `environment` selbst und liest die Secrets
    ohne Umweg.
  - **Zentrale `concurrency` war ein Trugschluss** (mein Argument, widerlegt):
    Setzt der Aufrufer auf **Workflow**-Ebene `cancel-in-progress: true`, wird
    der ganze Lauf abgebrochen und die Jobs des aufgerufenen Workflows sterben
    mit. Die Job-Einstellung im Baustein schuetzt gegen genau den Fall nicht.
  - Kosten waren real: eine zweite versionierte Schnittstelle mit neun
    gespiegelten Inputs, die bei jeder Aenderung mitgepflegt werden muss.
- **Der Job des Aufrufers setzt `environment`**, dann loest
  `secrets.DEPLOY_SSH_PRIVATE_KEY` dort direkt auf. Kein `secrets: inherit`,
  kein Durchreichen.
- **Kein `StrictHostKeyChecking=no`** und kein stiller Rueckfall, wenn
  `known_hosts` fehlt. Die Tests halten das fest.
- **`-e git_branch=<ref>` ist Pflicht** bei Playbooks mit `vars_prompt`: Bei
  geschlossenem stdin fragt Ansible nicht, sondern nimmt still
  `git_default_branch`.
- **Kein `ForwardAgent`.** Der Zielserver klont selbst von GitHub, nimmt dafuer
  aber das kurzlebige Lauf-Token - er braucht keine eigene GitHub-Identitaet.
  Den Deploy-Key an einen Kundenserver weiterzuleiten waere Exposition ohne
  Nutzen. Sams Entscheid: kurzlebiges Geheimnis mit kurzem Fussabdruck auf dem
  Server statt dauerhafter Deploy Key.
- **Das Aufraeumen der Remote-URL laeuft ueber
  `community.general.git_config`, nie ueber `-m shell`.** Der Parameter `repo`
  ist ein Ansible-Pfadtyp und loest die Tilde selbst auf. Der erste Entwurf war
  ein `cd '~/pfad'` in einem Shell-String - die Tilde expandierte nicht, und
  `2>/dev/null || true` liess den Fehlschlag als `CHANGED | rc=0` erscheinen.
  Nicht zurueckbauen.
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
