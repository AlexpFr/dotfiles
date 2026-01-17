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

  export DEBIAN_FRONTEND=noninteractive

  install_custom_bash_prompt
  # create_root_lvm_snapshot
  launch_post_install_script
  install_additional_packages
  add_sudoer_user "$username" "$encrypted_password"
  # purge_old_kernel
  # install_realtek_r8152_dkms
  # pin_interface "__CUSTOM_INTERFACE__" "__CUSTOM_TARGET__"
  # create_custom_data_lv
  # mount_new_custom_data_lv
  apt -y autoremove --purge || echo "apt autoremove --purge failed"
  apt -y autoclean || echo "apt autoclean failed"
  apt -y clean || echo "apt clean failed"
  fstrim -av
  
  unset DEBIAN_FRONTEND
}

launch_post_install_script() {
  local url="https://gist.githubusercontent.com/AlexpFr/sys_install/proxmox/proxmox-post-install.sh"
  bash -c "$(curl -fsSL "$url")"
}

install_additional_packages() {
  echo "Installing additional packages"
  apt install -y iperf3 vim btop git nvme-cli ethtool lshw smartmontools lm-sensors
}

add_sudoer_user() {
  # Usage: add_sudoer_user 'user_name' 'encrypted_password'
  # To generate encrypted password:
  # mkpasswd user_password'
  # openssl passwd -6 'user_password'
  local username=$1
  local encrypted_password=$2
  if [[ -z "$username" ]] || [[ ! "$encrypted_password" =~ ^\$ ]]; then
    echo "Username or password hash is empty or invalid, skipping user creation."
    return
  fi
  echo "Adding custom user $username with sudo privileges"
  # # With adduser:
  # adduser --disabled-password --gecos "" "$username"
  # usermod -p "$encrypted_password" "$username"
  # adduser "$username" sudo

  # With useradd:
  useradd -m -s /bin/bash -G sudo "$username"
  echo "$username:$encrypted_password" | chpasswd -e
}

# ----------------------------
# Optional functions below
# ----------------------------
install_custom_bash_prompt() {
  local url="https://raw.githubusercontent.com/AlexpFr/config_files/custom_prompt.sh"
  local profile_d_file=/etc/profile.d/custom_prompt.sh
  echo "Installing $profile_d_file from $url"
  curl -fsSL "$url" -o "$profile_d_file"
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
