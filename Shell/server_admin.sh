#!/usr/bin/env bash

set -u

SSHD_CONFIG="/etc/ssh/sshd_config"
SUDOERS_DIR="/etc/sudoers.d"

log() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

err() {
    echo "[ERROR] $*" >&2
}

pause() {
    echo
    read -r -p "按回车返回主菜单..." _
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请用 root 运行此脚本。"
        exit 1
    fi
}

detect_os() {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian)
                ;;
            *)
                warn "当前系统识别为: ${ID:-unknown}，脚本按 Debian/Ubuntu 兼容方式继续执行。"
                ;;
        esac
    else
        warn "未找到 /etc/os-release，继续尝试执行。"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    local cmd="$1"
    if ! command_exists "$cmd"; then
        err "缺少命令: $cmd"
        return 1
    fi
    return 0
}

require_file_exists() {
    local file="$1"
    if [[ ! -e "$file" ]]; then
        err "文件不存在: $file"
        return 1
    fi
    return 0
}

require_readable_file() {
    local file="$1"
    if [[ ! -r "$file" ]]; then
        err "文件不可读: $file"
        return 1
    fi
    return 0
}

require_writable_file() {
    local file="$1"
    if [[ ! -w "$file" ]]; then
        err "文件不可写: $file"
        return 1
    fi
    return 0
}

require_writable_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        err "目录不存在: $dir"
        return 1
    fi
    if [[ ! -w "$dir" ]]; then
        err "目录不可写: $dir"
        return 1
    fi
    return 0
}

validate_username() {
    local username="$1"

    if [[ -z "$username" ]]; then
        err "用户名不能为空。"
        return 1
    fi

    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
        err "用户名格式不合法：$username"
        return 1
    fi

    return 0
}

validate_port() {
    local port="$1"

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        err "端口必须是数字。"
        return 1
    fi

    if (( port < 1 || port > 65535 )); then
        err "端口范围必须在 1-65535 之间。"
        return 1
    fi

    return 0
}

get_current_ssh_port() {
    local current_port

    if [[ ! -f "$SSHD_CONFIG" ]]; then
        echo "22"
        return 0
    fi

    current_port="$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]*#.*)?$/ {
            print $2
            exit
        }
    ' "$SSHD_CONFIG")"

    if [[ -z "$current_port" ]]; then
        current_port="22"
    fi

    echo "$current_port"
    return 0
}

backup_file() {
    local src="$1"
    local backup_path="${src}.bak.$(date +%Y%m%d%H%M%S)"

    cp -a "$src" "$backup_path" || {
        err "备份文件失败: $src"
        return 1
    }

    echo "$backup_path"
    return 0
}

restore_file() {
    local backup="$1"
    local target="$2"

    if [[ -f "$backup" ]]; then
        cp -a "$backup" "$target" || {
            err "恢复文件失败: $backup -> $target"
            return 1
        }
        log "已恢复文件: $backup -> $target"
    fi

    return 0
}

configure_sudo_nopasswd() {
    local username="$1"
    local sudoers_file="${SUDOERS_DIR}/90-${username}-nopasswd"
    local tmp_file

    if ! require_command visudo; then
        return 1
    fi

    if ! require_writable_dir "$SUDOERS_DIR"; then
        return 1
    fi

    tmp_file="$(mktemp)"
    if [[ -z "$tmp_file" ]]; then
        err "创建临时文件失败。"
        return 1
    fi

    printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$username" > "$tmp_file"
    chmod 0440 "$tmp_file"

    if ! visudo -cf "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        err "sudoers 规则校验失败，未写入免密 sudo 配置。"
        return 1
    fi

    cp "$tmp_file" "$sudoers_file"
    local cp_rc=$?
    rm -f "$tmp_file"

    if [[ $cp_rc -ne 0 ]]; then
        err "写入 sudoers 文件失败: $sudoers_file"
        return 1
    fi

    chmod 0440 "$sudoers_file"

    if ! visudo -cf "$sudoers_file" >/dev/null 2>&1; then
        rm -f "$sudoers_file"
        err "免密 sudo 配置写入后校验失败，已回滚。"
        return 1
    fi

    log "已配置免密 sudo: $sudoers_file"
    return 0
}

