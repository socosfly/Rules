#!/usr/bin/env bash

set -Eeuo pipefail

CONF_FILE="/etc/systemd/resolved.conf"

RESOLVED_RESULT=""
UFW_RESULT=""
RESOLVED_OK=1
UFW_OK=1

log() {
  echo "[$(date '+%F %T')] INFO: $*"
}

error() {
  echo "[$(date '+%F %T')] ERROR: $*" >&2
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

backup_conf() {
  local backup
  backup="${CONF_FILE}.bak.$(date '+%Y%m%d%H%M%S')"
  cp -p "$CONF_FILE" "$backup"
  log "Backup created: $backup"
}

update_config_line() {
  local key="$1"
  local value="$2"
  local desired="${key}=${value}"

  if grep -Eq "^[[:space:]]*${key}=${value}[[:space:]]*$" "$CONF_FILE"; then
    echo "${key} already set to ${value}"
    return 0
  fi

  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}=" "$CONF_FILE"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${desired}|" "$CONF_FILE"
    log "Updated ${key} to ${value}"
  else
    printf '\n%s\n' "$desired" >> "$CONF_FILE"
    log "Added ${desired}"
  fi
}

task_resolved_conf() {
  log "Task 1 started: update $CONF_FILE"

  if [[ ! -f "$CONF_FILE" ]]; then
    echo "Not found: /etc/systemd/resolved.conf"
    RESOLVED_RESULT="FAILED - Not found: /etc/systemd/resolved.conf"
    return 1
  fi

  if ! is_root; then
    echo "Need root privilege"
    RESOLVED_RESULT="FAILED - Need root privilege"
    return 1
  fi

  if ! backup_conf; then
    error "Failed to backup $CONF_FILE"
    RESOLVED_RESULT="FAILED - backup unsuccessful"
    return 1
  fi

  if ! update_config_line "LLMNR" "no"; then
    error "Failed to update LLMNR"
    RESOLVED_RESULT="FAILED - update LLMNR unsuccessful"
    return 1
  fi

  if ! update_config_line "DNSStubListener" "no"; then
    error "Failed to update DNSStubListener"
    RESOLVED_RESULT="FAILED - update DNSStubListener unsuccessful"
    return 1
  fi

  if ! systemctl restart systemd-resolved; then
    echo "Need root privilege"
    RESOLVED_RESULT="FAILED - Need root privilege"
    return 1
  fi

  log "systemd-resolved restarted successfully"
  RESOLVED_RESULT="SUCCESS"
  return 0
}

ufw_rule_exists() {
  ufw status 2>/dev/null | grep -Fq "25/tcp                    DENY OUT"
}

task_ufw_deny_25() {
  log "Task 2 started: deny outbound tcp/25 via ufw"

  if ! command -v ufw >/dev/null 2>&1; then
    echo "ufw not found: Deny SMTP port unsuccessful"
    UFW_RESULT="FAILED - ufw not found: Deny SMTP port unsuccessful"
    return 1
  fi

  if ! is_root; then
    echo "Need root privilege"
    UFW_RESULT="FAILED - Need root privilege"
    return 1
  fi

  if ufw_rule_exists; then
    log "UFW rule for TCP/25 already exists"
    UFW_RESULT="SUCCESS - rule already exists"
    return 0
  fi

  if ! ufw deny out proto tcp to any port 25; then
    echo "Need root privilege"
    UFW_RESULT="FAILED - Need root privilege"
    return 1
  fi

  log "UFW rule added successfully"
  UFW_RESULT="SUCCESS"
  return 0
}

print_summary() {
  echo
  echo "===== Task Results ====="
  echo "Task 1 (Disable DNS on port 53 and 5355): ${RESOLVED_RESULT:-NOT RUN}"
  echo "Task 2 (Deny SMTP on port 25): ${UFW_RESULT:-NOT RUN}"
}

main() {
  if task_resolved_conf; then
    RESOLVED_OK=0
  fi

  if task_ufw_deny_25; then
    UFW_OK=0
  fi

  print_summary

  if [[ $RESOLVED_OK -eq 0 && $UFW_OK -eq 0 ]]; then
    exit 0
  else
    exit 1
  fi
}

main "$@"
