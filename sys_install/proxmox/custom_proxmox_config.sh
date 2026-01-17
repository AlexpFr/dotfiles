#!/usr/bin/env bash

# Usage:
# sudo bash install-proxmox.sh 'user_name' 'encrypted_password'
# or leave both empty to skip user creation
#
# To generate encrypted password:
# mkpasswd 'user_password' or openssl passwd -6 'user_password'

# TODO:
# Hardening:
#     - read -p "Username: " username and read -sp "Encrypted password: " encrypted_password
#     - Check external script signature (SHA256, SHA512...)

set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Run as root (sudo)." && exit 1

main() {
  local username="${1:-}"
  local encrypted_password="${2:-}"
  # If local file exists, use it, else use remote URL
  if [[ -f "/root/dotfiles/sys_install/proxmox/proxmox-post-install.sh" ]]; then
    proxmox_post_install_scipt="/root/dotfiles/sys_install/proxmox/proxmox-post-install.sh"
  else
    proxmox_post_install_scipt="https://raw.githubusercontent.com/AlexpFr/dotfiles/main/sys_install/proxmox/proxmox-post-install.sh"
  fi

  # custom_bash_prompt_file=/root/dotfiles/main/config_files/custom_prompt.sh or https://raw.githubusercontent.com/AlexpFr/dotfiles/main/config_files/custom_prompt.sh
  if [[ -f "/root/dotfiles/config_files/custom_prompt.sh" ]]; then
    custom_bash_prompt_file="/root/dotfiles/config_files/custom_prompt.sh"
  else
    custom_bash_prompt_file="https://raw.githubusercontent.com/AlexpFr/dotfiles/main/config_files/custom_prompt.sh"
  fi

  export DEBIAN_FRONTEND=noninteractive

  install_custom_bash_prompt "$custom_bash_prompt_file"
  disable_motd_messages "root"
  # create_root_lvm_snapshot
  launch_post_install_script "$proxmox_post_install_scipt"
  install_additional_packages
  add_sudoer_user "$username" "$encrypted_password"
  nopassword_sudoers_entry "$username"
  disable_motd_messages "$username"
  purge_old_kernel
  # install_realtek_r8152_dkms
  # pin_interface "__CUSTOM_INTERFACE__" "__CUSTOM_TARGET__"
  # create_custom_data_lv
  # mount_new_custom_data_lv
  clean_apt
  sync && sleep 2 && sync && fstrim -av
  
  unset DEBIAN_FRONTEND
}

