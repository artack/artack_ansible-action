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
# 1 = Repo per HTTPS mit dem kurzlebigen GITHUB_TOKEN klonen statt per ssh://.
clone_with_token="${7-0}"

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

# Der ZIELSERVER klont selbst von GitHub (ansistrano_deploy_via: git, das
# git-Modul laeuft ohne delegate_to). Bei einem manuellen Deploy authentisiert er
# sich mit dem weitergeleiteten Agenten des Menschen; in der CI gibt es den
# nicht. Statt eines Deploy Keys nehmen wir das kurzlebige GITHUB_TOKEN des
# Laufs: auf das aufrufende Repo begrenzt, read-only, und es verfaellt mit dem
# Job. Nur fuer diesen Lauf per -e, das Playbook bleibt auf ssh:// - der manuelle
# Weg ueber die Agent-Weiterleitung bleibt damit unberuehrt.
original_repo=""
if [[ "${clone_with_token}" == "1" ]]; then
  [[ -n "${ARTACK_GITHUB_TOKEN:-}" ]] || fail "ARTACK_GITHUB_TOKEN ist leer - ohne Token kein HTTPS-Klon."
  [[ -n "${GITHUB_REPOSITORY:-}" ]] || fail "GITHUB_REPOSITORY ist leer - laeuft das ausserhalb von GitHub Actions?"
  original_repo="$(sed -n 's/^[[:space:]]*ansistrano_git_repo:[[:space:]]*//p' "${playbook}" | head -1 | tr -d '"'"'")"
  args+=(-e "ansistrano_git_repo=https://x-access-token:${ARTACK_GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git")
  echo "Klon per HTTPS mit dem Lauf-Token (github.com/${GITHUB_REPOSITORY})."
fi
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

# Aufraeumen: Das git-Modul schreibt die Remote-URL in
# <deploy_to>/repo/.git/config auf dem Server, und dieses Verzeichnis ueberlebt
# das Release. Der Token darin ist nach dem Job wertlos, soll aber trotzdem nicht
# liegenbleiben - darum wird die URL auf den Wert aus dem Playbook
# zurueckgesetzt. Laeuft auch, wenn das Playbook gescheitert ist.
reset_remote_url() {
  [[ -n "${original_repo}" ]] || return 0
  local host deploy_to
  host="$(ansible-playbook "${playbook}" "${args[@]}" --list-hosts < /dev/null 2>/dev/null \
    | sed -n '/hosts ([0-9]*)/,$p' | tail -n +2 | tr -d ' ' | grep -v '^$' | head -1)"
  deploy_to="$(sed -n 's/^[[:space:]]*ansistrano_deploy_to:[[:space:]]*//p' "${playbook}" | head -1 | tr -d '"'"'")"
  [[ -n "${host}" && -n "${deploy_to}" ]] || { echo "::warning::Remote-URL konnte nicht zurueckgesetzt werden (Host oder Pfad unbekannt)."; return 0; }
  echo "::group::Remote-URL zuruecksetzen"
  ansible "${host}" -m shell -a \
    "cd '${deploy_to}/repo' 2>/dev/null && git remote set-url origin '${original_repo}' || true" \
    < /dev/null || echo "::warning::Zuruecksetzen der Remote-URL fehlgeschlagen - im .git/config des Servers steht ein abgelaufener Token."
  echo "::endgroup::"
}
trap 'reset_remote_url; cleanup' EXIT

# stdin bewusst geschlossen: ein unerwarteter Prompt soll auffallen, nicht warten.
ansible-playbook "${playbook}" "${args[@]}" < /dev/null
