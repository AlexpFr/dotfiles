#!/bin/bash

# /etc/profile.d/custom_prompt.sh
# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias vi='vim'
alias grep='grep --color=auto'
alias df='df -h'
alias dud='du -h */'
alias du='du -hs'
alias ping='ping -c 5'
alias ..='cd ..'
alias ...='cd ../..'

alias ls='ls -ahF --color=auto'
alias ll='ls -l'
alias path='echo -e ${PATH//:/\\n}' 
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -I'
alias ln='ln -i'
alias chown='chown --preserve-root'
alias chmod='chmod --preserve-root'
alias chgrp='chgrp --preserve-root'


function pre_prompt {
    PS1=${PS1_CUSTOM}
    user="$USER"
    host="${HOSTNAME%%.*}"
    printf -v date_long "%(%A %d %B %Y)T" -1
	# shellcheck disable=SC2034
    printf -v time_hms "%(%H:%M:%S)T" -1
    newPWD="${PWD/#$HOME/\~}"

    git_info=""
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local branch status dirty
        branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
        
        status=$(git status --porcelain 2>/dev/null)
        dirty=""
        
        [[ "$status" =~ [MADR] ]]  && dirty+="+" # Staged
        [[ "$status" =~ \ [MADR] ]] && dirty+="*" # Modified
        [[ "$status" =~ \?\? ]]    && dirty+="?" # Untracked
        
        [[ -n "$dirty" ]] && dirty=" [$dirty]"
        git_info="|  $branch$dirty |"
    fi

    local fixed_chars=10
    local var_width=$((${#user} + 1 + ${#host} + 1 + ${#date_long} + ${#newPWD} + ${#git_info}))
    local fillsize=$((COLUMNS - fixed_chars - var_width))

    fill=""
    if (( fillsize > 0 )); then
        for (( i=0; i<fillsize; i++ )); do fill+="─"; done
    else
        fill="-"
    fi
}

PROMPT_COMMAND=pre_prompt

# shellcheck disable=SC2034
function setup_prompt {
    local black="\[\033[0;38;5;0m\]"
    local red="\[\033[0;38;5;1m\]"
    local orange="\[\033[0;38;5;130m\]"
    local green="\[\033[0;38;5;2m\]"
    local yellow="\[\033[0;38;5;3m\]"
    local blue="\[\033[0;38;5;4m\]"
    local bblue="\[\033[0;38;5;12m\]"
    local magenta="\[\033[0;38;5;55m\]"
    local cyan="\[\033[0;38;5;6m\]"
    local white="\[\033[0;38;5;7m\]"
    local coldblue="\[\033[0;38;5;33m\]"
    local smoothblue="\[\033[0;38;5;111m\]"
    local iceblue="\[\033[0;38;5;45m\]"
    local turqoise="\[\033[0;38;5;50m\]"
    local smoothgreen="\[\033[0;38;5;42m\]"

    local couleur_info couleur_decor couleur_commande
    if (( UID == 0 )); then
        couleur_info=$red
    else
        couleur_info=$green
    fi
    couleur_decor=$bblue
    couleur_commande=$white

    case "$TERM" in
        xterm*|screen*)
        PS1_CUSTOM=""${couleur_decor}"┌─("${couleur_info}"\u@\h \$date_long"${couleur_decor}")─"${magenta}"\$git_info"${couleur_decor}"\${fill}─("${couleur_info}"\$newPWD"${couleur_decor}")─┐\n"${couleur_decor}"└─("${couleur_info}"\$time_hms \\$"${couleur_decor}")─>"${couleur_commande}" "
        ;;
        *)
        PS1_CUSTOM="┌─(\u@\h \$date_long)─\${fill}─(\$newPWD)─┐\n└─(\$time_hms \\$)─> "
        ;;
    esac
}

setup_prompt
unset setup_prompt
