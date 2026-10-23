#!/bin/bash
# macOS system initialization script (idempotent)

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

download_zshrc() {
    log_info "Downloading .zshrc..."
    local target_file="$HOME/.zshrc"
    local source_url="https://raw.githubusercontent.com/windypaddy/scripts/refs/heads/main/shell/zsh.zshrc"
    local temp_file="/tmp/.zshrc.$$"

    if ! wget -q -O "$temp_file" "$source_url"; then
        log_error "Failed to download .zshrc"
        rm -f "$temp_file"
        exit 1
    fi

    if [[ ! -s "$temp_file" ]]; then
        log_error "Downloaded file is empty"
        rm -f "$temp_file"
        exit 1
    fi

    if [[ -f "$target_file" ]] && diff -q "$target_file" "$temp_file" > /dev/null 2>&1; then
        log_info ".zshrc content unchanged, skipping"
        rm -f "$temp_file"
        return 0
    fi

    mv "$temp_file" "$target_file"
    log_info ".zshrc updated"
}

main() {
    log_info "Starting macOS system initialization..."
    echo "========================================"

    download_zshrc

    echo "========================================"
    log_info "macOS system initialization completed"
    log_warn "Note: Run 'source ~/.zshrc' or restart terminal to apply changes"
}

main "$@"