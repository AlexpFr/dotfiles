#!/bin/bash
# Usage: ./make-debian13-template.sh <VMID> <STORAGE> [NAME] [timezone]
# Example: ./make-debian13-template.sh 9000 local-lvm debian13-trixie-template Europe/Paris
# https://forum.proxmox.com/threads/pve9-create-a-vm-template-for-a-debian-trixie-server-with-cloud-init.170206/
# https://www.ribault.me/proxmox-personnaliser-alpine-linux-cloud-init/

set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Run as root (sudo)." && exit 1

TMPDIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$TMPDIR'" EXIT

#region envars
VMID="${1:?Usage: $0 <vmid> <storage> [name]}"
STORAGE="${2:?Usage: $0 <vmid> <storage> [name]}"
NAME="${3:-debian-13-trixie-docker-template}"
TIMEZONE="${4:-Europe/Paris}"

# Image settings
IMG_NAME="debian-13-genericcloud-amd64.qcow2"
IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/${IMG_NAME}"
IMG_CHECKSUM_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
IMG_PATH="${TMPDIR}/${IMG_NAME}"
IMG_SHRUNK_PATH="${TMPDIR}/debian-13-genericcloud-amd64-shrunk.qcow2"

# Cloud-init snippet location (must be on a storage that supports "Snippets"; typically 'local')
SNIPPET_STORAGE="local"
SNIPPET_FILENAME="debian-vendor.yaml"
SNIPPET_PATH="/var/lib/vz/snippets/${SNIPPET_FILENAME}"

# Cloud-init defaults
CI_USER="debian"
CI_PASS='debian'
SSHKEYS_FILE="/root/.ssh/authorized_keys"
#endregion

#region Functions
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

check_dependencies() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || { log "ERROR: '$cmd' not installed. Install it and try again." >&2; exit 1; }
  done
}

download_image() {
  local img_path="$IMG_PATH"
  local checksum=""
  checksum=$(curl -fsSL "${IMG_CHECKSUM_URL}" | grep -i "${IMG_NAME}" | awk '{print $1}')
  [[ -n "$checksum" ]] || { log "ERROR: Could not retrieve checksum for image" >&2; return 1; }

  # Helper function to validate QCOW2 format
  validate_qcow2() {
    file "$1" | grep -q "QEMU QCOW" || { log "ERROR: File is not a valid QCOW2 image: $1" >&2; return 1; }
  }

  # Helper function to verify checksum
  verify_checksum() {
    echo "${checksum}  $1" | sha512sum -c --status
  }

  # If image exists, validate and verify checksum
  if [[ -f "$img_path" ]]; then
    validate_qcow2 "$img_path" || return 1
    log "Image file exists. Verifying checksum..."
    if verify_checksum "$img_path"; then
      log "Checksum valid. Using existing image."
      return 0
    else
      log "Checksum invalid. Downloading fresh copy..."
      rm -f "$img_path"
    fi
  fi

  # Download the image
  log "Downloading image from $IMG_URL..."
  # If aria2c is available, use it for faster download
  command -v aria2c &>/dev/null && aria2c -x 16 -s 16 --dir="${TMPDIR}" -o "${IMG_NAME}" "$IMG_URL" || \
  wget -q --show-progress -O "$img_path" "$IMG_URL" || { log "ERROR: Download failed" >&2; return 1; }
  [[ -f "$img_path" ]] || { log "ERROR: Image file not found after download" >&2; return 1; }

  # Validate the downloaded image
  validate_qcow2 "$img_path" || { rm -f "$img_path"; return 1; }
  verify_checksum "$img_path" || { log "ERROR: Checksum verification failed" >&2; rm -f "$img_path"; return 1; }
  
  log "Image validated successfully."
}

# Generate the cloud-init snippet (minimal)
generate_snippet() {
  local path="$1"
  mkdir -p "${path%/*}"
  cat > "$path" <<EOF
#cloud-config
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
timezone: "${TIMEZONE}"
hostname: "${NAME}"
apt:
  generate_mirrorlists: false
EOF
  log "Cloud-init snippet generated at $path"
}

check_vm_storage() {
  local storage_name="$1"
  if ! pvesm status | grep "$storage_name" &>/dev/null; then
    log "ERROR: Storage '$storage_name' not found or not accessible." >&2
    exit 1
  fi
}
#endregion

log "Starting template creation for VMID=$VMID, Storage=$STORAGE"

check_dependencies curl wget qemu-img virt-customize qm file
check_vm_storage "${STORAGE}"
generate_snippet "${SNIPPET_PATH}"
download_image "${IMG_PATH}"

#region VM Files
# Create mirror lists
DEBIAN_MIRRORS=$(cat <<'EOF'
https://debian.mirrors.ovh.net/debian
# http://debian.proxad.net/debian
# http://ftp.es.debian.org/debian
# http://deb.debian.org/debian
EOF
)

# create the file of security mirrors
DEBIAN_SECURITY_MIRRORS=$(cat <<'EOF'
https://debian.mirrors.ovh.net/debian-security
# http://debian.proxad.net/debian-security
# http://ftp.es.debian.org/debian-security
# http://deb.debian.org/debian-security
EOF
)

CLOUD_CFG_D_FILE=$(cat <<'EOF'
system_info:
  default_user:
    groups: [docker, __CURRENT_GROUPS__]
    lock_passwd: false

apt:
  generate_mirrorlists: false
EOF
)

cat > "$TMPDIR/10-vm-limits.conf" <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=1month
EOF

log "Optimizing image..."
DOCKER_KEY=$(curl -fsSL https://download.docker.com/linux/debian/gpg)
DOCKER_SOURCES=$(cat <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
)

cat > "$TMPDIR/daemon.json" <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "no-new-privileges": true,
  "userns-remap": "default",
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  }
}
EOF
#endregion

