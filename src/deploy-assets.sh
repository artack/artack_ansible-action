#!/usr/bin/env bash
#
# Liefert gebaute Frontend-Assets auf den Zielserver aus.
#
# Laeuft VOR dem Playbook, also vor dem Symlink-Wechsel. Warum diese
# Reihenfolge - und warum sie nicht perfekt ist:
#
# Bei unseren Projekten ist das Asset-Verzeichnis (z.B. public/build) ein
# ansistrano SHARED path: Jedes Release verlinkt auf dasselbe Verzeichnis
# ausserhalb des Releases. Damit gibt es keine Reihenfolge, die ganz sauber ist:
#   - vor dem Symlink  -> kurz laeuft der ALTE Code mit den NEUEN Assets
#   - nach dem Symlink -> kurz laeuft der NEUE Code mit den ALTEN Assets
# Wir nehmen "vorher", weil Encore die Dateinamen hasht und wir mit
# "cp/scp" nichts loeschen: Die alten gehashten Dateien bleiben liegen, der
# alte Code findet sie also weiter. Nur entrypoints.json/manifest.json werden
# ueberschrieben - das ist das verbleibende Fenster, und es ist Sekunden lang.
# Sauber wird es erst, wenn die Assets IM Release liegen; dann schaltet der
# Symlink Code und Assets in einem Zug um. Das ist ein eigenes Vorhaben, weil es
# die Verzeichnisstruktur auf dem Kundenserver aendert.
#
# Erwartet denselben Schluessel und dieselben known_hosts wie der Deploy:
#   ARTACK_SSH_PRIVATE_KEY, ARTACK_SSH_KNOWN_HOSTS
#
# Aufruf: deploy-assets.sh <quellverzeichnis> <ziel user@host:pfad>

set -euo pipefail

source_dir="${1:?quellverzeichnis fehlt}"
target="${2:?ziel fehlt}"

fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

[[ -d "${source_dir}" ]] || fail "Asset-Verzeichnis '${source_dir}' fehlt - ist der Build gelaufen?"
[[ -n "$(ls -A "${source_dir}")" ]] || fail "Asset-Verzeichnis '${source_dir}' ist leer - der Build hat nichts erzeugt."
[[ -n "${ARTACK_SSH_PRIVATE_KEY:-}" ]] || fail "ARTACK_SSH_PRIVATE_KEY ist leer - Secret nicht gesetzt oder nicht an die Umgebung durchgereicht."
[[ -n "${ARTACK_SSH_KNOWN_HOSTS:-}" ]] || fail "ARTACK_SSH_KNOWN_HOSTS ist leer. Wir setzen bewusst kein StrictHostKeyChecking=no."
[[ "${target}" == *:* ]] || fail "Ziel '${target}' muss die Form user@host:/pfad haben."

runtime_dir="$(mktemp -d)"; chmod 700 "${runtime_dir}"
agent_pid=""
cleanup() { [[ -n "${agent_pid}" ]] && kill "${agent_pid}" 2>/dev/null || true; rm -rf "${runtime_dir}"; }
trap cleanup EXIT

known_hosts="${runtime_dir}/known_hosts"
printf '%s\n' "${ARTACK_SSH_KNOWN_HOSTS}" > "${known_hosts}"
chmod 600 "${known_hosts}"

eval "$(ssh-agent -s)" > /dev/null
agent_pid="${SSH_AGENT_PID}"
printf '%s\n' "${ARTACK_SSH_PRIVATE_KEY}" | ssh-add - 2>/dev/null \
  || fail "Deploy-Schluessel konnte nicht geladen werden."

ssh_opts=(-o "UserKnownHostsFile=${known_hosts}" -o StrictHostKeyChecking=yes -o BatchMode=yes)
remote_path="${target#*:}"
remote_host="${target%%:*}"

echo "Assets: ${source_dir} -> ${target}"
# Zielverzeichnis anlegen, falls es fehlt - beim ersten Lauf eines Projekts.
ssh "${ssh_opts[@]}" "${remote_host}" "mkdir -p '${remote_path}'" \
  || fail "Zielverzeichnis '${remote_path}' konnte nicht angelegt werden."

# scp statt rsync: rsync muss auf dem Server vorhanden sein, scp nicht. Es wird
# nichts geloescht - alte gehashte Dateien bleiben absichtlich liegen, damit der
# noch laufende alte Code seine Assets weiter findet.
scp "${ssh_opts[@]}" -r "${source_dir%/}/." "${target}" \
  || fail "Asset-Upload nach '${target}' fehlgeschlagen."

echo "Assets ausgeliefert."
