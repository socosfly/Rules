#!/usr/bin/env bash

set -Eeuo pipefail

CONF_FILE="/etc/systemd/resolved.conf"

DNS_SELECTED=0
LLMNR_SELECTED=0
UFW_SELECTED=0

DNS_RESULT="已跳过 - 用户未选择"
LLMNR_RESULT="已跳过 - 用户未选择"
UFW_RESULT="已跳过 - 用户未选择"

log() {
  echo "[$(date '+%F %T')] 信息: $*"
}

error() {
  echo "[$(date '+%F %T')] 错误: $*" >&2
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

backup_conf() {
  local backup
  backup="${CONF_FILE}.bak.$(date '+%Y%m%d%H%M%S')"
  cp -p "$CONF_FILE" "$backup"
  log "已创建备份: $backup"
}

config_line_already_set() {
  local key="$1"
  local value="$2"
  grep -Eq "^[[:space:]]*${key}=${value}[[:space:]]*$" "$CONF_FILE"
}

update_config_line() {
  local key="$1"
  local value="$2"
  local desired="${key}=${value}"

  if config_line_already_set "$key" "$value"; then
    echo "${key} 已经设置为 ${value}"
    return 2
  fi

  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}=" "$CONF_FILE"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${desired}|" "$CONF_FILE"
    log "已更新 ${key} 为 ${value}"
  else
    printf '\n%s\n' "$desired" >> "$CONF_FILE"
    log "已添加 ${desired}"
  fi

  return 0
}

restart_resolved_service() {
  if ! systemctl restart systemd-resolved; then
    error "重启 systemd-resolved 失败"
    return 1
  fi
  log "systemd-resolved 重启成功"
  return 0
}

ufw_rule_exists() {
  ufw status 2>/dev/null | grep -Eq '25/tcp[[:space:]]+DENY OUT'
}

show_menu() {
  echo "=============================="
  echo "       系统配置任务菜单"
  echo "=============================="
  echo "1. 设置 DNSStubListener=no"
  echo "2. 设置 LLMNR=no"
  echo "3. 封禁 UFW 出站 SMTP 25 端口"
  echo "=============================="
  echo "请输入要执行的编号，可多选，用空格分隔"
  echo "例如: 1 3"
  echo "输入 all 表示全部执行"
  echo "直接回车表示全部跳过"
  echo "=============================="
}

select_tasks() {
  local input item

  show_menu
  read -r -p "请选择: " input

  if [[ -z "${input// }" ]]; then
    return 0
  fi

  if [[ "$input" == "all" || "$input" == "ALL" ]]; then
    DNS_SELECTED=1
    LLMNR_SELECTED=1
    UFW_SELECTED=1
    DNS_RESULT="等待执行"
    LLMNR_RESULT="等待执行"
    UFW_RESULT="等待执行"
    return 0
  fi

  for item in $input; do
    case "$item" in
      1)
        DNS_SELECTED=1
        DNS_RESULT="等待执行"
        ;;
      2)
        LLMNR_SELECTED=1
        LLMNR_RESULT="等待执行"
        ;;
      3)
        UFW_SELECTED=1
        UFW_RESULT="等待执行"
        ;;
      *)
        echo "无效选项: $item，已忽略"
        ;;
    esac
  done
}

