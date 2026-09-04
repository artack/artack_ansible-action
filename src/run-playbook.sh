#!/usr/bin/env bash
#
# Fuehrt ein artack-Ansistrano-Playbook nicht-interaktiv aus - nichts weiter.
#
# Der Anspruch: Jedes Projekt, auch ein unbekanntes, gibt den Pfad zu seinem
# bestehenden Playbook an, und es laeuft wie von Hand. Darum wird hier nichts
# umgeschrieben, nichts geprueft und nichts ueber das Playbook hinaus getan.
#
# Geheimnisse ausschliesslich ueber die Umgebung, damit sie nie in einer
# Kommandozeile oder in einer Datei im Workspace landen:
#   ARTACK_SSH_PRIVATE_KEY   privater Deploy-Schluessel
#   ARTACK_SSH_KNOWN_HOSTS   known_hosts-Eintrag/e des Zielservers
# Optional:
#   ARTACK_GALAXY_REQUIREMENTS_INLINE  Requirements-YAML als Text (Override)
#
# Aufruf: run-playbook.sh <playbook> <git-ref|""> <galaxy-requirements|""> \
#                          <extra-vars|""> <clone-with-token 1|0>

set -euo pipefail

playbook_arg="${1:?playbook fehlt}"
git_ref="${2-}"
galaxy_requirements="${3-}"
extra_vars="${4-}"
clone_with_token="${5-1}"

fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

# Bekannt-gute Rollen-Versionen, eingebaut als Default.
#
# Warum nicht die requirements.yml des Projekts: Die pinnt keine Versionen.
# `ansible-galaxy install` aktualisiert eine bereits vorhandene Rolle nicht -
# auf einer Entwicklermaschine liegt darum, was dort vor Jahren installiert
# wurde, waehrend ein frischer Runner die neuesten holt. ansistrano.deploy 4.4.0
# setzt `ansistrano_release_path` per set_fact als String, waehrend bis 4.3.0
# ein registriertes Ergebnis mit `.stdout` daraus wurde - und `.stdout` war die
# dokumentierte Schnittstelle. Alle artack-Playbooks und -Hooks greifen so
# darauf zu und brechen mit 4.4.0.
#
# "Out of the box wie vorher" heisst deshalb: dieselben Versionen wie auf der
# Entwicklermaschine. Das sind die aus dem gruenen Pilotlauf.
#
# DAS IST EINE FRIST, KEIN ZUSTAND. cbrunnkvist.ansistrano-symfony-deploy hat
# seit 2024-09 keinen Commit und passt nicht mehr zur aktuellen Hauptrolle. Der
# Ausweg ist, `.stdout`-Zugriffe auf
# `ansistrano_release_path.stdout | default(ansistrano_release_path)`
# umzustellen - dann laeuft beides. Bis dahin gilt dieses Pinning.
#
# Herkunft der einzelnen Pins, unterschiedlich belastbar:
#   ansistrano.deploy 4.0.1  - im gruenen Lauf ausgefuehrt. Belegt.
#   cbrunnkvist v1.4.1       - im gruenen Lauf ausgefuehrt, und ohnehin die
#                              neueste Fassung. Belegt.
#   ansistrano.rollback 3.1.0 - NICHT gemessen. Das ist die Fassung auf der
#                              Entwicklermaschine (installiert 2022-05-16); ein
#                              Rollback ist nie gelaufen. Es gibt auch keine
#                              Kompatibilitaetsbedingung zu deploy 4.0.1: Die
#                              Rollback-Rolle setzt ihre Variablen selbst und
#                              nichts von aussen greift darauf zu - 3.1.0
#                              (.stdout) und 4.0.1 (set_fact) sind beide in sich
#                              stimmig. Der Pin steht hier nur, damit nicht
#                              still "latest" gezogen wird, und folgt der
#                              Entwicklermaschine.
read -r -d '' DEFAULT_REQUIREMENTS <<'REQUIREMENTS' || true
- src: ansistrano.deploy
  version: 4.0.1
- src: ansistrano.rollback
  version: 3.1.0
- src: cbrunnkvist.ansistrano-symfony-deploy
  version: v1.4.1
REQUIREMENTS

[[ -f "${playbook_arg}" ]] || fail "Playbook '${playbook_arg}' nicht gefunden."
[[ -n "${ARTACK_SSH_PRIVATE_KEY:-}" ]] || fail "ARTACK_SSH_PRIVATE_KEY ist leer - Secret nicht gesetzt oder nicht an die Umgebung durchgereicht."
[[ -n "${ARTACK_SSH_KNOWN_HOSTS:-}" ]] || fail "ARTACK_SSH_KNOWN_HOSTS ist leer. Wir setzen bewusst kein StrictHostKeyChecking=no - ohne Host-Key kein Deployment."

