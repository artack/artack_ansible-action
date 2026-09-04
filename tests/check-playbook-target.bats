#!/usr/bin/env bats
#
# Die Ziel-Pruefung ist die Zusicherung, dass ein Playbook auf genau die
# Umgebung zeigt, die es treffen soll. Die Faelle hier sind aus den echten
# Projekten abgeleitet (Befunde vom 2026-09-04).

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/check-playbook-target.sh"
  WORK="$(mktemp -d)"
  STUBS="${WORK}/bin"
  mkdir -p "${STUBS}"
  cd "${WORK}"

  # Stub loest die Hosts auf, die als HOSTS-Umgebungsvariable gesetzt sind -
  # so lassen sich "hosts: all" und ein gerichtetes Playbook nachbilden.
  cat > "${STUBS}/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
playbook="$1"
var="HOSTS_${playbook//[^a-zA-Z0-9]/_}"
hosts="${!var:-btc-prod}"
count="$(echo ${hosts} | wc -w | tr -d ' ')"
printf '  play #1 (x): x\n    pattern: [x]\n    hosts (%s):\n' "${count}"
for h in ${hosts}; do printf '      %s\n' "${h}"; done
EOF
  chmod +x "${STUBS}"/*
  export PATH="${STUBS}:${PATH}"
}

teardown() { rm -rf "${WORK}"; }

playbook_with() { printf '    ansistrano_deploy_to: "%s"\n' "$2" > "$1"; }

@test "OK, wenn Rollback und Deploy auf dasselbe Ziel zeigen" {
  playbook_with deploy_prod.yaml '~/public_html'
  playbook_with rollback_prod.yaml '~/public_html'
  run "${SCRIPT}" rollback_prod.yaml
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"OK"* ]]
}

@test "Abbruch beim dist-Platzhalter /var/www/my-app (Fall btc, website)" {
  playbook_with deploy_prod.yaml '~/public_html'
  playbook_with rollback_prod.yaml '/var/www/my-app'
  run "${SCRIPT}" rollback_prod.yaml
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist-Platzhalter"* ]]
}

@test "Abbruch, wenn das Playbook mehr als eine Umgebung trifft (Fall hosts: all)" {
  playbook_with deploy_prod.yaml '~/public_html'
  playbook_with rollback_prod.yaml '~/public_html'
  export HOSTS_rollback_prod_yaml="btc-prod btc-stag"
  run "${SCRIPT}" rollback_prod.yaml
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"trifft 2 Hosts"* ]]
}

@test "Abbruch bei Pfad-Abweichung (Fall metaapp_legacy)" {
  playbook_with deploy_prod.yaml '/home/www-metaapp-prod/public_html'
  playbook_with rollback_prod.yaml '/home/www-metaapp-prod/www'
  run "${SCRIPT}" rollback_prod.yaml
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Pfad-Abweichung"* ]]
}

@test "Abbruch bei Host-Abweichung" {
  playbook_with deploy_prod.yaml '~/public_html'
  playbook_with rollback_prod.yaml '~/public_html'
  export HOSTS_rollback_prod_yaml="btc-stag"
  run "${SCRIPT}" rollback_prod.yaml
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Host-Abweichung"* ]]
}

@test "Abbruch, wenn das Referenz-Playbook fehlt" {
  playbook_with rollback_prod.yaml '~/public_html'
  run "${SCRIPT}" rollback_prod.yaml
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Referenz-Playbook"* ]]
}

@test "Deploy-Playbook braucht keine Referenz" {
  playbook_with deploy_prod.yaml '~/public_html'
  run "${SCRIPT}" deploy_prod.yaml
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Keine Referenz noetig"* ]]
}

@test "Abbruch, wenn ansistrano_deploy_to fehlt" {
  : > deploy_prod.yaml
  run "${SCRIPT}" deploy_prod.yaml
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"kein ansistrano_deploy_to"* ]]
}