add_new_user() {
    local username password password2

    echo
    read -r -p "请输入新用户名: " username
    if ! validate_username "$username"; then
        pause
        return
    fi

    if id "$username" >/dev/null 2>&1; then
        err "用户已存在: $username"
        pause
        return
    fi

    while true; do
        read -r -s -p "请输入密码: " password
        echo
        if [[ -z "$password" ]]; then
            err "密码不能为空。"
            continue
        fi

        read -r -s -p "请再次输入密码: " password2
        echo

        if [[ "$password" != "$password2" ]]; then
            err "两次输入的密码不一致，请重试。"
            continue
        fi
        break
    done

    require_command useradd || { pause; return; }
    require_command usermod || { pause; return; }
    require_command chpasswd || { pause; return; }

    if ! getent group sudo >/dev/null 2>&1; then
        err "系统中不存在 sudo 组，请确认 sudo 是否已安装。"
        pause
        return
    fi

    if ! require_writable_dir "$SUDOERS_DIR"; then
        pause
        return
    fi

    if ! require_command visudo; then
        pause
        return
    fi

    useradd -m -s /bin/bash "$username"
    if [[ $? -ne 0 ]]; then
        err "创建用户失败。"
        pause
        return
    fi

    echo "${username}:${password}" | chpasswd
    if [[ $? -ne 0 ]]; then
        err "设置密码失败。"
        pause
        return
    fi

    usermod -aG sudo "$username"
    if [[ $? -ne 0 ]]; then
        err "加入 sudo 组失败。"
        pause
        return
    fi

    if configure_sudo_nopasswd "$username"; then
        log "用户创建成功: $username"
        log "已加入 sudo 组，并已配置 sudo 免输入密码。"
    else
        warn "用户已创建并加入 sudo 组，但免密 sudo 配置失败，请手动检查。"
    fi

    pause
    return
}

change_ssh_port() {
    local port current_port confirm tmp_file sshd_backup

    echo
    read -r -p "请输入新的 SSH 端口号: " port
    if ! validate_port "$port"; then
        pause
        return
    fi

    if ! require_file_exists "$SSHD_CONFIG"; then
        pause
        return
    fi

    if ! require_readable_file "$SSHD_CONFIG"; then
        pause
        return
    fi

    if ! require_writable_file "$SSHD_CONFIG"; then
        pause
        return
    fi

    if ! require_command sshd; then
        err "未找到 sshd 命令，无法校验 SSH 配置。"
        pause
        return
    fi

    current_port="$(get_current_ssh_port)"

    echo
    read -r -p "是否要将 SSH 端口从 \"$current_port\" 修改为 \"$port\"？输入 y 确认: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "已取消修改，返回主菜单。"
        pause
        return
    fi

    if [[ "$current_port" == "$port" ]]; then
        log "当前 SSH 端口已经是 $port，无需修改。"
        pause
        return
    fi

    sshd_backup="$(backup_file "$SSHD_CONFIG")"
    if [[ $? -ne 0 || -z "$sshd_backup" ]]; then
        pause
        return
    fi

    tmp_file="$(mktemp)"
    if [[ -z "$tmp_file" ]]; then
        err "创建临时文件失败。"
        pause
        return
    fi

    awk -v new_port="$port" '
        BEGIN { replaced=0 }
        /^[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]*#.*)?$/ && replaced==0 {
            print "Port " new_port
            replaced=1
            next
        }
        { print }
        END {
            if (replaced==0) {
                print ""
                print "Port " new_port
            }
        }
    ' "$SSHD_CONFIG" > "$tmp_file"

    if [[ $? -ne 0 ]]; then
        rm -f "$tmp_file"
        err "修改 SSH 配置失败。"
        pause
        return
    fi

    cat "$tmp_file" > "$SSHD_CONFIG"
    rm -f "$tmp_file"

    if ! sshd -t -f "$SSHD_CONFIG"; then
        err "SSH 配置校验失败，正在恢复原配置。"
        restore_file "$sshd_backup" "$SSHD_CONFIG"
        pause
        return
    fi

    log "SSH 端口修改成功，新端口: $port"
    echo
    echo "请手动重启 SSH 服务使配置生效，例如："
    echo "systemctl restart ssh"
    echo "或"
    echo "systemctl restart sshd"
    echo
    echo "建议执行以下 UFW 命令放行新端口并删除旧规则："
    echo "ufw limit ${port}/tcp comment 'ssh port'"
    echo "ufw delete allow ${current_port}/tcp"
    warn "请先确认新端口已放行，并保持当前会话不断开，再手动重启 SSH 服务。"

    pause
    return
}

