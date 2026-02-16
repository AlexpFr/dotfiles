alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias cls='clear'
alias ..='cd ..'

export PATH="/ucrt64/bin:/mingw64/bin:/usr/bin:/c/Program Files/Git/bin:$PATH"

if test -f /etc/profile.d/git-sdk.sh
then
        TITLEPREFIX=SDK-${MSYSTEM#MINGW}
else
        TITLEPREFIX=$MSYSTEM
fi

if test -f ~/.config/git/git-prompt.sh
then
        . ~/.config/git/git-prompt.sh
else
        PS1='\[\033]0;$TITLEPREFIX:$PWD\007\]' # set window title
        # PS1="$PS1"'\n'                 # new line
        PS1="$PS1"'\[\033[32m\]'       # change to green
        PS1="$PS1"'\u@\h '             # user@host<space>
        PS1="$PS1"'\[\033[35m\]'       # change to purple
        # PS1="$PS1"'$MSYSTEM '          # show MSYSTEM
        PS1="$PS1"'\[\033[33m\]'       # change to brownish yellow
        PS1="$PS1"'\w'                 # current working directory
        if test -z "$WINELOADERNOEXEC"
        then
                GIT_EXEC_PATH="$(git --exec-path 2>/dev/null)"
                COMPLETION_PATH="${GIT_EXEC_PATH%/libexec/git-core}"
                COMPLETION_PATH="${COMPLETION_PATH%/lib/git-core}"
                COMPLETION_PATH="$COMPLETION_PATH/share/git/completion"
                if test -f "$COMPLETION_PATH/git-prompt.sh"
                then
                        . "$COMPLETION_PATH/git-completion.bash"
                        . "$COMPLETION_PATH/git-prompt.sh"
                        PS1="$PS1"'\[\033[36m\]'  # change color to cyan
                        PS1="$PS1"'`__git_ps1`'   # bash function
                fi
        fi
        PS1="$PS1"'\[\033[0m\]'        # change color
        # PS1="$PS1"'\n'                 # new line
        PS1="$PS1"'$ '                 # prompt: always $
fi

MSYS2_PS1="$PS1"               # for detection by MSYS2 SDK's bash.basrc

# Evaluate all user-specific Bash completion scripts (if any)
if test -z "$WINELOADERNOEXEC"
then
        for c in "$HOME"/bash_completion.d/*.bash
        do
                # Handle absence of any scripts (or the folder) gracefully
                test ! -f "$c" ||
                . "$c"
        done
fi

export PATH="/c/Program Files/OpenSSH:$PATH"

# https://github.com/masahide/OmniSSHAgent
#export SSH_AUTH_SOCK="/c/Users/$USER/OmniSSHCygwin.sock"

# pacman -S ssh-pageant
# export SSH_AUTH_SOCK="/tmp/.ssh-pageant-$USERNAME"
# if ! ps -ef | grep -v grep | grep -q ssh-pageant; then
#     rm -f "$SSH_AUTH_SOCK"
#     # L'option -r permet de réutiliser un socket existant si possible
#     ssh-pageant -r -a "$SSH_AUTH_SOCK"
# fi