#region Customize image
VC_ARGS=(
  -a "$IMG_PATH"
  --timezone "Europe/Paris"

  # journald limits
  --copy-in "${TMPDIR}/10-vm-limits.conf:/tmp/"
  --run-command "set -eux; install -D -o root -g root -m 644 /tmp/10-vm-limits.conf /etc/systemd/journald.conf.d/10-vm-limits.conf"
  --run-command "rm /tmp/10-vm-limits.conf"

  # Mirror lists
  --run-command "set -eux; printf '%s\n' '${DEBIAN_MIRRORS}' > /etc/apt/mirrors/debian.list"
  --run-command "set -eux; printf '%s\n' '${DEBIAN_SECURITY_MIRRORS}' > /etc/apt/mirrors/debian-security.list"

  # Docker repo
  --run-command 'set -eux; install -m 0755 -d /etc/apt/keyrings'
  --run-command "set -eux; printf '%s\n' '${DOCKER_KEY}' > /etc/apt/keyrings/docker.asc"
  --run-command 'set -eux; chmod a+r /etc/apt/keyrings/docker.asc'
  --run-command "set -eux; printf '%s\n' '${DOCKER_SOURCES}' > /etc/apt/sources.list.d/docker.sources"

  # System update
  --run-command 'set -eux; apt-get -q -y -o Dpkg::Options::=--force-confnew update'
  --run-command 'set -eux; apt-get -q -y -o Dpkg::Options::=--force-confnew full-upgrade'

  # QEMU Guest Agent install
  --install "qemu-guest-agent"
  --run-command 'set -eux; systemctl enable qemu-guest-agent || true'

  # Docker install
  --copy-in "${TMPDIR}/daemon.json:/tmp/"
  --run-command 'set -eux; install -D -o root -g root -m 644 /tmp/daemon.json /etc/docker/daemon.json'
  --run-command "rm /tmp/daemon.json"

  --install docker-ce,docker-ce-cli,containerd.io,docker-buildx-plugin,docker-compose-plugin

  # Cloud-init customization
  --run-command "set -eux; printf '%s\n' \"${CLOUD_CFG_D_FILE}\" > /etc/cloud/cloud.cfg.d/90-debian-docker.cfg"
  --run-command "set -eux; sed -i \"s/__CURRENT_GROUPS__/\$(grep 'groups: \\[' /etc/cloud/cloud.cfg.d/01_debian_cloud.cfg | sed 's/.*\\[//;s/\\].*//')/\" /etc/cloud/cloud.cfg.d/90-debian-docker.cfg"
  
  # Clean up
  --run-command 'set -eux; rm -rf /var/lib/cloud/* || true'
  --truncate /etc/machine-id
  # --run-command 'set -eux; rm -rf /var/lib/apt/lists/* || true'
  --run-command 'set -eux; fstrim -av || true'
)

# if ! virt-customize --verbose -x --smp 8 --memsize 4096 "${VC_ARGS[@]}"; then
if ! virt-customize --smp 8 --memsize 4096 "${VC_ARGS[@]}"; then
  log "ERROR: virt-customize failed. Image may be corrupted." >&2
  exit 1
fi

# Compress/convert
[[ -f "$IMG_SHRUNK_PATH" ]] && rm -f "$IMG_SHRUNK_PATH"
qemu-img convert -p -O qcow2 -c -o compression_type=zstd -o preallocation=off "$IMG_PATH" "$IMG_SHRUNK_PATH"
#endregion

#region Create VM
# Delete an existing VM/template with this VMID
if qm status "$VMID" &>/dev/null; then
  log "VMID $VMID exists, removing it..."
  qm stop "$VMID" --skiplock 1 --timeout 30 >/dev/null 2>&1 || true
  qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1 || true
  log "VMID $VMID removed."
fi

# create VM
qm create "$VMID" \
  --name "$NAME" \
  --ostype l26 \
  --machine q35 \
  --bios ovmf \
  --cpu host \
  --cores 4 \
  --memory 4096 \
  --agent 1 \
  --serial0 socket \
  --vga serial0 \
  --tablet 0 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single \
  --scsi1 "${STORAGE}:cloudinit" \
  --ciuser "$CI_USER" \
  --cipassword "$CI_PASS" \
  --sshkeys "$SSHKEYS_FILE" \
  --ipconfig0 ip=dhcp,ip6=auto \
  --cicustom "vendor=${SNIPPET_STORAGE}:snippets/${SNIPPET_FILENAME}" \
  --ciupgrade 0

# EFI vars disk (avoid "temporary efivars disk" warning)
qm set "$VMID" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0"

# Import and attach disk as scsi0
qm importdisk "$VMID" "$IMG_SHRUNK_PATH" "$STORAGE" -format qcow2
qm resize "$VMID" scsi0 20G

# Find the imported volume from "unused0:" and attach it as scsi0
IMPORTED_VOL="$(qm config "$VMID" | awk -F': ' '/^unused0:/{print $2; exit}')"
if [[ -z "${IMPORTED_VOL}" ]]; then
  log "ERROR: importdisk did not create unused0 for VMID $VMID"
  exit 1
fi

# Attach imported disk as scsi0 and set as boot disk
qm set "$VMID" \
  --scsi0 "${IMPORTED_VOL},discard=on,iothread=1,ssd=1" \
  --boot order=scsi0

# finalize as template
qm template "$VMID"
#endregion

log "Template created: VMID=$VMID  (image baked + snippet generated)"
log "Snippet: $SNIPPET_PATH  (referenced as ${SNIPPET_STORAGE}:snippets/${SNIPPET_FILENAME})"