add_ssh_key() {
    local username ssh_key user_home user_group ssh_dir auth_keys owner_group

    echo
    read -r -p "请输入用户名: " username
    if ! validate_username "$username"; then
        pause
        return
    fi

    if ! id "$username" >/dev/null 2>&1; then
        err "用户不存在: $username"
        pause
        return
    fi

    user_home="$(getent passwd "$username" | cut -d: -f6)"
    user_group="$(id -gn "$username")"

    if [[ -z "$user_home" ]]; then
        err "无法获取用户家目录: $username"
        pause
        return
    fi

    if [[ ! -d "$user_home" ]]; then
        err "用户家目录不存在: $user_home"
        pause
        return
    fi

    echo "请输入 SSH 公钥，粘贴后按回车："
    read -r ssh_key

    if [[ -z "$ssh_key" ]]; then
        err "SSH 公钥不能为空。"
        pause
        return
    fi

    ssh_dir="${user_home}/.ssh"
    auth_keys="${ssh_dir}/authorized_keys"

    if [[ ! -d "$ssh_dir" ]]; then
        install -d -m 700 -o "$username" -g "$user_group" "$ssh_dir"
        if [[ $? -ne 0 ]]; then
            err "创建目录失败: $ssh_dir"
            pause
            return
        fi
    fi

    chown "$username:$user_group" "$ssh_dir"
    if [[ $? -ne 0 ]]; then
        err "设置目录所有者失败: $ssh_dir"
        pause
        return
    fi

    chmod 700 "$ssh_dir"
    if [[ $? -ne 0 ]]; then
        err "设置目录权限失败: $ssh_dir"
        pause
        return
    fi

    if [[ ! -f "$auth_keys" ]]; then
        if command_exists runuser; then
            runuser -u "$username" -- bash -c "umask 077 && touch '$auth_keys'"
        elif command_exists sudo; then
            sudo -u "$username" bash -c "umask 077 && touch '$auth_keys'"
        else
            touch "$auth_keys"
        fi

        if [[ ! -f "$auth_keys" ]]; then
            err "创建文件失败: $auth_keys"
            pause
            return
        fi
    fi

    chown "$username:$user_group" "$auth_keys"
    if [[ $? -ne 0 ]]; then
        err "设置文件所有者失败: $auth_keys"
        pause
        return
    fi

    chmod 600 "$auth_keys"
    if [[ $? -ne 0 ]]; then
        err "设置文件权限失败: $auth_keys"
        pause
        return
    fi

    if grep -Fxq "$ssh_key" "$auth_keys" 2>/dev/null; then
        log "相同的 SSH 公钥已存在，未重复添加。"
    else
        printf '%s\n' "$ssh_key" >> "$auth_keys"
        if [[ $? -ne 0 ]]; then
            err "写入 SSH 公钥失败。"
            pause
            return
        fi
        log "SSH 公钥已成功添加到: $auth_keys"
    fi

    chown "$username:$user_group" "$auth_keys"
    chmod 600 "$auth_keys"
    chown "$username:$user_group" "$ssh_dir"
    chmod 700 "$ssh_dir"

    owner_group="$(stat -c '%U:%G %a' "$auth_keys" 2>/dev/null)"
    if [[ $? -eq 0 ]]; then
        log "authorized_keys 当前属性: $owner_group"
    fi

    log "已确保文件所有者为用户 $username，且该用户可正常访问 SSH 密钥文件。"

    pause
    return
}

set_timezone_asia_shanghai() {
    local tz="Asia/Shanghai"

    echo

    require_command dpkg-reconfigure || { pause; return; }
    require_file_exists "/usr/share/zoneinfo/${tz}" || { pause; return; }

    if [[ -e /etc/timezone && ! -w /etc/timezone ]]; then
        err "文件不可写: /etc/timezone"
        pause
        return
    fi

    if [[ -e /etc/localtime && ! -w /etc/localtime ]]; then
        if [[ ! -w /etc ]]; then
            err "无法修改 /etc/localtime，/etc 不可写。"
            pause
            return
        fi
    fi

    echo "$tz" > /etc/timezone
    if [[ $? -ne 0 ]]; then
        err "写入 /etc/timezone 失败。"
        pause
        return
    fi

    ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
    if [[ $? -ne 0 ]]; then
        err "更新 /etc/localtime 失败。"
        pause
        return
    fi

    if dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1; then
        log "时区已修改为: ${tz}"
        date
    else
        err "执行 dpkg-reconfigure tzdata 失败。"
    fi

    pause
    return
}