execute_resolved_tasks() {
  local changed=0
  local need_backup=0

  if [[ $DNS_SELECTED -eq 0 && $LLMNR_SELECTED -eq 0 ]]; then
    return 0
  fi

  log "开始检查 systemd-resolved 相关任务"

  if [[ ! -f "$CONF_FILE" ]]; then
    [[ $DNS_SELECTED -eq 1 ]] && DNS_RESULT="执行失败 - 未找到: /etc/systemd/resolved.conf"
    [[ $LLMNR_SELECTED -eq 1 ]] && LLMNR_RESULT="执行失败 - 未找到: /etc/systemd/resolved.conf"
    return 1
  fi

  if ! is_root; then
    [[ $DNS_SELECTED -eq 1 ]] && DNS_RESULT="执行失败 - 需要 root 权限"
    [[ $LLMNR_SELECTED -eq 1 ]] && LLMNR_RESULT="执行失败 - 需要 root 权限"
    return 1
  fi

  if [[ $DNS_SELECTED -eq 1 ]]; then
    if config_line_already_set "DNSStubListener" "no"; then
      DNS_RESULT="无需执行"
    else
      need_backup=1
    fi
  fi

  if [[ $LLMNR_SELECTED -eq 1 ]]; then
    if config_line_already_set "LLMNR" "no"; then
      LLMNR_RESULT="无需执行"
    else
      need_backup=1
    fi
  fi

  if [[ $need_backup -eq 1 ]]; then
    if ! backup_conf; then
      [[ $DNS_SELECTED -eq 1 && "$DNS_RESULT" == "等待执行" ]] && DNS_RESULT="执行失败 - 备份失败"
      [[ $LLMNR_SELECTED -eq 1 && "$LLMNR_RESULT" == "等待执行" ]] && LLMNR_RESULT="执行失败 - 备份失败"
      return 1
    fi
  fi

  if [[ $DNS_SELECTED -eq 1 && "$DNS_RESULT" == "等待执行" ]]; then
    if update_config_line "DNSStubListener" "no"; then
      DNS_RESULT="执行成功"
      changed=1
    else
      rc=$?
      if [[ $rc -eq 2 ]]; then
        DNS_RESULT="无需执行"
      else
        DNS_RESULT="执行失败 - 更新 DNSStubListener 失败"
      fi
    fi
  fi

  if [[ $LLMNR_SELECTED -eq 1 && "$LLMNR_RESULT" == "等待执行" ]]; then
    if update_config_line "LLMNR" "no"; then
      LLMNR_RESULT="执行成功"
      changed=1
    else
      rc=$?
      if [[ $rc -eq 2 ]]; then
        LLMNR_RESULT="无需执行"
      else
        LLMNR_RESULT="执行失败 - 更新 LLMNR 失败"
      fi
    fi
  fi

  if [[ $changed -eq 1 ]]; then
    if ! restart_resolved_service; then
      [[ "$DNS_RESULT" == "执行成功" ]] && DNS_RESULT="执行失败 - 重启 systemd-resolved 失败"
      [[ "$LLMNR_RESULT" == "执行成功" ]] && LLMNR_RESULT="执行失败 - 重启 systemd-resolved 失败"
      return 1
    fi
  fi

  return 0
}

execute_ufw_task() {
  if [[ $UFW_SELECTED -eq 0 ]]; then
    return 0
  fi

  log "开始检查 UFW 任务"

  if ! command -v ufw >/dev/null 2>&1; then
    UFW_RESULT="执行失败 - 未安装 ufw，无法封禁 SMTP 25 端口"
    return 1
  fi

  if ! is_root; then
    UFW_RESULT="执行失败 - 需要 root 权限"
    return 1
  fi

  if ufw_rule_exists; then
    UFW_RESULT="无需执行"
    return 0
  fi

  if ! ufw deny out proto tcp to any port 25; then
    error "添加 UFW 25 端口出站封禁规则失败"
    UFW_RESULT="执行失败 - 封禁 SMTP 25 端口失败"
    return 1
  fi

  log "已成功添加 UFW 25 端口出站封禁规则"
  UFW_RESULT="执行成功"
  return 0
}

print_summary() {
  echo
  echo "=============================="
  echo "          执行结果"
  echo "=============================="
  echo "任务1（设置 DNSStubListener=no）: ${DNS_RESULT}"
  echo "任务2（设置 LLMNR=no）: ${LLMNR_RESULT}"
  echo "任务3（封禁 UFW 出站 SMTP 25 端口）: ${UFW_RESULT}"
  echo "=============================="
}

main() {
  select_tasks

  echo
  echo "=============================="
  echo "          开始执行"
  echo "=============================="

  execute_resolved_tasks || true
  execute_ufw_task || true

  print_summary

  if [[ "$DNS_RESULT" =~ ^(执行成功|无需执行|已跳过) ]] && \
     [[ "$LLMNR_RESULT" =~ ^(执行成功|无需执行|已跳过) ]] && \
     [[ "$UFW_RESULT" =~ ^(执行成功|无需执行|已跳过) ]]; then
    exit 0
  else
    exit 1
  fi
}

main "$@"
