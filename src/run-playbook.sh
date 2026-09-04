#!/usr/bin/env bash
#
# Fuehrt ein artack-Ansistrano-Playbook nicht-interaktiv aus.
#
# Erwartet die beiden Geheimnisse ausschliesslich ueber die Umgebung, damit sie
# nie in einer Kommandozeile oder in einer Datei im Workspace landen:
#   ARTACK_SSH_PRIVATE_KEY   privater Deploy-Schluessel (CI -> Zielserver)
#   ARTACK_SSH_KNOWN_HOSTS   known_hosts-Eintrag/e des Zielservers
#
# Aufruf: run-playbook.sh <playbook> <git-ref|""> <galaxy-requirements|""> \
#                          <extra-vars|""> <check-target 1|0> <referenz-playbook|"">

set -euo pipefail

playbook="${1:?playbook fehlt}"
git_ref="${2-}"
galaxy_requirements="${3-}"
extra_vars="${4-}"
check_target="${5-1}"
reference_playbook="${6-}"

fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

[[ -f "${playbook}" ]] || fail "Playbook '${playbook}' nicht gefunden (working-directory falsch?)."
[[ -n "${ARTACK_SSH_PRIVATE_KEY:-}" ]] || fail "ARTACK_SSH_PRIVATE_KEY ist leer - Secret nicht gesetzt oder nicht an die Umgebung durchgereicht."
[[ -n "${ARTACK_SSH_KNOWN_HOSTS:-}" ]] || fail "ARTACK_SSH_KNOWN_HOSTS ist leer. Wir setzen bewusst kein StrictHostKeyChecking=no - ohne Host-Key kein Deployment."

# Privates Arbeitsverzeichnis fuer known_hosts; der Schluessel selbst bleibt im Agent.
runtime_dir="$(mktemp -d)"
chmod 700 "${runtime_dir}"
agent_pid=""

cleanup() {
  [[ -n "${agent_pid}" ]] && kill "${agent_pid}" 2>/dev/null || true
  rm -rf "${runtime_dir}"
}
trap cleanup EXIT

known_hosts="${runtime_dir}/known_hosts"
printf '%s\n' "${ARTACK_SSH_KNOWN_HOSTS}" > "${known_hosts}"
chmod 600 "${known_hosts}"

# ssh-agent lebt nur fuer diesen Prozess und stirbt mit ihm (siehe trap).
eval "$(ssh-agent -s)" > /dev/null
agent_pid="${SSH_AGENT_PID}"
printf '%s\n' "${ARTACK_SSH_PRIVATE_KEY}" | ssh-add - 2>/dev/null \
  || fail "Deploy-Schluessel konnte nicht geladen werden (Format? Passphrase? fehlender Zeilenumbruch am Ende?)."

# Host-Key wird geprueft, nicht umgangen.
export ANSIBLE_HOST_KEY_CHECKING=True
export ANSIBLE_SSH_COMMON_ARGS="-o UserKnownHostsFile=${known_hosts} -o StrictHostKeyChecking=yes"
export ANSIBLE_FORCE_COLOR=1

args=()
# Der Branch wird explizit gesetzt, damit das vars_prompt der Playbooks nicht
# stillschweigend auf seinen Default (git_default_branch) zurueckfaellt.
[[ -n "${git_ref}" ]] && args+=(-e "git_branch=${git_ref}")
[[ -n "${extra_vars}" ]] && args+=(-e "${extra_vars}")

if [[ -n "${galaxy_requirements}" ]]; then
  [[ -f "${galaxy_requirements}" ]] || fail "Galaxy-Requirements '${galaxy_requirements}' nicht gefunden. Bei Projekten ohne Submodul galaxy-requirements leeren und die Rollen anders bereitstellen."
  echo "::group::ansible-galaxy install"
  ansible-galaxy install -r "${galaxy_requirements}"
  echo "::endgroup::"
fi

# Ziel-Pruefung VOR dem Lauf: --syntax-check prueft Form, nicht Ziel. Diese
# Pruefung faengt untailorierte dist-Vorlagen ("hosts: all",
# ansistrano_deploy_to: /var/www/my-app), die sonst die falsche Umgebung treffen.
if [[ "${check_target}" == "1" ]]; then
  echo "::group::Ziel-Pruefung"
  "$(dirname "${BASH_SOURCE[0]}")/check-playbook-target.sh" "${playbook}" "${reference_playbook}"
  echo "::endgroup::"
else
  echo "::warning::Ziel-Pruefung uebersprungen (check-target: false). Das Playbook kann auf die falsche Umgebung zeigen."
fi

echo "::group::ansible-playbook --syntax-check"
ansible-playbook "${playbook}" "${args[@]}" --syntax-check < /dev/null
echo "::endgroup::"

# stdin bewusst geschlossen: ein unerwarteter Prompt soll auffallen, nicht warten.
ansible-playbook "${playbook}" "${args[@]}" < /dev/null
