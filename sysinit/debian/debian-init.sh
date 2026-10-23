#!/bin/bash
# Debian system initialization script (idempotent)
#
# Ported from ansible-controls/playbooks/basics.yml. See CODEBUDDY.md for the
# list of source tasks that are intentionally NOT ported to this script.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# install_static_file <target> <content> <owner> <mode>
# Writes <content> to <target> only if it differs. Returns 0 if unchanged,
# 1 if the file was written/updated.
install_static_file() {
    local target="$1"
    local content="$2"
    local owner="$3"
    local mode="$4"
    local tmp

    tmp="$(mktemp)"
    printf '%s' "$content" > "$tmp"

    if [[ -f "$target" ]] && diff -q "$target" "$tmp" > /dev/null 2>&1; then
        rm -f "$tmp"
        return 0
    fi

    mv "$tmp" "$target"
    chown "$owner" "$target"
    chmod "$mode" "$target"
    return 1
}

configure_timezone() {
    log_info "Configuring timezone..."
    local target_timezone="Asia/Singapore"
    local current_timezone

    current_timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "")

    if [[ "$current_timezone" == "$target_timezone" ]]; then
        log_info "Timezone already set to $target_timezone, skipping"
        return 0
    fi

    if command -v timedatectl &> /dev/null; then
        timedatectl set-timezone "$target_timezone"
    else
        ln -sf "/usr/share/zoneinfo/$target_timezone" /etc/localtime
        echo "$target_timezone" > /etc/timezone
    fi

    log_info "Timezone set to $target_timezone"
}

configure_apt() {
    log_info "Configuring apt mirrors and sources..."
    local mirrors_dir="/etc/apt/mirrors"
    local sources_file="/etc/apt/sources.list.d/debian.sources"
    local debian_list="$mirrors_dir/debian.list"
    local debian_sec_list="$mirrors_dir/debian-security.list"
    local changed=false

    if [[ ! -d "$mirrors_dir" ]]; then
        mkdir -p "$mirrors_dir"
        chown root:root "$mirrors_dir"
        chmod 0755 "$mirrors_dir"
        changed=true
    fi

    local debian_sources_content
    read -r -d '' debian_sources_content <<'EOF'
Types: deb deb-src
URIs: mirror+file:///etc/apt/mirrors/debian.list
Suites: trixie trixie-updates trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: mirror+file:///etc/apt/mirrors/debian-security.list
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    local debian_list_content
    read -r -d '' debian_list_content <<'EOF'
https://mirrors.tuna.tsinghua.edu.cn/debian
https://mirrors.ustc.edu.cn/debian
EOF

    local debian_sec_list_content
    read -r -d '' debian_sec_list_content <<'EOF'
https://deb.debian.org/debian-security
EOF

    if install_static_file "$debian_list" "$debian_list_content" root:root 0644; then
        log_info "apt mirror list unchanged, skipping"
    else
        log_info "apt mirror list updated"
        changed=true
    fi

    if install_static_file "$debian_sec_list" "$debian_sec_list_content" root:root 0644; then
        log_info "apt security mirror list unchanged, skipping"
    else
        log_info "apt security mirror list updated"
        changed=true
    fi

    if install_static_file "$sources_file" "$debian_sources_content" root:root 0644; then
        log_info "apt sources unchanged, skipping"
    else
        log_info "apt sources updated"
        changed=true
    fi

    if [[ "$changed" == false ]]; then
        log_info "apt mirrors and sources already in target state, skipping"
    else
        log_info "apt mirrors and sources configured (run 'apt-get update' to fetch)"
    fi
}

configure_ssh() {
    log_info "Configuring SSH server (drop-in)..."
    local dropin_dir="/etc/ssh/sshd_config.d"
    local sshd_config="/etc/ssh/sshd_config"
    local dropin_file="$dropin_dir/03-mira.conf"
    local changed=false
    local include_backup=""

    if [[ ! -d "$dropin_dir" ]]; then
        mkdir -p "$dropin_dir"
        chown root:root "$dropin_dir"
        chmod 0755 "$dropin_dir"
        changed=true
    fi

    if ! grep -qE '^Include /etc/ssh/sshd_config\.d/\*\.conf' "$sshd_config"; then
        include_backup="${sshd_config}.bak.$(date +%s)"
        cp "$sshd_config" "$include_backup"
        printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> "$sshd_config"
        changed=true
    fi

    local mira_conf_content
    read -r -d '' mira_conf_content <<'EOF'
# Managed by scripts — sysinit/debian/debian-init.sh
# Root may only log in via SSH keys; password / keyboard-interactive auth are disabled.
# Loaded via `Include /etc/ssh/sshd_config.d/*.conf` in sshd_config.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers root
AuthenticationMethods publickey
GSSAPIAuthentication no
EOF

    if install_static_file "$dropin_file" "$mira_conf_content" root:root 0644; then
        log_info "03-mira.conf unchanged, skipping"
    else
        log_info "03-mira.conf deployed"
        changed=true
    fi

    for f in 50-cloud-init.conf 99-cloud-init-allow-root-pw.conf; do
        if [[ -f "$dropin_dir/$f" ]]; then
            rm -f "$dropin_dir/$f"
            log_info "Removed cloud-init sshd drop-in $f"
            changed=true
        fi
    done

    if [[ "$changed" == false ]]; then
        log_info "SSH already in target state, skipping reload"
        return 0
    fi

    if sshd -t; then
        systemctl reload ssh
        log_info "sshd reloaded"
    else
        log_error "SSH config validation failed"
        if [[ -n "$include_backup" && -f "$include_backup" ]]; then
            log_error "Restoring $sshd_config from backup"
            cp "$include_backup" "$sshd_config"
        fi
        exit 1
    fi
}