check_other_firewall_conflicts() {
    local conflict_found=0

    echo
    log "开始检查本机是否存在其他已启用的防火墙或现有规则冲突。"

    if command_exists systemctl; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            warn "检测到 firewalld 正在运行。"
            conflict_found=1
        fi

        if systemctl is-active --quiet nftables 2>/dev/null; then
            warn "检测到 nftables 服务正在运行。"
            conflict_found=1
        fi
    fi

    if command_exists nft; then
        if nft list ruleset 2>/dev/null | grep -q '[^[:space:]]'; then
            warn "检测到本机存在 nftables 规则集。"
            conflict_found=1
        fi
    fi

    if command_exists iptables-save; then
        if iptables-save 2>/dev/null | grep -E -q '^-A|^-P'; then
            warn "检测到本机存在 IPv4 iptables 规则。"
            conflict_found=1
        fi
    fi

    if command_exists ip6tables-save; then
        if ip6tables-save 2>/dev/null | grep -E -q '^-A|^-P'; then
            warn "检测到本机存在 IPv6 iptables 规则。"
            conflict_found=1
        fi
    fi

    if [[ "$conflict_found" -eq 1 ]]; then
        warn "检测到其他防火墙服务或现有规则，继续启用 UFW 可能产生冲突。"
        warn "请先确认并清理现有防火墙配置，再重新执行该菜单。"
        return 1
    fi

    log "未检测到其他已启用的防火墙或明显冲突规则。"
    return 0
}

install_and_configure_ufw() {
    local ssh_port ufw_status enable_confirm

    echo

    require_command apt-get || { pause; return; }
    require_command dpkg-query || { pause; return; }

    if ! dpkg-query -W -f='${Status}' ufw 2>/dev/null | grep -q "install ok installed"; then
        log "检测到本机未安装 ufw，开始安装。"

        apt-get update
        if [[ $? -ne 0 ]]; then
            err "apt-get update 执行失败。"
            pause
            return
        fi

        apt-get install -y ufw
        if [[ $? -ne 0 ]]; then
            err "安装 ufw 失败。"
            pause
            return
        fi

        log "ufw 安装成功。"
    else
        log "检测到 ufw 已安装。"
    fi

    require_command ufw || { pause; return; }

    ufw_status="$(ufw status 2>/dev/null | head -n 1)"
    ssh_port="$(get_current_ssh_port)"

    if echo "$ufw_status" | grep -qi "Status: active"; then
        log "UFW 当前已启用。"
        echo "当前 SSH 端口: ${ssh_port}"
        echo "建议确认以下规则存在："
        echo "ufw default allow outgoing"
        echo "ufw default deny incoming"
        echo "ufw limit log ${ssh_port}/tcp comment 'ssh port'"
        pause
        return
    fi

    if ! check_other_firewall_conflicts; then
        pause
        return
    fi

    read -r -p "检测到 UFW 未启用，是否现在启用防火墙？输入 y 确认: " enable_confirm
    if [[ "$enable_confirm" != "y" && "$enable_confirm" != "Y" ]]; then
        log "已取消启用 UFW，返回主菜单。"
        pause
        return
    fi

    log "开始配置 UFW 默认规则。"

    ufw default allow outgoing
    if [[ $? -ne 0 ]]; then
        err "执行 'ufw default allow outgoing' 失败。"
        pause
        return
    fi

    ufw default deny incoming
    if [[ $? -ne 0 ]]; then
        err "执行 'ufw default deny incoming' 失败。"
        pause
        return
    fi

    log "开始放行 SSH 端口: ${ssh_port}"
    ufw limit log "${ssh_port}/tcp" comment 'ssh port'
    if [[ $? -ne 0 ]]; then
        err "执行 'ufw limit log ${ssh_port}/tcp comment '\''ssh port'\''' 失败。"
        pause
        return
    fi

    echo
    warn "即将启用 UFW。请确认当前 SSH 端口 ${ssh_port} 已正确放行，避免断开连接。"
    read -r -p "再次确认启用 UFW？输入 y 确认: " enable_confirm
    if [[ "$enable_confirm" != "y" && "$enable_confirm" != "Y" ]]; then
        log "已取消启用 UFW，当前规则已写入但防火墙未启用。"
        pause
        return
    fi

    ufw --force enable
    if [[ $? -ne 0 ]]; then
        err "启用 UFW 失败。"
        pause
        return
    fi

    log "UFW 已启用。"
    log "默认规则：allow outgoing / deny incoming"
    log "已放行 SSH 端口：${ssh_port}"

    pause
    return
}

