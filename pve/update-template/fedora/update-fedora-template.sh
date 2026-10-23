#!/usr/bin/env bash
#
# Build (or rebuild) the Fedora VM template on the local Proxmox (PVE) host.
#
# This is a plain-shell port of ansible-controls/playbooks/update-fedora-template.yml.
# The script is self-contained: it downloads its cloud-init snippets from GitHub
# (following the download-from-raw, diff-based idempotent pattern used by the
# sysinit scripts), deploys them to /var/lib/vz/snippets, then rebuilds the
# template via qm.
#
# Usage: bash update-fedora-template.sh
# Must be run as root (writes to /var/lib/vz/snippets and runs qm).
#
# Flow:
#   1. Extract description from the existing Fedora template
#   2. Discover the latest Fedora release, locate the Generic cloud qcow2
#      image and its checksum, build a {digest, version} JSON, compare with
#      the template description, exit if identical
#   3. Download the qcow2 image and verify it
#   4. Destroy the old template, full-clone the base template, rebuild VM with same vmid
#   5. Import the qcow2 directly as scsi0, then resize it with qm
#   6. Add a NIC (bridge=lan, firewall=1)
#   7. Configure cloud-init (custom user-data: cloud-init-fedora.yaml)
#   8. Start the VM, wait for it to power off, then convert it to a template
#   9. Set the template description to a hex encoding of the generated JSON
set -euo pipefail

# ===================== Logging (sysinit style) =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ===================== Configurable variables =====================
# VMID of the base template (clone source)
BASE_VMID=11001
# VMID of the Fedora VM template
FEDORA_VMID=12004

# Fedora releases directory. A fixed mirror is used on purpose: the official
# download.fedoraproject.org endpoint 302-redirects to a random nearby mirror,
# which may lag behind and lack the newest release. TUNA is a stable mirror,
# but its release directory may exist before the cloud images are synced; the
# script then falls back to the previous release.
RELEASES_URL="https://mirrors.tuna.tsinghua.edu.cn/fedora/releases/"
ARCH="x86_64"

# Helper settings
STORAGE="vd"             # Storage for disk / cloud-init
VM_NAME="fedora-cloud"   # Name of the rebuilt VM
CUSTOM_SCRIPT="local:snippets/cloud-init-fedora.yaml"   # Custom cloud-init user-data
NETWORK_SCRIPT="local:snippets/cloud-init-fedora-network.yaml"   # Custom cloud-init network-config (datasource)
DISK_SIZE="8G"          # Target size for resize
WAIT_TIMEOUT=900         # Max seconds to wait for the VM to power off

# Optional local qcow2 image for quick debugging: when set, the image is
# copied into the workspace instead of being downloaded from the mirror.
# Leave empty for normal use.
LOCAL_IMAGE_FILE=""

# GitHub raw base for downloading the cloud-init snippets. NOTE: the URL embeds
# the branch name 'main' and the repo path; keep in sync if either changes
# (see CODEBUDDY.md).
RAW_BASE="https://raw.githubusercontent.com/windypaddy/scripts/refs/heads/main/pve/update-template/fedora"
# Where the snippets live on the PVE host (matches the local:snippets/ refs above).
SNIPPETS_DIR="/var/lib/vz/snippets"

