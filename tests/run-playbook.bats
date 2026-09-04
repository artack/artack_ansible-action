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
EOF
  cat > "${STUBS}/ansible-galaxy" <<'EOF'
#!/usr/bin/env bash
echo "ansible-galaxy $*" >> "${WORK}/calls.log"
cp "${3}" "${WORK}/requirements.used"
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
  tail -1 "${WORK}/calls.log" | grep -q -- "-e git_branch=release/1.2.3"
}

@test "prueft die Syntax, bevor der Server angefasst wird" {
  run "${SCRIPT}" deploy_prod.yaml master "" ""
  [ "${status}" -eq 0 ]
  grep "ansible-playbook" "${WORK}/calls.log" | head -1 | grep -q -- "--syntax-check"
  tail -1 "${WORK}/calls.log" | grep -qv -- "--syntax-check"
}

@test "setzt kein git_branch, wenn kein Ref uebergeben wird" {
  run "${SCRIPT}" deploy_prod.yaml "" "" ""
  [ "${status}" -eq 0 ]
  ! grep -q -- "git_branch" "${WORK}/calls.log"
}

@test "reicht extra-vars als weiteres -e durch" {
  run "${SCRIPT}" deploy_prod.yaml master "" "artack_run_opcache_clear=false"
  [ "${status}" -eq 0 ]
  tail -1 "${WORK}/calls.log" | grep -q -- "-e artack_run_opcache_clear=false"
}

@test "installiert ohne Angabe die eingebauten, gepinnten Rollen-Versionen" {
  run "${SCRIPT}" deploy_prod.yaml master "" ""
  [ "${status}" -eq 0 ]
  grep -q "version: 4.0.1" "${WORK}/requirements.used"
  grep -q "cbrunnkvist.ansistrano-symfony-deploy" "${WORK}/requirements.used"
}

@test "der Inline-Override gewinnt gegen die eingebauten Versionen" {
  export ARTACK_GALAXY_REQUIREMENTS_INLINE="- src: ansistrano.deploy
  version: 9.9.9"
  run "${SCRIPT}" deploy_prod.yaml master "" ""
  [ "${status}" -eq 0 ]
  grep -q "version: 9.9.9" "${WORK}/requirements.used"
  ! grep -q "version: 4.0.1" "${WORK}/requirements.used"
}

@test "eine angegebene Requirements-Datei wird benutzt und gewarnt" {
  printf -- "- src: ansistrano.deploy\n" > eigene.yml
  run "${SCRIPT}" deploy_prod.yaml master eigene.yml ""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"pinnt vermutlich keine Versionen"* ]]
}

@test "bricht ab, wenn die angegebene Requirements-Datei fehlt" {
  run "${SCRIPT}" deploy_prod.yaml master fehlt.yml ""
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"nicht gefunden"* ]]
}

@test "leitet das Arbeitsverzeichnis aus dem Playbook-Pfad ab" {
  mkdir -p unterordner
  : > unterordner/deploy_stag.yaml
  run "${SCRIPT}" unterordner/deploy_stag.yaml master "" ""
  [ "${status}" -eq 0 ]
  # Aufgerufen wird der Basename, nicht der Pfad - das Verzeichnis ist gewechselt.
  tail -1 "${WORK}/calls.log" | grep -q "ansible-playbook deploy_stag.yaml"
  ! grep -q "unterordner/deploy_stag.yaml" "${WORK}/calls.log"
}

@test "leitet fuer ein Playbook im Wurzelverzeichnis auf . ab" {
  run "${SCRIPT}" deploy_prod.yaml master "" ""
  [ "${status}" -eq 0 ]
  tail -1 "${WORK}/calls.log" | grep -q "ansible-playbook deploy_prod.yaml"
}

@test "leitet Agent-Forwarding an, damit der Server selbst klonen kann" {
  cat > "${STUBS}/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
echo "${ANSIBLE_SSH_COMMON_ARGS}" >> "${WORK}/env.log"
EOF
  chmod +x "${STUBS}/ansible-playbook"
  run "${SCRIPT}" deploy_prod.yaml master "" ""
  [ "${status}" -eq 0 ]
  grep -q "ForwardAgent=yes" "${WORK}/env.log"
  grep -q "StrictHostKeyChecking=yes" "${WORK}/env.log"
}
