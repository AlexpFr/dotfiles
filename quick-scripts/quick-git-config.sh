#!/bin/bash
# Quick Git configuration script
# This script sets up Git with user information, GPG signing using SSH keys, and some useful aliases.

USERNAME="$1"
USEREMAIL="$2"

if [[ -z "$USERNAME" || -z "$USEREMAIL" ]]; then
  echo "Usage: $0 <USERNAME> <USEREMAIL>"
  echo "Example: $0 \"Your Name\" \"your.email@example.com\""
  exit 1
fi

if ! ssh-add -L | grep -F "${USEREMAIL}" > /dev/null; then
  echo "Error: No SSH key found for ${USEREMAIL} in ssh-agent."
  echo "Make sure you have an SSH key with ${USEREMAIL} as a part of comment and that it's added to the ssh-agent."
  exit 1
fi

ALLOWED_SIGNERS_FILE="$HOME/.ssh/allowed_signers"
GIT_GFG_CMD="git config --global"

install -dm 700 "${ALLOWED_SIGNERS_FILE%/*}"
install -m 600 /dev/stdin "${ALLOWED_SIGNERS_FILE}" \
  < <(printf '%s namespaces="git" %s' "${USEREMAIL}" "$(ssh-add -L | grep -F "${USEREMAIL}" || echo 'no-key-found')")

for cmd in "${GIT_GFG_CMD[@]}"; do
  ${cmd} user.name "${USERNAME}"
  ${cmd} user.email "${USEREMAIL}"

  ${cmd} gpg.format ssh
  ${cmd} gpg.ssh.defaultKeyCommand "sh -c 'ssh-add -L | grep -F ${USEREMAIL}'"
  ${cmd} gpg.ssh.allowedSignersFile "${ALLOWED_SIGNERS_FILE}"
  ${cmd} commit.gpgsign true
  ${cmd} tag.gpgsign true

  ${cmd} core.editor "code --wait --new-window"

  ${cmd} diff.tool vscode
  # shellcheck disable=SC2016
  ${cmd} difftool.vscode.cmd 'code --wait --diff $LOCAL $REMOTE'

  ${cmd} merge.tool vscode
  # shellcheck disable=SC2016
  ${cmd} mergetool.vscode.cmd 'code --wait $MERGED'

  ${cmd} alias.aliases '!git config --get-regexp ^alias.'
  ${cmd} alias.oops 'commit --amend --no-edit'
  ${cmd} alias.reword 'commit --amend'
  ${cmd} alias.uncommit 'reset --soft HEAD~1'

  ${cmd} alias.push-with-lease 'push --force-with-lease'
  ${cmd} alias.review-local '!git lg @{push}..'

  ${cmd} alias.untrack 'rm --cached --'

  ${cmd} alias.lg "log -n 30 --graph --date=relative --pretty=tformat:'%Cred%h%Creset %C(auto)%d%Creset %s %Cgreen(%an %ad)%Creset'"
  ${cmd} alias.slg "log -n 30 --graph --date=relative --pretty=tformat:'%Cred%h%Creset <Sign: %C(auto)%G?%C(reset)>%C(auto)%d%Creset %s %Cgreen(%an %ad)%Creset'"
done
