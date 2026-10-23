#!/bin/bash
# Debian system initialization script (idempotent)

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

configure_ssh() {
    log_info "Configuring SSH server..."
    local sshd_config="/etc/ssh/sshd_config"
    local backup="${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"

    if [[ ! -f "${sshd_config}.original" ]]; then
        cp "$sshd_config" "${sshd_config}.original"
    fi

    local need_change=false

    if grep -qE "^#?PermitRootLogin" "$sshd_config"; then
        if ! grep -qE "^PermitRootLogin\s+yes" "$sshd_config"; then
            need_change=true
        fi
    else
        need_change=true
    fi

    if grep -qE "^#?PasswordAuthentication" "$sshd_config"; then
        if ! grep -qE "^PasswordAuthentication\s+no" "$sshd_config"; then
            need_change=true
        fi
    else
        need_change=true
    fi

    if [[ "$need_change" == false ]]; then
        log_info "SSH config already in target state, skipping"
        return 0
    fi

    cp "$sshd_config" "$backup"

    if grep -qE "^#?PermitRootLogin" "$sshd_config"; then
        sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin yes/' "$sshd_config"
    else
        echo "PermitRootLogin yes" >> "$sshd_config"
    fi

    if grep -qE "^#?PasswordAuthentication" "$sshd_config"; then
        sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config"
    else
        echo "PasswordAuthentication no" >> "$sshd_config"
    fi

    if sshd -t; then
        log_info "SSH config validated"
        systemctl restart sshd
        log_info "SSH service restarted"
    else
        log_error "SSH config validation failed, restoring backup"
        cp "$backup" "$sshd_config"
        exit 1
    fi
}

configure_timezone() {
    log_info "Configuring timezone..."
    local target_timezone="Asia/Hong_Kong"
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

    if [[ -f /etc/default/locale ]]; then
        if grep -qE "^LC_TIME=$target_lc_time" /etc/default/locale; then
            log_info "LC_TIME already configured, skipping"
            return 0
        fi
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

    configure_ssh
    configure_timezone
    configure_locale
    download_bashrc

    echo "========================================"
    log_info "Debian system initialization completed"
    log_warn "Note: LC_TIME changes require re-login to take effect"
}

main "$@"