# Das Verzeichnis des Playbooks ist das Arbeitsverzeichnis: Dort liegen
# ansible.cfg und hosts.yaml, und ansible.cfg wird nur aus dem aktuellen
# Verzeichnis gelesen. Ein Playbook im Wurzelverzeichnis ergibt ".".
playbook_dir="$(dirname -- "${playbook_arg}")"
playbook="$(basename -- "${playbook_arg}")"
cd -- "${playbook_dir}"

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
#
# BEWUSST OHNE ForwardAgent: Der Schluessel dient nur dem Server-Login. Fuer den
# Klon nimmt der Server das Lauf-Token (siehe unten), er braucht also keine
# eigene GitHub-Identitaet - und den Deploy-Key an einen Kundenserver
# weiterzureichen waere dann Exposition ohne Nutzen. Der Agent bleibt lokal.
export ANSIBLE_HOST_KEY_CHECKING=True
export ANSIBLE_SSH_COMMON_ARGS="-o UserKnownHostsFile=${known_hosts} -o StrictHostKeyChecking=yes"
export ANSIBLE_FORCE_COLOR=1

args=()
# Der Branch wird explizit gesetzt, damit das vars_prompt der Playbooks nicht
# stillschweigend auf seinen Default (git_default_branch) zurueckfaellt: Bei
# geschlossenem stdin fragt Ansible nicht, sondern nimmt den Default.
[[ -n "${git_ref}" ]] && args+=(-e "git_branch=${git_ref}")
[[ -n "${extra_vars}" ]] && args+=(-e "${extra_vars}")

# Der ZIELSERVER klont selbst von GitHub (ansistrano_deploy_via: git, das
# git-Modul der Rolle laeuft ohne delegate_to). Von Hand klappt das ueber den
# weitergeleiteten Agenten des Menschen; in der CI gibt es den nicht. Statt
# eines dauerhaften Deploy Keys nimmt der Lauf sein eigenes GITHUB_TOKEN: laut
# Doku "scoped to the invoking repository and expires after job completion".
#
# Nur fuer diesen Lauf per -e. Das Playbook bleibt auf ssh:// - der manuelle Weg
# ueber die Agent-Weiterleitung ist unberuehrt. Nach dem Lauf wird die
# Remote-URL zurueckgesetzt (siehe reset_remote_url).
#
# Der Handel, den Sam bewusst eingegangen ist: kurzlebiges Geheimnis mit
# kurzzeitigem Fussabdruck auf dem Server statt dauerhaftes Geheimnis ohne.
original_repo=""
if [[ "${clone_with_token}" == "1" ]]; then
  [[ -n "${ARTACK_GITHUB_TOKEN:-}" ]] || fail "ARTACK_GITHUB_TOKEN ist leer - ohne Token kein HTTPS-Klon. Fuer ein Repo ausserhalb von github.com clone-with-github-token auf false setzen."
  [[ -n "${GITHUB_REPOSITORY:-}" ]] || fail "GITHUB_REPOSITORY ist leer - laeuft das ausserhalb von GitHub Actions?"
  original_repo="$(sed -n 's/^[[:space:]]*ansistrano_git_repo:[[:space:]]*//p' "${playbook}" | head -1 | tr -d '"'"'")"
  [[ -n "${original_repo}" ]] || fail "'${playbook}' setzt kein ansistrano_git_repo - ohne den Ausgangswert liesse sich die Remote-URL danach nicht zuruecksetzen."
  args+=(-e "ansistrano_git_repo=https://x-access-token:${ARTACK_GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git")
  echo "Klon per HTTPS mit dem Lauf-Token (github.com/${GITHUB_REPOSITORY})."
fi

requirements="${runtime_dir}/requirements.yml"
if [[ -n "${ARTACK_GALAXY_REQUIREMENTS_INLINE:-}" ]]; then
  printf '%s\n' "${ARTACK_GALAXY_REQUIREMENTS_INLINE}" > "${requirements}"
  echo "Galaxy-Rollen: Override des Aufrufers."
elif [[ -n "${galaxy_requirements}" ]]; then
  [[ -f "${galaxy_requirements}" ]] || fail "Galaxy-Requirements '${galaxy_requirements}' nicht gefunden."
  cp -- "${galaxy_requirements}" "${requirements}"
  echo "::warning::'${galaxy_requirements}' pinnt vermutlich keine Versionen - dann holt der Runner die neuesten Rollen, und artack-Playbooks brechen an ansistrano.deploy 4.4.0."
else
  printf '%s\n' "${DEFAULT_REQUIREMENTS}" > "${requirements}"
  echo "Galaxy-Rollen: eingebaute, bekannt-gute Versionen."
