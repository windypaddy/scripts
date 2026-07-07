# ~/.zshrc - Zsh configuration for macOS
# Based on bash.bashrc, adapted for zsh on macOS

# If not running interactively, don't do anything
[[ -o interactive ]] || return

# Enable colors in zsh
autoload -U colors && colors

# Set window title for terminal emulators
case "$TERM" in
xterm*|rxvt*|screen*|tmux*)
    precmd() { print -Pn "\e]0;%n@%m: %~\a" }
    ;;
esac

# Initialize zsh completion system
autoload -Uz compinit && compinit

# Enable menu-driven completion
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# Command not found handler for macOS (Homebrew)
if command -v brew &>/dev/null; then
    if [[ -f "$(brew --prefix)/etc/profile.d/command-not-found-init" ]]; then
        source "$(brew --prefix)/etc/profile.d/command-not-found-init"
    fi
fi

# Prompt configuration
PROMPT='%F{green}%n@%m%f:%F{blue}%~%f%# '

# History configuration
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_FIND_NO_DUPS
setopt SHARE_HISTORY
setopt APPEND_HISTORY
setopt INC_APPEND_HISTORY

# History timestamp format
alias history='fc -il 1'

# Key bindings - history search (like bash.bashrc)
bindkey '\e[A' history-beginning-search-backward
bindkey '\e[B' history-beginning-search-forward
bindkey '^[[A' history-beginning-search-backward
bindkey '^[[B' history-beginning-search-forward

# Alias for ls (macOS uses -G for color, not --color)
# If GNU coreutils is installed (gls), use that for --color support
if command -v gls &>/dev/null; then
    alias ll='gls -Fl --color=auto --time-style=long-iso'
    alias ls='gls --color=auto'
else
    # macOS native ls: use -D for ISO-style time format
    alias ll='ls -FlG -D "%Y-%m-%d %H:%M"'
    alias ls='ls -G'
fi

# Safety aliases
alias rm='rm -i'
alias mv='mv -i'
alias cp='cp -i'

# cdll function - cd and ls
function cdll() {
    local DIR="${*:-$HOME}"
    builtin cd "${DIR}" && ll
}

# mkcd function - mkdir and cd
function mkcd() {
    if [[ $# -ge 1 ]]; then
        mkdir -p "$1" && cd "$1"
    fi
}

# Additional useful zsh options
setopt AUTO_CD              # cd by typing directory name alone
setopt AUTO_PUSHD           # push old directory to stack
setopt PUSHD_IGNORE_DUPS    # don't push duplicates
setopt CORRECT              # command auto-correction

# Enable edit-command-line (Ctrl+X Ctrl+E to edit command in $EDITOR)
autoload -z edit-command-line
zle -N edit-command-line
bindkey '^X^E' edit-command-line