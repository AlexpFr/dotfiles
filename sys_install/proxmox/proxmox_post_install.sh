#!/usr/bin/env bash

# Based on https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh
# Original credit:
# # Copyright (c) 2021-2026 tteck
# # Author: tteckster | MickLesk (CanbiZ)
# # License: MIT
# # https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Run as root (sudo)." && exit 1

TMPDIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$TMPDIR'" EXIT

main() {
  prepare_files
  configure_repositories
  # disable_ha
  system_update
  remove_nag
  gpu_passthrough
  # system_reboot
}

function gpu_passthrough() {
  echo "Configuring GPU passthrough (Optional, requires additional setup)"
  mkdir -p /etc/modprobe.d
  echo "blacklist amdgpu" | tee /etc/modprobe.d/blacklist-gpu.conf >/dev/null
  echo "blacklist snd_hda_intel" | tee -a /etc/modprobe.d/blacklist-gpu.conf >/dev/null
  echo "options vfio-pci ids=1002:1681,1002:1640 disable_vga=1" | tee /etc/modprobe.d/vfio-gpu.conf >/dev/null

  mkdir -p /etc/modules-load.d
  echo "vfio" | tee /etc/modules-load.d/vfio.conf >/dev/null
  echo "vfio_iommu_type1" | tee -a /etc/modules-load.d/vfio.conf >/dev/null
  echo "vfio_pci" | tee -a /etc/modules-load.d/vfio.conf >/dev/null

  mkdir -p /etc/default/grub.d
  # shellcheck disable=SC2016
  echo 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} iommu=pt"' | tee /etc/default/grub.d/iommu.cfg >/dev/null

  update-grub
  update-initramfs -u -k all
  echo "Configured GPU passthrough (Reboot required)"

  # apt install libgl1 libegl1
  # lspci -nn | grep -E "VGA|3D"
  # lspci -nnk -s e5:00.0
  # lspci -nnk -s e5:00.1
  # find /sys/kernel/iommu_groups/ -type l | sort
  # journalctl -b -1 | grep -i -E "vfio|amd|gpu|qemu|kvm" | tail -n 100
  # lspci -tv
  # apt install vendor-reset
  # qm start 103 && screen -S vm103 qm terminal 103
  # grep -i "AuthenticAMD" /proc/cpuinfo
  # lspci -vvv
}

configure_repositories() {
  local pve_enterprise_sources=/etc/apt/sources.list.d/pve-enterprise.sources
  if [ -f "$pve_enterprise_sources" ]; then
    echo "disable 'pve-enterprise' repository file"
    echo "Enabled: false" >>"$pve_enterprise_sources"
  fi

  local ceph_enterprise_sources=/etc/apt/sources.list.d/ceph.sources
  if [ -f "$ceph_enterprise_sources" ]; then
    echo "disable 'ceph enterprise' repository file"
    echo "Enabled: false" >>"$ceph_enterprise_sources"
  fi

  echo "Adding 'pve-no-subscription' repository"
  install -m 644 "${TMPDIR}"/proxmox.sources /etc/apt/sources.list.d/proxmox.sources
}

remove_nag() {
  echo "Disabling subscription nag"
  # Create external script, this is needed because DPkg::Post-Invoke is fidly with quote interpretation
  install -m 755 "${TMPDIR}"/pve-remove-nag.sh /usr/local/bin/pve-remove-nag.sh
  install -m 644 "${TMPDIR}"/no-nag-script /etc/apt/apt.conf.d/no-nag-script
  echo "Disabled subscription nag (Delete browser cache)"

  apt --reinstall install proxmox-widget-toolkit || echo "Widget toolkit reinstall failed"
}

disable_ha() {
  if systemctl is-active --quiet pve-ha-lrm; then
    echo "Disabling high availability"
    systemctl disable -q --now pve-ha-lrm
    systemctl disable -q --now pve-ha-crm
    echo "Disabled high availability"

    echo "Disabling Corosync"
    systemctl disable -q --now corosync
    echo "Disabled Corosync"
  fi
}

system_update() {
  echo "Updating Proxmox VE (Patience)"
  apt update || echo "apt update failed"
  apt -y full-upgrade || echo "apt full-upgrade failed"
  apt autoremove --purge || echo "apt autoremove --purge failed"
  apt autoclean || echo "apt autoclean failed"
  apt clean || echo "apt clean failed"
  echo "Updated Proxmox VE"
  # After reboot: apt purge proxmox-kernel-6.17.2-1-pve-signed
}

system_reboot() {
  echo "Rebooting Proxmox VE"
  sleep 2
  echo "Completed Post Install Routines"
  reboot
}

prepare_files() {
  # region File Creations
  cat >"${TMPDIR}"/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

  cat >"${TMPDIR}"/pve-remove-nag.sh <<'EOF'
#!/bin/sh
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
  echo "Patching Web UI nag..."
  sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi

MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
  echo "Patching Mobile UI nag..."
  printf "%s\n" \
    "$MARKER" \
    "<script>" \
    "  function removeSubscriptionElements() {" \
    "    // --- Remove subscription dialogs ---" \
    "    const dialogs = document.querySelectorAll('dialog.pwt-outer-dialog');" \
    "    dialogs.forEach(dialog => {" \
    "      const text = (dialog.textContent || '').toLowerCase();" \
    "      if (text.includes('subscription')) {" \
    "        dialog.remove();" \
    "        console.log('Removed subscription dialog');" \
    "      }" \
    "    });" \
    "" \
    "    // --- Remove subscription cards, but keep Reboot/Shutdown/Console ---" \
    "    const cards = document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center');" \
    "    cards.forEach(card => {" \
    "      const text = (card.textContent || '').toLowerCase();" \
    "      const hasButton = card.querySelector('button');" \
    "      if (!hasButton && text.includes('subscription')) {" \
    "        card.remove();" \
    "        console.log('Removed subscription card');" \
    "      }" \
    "    });" \
    "  }" \
    "" \
    "  const observer = new MutationObserver(removeSubscriptionElements);" \
    "  observer.observe(document.body, { childList: true, subtree: true });" \
    "  removeSubscriptionElements();" \
    "  setInterval(removeSubscriptionElements, 300);" \
    "  setTimeout(() => {observer.disconnect();}, 10000);" \
    "</script>" \
    "" >> "$MOBILE_TPL"
fi
EOF

  cat >"${TMPDIR}"/no-nag-script <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };
EOF
  # endregion
}

main