fi

echo "::group::ansible-galaxy install"
cat "${requirements}"
ansible-galaxy install -r "${requirements}"
echo "::endgroup::"

echo "::group::ansible-playbook --syntax-check"
ansible-playbook "${playbook}" "${args[@]}" --syntax-check < /dev/null
echo "::endgroup::"

# Aufraeumen: Das git-Modul der Rolle schreibt die Remote-URL in
# <deploy_to>/repo/.git/config auf dem Server, und dieses Verzeichnis ueberlebt
# das Release. Der Token darin ist nach dem Job wertlos, soll aber nicht
# liegenbleiben.
#
# Ueber community.general.git_config, NICHT per Shell: Dessen Parameter `repo`
# ist ein Ansible-Pfadtyp und loest die Tilde selbst auf. Der erste Entwurf war
# ein "-m shell" mit cd '~/pfad' - die Tilde in einfachen Anfuehrungszeichen
# expandiert keine Shell, und "2>/dev/null || true" liess den Fehlschlag als
# "CHANGED | rc=0" erscheinen, waehrend der Token liegenblieb. Das Modul macht
# diese Klasse Fehler unmoeglich.
#
# Laeuft auch, wenn das Playbook gescheitert ist (trap), und der Erfolg wird am
# ZUSTAND gemessen: Die URL wird zurueckgelesen und auf "x-access-token" geprueft.
reset_remote_url() {
  [[ -n "${original_repo}" ]] || return 0
  local host deploy_to args_json url listed
  # Die beiden Ermittlungen sind reine LESE-Vorgaenge, und ihr Fehlschlag wird
  # unten ausdruecklich gemeldet - darum hier "|| true". Ohne das bricht
  # `set -euo pipefail` schon an einem leeren grep ab, und der Lauf endet mit
  # einem nackten exit 1 statt mit der Meldung, die sagt was fehlt. Das ist
  # NICHT das Muster "Fehler schlucken": geschluckt wird nichts, der Zustand
  # wird gleich danach geprueft.
  listed="$(ansible-playbook "${playbook}" "${args[@]}" --list-hosts < /dev/null 2>/dev/null || true)"
  host="$(printf '%s\n' "${listed}" | sed -n '/hosts ([0-9]*)/,$p' | tail -n +2 | tr -d ' ' | grep -v '^$' | head -1 || true)"
  deploy_to="$(sed -n 's/^[[:space:]]*ansistrano_deploy_to:[[:space:]]*//p' "${playbook}" | head -1 | tr -d '"'"'" || true)"
  if [[ -z "${host}" || -z "${deploy_to}" ]]; then
    echo "::error::Remote-URL konnte nicht zurueckgesetzt werden - Host oder ansistrano_deploy_to nicht ermittelbar. Im .git/config des Servers bleibt ein abgelaufener Token stehen."
    return 0
  fi
  # JSON-Argumente statt key=value: Die URL enthaelt ":" und "@". Ein
  # Anfuehrungszeichen darin waere ein Fehler, nicht ein Sonderfall.
  case "${original_repo}${deploy_to}" in
    *'"'*|*'\'*) echo "::error::Unerwartetes Zeichen in Repo-URL oder Pfad - Remote-URL nicht zurueckgesetzt."; return 0 ;;
  esac

  echo "::group::Remote-URL zuruecksetzen"
  args_json="$(printf '{"name":"remote.origin.url","scope":"local","repo":"%s/repo","value":"%s"}' \
    "${deploy_to}" "${original_repo}")"
  if ! ansible "${host}" -m community.general.git_config -a "${args_json}" < /dev/null; then
    echo "::error::Zuruecksetzen der Remote-URL fehlgeschlagen - im .git/config des Servers bleibt ein abgelaufener Token stehen."
    echo "::endgroup::"
    return 0
  fi
  # Gegenprobe am Zustand, nicht am Rueckgabewert.
  url="$(ansible "${host}" -m community.general.git_config \
    -a "$(printf '{"name":"remote.origin.url","scope":"local","repo":"%s/repo"}' "${deploy_to}")" \
    < /dev/null 2>&1)" || true
  if printf '%s' "${url}" | grep -q 'x-access-token'; then
    echo "::error::Die Remote-URL auf dem Server enthaelt weiterhin einen Token."
  else
    echo "Remote-URL zurueckgesetzt auf ${original_repo}"
  fi
  echo "::endgroup::"
}
trap 'reset_remote_url; cleanup' EXIT

# stdin bewusst geschlossen: ein unerwarteter Prompt soll auffallen, nicht warten.
ansible-playbook "${playbook}" "${args[@]}" < /dev/null