clean_apt() {
  apt -y autoremove --purge || echo "apt autoremove --purge failed"
  apt -y autoclean || echo "apt autoclean failed"
  apt -y clean || echo "apt clean failed"
  rm -rf /var/lib/apt/lists/* || echo "Removing /var/lib/apt/lists/* failed"
}

nopassword_sudoers_entry() {
  local username=$1
  local sudoers_file="/etc/sudoers.d/010_${username}_nopasswd"
  echo "Creating sudoers file $sudoers_file for user $username"
  echo "$username ALL=(ALL:ALL) NOPASSWD: ALL" > "$sudoers_file"
  chmod 440 "$sudoers_file"
}

disable_motd_messages() {
  local _user=$1
  local user_homedir="/home/$_user"
  [[ "$_user" == "root" ]] && user_homedir="/root"
  echo "Disabling MOTD messages for user in $user_homedir"
  # si le répertoire n'existe pas, on ne fait rien
  [[ ! -d "$user_homedir" ]] && echo "User home directory $user_homedir does not exist, skipping." && return
  touch "$user_homedir/.hushlogin"
  chown "$_user":"$_user" "$user_homedir/.hushlogin"
}

launch_post_install_script() {
  local file_or_url="$1"
  echo "Launching Proxmox post-install script from $file_or_url"
  if [[ -f "$file_or_url" ]]; then
    bash "$file_or_url"
  elif [[ "$file_or_url" =~ ^https?:// ]]; then
    bash -c "$(curl -fsSL "$file_or_url")"
  else
    echo "Invalid file or URL: $file_or_url"
    return 1
  fi
}

install_additional_packages() {
  echo "Installing additional packages"
  apt install -y iperf3 vim btop git nvme-cli ethtool lshw smartmontools lm-sensors pciutils fastfetch
}

add_sudoer_user() {
  local username=$1
  local encrypted_password=$2
  if [[ -z "$username" ]] || [[ ! "$encrypted_password" =~ ^\$ ]]; then
    echo "Username or password hash is empty or invalid, skipping user creation."
    return
  fi
  echo "Adding custom user $username with sudo privileges"
  useradd -m -s /bin/bash -G sudo "$username"
  echo "$username:$encrypted_password" | chpasswd -e
}

# ----------------------------
# Optional functions below
# ----------------------------
install_custom_bash_prompt() {
  local file_or_url="$1"
  local profile_d_file=/etc/profile.d/custom_prompt.sh
  # si le fichier est local
  if [[ -f "$file_or_url" ]]; then
    echo "Installing $profile_d_file from local file $file_or_url"
    cp "$file_or_url" "$profile_d_file"
  elif [[ "$file_or_url" =~ ^https?:// ]]; then
    echo "Installing $profile_d_file from URL $file_or_url"
    curl -fsSL "$file_or_url" -o "$profile_d_file"
  else
    echo "Invalid file or URL: $file_or_url"
    return 1
  fi

  chown root:root "$profile_d_file"
  chmod 755 "$profile_d_file"
  #shellcheck disable=SC1090
  source "$profile_d_file"
}

purge_old_kernel() {
  apt purge -y proxmox-kernel-6.17.2-1-pve-signed
}

create_root_lvm_snapshot() {
  # détermier la taille du volume root:
  local root_lv_size "0"
  root_lv_size=$(lvs --noheadings -o LV_SIZE --units G /dev/mapper/pve-root | tr -d ' ')
  lvcreate -L "${root_lv_size}" -s -n root_preupgrade /dev/mapper/pve-root
  # # Revert to snapshot if needed
  # lvconvert --merge /dev/mapper/pve-root_preupgrade
  # shutdown -r now
  # dmsetup remove pve-root_preupgrade
  # lvremove -f /dev/pve/root_preupgrade

  # # Remove snapshot after successful upgrade
  # lvremove -f /dev/pve/root_preupgrade
}

install_realtek_r8152_dkms() {
  # https://github.com/awesometic/realtek-r8152-dkms
  apt update
  apt install -y proxmox-headers-6.17 dkms
  apt purge -y realtek-r8152-dkms > /dev/null 2>&1 || echo "No existing r8152 dkms to remove"
  local version=2.21.4-1
  wget https://github.com/awesometic/realtek-r8152-dkms/releases/download/${version}realtek-r8152-dkms_${version}.deb
  dpkg -i realtek-r8152-dkms_${version}.deb
}

pin_interface() {
  local iface=$1
  local target=$2
  echo "Pinning interface $iface to $target"
  ppve-network-interface-pinning generate --interface "$iface" --target "$target"
  systemctl restart networking.service
}

create_custom_data_lv() {
  local vgname=pve
  local lvname=user-data
  local lvm_size=726G
  local vmid=100
  lvcreate -L ${lvm_size} -n ${lvname} ${vgname}
  qm shutdown ${vmid}
  qm set ${vmid} -scsi1 /dev/mapper/${vgname}-${lvname}
}

mount_new_custom_data_lv() {
  local vgname=pve
  local lvname=user-data
  mkfs.ext4 /dev/pve/${lvname}
  mkdir /mnt/${lvname}
  mount /dev/pve/${lvname} /mnt/${lvname}
  umount /mnt/${lvname}
  # # To auto-mount at boot, add to /etc/fstab:
  # echo "/dev/pve/${lvname} /mnt/${lvname} ext4 defaults 0 2" >> /etc/fstab
}

main "$@"