show_local_ip_addresses() {
    local ipv4_list ipv6_list

    echo
    log "本机 IP 地址如下："
    echo

    ipv4_list="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2 "  " $4}')"
    ipv6_list="$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $2 "  " $4}' | grep -v '::1' || true)"

    echo "IPv4 地址："
    if [[ -n "$ipv4_list" ]]; then
        echo "$ipv4_list"
    else
        echo "未发现非回环 IPv4 地址"
    fi

    echo
    echo "IPv6 地址："
    if [[ -n "$ipv6_list" ]]; then
        echo "$ipv6_list"
    else
        echo "未发现非回环 IPv6 地址"
    fi

    pause
    return
}

show_ip_priority() {
    local default_ip ipv4_ip ipv6_ip
    local default_family="未知"

    echo

    require_command curl || { pause; return; }

    default_ip="$(curl -s --connect-timeout 5 --max-time 8 ip.p3terx.com 2>/dev/null || true)"
    ipv4_ip="$(curl -4 -s --connect-timeout 5 --max-time 8 ip.p3terx.com 2>/dev/null || true)"
    ipv6_ip="$(curl -6 -s --connect-timeout 5 --max-time 8 ip.p3terx.com 2>/dev/null || true)"

    echo "外网出口探测结果："
    echo

    if [[ -n "$default_ip" ]]; then
        if [[ "$default_ip" == *:* ]]; then
            default_family="IPv6"
        elif [[ "$default_ip" == *.* ]]; then
            default_family="IPv4"
        fi

        echo "默认优先出口地址: $default_ip"
        echo "默认优先协议: $default_family"
        echo
    else
        echo "默认优先出口地址: 未检测到"
        echo
    fi

    if [[ -n "$ipv4_ip" ]]; then
        echo "IPv4 出口地址: $ipv4_ip"
    else
        echo "IPv4 出口地址: 未检测到"
    fi

    if [[ -n "$ipv6_ip" ]]; then
        echo "IPv6 出口地址: $ipv6_ip"
    else
        echo "IPv6 出口地址: 未检测到"
    fi

    echo

    if [[ -n "$default_ip" ]]; then
        log "当前访问外部互联网默认优先使用 ${default_family}。"
    else
        warn "无法通过 curl ip.p3terx.com 探测默认外网出口。"
    fi

    pause
    return
}

ip_management_menu() {
    local subchoice

    while true; do
        clear
        cat <<'EOF'
==============================
         IP地址管理
==============================
1. 本机IP地址
2. IPv4和IPv6优先及出口地址
0. 返回主菜单
==============================
EOF

        read -r -p "请选择功能: " subchoice

        case "$subchoice" in
            1)
                show_local_ip_addresses
                ;;
            2)
                show_ip_priority
                ;;
            0)
                return
                ;;
            *)
                err "无效选择，请重新输入。"
                pause
                ;;
        esac
    done
}

show_menu() {
    clear
    cat <<'EOF'
==============================
        VPS初始化配置
==============================
1. 增加新用户
2. 修改 SSH 端口
3. 增加 SSH 密钥
4. 修改时区为 Asia/Shanghai
5. 安装/配置 UFW 防火墙
6. IP地址管理
0. 退出
==============================
EOF
}

main() {
    local choice

    require_root
    detect_os

    require_command useradd || exit 1
    require_command usermod || exit 1
    require_command chpasswd || exit 1
    require_command getent || exit 1
    require_command awk || exit 1
    require_command grep || exit 1
    require_command cp || exit 1
    require_command chmod || exit 1
    require_command chown || exit 1
    require_command install || exit 1
    require_command mktemp || exit 1
    require_command id || exit 1
    require_command cut || exit 1
    require_command head || exit 1
    require_command apt-get || exit 1
    require_command dpkg-query || exit 1
    require_command dpkg-reconfigure || exit 1
    require_command ip || exit 1

    while true; do
        show_menu
        read -r -p "请选择功能: " choice

        case "$choice" in
            1)
                add_new_user
                ;;
            2)
                change_ssh_port
                ;;
            3)
                add_ssh_key
                ;;
            4)
                set_timezone_asia_shanghai
                ;;
            5)
                install_and_configure_ufw
                ;;
            6)
                ip_management_menu
                ;;
            0)
                log "已退出。"
                exit 0
                ;;
            *)
                err "无效选择，请重新输入。"
                pause
                ;;
        esac
    done
}

main
