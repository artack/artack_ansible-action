#!/usr/bin/env bash
#
# Prueft, dass ein Playbook auf das Ziel zeigt, das es treffen soll - und bricht
# sonst ab. Faengt untailorierte dist-Vorlagen: "hosts: all" trifft prod UND
# stag gleichzeitig, und "ansistrano_deploy_to: /var/www/my-app" zeigt an einen
# Pfad, den es auf dem Zielserver nicht gibt.
#
# --syntax-check faengt das NICHT - er prueft Form, nicht Ziel.
#
# Aufruf: check-playbook-target.sh <playbook> [referenz-playbook]
#
# Ohne Referenz wird sie aus dem Namen abgeleitet: rollback_prod.yaml ->
# deploy_prod.yaml. Das Deploy-Playbook ist die Wahrheit: es laeuft regelmaessig
# und ist deshalb tailoriert.

set -euo pipefail

playbook="${1:?playbook fehlt}"
reference="${2-}"

fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

[[ -f "${playbook}" ]] || fail "Playbook '${playbook}' nicht gefunden."

if [[ -z "${reference}" ]]; then
  reference="${playbook/rollback_/deploy_}"
fi

# Erster nicht kommentierter Wert von ansistrano_deploy_to.
deploy_to_of() {
  sed -n 's/^[[:space:]]*ansistrano_deploy_to:[[:space:]]*//p' "$1" \
    | head -1 | tr -d '"'"'"
}

# Aufgeloeste Hostliste. Bewusst ueber Ansible und nicht per grep: so wird
# "hosts: all" zur tatsaechlichen Liste expandiert, und genau darum geht es.
hosts_of() {
  ansible-playbook "$1" -e git_branch=check --list-hosts < /dev/null 2>/dev/null \
    | sed -n '/hosts ([0-9]*)/,$p' | tail -n +2 | tr -d ' ' | grep -v '^$' | sort -u
}

playbook_hosts="$(hosts_of "${playbook}")"
playbook_to="$(deploy_to_of "${playbook}")"

[[ -n "${playbook_hosts}" ]] || fail "Konnte die Hosts von '${playbook}' nicht aufloesen (Inventar? ansible.cfg?)."
[[ -n "${playbook_to}" ]] || fail "'${playbook}' setzt kein ansistrano_deploy_to."

note "${playbook}:"
note "  hosts              -> $(echo "${playbook_hosts}" | tr '\n' ' ')"
note "  ansistrano_deploy_to -> ${playbook_to}"

# 1. Die dist-Platzhalter, unabhaengig von jeder Referenz.
case "${playbook_to}" in
  /var/www/my-app|/var/www/my-app/*)
    fail "'${playbook}' traegt noch den dist-Platzhalter ansistrano_deploy_to: ${playbook_to}. Das Playbook ist nicht tailoriert." ;;
esac

# 2. Trifft das Playbook mehr als einen Host, ist es nicht auf eine Umgebung
#    gerichtet - das ist der "hosts: all"-Fall.
host_count="$(echo "${playbook_hosts}" | wc -l | tr -d ' ')"
if [[ "${host_count}" -gt 1 ]]; then
  fail "'${playbook}' trifft ${host_count} Hosts ($(echo "${playbook_hosts}" | tr '\n' ' ')). Ein Playbook muss auf genau eine Umgebung zeigen - vermutlich 'hosts: all' aus der dist-Vorlage."
fi

# 3. Abgleich mit dem Deploy-Playbook derselben Umgebung.
if [[ "${reference}" == "${playbook}" ]]; then
  note "Keine Referenz noetig - '${playbook}' ist selbst das Deploy-Playbook."
  exit 0
fi

if [[ ! -f "${reference}" ]]; then
  fail "Referenz-Playbook '${reference}' fehlt. Ohne Deploy-Playbook derselben Umgebung ist das Ziel von '${playbook}' nicht pruefbar - Referenz explizit angeben."
fi

reference_hosts="$(hosts_of "${reference}")"
reference_to="$(deploy_to_of "${reference}")"

note "${reference}: (Referenz)"
note "  hosts              -> $(echo "${reference_hosts}" | tr '\n' ' ')"
note "  ansistrano_deploy_to -> ${reference_to}"

[[ "${playbook_hosts}" == "${reference_hosts}" ]] \
  || fail "Host-Abweichung: '${playbook}' -> $(echo "${playbook_hosts}" | tr '\n' ' ') , '${reference}' -> $(echo "${reference_hosts}" | tr '\n' ' ')."

[[ "${playbook_to}" == "${reference_to}" ]] \
  || fail "Pfad-Abweichung bei ansistrano_deploy_to: '${playbook}' -> ${playbook_to} , '${reference}' -> ${reference_to}."

note "OK - '${playbook}' zeigt auf dasselbe Ziel wie '${reference}'."
