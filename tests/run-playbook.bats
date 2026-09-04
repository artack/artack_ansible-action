#!/usr/bin/env bats
#
# Die Zusicherungen des Kerns. Externe Werkzeuge sind gestubbt - kein Netz,
# kein Server.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/run-playbook.sh"
  WORK="$(mktemp -d)"
  STUBS="${WORK}/bin"
  mkdir -p "${STUBS}"
  cd "${WORK}"

  cat > "${STUBS}/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo "SSH_AGENT_PID=$$; export SSH_AGENT_PID;"
EOF
  cat > "${STUBS}/ssh-add" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
EOF
  cat > "${STUBS}/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
echo "ansible-playbook $*" >> "${WORK}/calls.log"
# Das Aufraeumen ermittelt den Host ueber --list-hosts.
if [[ "$*" == *--list-hosts* ]]; then
  printf '  play #1 (x): x\n    pattern: [x]\n    hosts (1):\n      btc-stag\n'
fi
EOF
  cat > "${STUBS}/ansible-galaxy" <<'EOF'
#!/usr/bin/env bash
echo "ansible-galaxy $*" >> "${WORK}/calls.log"
cp "${3}" "${WORK}/requirements.used"
EOF
  cat > "${STUBS}/ansible" <<'EOF'
#!/usr/bin/env bash
echo "ansible $*" >> "${WORK}/ansible.log"
# Liest die URL zurueck: gibt den zuletzt gesetzten Wert aus.
grep -o '"value":"[^"]*"' "${WORK}/ansible.log" | tail -1 | sed 's/.*"value":"//;s/"$//'
EOF
  chmod +x "${STUBS}"/*
  export WORK
  export PATH="${STUBS}:${PATH}"

  export ARTACK_SSH_PRIVATE_KEY="fake-key"
  export ARTACK_SSH_KNOWN_HOSTS="example.test ssh-ed25519 AAAAfake"
  : > deploy_prod.yaml
}

teardown() {
  rm -rf "${WORK}"
}

@test "bricht ab, wenn das Playbook fehlt" {
  run "${SCRIPT}" nicht_da.yaml master "" "" 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"nicht gefunden"* ]]
}

@test "bricht ab, wenn der private Schluessel leer ist" {
  export ARTACK_SSH_PRIVATE_KEY=""
  run "${SCRIPT}" deploy_prod.yaml master "" "" 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ARTACK_SSH_PRIVATE_KEY"* ]]
}

@test "bricht ab, wenn known_hosts leer ist - kein StrictHostKeyChecking=no" {
  export ARTACK_SSH_KNOWN_HOSTS=""
  run "${SCRIPT}" deploy_prod.yaml master "" "" 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ARTACK_SSH_KNOWN_HOSTS"* ]]
}

@test "setzt git_branch explizit, damit das vars_prompt nicht auf seinen Default faellt" {
  run "${SCRIPT}" deploy_prod.yaml release/1.2.3 "" "" 0
  [ "${status}" -eq 0 ]
  tail -1 "${WORK}/calls.log" | grep -q -- "-e git_branch=release/1.2.3"
}

@test "prueft die Syntax, bevor der Server angefasst wird" {
  run "${SCRIPT}" deploy_prod.yaml master "" "" 0
  [ "${status}" -eq 0 ]
  grep "ansible-playbook" "${WORK}/calls.log" | head -1 | grep -q -- "--syntax-check"
  tail -1 "${WORK}/calls.log" | grep -qv -- "--syntax-check"
}

@test "setzt kein git_branch, wenn kein Ref uebergeben wird" {
  run "${SCRIPT}" deploy_prod.yaml "" "" "" 0
  [ "${status}" -eq 0 ]
  ! grep -q -- "git_branch" "${WORK}/calls.log"
}

@test "reicht extra-vars als weiteres -e durch" {
  run "${SCRIPT}" deploy_prod.yaml master "" "artack_run_opcache_clear=false" 0
  [ "${status}" -eq 0 ]
  tail -1 "${WORK}/calls.log" | grep -q -- "-e artack_run_opcache_clear=false"
}

@test "installiert ohne Angabe die eingebauten, gepinnten Rollen-Versionen" {
  run "${SCRIPT}" deploy_prod.yaml master "" "" 0
  [ "${status}" -eq 0 ]
  grep -q "version: 4.0.1" "${WORK}/requirements.used"
  grep -q "cbrunnkvist.ansistrano-symfony-deploy" "${WORK}/requirements.used"
}

@test "der Inline-Override gewinnt gegen die eingebauten Versionen" {
  export ARTACK_GALAXY_REQUIREMENTS_INLINE="- src: ansistrano.deploy
  version: 9.9.9"
  run "${SCRIPT}" deploy_prod.yaml master "" "" 0
  [ "${status}" -eq 0 ]
  grep -q "version: 9.9.9" "${WORK}/requirements.used"
  ! grep -q "version: 4.0.1" "${WORK}/requirements.used"
}

@test "eine angegebene Requirements-Datei wird benutzt und gewarnt" {
  printf -- "- src: ansistrano.deploy\n" > eigene.yml
  run "${SCRIPT}" deploy_prod.yaml master eigene.yml "" 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"pinnt vermutlich keine Versionen"* ]]
}

@test "bricht ab, wenn die angegebene Requirements-Datei fehlt" {
  run "${SCRIPT}" deploy_prod.yaml master fehlt.yml "" 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"nicht gefunden"* ]]
}

@test "leitet das Arbeitsverzeichnis aus dem Playbook-Pfad ab" {
  mkdir -p unterordner
  : > unterordner/deploy_stag.yaml
  run "${SCRIPT}" unterordner/deploy_stag.yaml master "" "" 0
  [ "${status}" -eq 0 ]
  # Aufgerufen wird der Basename, nicht der Pfad - das Verzeichnis ist gewechselt.
  tail -1 "${WORK}/calls.log" | grep -q "ansible-playbook deploy_stag.yaml"
  ! grep -q "unterordner/deploy_stag.yaml" "${WORK}/calls.log"
}

@test "leitet fuer ein Playbook im Wurzelverzeichnis auf . ab" {
  run "${SCRIPT}" deploy_prod.yaml master "" "" 0
  [ "${status}" -eq 0 ]
  tail -1 "${WORK}/calls.log" | grep -q "ansible-playbook deploy_prod.yaml"
}

@test "prueft den Host-Key und leitet den Agenten NICHT weiter" {
  cat > "${STUBS}/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
echo "${ANSIBLE_SSH_COMMON_ARGS}" >> "${WORK}/env.log"
EOF
  chmod +x "${STUBS}/ansible-playbook"
  run "${SCRIPT}" deploy_prod.yaml master "" "" 0
  [ "${status}" -eq 0 ]
  grep -q "StrictHostKeyChecking=yes" "${WORK}/env.log"
  # Der Schluessel dient nur dem Server-Login; fuer den Klon nimmt der Server
  # das Lauf-Token. Weiterleiten waere Exposition ohne Nutzen.
  ! grep -q "ForwardAgent" "${WORK}/env.log"
}

@test "klont per HTTPS mit dem Lauf-Token, wenn eingeschaltet" {
  printf -- '    ansistrano_deploy_to: "~/public_html"\n    ansistrano_git_repo: ssh://git@github.com/artack/x.git\n' > deploy_prod.yaml
  ARTACK_GITHUB_TOKEN=ghs_test GITHUB_REPOSITORY=artack/x \
    run "${SCRIPT}" deploy_prod.yaml master "" "" 1
  [ "${status}" -eq 0 ]
  grep -q -- "ansistrano_git_repo=https://x-access-token:ghs_test@github.com/artack/x.git" "${WORK}/calls.log"
}

@test "setzt die Remote-URL per Ansible-Modul zurueck, nicht per Shell" {
  printf -- '    ansistrano_deploy_to: "~/public_html"\n    ansistrano_git_repo: ssh://git@github.com/artack/x.git\n' > deploy_prod.yaml
  ARTACK_GITHUB_TOKEN=ghs_test GITHUB_REPOSITORY=artack/x \
    run "${SCRIPT}" deploy_prod.yaml master "" "" 1
  [ "${status}" -eq 0 ]
  grep -q -- "-m community.general.git_config" "${WORK}/ansible.log"
  grep -q '"value":"ssh://git@github.com/artack/x.git"' "${WORK}/ansible.log"
  ! grep -q -- "-m shell" "${WORK}/ansible.log"
  [[ "${output}" == *"Remote-URL zurueckgesetzt"* ]]
}

@test "bricht ab, wenn der Token-Klon eingeschaltet ist aber kein Token da ist" {
  GITHUB_REPOSITORY=artack/x run "${SCRIPT}" deploy_prod.yaml master "" "" 1
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ARTACK_GITHUB_TOKEN"* ]]
}

@test "bricht ab, wenn das Playbook kein ansistrano_git_repo hat" {
  ARTACK_GITHUB_TOKEN=ghs_test GITHUB_REPOSITORY=artack/x \
    run "${SCRIPT}" deploy_prod.yaml master "" "" 1
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ansistrano_git_repo"* ]]
}

@test "ohne Token-Klon wird die Remote-URL nicht angetastet" {
  run "${SCRIPT}" deploy_prod.yaml master "" "" 0
  [ "${status}" -eq 0 ]
  [ ! -f "${WORK}/ansible.log" ]
}
