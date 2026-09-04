#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/run-playbook.sh"
  WORK="$(mktemp -d)"
  STUBS="${WORK}/bin"
  mkdir -p "${STUBS}"
  cd "${WORK}"

  # Aufrufe der externen Werkzeuge werden protokolliert statt ausgefuehrt.
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
# Die Ziel-Pruefung loest die Hosts ueber --list-hosts auf.
if [[ "$*" == *--list-hosts* ]]; then
  printf '  play #1 (x): x\n    pattern: [x]\n    hosts (1):\n      btc-prod\n'
fi
EOF
  cat > "${STUBS}/ansible-galaxy" <<'EOF'
#!/usr/bin/env bash
echo "ansible-galaxy $*" >> "${WORK}/calls.log"
EOF
  chmod +x "${STUBS}"/*
  export WORK
  export PATH="${STUBS}:${PATH}"

  export ARTACK_SSH_PRIVATE_KEY="fake-key"
  export ARTACK_SSH_KNOWN_HOSTS="example.test ssh-ed25519 AAAAfake"
  printf '    ansistrano_deploy_to: "~/public_html"\n' > deploy_prod.yaml
}

teardown() {
  rm -rf "${WORK}"
}

@test "bricht ab, wenn das Playbook fehlt" {
  run "${SCRIPT}" nicht_da.yaml master "" ""
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"nicht gefunden"* ]]
}

@test "bricht ab, wenn der private Schluessel leer ist" {
  export ARTACK_SSH_PRIVATE_KEY=""
  run "${SCRIPT}" deploy_prod.yaml master "" ""
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ARTACK_SSH_PRIVATE_KEY"* ]]
}

@test "bricht ab, wenn known_hosts leer ist - kein StrictHostKeyChecking=no" {
  export ARTACK_SSH_KNOWN_HOSTS=""
  run "${SCRIPT}" deploy_prod.yaml master "" ""
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ARTACK_SSH_KNOWN_HOSTS"* ]]
}

@test "setzt git_branch explizit, damit das vars_prompt nicht auf seinen Default faellt" {
  run "${SCRIPT}" deploy_prod.yaml release/1.2.3 "" ""
  [ "${status}" -eq 0 ]
  grep -q -- "-e git_branch=release/1.2.3" "${WORK}/calls.log"
}

@test "prueft die Syntax, bevor der Server angefasst wird" {
  run "${SCRIPT}" deploy_prod.yaml master "" ""
  [ "${status}" -eq 0 ]
  # Der erste Playbook-Aufruf muss der Syntaxpruefung gehoeren.
  grep "ansible-playbook" "${WORK}/calls.log" | head -1 | grep -q -- "--syntax-check"
}

@test "setzt kein git_branch beim Rollback" {
  printf '    ansistrano_deploy_to: "~/public_html"\n' > rollback_prod.yaml
  run "${SCRIPT}" rollback_prod.yaml "" "" ""
  [ "${status}" -eq 0 ]
  ! grep -q -- "git_branch" "${WORK}/calls.log"
}

@test "ueberspringt Galaxy, wenn keine Requirements angegeben sind" {
  run "${SCRIPT}" deploy_prod.yaml master "" ""
  [ "${status}" -eq 0 ]
  ! grep -q "ansible-galaxy" "${WORK}/calls.log"
}

@test "installiert die Rollen, wenn eine Requirements-Datei angegeben ist" {
  mkdir -p deployment && touch deployment/requirements.yml
  run "${SCRIPT}" deploy_prod.yaml master deployment/requirements.yml ""
  [ "${status}" -eq 0 ]
  grep -q "ansible-galaxy install -r deployment/requirements.yml" "${WORK}/calls.log"
}

@test "bricht ab, wenn die angegebene Requirements-Datei fehlt" {
  run "${SCRIPT}" deploy_prod.yaml master deployment/requirements.yml ""
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"nicht gefunden"* ]]
}

@test "reicht extra-vars als weiteres -e durch" {
  run "${SCRIPT}" deploy_prod.yaml master "" "artack_run_opcache_clear=false"
  [ "${status}" -eq 0 ]
  grep -q -- "-e artack_run_opcache_clear=false" "${WORK}/calls.log"
}

@test "prueft das Ziel, bevor der Server angefasst wird" {
  run "${SCRIPT}" deploy_prod.yaml master "" "" 1 ""
  [ "${status}" -eq 0 ]
  grep -q -- "--list-hosts" "${WORK}/calls.log"
}

@test "check-target 0 ueberspringt die Ziel-Pruefung und warnt" {
  run "${SCRIPT}" deploy_prod.yaml master "" "" 0 ""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Ziel-Pruefung uebersprungen"* ]]
  ! grep -q -- "--list-hosts" "${WORK}/calls.log"
}