# Work directory: use the "tmp" subdir on the pve storage mount (/mnt/pve/tmp)
# instead of /tmp, so the multi-GB images don't touch the root filesystem or a
# memory-backed tmpfs.
TMPDIR=$(mktemp -d /mnt/pve/tmp/tmp/fedimg.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# ===================== Bootstrap: root check + snippet deploy =====================
check_root() {
  if (( EUID != 0 )); then
    log_error "This script must be run as root"
    exit 1
  fi
}

# Download a cloud-init snippet from GitHub and install it into SNIPPETS_DIR if
# it is missing or changed. Mirrors the idempotent download pattern in the
# sysinit scripts: fetch to a temp file, diff against the current file, only
# write when they differ.
download_snippet() {
  local name="$1"
  local url="${RAW_BASE}/${name}"
  local dest="${SNIPPETS_DIR}/${name}"
  local temp_file
  temp_file="$(mktemp)"

  if ! curl -fsSL "$url" -o "$temp_file"; then
    log_error "Failed to download ${name} from ${url}"
    rm -f "$temp_file"
    exit 1
  fi

  if [[ ! -s "$temp_file" ]]; then
    log_error "Downloaded ${name} is empty"
    rm -f "$temp_file"
    exit 1
  fi

  if [[ -f "$dest" ]] && diff -q "$dest" "$temp_file" > /dev/null 2>&1; then
    log_info "${name} unchanged, skipping"
    rm -f "$temp_file"
    return 0
  fi

  install -o root -g root -m 0644 "$temp_file" "$dest"
  log_info "${name} deployed to ${dest}"
  rm -f "$temp_file"
}

main() {
  check_root

  # Ensure the snippet directory exists and deploy the cloud-init user-data /
  # network-config from GitHub.
  mkdir -p "$SNIPPETS_DIR"
  chown root:root "$SNIPPETS_DIR"
  chmod 0755 "$SNIPPETS_DIR"
  download_snippet "cloud-init-fedora.yaml"
  download_snippet "cloud-init-fedora-network.yaml"

# ===================== 1. Extract description from the existing template =====================
log_info "Extracting description from template $FEDORA_VMID"
OLD_DESCRIPTION=$(qm config "$FEDORA_VMID" 2>/dev/null | sed -n 's/^description: //p' || true)

# ===================== 2. Discover version, build the JSON, compare =====================
log_info "Discovering the latest Fedora release from $RELEASES_URL"
RELEASES=$(curl -fsSL "$RELEASES_URL" | grep -oE 'href="[0-9]+/"' | sed -E 's/href="([0-9]+)\/"/\1/' | sort -nr)
if [[ -z "$RELEASES" ]]; then
  log_error "could not determine the latest Fedora release version"
  exit 1
fi

# Try the newest release first, then fall back to older ones: a mirror may
# carry the release directory but not (yet) the cloud image files inside it.
IMAGE_FILE=""
FEDORA_VER=""
for VER in $RELEASES; do
  IMAGES_URL="${RELEASES_URL}${VER}/Cloud/${ARCH}/images/"
  log_info "Listing cloud images for Fedora $VER"
  IMAGE_FILE=$(curl -fsSL "$IMAGES_URL" 2>/dev/null | grep -oE 'Fedora-Cloud-Base-Generic-[0-9]+-[0-9.]+\.x86_64\.qcow2' | head -1 || true)
  if [[ -n "$IMAGE_FILE" ]]; then
    FEDORA_VER="$VER"
    log_info "Using Fedora $FEDORA_VER (image: $IMAGE_FILE)"
    break
  fi
  log_info "No Generic qcow2 image for Fedora $VER, trying the previous release"
done
if [[ -z "$FEDORA_VER" ]]; then
  log_error "no Generic qcow2 image found in any release under $RELEASES_URL"
  exit 1
fi

# The build tag (e.g. "43-1.6") is used as the version and to locate the checksum file
BUILD=$(echo "$IMAGE_FILE" | sed -E 's/Fedora-Cloud-Base-Generic-([0-9]+-[0-9.]+)\.x86_64\.qcow2/\1/')
CHECKSUM_URL="${IMAGES_URL%/}/Fedora-Cloud-${BUILD}-${ARCH}-CHECKSUM"

log_info "Found image: $IMAGE_FILE (version $BUILD)"
# Fedora's CHECKSUM file is PGP-signed with lines like "SHA256 (file) = hash"
DIGEST=$(curl -fsSL "$CHECKSUM_URL" | grep -F "($IMAGE_FILE) =" | awk -F'= ' '{print $2}' | tr -d '[:space:]')
if [[ -z "$DIGEST" ]]; then
  log_error "no checksum matched $IMAGE_FILE in the checksum file"
  exit 1
fi

VERSION="$BUILD"
JSON_STRING=$(jq -nc --arg digest "$DIGEST" --arg version "$VERSION" '{digest:$digest, version:$version}')
# Store a hex encoding of the JSON in the template description instead of the
# raw JSON: Proxmox URL-encodes ':' (-> %3A) in the description value, breaking
# the write/read round-trip. Hex only uses [0-9a-f], which Proxmox never
# re-encodes. `od` ships with Debian's coreutils.
DESCRIPTION_HEX=$(printf '%s' "$JSON_STRING" | od -An -tx1 | tr -d ' \n')
log_info "Generated JSON: $JSON_STRING"
log_info "Current template description: $OLD_DESCRIPTION"

if [[ -n "$OLD_DESCRIPTION" && "$OLD_DESCRIPTION" == "$DESCRIPTION_HEX" ]]; then
  log_info "Image unchanged (digest=$DIGEST version=$VERSION), no rebuild needed, exit"
  exit 0
fi
log_info "Image changed, rebuilding template"

# ===================== 3. Download the qcow2 image and verify it =====================
IMAGE_URL="${IMAGES_URL}${IMAGE_FILE}"
if [[ -n "$LOCAL_IMAGE_FILE" ]]; then
  log_info "Using local image (skip download): $LOCAL_IMAGE_FILE"
  cp "$LOCAL_IMAGE_FILE" "$TMPDIR/$IMAGE_FILE"
else
  log_info "Downloading system image: $IMAGE_URL"
  curl -fsSL "$IMAGE_URL" -o "$TMPDIR/$IMAGE_FILE"
fi

# Verify the downloaded image with the sha256 checksum (never skipped)
echo "$DIGEST  $TMPDIR/$IMAGE_FILE" | sha256sum -c -
log_info "Image checksum verified"

# ===================== 4. Destroy old template, full-clone the base template =====================
if qm status "$FEDORA_VMID" >/dev/null 2>&1; then
  log_info "Disabling protection on $FEDORA_VMID"
  qm set "$FEDORA_VMID" --protection 0
  log_info "Destroying old template/VM $FEDORA_VMID"
  qm destroy "$FEDORA_VMID" --purge
fi

log_info "Full-cloning base template $BASE_VMID to $FEDORA_VMID"
qm clone "$BASE_VMID" "$FEDORA_VMID" --full 1 --name "$VM_NAME"

# ===================== 5. Import the qcow2 directly, then resize with qm =====================
log_info "Importing qcow2 image and attaching as scsi0"
qm set "$FEDORA_VMID" --scsi0 "$STORAGE:0,import-from=$TMPDIR/$IMAGE_FILE,iothread=1,ssd=1"
log_info "Resizing scsi0 to $DISK_SIZE"
qm resize "$FEDORA_VMID" scsi0 "$DISK_SIZE"

# ===================== 6. Add NIC =====================
log_info "Adding NIC (bridge=lan, firewall=1)"
qm set "$FEDORA_VMID" --net0 virtio,bridge=lan,firewall=1

# ===================== 7. Configure cloud-init =====================
log_info "Configuring cloud-init (user-data: $CUSTOM_SCRIPT, network: $NETWORK_SCRIPT)"
qm set "$FEDORA_VMID" --ide2 "$STORAGE:cloudinit"
qm set "$FEDORA_VMID" --cicustom "user=$CUSTOM_SCRIPT,network=$NETWORK_SCRIPT"

# ===================== 8. Start VM, wait for auto power-off, then convert to template =====================
log_info "Starting VM $FEDORA_VMID, waiting for auto power-off (cloud-init poweroff)"
qm start "$FEDORA_VMID"
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
while [[ "$(qm status "$FEDORA_VMID")" != *stopped* ]]; do
  if (( $(date +%s) > deadline )); then
    log_error "timed out waiting for VM $FEDORA_VMID to power off (${WAIT_TIMEOUT}s)"
    qm stop "$FEDORA_VMID" 2>/dev/null || true
    exit 1
  fi
  sleep 5
done
log_info "VM powered off"

# Remove the cloud-init drive and its custom user-data before converting to a
# template. The clone inherits protection from the base template, so disable
# protection first, detach them (ide2, cicustom), then re-enable protection.
log_info "Removing cloud-init drive (protection disabled first)"
qm set "$FEDORA_VMID" --protection 0
qm set "$FEDORA_VMID" --delete ide2,cicustom
qm set "$FEDORA_VMID" --protection 1

log_info "Converting to template"
qm template "$FEDORA_VMID"

# ===================== 9. Set template description =====================
log_info "Setting template description: $DESCRIPTION_HEX"
qm set "$FEDORA_VMID" --description "$DESCRIPTION_HEX"

log_info "Done: template $FEDORA_VMID updated to $IMAGE_FILE ($DISK_SIZE)"
}

main "$@"
