#!/bin/bash

PROXMOX_IP=""
SSH_PUBLIC_KEY_PATH=""
PROXMOX_USER=''
USER_PWD_HASH=''
LOCAL_REPO_PATH=""
GIT_REPO_URL="https://github.com/AlexpFr/dotfiles.git"

# Required variables list
REQUIRED_VARS=(
    "PROXMOX_IP"
    "SSH_PUBLIC_KEY_PATH"
    "PROXMOX_USER"
    "USER_PWD_HASH"
    "LOCAL_REPO_PATH"
    "GIT_REPO_URL"
)

# Function to display help
show_help() {
    echo "=========================================="
    echo "ERROR: Missing required environment variables"
    echo "=========================================="
    echo ""
    echo "Please create a .env file with the following variables:"
    echo ""
    echo "PROXMOX_IP=\"\"                # Proxmox server IP address"
    echo "SSH_PUBLIC_KEY_PATH=\"\"       # Path to your SSH public key"
    echo "PROXMOX_USER=\"\"              # Proxmox username"
    echo "USER_PWD_HASH=\"\"             # User password hash"
    echo "LOCAL_REPO_PATH=\"\"           # Local repository path"
    echo "GIT_REPO_URL=\"https://github.com/AlexpFr/dotfiles.git\"  # Git repository URL"
    echo ""
    echo "Missing variables:"
    for var in "${MISSING_VARS[@]}"; do
        echo "  - $var"
    done
    echo ""
    exit 1
}

# Load .env file if it exists
if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo "Error: .env file not found"
    show_help
fi

# Check if all required variables are set and not empty
MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING_VARS+=("$var")
    fi
done

# If any variable is missing, show help and exit
if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    show_help
fi

# All variables are set, continue with your script
echo "All required variables are set. Starting script..."

# Copy ssh key to Proxmox server for passwordless login:
ssh root@${PROXMOX_IP} "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ${SSH_PUBLIC_KEY_PATH}

case "${LAUNCH_TYPE:curl}" in
  git)
    ssh root@${PROXMOX_IP} "apt update && apt install -y git"
    ssh root@${PROXMOX_IP} "git clone \${GIT_REPO_URL} /root/dotfiles"

    echo "Methode $LAUNCH_TYPE, run the folowings commands:"
    echo "ssh root@${PROXMOX_IP}"
	echo "cp /root/dotfiles/sys_install/proxmox/.env.sample /root/dotfiles/sys_install/proxmox/.env"
	echo "nano /root/dotfiles/sys_install/proxmox/.env"
    echo "bash /root/dotfiles/sys_install/proxmox/full_proxmox_config.sh '${PROXMOX_USER}' '${USER_PWD_HASH}'"
    ;;
  scp)
    scp ${LOCAL_REPO_PATH}/sys_install/proxmox/full_proxmox_config.sh root@${PROXMOX_IP}:/root/full_proxmox_config.sh
    scp ${LOCAL_REPO_PATH}/sys_install/proxmox/proxmox_post_install.sh root@${PROXMOX_IP}:/root/proxmox_post_install.sh
    scp ${LOCAL_REPO_PATH}/config_files/custom_prompt.sh root@${PROXMOX_IP}:/root/custom_prompt.sh
	scp ${LOCAL_REPO_PATH}/sys_install/proxmox/.env root@${PROXMOX_IP}:/root/.env

    echo "Methode $LAUNCH_TYPE, run the folowings commands:"
    echo "ssh root@${PROXMOX_IP}"
	echo "nano /root/.env"
    echo "bash /root/full_proxmox_config.sh '${PROXMOX_USER}' '${USER_PWD_HASH}'"
    ;;
  curl)
    echo "Methode $LAUNCH_TYPE, run the folowings commands:"
    echo "ssh root@${PROXMOX_IP}"
    echo "url=https://raw.githubusercontent.com/AlexpFr/dotfiles/main/sys_install/proxmox"
	echo "curl -fsSL "\$url"/.env.sample -o .env"
	echo "nano .env"
    echo "curl -fsSL "\$url"/full_proxmox_config.sh | bash -s -- '${PROXMOX_USER}' '${USER_PWD_HASH}'"
    ;;
  *)
    echo "Invalid TYPE: $LAUNCH_TYPE"
    exit 1
    ;;
esac