remove_debian_user() {
    if id -u debian > /dev/null 2>&1; then
        userdel -r debian 2>/dev/null || userdel debian
        log_info "Removed debian user"
    else
        log_info "debian user absent, skipping"
    fi
}

configure_locale() {
    log_info "Configuring locale..."
    local target_lc_time="en_DK.UTF-8"

    if ! locale -a | grep -q "en_DK.utf8"; then
        if [[ -f /etc/locale.gen ]]; then
            sed -i 's/^# *en_DK.UTF-8 UTF-8/en_DK.UTF-8 UTF-8/' /etc/locale.gen
            if ! grep -q "^en_DK.UTF-8 UTF-8" /etc/locale.gen; then
                echo "en_DK.UTF-8 UTF-8" >> /etc/locale.gen
            fi
            locale-gen
        fi
    fi

    if [[ -f /etc/default/locale ]] && grep -qE "^LC_TIME=$target_lc_time" /etc/default/locale; then
        log_info "LC_TIME already configured, skipping"
        return 0
    fi

    if command -v update-locale &> /dev/null; then
        update-locale LC_TIME="$target_lc_time"
        log_info "LC_TIME configured to $target_lc_time"
    else
        if [[ -f /etc/default/locale ]]; then
            if grep -qE "^LC_TIME=" /etc/default/locale; then
                sed -i "s/^LC_TIME=.*/LC_TIME=\"$target_lc_time\"/" /etc/default/locale
            else
                echo "LC_TIME=\"$target_lc_time\"" >> /etc/default/locale
            fi
        else
            echo "LC_TIME=\"$target_lc_time\"" > /etc/default/locale
        fi
    fi
}

configure_environment() {
    log_info "Configuring /etc/environment defaults..."
    local target="/etc/environment"
    local vars=(
        "EDITOR=/usr/bin/vim"
        "VISUAL=/usr/bin/vim"
        "SYSTEMD_LESS=FRMK"
        "LESS=RMK"
    )
    local key value

    touch "$target" 2>/dev/null || { log_warn "Cannot write $target, skipping"; return; }

    for kv in "${vars[@]}"; do
        key="${kv%%=*}"
        if grep -qE "^${key}=" "$target"; then
            if ! grep -qxF "$kv" "$target"; then
                sed -i "s|^${key}=.*|${kv}|" "$target"
                log_info "Updated $key in $target"
            fi
        else
            echo "$kv" >> "$target"
            log_info "Added $key to $target"
        fi
    done
}

download_bashrc() {
    log_info "Downloading bash.bashrc..."
    local target_file="/etc/bash.bashrc"
    local source_url="https://raw.githubusercontent.com/windypaddy/scripts/refs/heads/main/shell/bash.bashrc"
    local temp_file="/tmp/bash.bashrc.$$"

    if ! wget -q -O "$temp_file" "$source_url"; then
        log_error "Failed to download bash.bashrc"
        rm -f "$temp_file"
        exit 1
    fi

    if [[ ! -s "$temp_file" ]]; then
        log_error "Downloaded file is empty"
        rm -f "$temp_file"
        exit 1
    fi

    if [[ -f "$target_file" ]] && diff -q "$target_file" "$temp_file" > /dev/null 2>&1; then
        log_info "bash.bashrc content unchanged, skipping"
        rm -f "$temp_file"
        return 0
    fi

    mv "$temp_file" "$target_file"
    chmod 644 "$target_file"
    log_info "bash.bashrc updated"
}

main() {
    log_info "Starting Debian system initialization..."
    echo "========================================"

    check_root

    download_bashrc
    configure_timezone
    configure_apt
    configure_ssh
    remove_debian_user
    configure_locale
    configure_environment

    echo "========================================"
    log_info "Debian system initialization completed"
    log_warn "Note: LC_TIME and /etc/environment changes require re-login to take effect"
}

main "$@"
