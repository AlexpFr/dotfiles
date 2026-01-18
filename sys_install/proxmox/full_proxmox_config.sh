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
trap 'echo "An error occurred. Exiting..."; exit 1' ERR

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
  copy_ssh_key_from_root "$username"

  # install_realtek_r8152_dkms
  pin_interface "${PIN_IFACE[@]:-}"
  # create_custom_data_lv
  # mount_new_custom_data_lv

  sysctl_config
  sysctl_bbr_congestion_control
  sysctl_net_config
  ifupdown_interface_config "nic1"

  purge_old_kernel

  clean_apt
  trim_all_fs
  
  unset DEBIAN_FRONTEND
}

trim_all_fs() {
  echo "Trimming all mounted filesystems..."
  sync && sleep 2 && sync && fstrim -av && sleep 2 && sync && fstrim -av
}

copy_ssh_key_from_root() {
  local username=$1
  local ssh_public_key_path="/root/.ssh/authorized_keys"
  local user_homedir="/home/$username"

  [[ "$username" == "root" ]] && echo "Skipping SSH key copy for root user." && return
  [[ ! -d "$user_homedir" ]] && echo "User home directory $user_homedir does not exist, skipping." && return
  [[ ! -f "$ssh_public_key_path" ]] && echo "SSH public key file $ssh_public_key_path does not exist, skipping." && return

  echo "Copying SSH public key from root to user $username"
  local ssh_dir="$user_homedir/.ssh"
  local auth_keys_file="$ssh_dir/authorized_keys"
  install -d -m 700 -o "$username" -g "$username" "$ssh_dir"
  cp "$ssh_public_key_path" "$auth_keys_file"
  chown "$username":"$username" "$auth_keys_file"
  chmod 600 "$auth_keys_file"
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
  apt install -y iperf3 vim btop git nvme-cli lshw lm-sensors fastfetch
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

#region sysctl/network configurations
sysctl_bbr_congestion_control() {
  echo "Configuring BBR congestion control..."
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
  cat <<EOF >/etc/sysctl.d/99-custom-bbr.conf
# Enable BBR congestion control
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF

  modprobe tcp_bbr
  sysctl -p /etc/sysctl.d/99-custom-bbr.conf
}

sysctl_net_config() {
  echo "Configuring TCP parameters..."
  cat <<EOF >/etc/sysctl.d/99-custom-net.conf
# Disable TCP slow start after idle
net.ipv4.tcp_slow_start_after_idle = 0

# Increase the maximum number of packets in the network device queue
net.core.netdev_max_backlog = 4096

# Increase the maximum number of packets in the network device queue
net.core.netdev_budget = 600

# Increase the maximum time (in microseconds) the CPU can spend processing packets
net.core.netdev_budget_usecs = 4000

# Increase minimum UDP buffer sizes
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Increase socket buffer sizes
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# 64KB  = 65536
# 128KB = 131072
# 256KB = 262144
# 512KB = 524288
# 1MB   = 1048576
# 2MB   = 2097152
# 4MB   = 4194304
# 8MB   = 8388608
# 16MB  = 16777216
# 32MB  = 33554432
# 64MB  = 67108864
EOF
  sysctl -p /etc/sysctl.d/99-custom-net.conf
}

sysctl_config() {
  echo "Configuring sysctl parameters..."
  cat <<EOF >/etc/sysctl.d/99-custom-config.conf
vm.swappiness = 5
vm.vfs_cache_pressure = 50
EOF
  sysctl -p /etc/sysctl.d/99-custom-config.conf
}

ifupdown_interface_config() {
  local iface=$1
  local size=4096
  echo "Configuring ethtool settings for interface $iface"
  cat <<EOF >/etc/network/if-up.d/"$iface"-tuning
#!/bin/sh
if [ "\$IFACE" = "$iface" ]; then
  # Increase RX and TX ring buffer sizes
  /usr/sbin/ethtool -G "$iface" rx $size tx $size 2>/dev/null || true
fi
EOF
  chmod +x /etc/network/if-up.d/"$iface"-tuning
}
#endregion

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
  local pair
  for pair in "$@"; do
    local mac_target="${pair%%=*}"
    local target_name="${pair#*=}"
    if [[ -z "$mac_target" ]] || [[ -z "$target_name" ]]; then
        return
    fi

    mac_target=${mac_target//[[:space:].:-]/}

    local iface=""
    local mac=""
    for i in /sys/class/net/*; do
      [[ -L "$i" ]] || continue
      iface=$(basename "$i")
      mac=$(ethtool -P "$iface" 2>/dev/null | grep -i 'Permanent Address' | awk '{print $3}')
      mac=${mac//[[:space:].:-]/}
      [[ "${mac,,}" == "${mac_target,,}" ]] && break
    done

    if [ -z "$mac" ] || [ "$mac" != "$mac_target" ]; then
        echo "Error: no interface found with MAC $mac_target" >&2
        return 1
    fi

    echo "Pinning interface $iface (MAC $mac) vers $target_name"

    pve-network-interface-pinning generate --interface "$iface" --target "$target_name"
  done

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
