#!/usr/bin/env bash
#
# Build (or rebuild) the Debian VM template on the local Proxmox (PVE) host.
#
# This is a plain-shell port of ansible-controls/playbooks/update-debian-template.yml.
# The script is self-contained: it downloads its cloud-init snippets from GitHub
# (following the download-from-raw, diff-based idempotent pattern used by the
# sysinit scripts), deploys them to /var/lib/vz/snippets, then rebuilds the
# template via qm.
#
# Usage: bash update-debian-template.sh
# Must be run as root (writes to /var/lib/vz/snippets and runs qm).
#
# Flow:
#   1. Extract description from the existing Debian template
#   2. Download image metadata / checksum, build a {digest, version} JSON,
#      compare with the template description, exit if identical
#   3. Download the image archive -> extract raw disk
#   4. Destroy the old template, full-clone the base template, rebuild VM with same vmid
#   5. Import the raw disk as scsi0, then resize it with qm
#   6. Add a NIC (bridge=lan, firewall=1)
#   7. Configure cloud-init (custom user-data: cloud-init-debian.yaml)
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
# VMID of the Debian VM template
DEBIAN_VMID=12002

# System image download URL
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.tar.xz"
# Image metadata URL (must return a JSON containing a version field, e.g. {"version":"12.10.0"})
META_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.json"
# Image checksum URL (format: <hash>  <filename>, e.g. SHA512SUMS)
CHECKSUM_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"

# Helper settings
STORAGE="vd"            # Storage for disk / cloud-init
VM_NAME="debian-cloud"   # Name of the rebuilt VM
CUSTOM_SCRIPT="local:snippets/cloud-init-debian.yaml"   # Custom cloud-init user-data
NETWORK_SCRIPT="local:snippets/cloud-init-debian-network.yaml"   # Custom cloud-init network-config (datasource)
DISK_SIZE="8G"                 # Target size for resize
WAIT_TIMEOUT=900               # Max seconds to wait for the VM to power off

# GitHub raw base for downloading the cloud-init snippets. NOTE: the URL embeds
# the branch name 'main' and the repo path; keep in sync if either changes
# (see CODEBUDDY.md).
RAW_BASE="https://raw.githubusercontent.com/windypaddy/scripts/refs/heads/main/pve/update-template/debian"
# Where the snippets live on the PVE host (matches the local:snippets/ refs above).
SNIPPETS_DIR="/var/lib/vz/snippets"

# Work directory: use /srv/var (a dedicated storage mount) instead of /tmp, so
# the multi-GB images don't touch the root filesystem or a memory-backed tmpfs.
TMPDIR=$(mktemp -d /srv/var/debimg.XXXXXX)
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
  download_snippet "cloud-init-debian.yaml"
  download_snippet "cloud-init-debian-network.yaml"

# ===================== 1. Extract description from the existing template =====================
log_info "Extracting description from template $DEBIAN_VMID"
OLD_DESCRIPTION=$(qm config "$DEBIAN_VMID" 2>/dev/null | sed -n 's/^description: //p' || true)

# ===================== 2. Build the JSON and compare with the template description =====================
log_info "Downloading image metadata and checksum"
IMAGE_FILE=$(basename "$IMAGE_URL")

META_CONTENT=$(curl -fsSL "$META_URL")
# Debian's metadata JSON nests the version at .items[0].data.info.version;
# also accept a top-level .version, falling back to plain text for other sources
VERSION=$(echo "$META_CONTENT" | jq -r '.items[0].data.info.version // .version // empty' 2>/dev/null || true)
if [[ -z "$VERSION" ]]; then
  VERSION=$(echo "$META_CONTENT" | tr -d '[:space:]')
fi

DIGEST=$(curl -fsSL "$CHECKSUM_URL" | awk -v f="$IMAGE_FILE" '$2==f {print $1; exit}')
if [[ -z "$DIGEST" ]]; then
  log_error "no checksum matched $IMAGE_FILE in the checksum file"
  exit 1
fi

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

# ===================== 3. Download image archive -> extract raw =====================
log_info "Downloading system image: $IMAGE_URL"
curl -fsSL "$IMAGE_URL" -o "$TMPDIR/$IMAGE_FILE"

# Verify the downloaded archive with the checksum (never skipped)
case "${#DIGEST}" in
  64)  echo "$DIGEST  $TMPDIR/$IMAGE_FILE" | sha256sum -c - ;;
  128) echo "$DIGEST  $TMPDIR/$IMAGE_FILE" | sha512sum -c - ;;
  *)
    log_error "unexpected checksum length ${#DIGEST} for $IMAGE_FILE"
    exit 1
    ;;
esac
log_info "Image checksum verified"

# The archive contains a single raw disk image (disk.raw); extract it
log_info "Extracting image archive"
tar -xJf "$TMPDIR/$IMAGE_FILE" -C "$TMPDIR"
RAW_FILE="$TMPDIR/disk.raw"

# ===================== 4. Destroy old template, full-clone the base template =====================
if qm status "$DEBIAN_VMID" >/dev/null 2>&1; then
  log_info "Disabling protection on $DEBIAN_VMID"
  qm set "$DEBIAN_VMID" --protection 0
  log_info "Destroying old template/VM $DEBIAN_VMID"
  qm destroy "$DEBIAN_VMID" --purge
fi

log_info "Full-cloning base template $BASE_VMID to $DEBIAN_VMID"
qm clone "$BASE_VMID" "$DEBIAN_VMID" --full 1 --name "$VM_NAME"

# ===================== 5. Import raw disk as scsi0, then resize with qm =====================
log_info "Importing raw disk and attaching as scsi0"
qm set "$DEBIAN_VMID" --scsi0 "$STORAGE:0,import-from=$RAW_FILE,iothread=1,ssd=1"
log_info "Resizing scsi0 to $DISK_SIZE"
qm resize "$DEBIAN_VMID" scsi0 "$DISK_SIZE"

# ===================== 6. Add NIC =====================
log_info "Adding NIC (bridge=lan, firewall=1)"
qm set "$DEBIAN_VMID" --net0 virtio,bridge=lan,firewall=1

# ===================== 7. Configure cloud-init =====================
log_info "Configuring cloud-init (user-data: $CUSTOM_SCRIPT, network: $NETWORK_SCRIPT)"
qm set "$DEBIAN_VMID" --ide2 "$STORAGE:cloudinit"
qm set "$DEBIAN_VMID" --cicustom "user=$CUSTOM_SCRIPT,network=$NETWORK_SCRIPT"

# ===================== 8. Start VM, wait for auto power-off, then convert to template =====================
log_info "Starting VM $DEBIAN_VMID, waiting for auto power-off (cloud-init poweroff)"
qm start "$DEBIAN_VMID"
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
while [[ "$(qm status "$DEBIAN_VMID")" != *stopped* ]]; do
  if (( $(date +%s) > deadline )); then
    log_error "timed out waiting for VM $DEBIAN_VMID to power off (${WAIT_TIMEOUT}s)"
    qm stop "$DEBIAN_VMID" 2>/dev/null || true
    exit 1
  fi
  sleep 5
done
log_info "VM powered off"

# Remove the cloud-init drive and its custom user-data before converting to a
# template. The clone inherits protection from the base template, so disable
# protection first, detach them (ide2, cicustom), then re-enable protection.
log_info "Removing cloud-init drive (protection disabled first)"
qm set "$DEBIAN_VMID" --protection 0
qm set "$DEBIAN_VMID" --delete ide2,cicustom
qm set "$DEBIAN_VMID" --protection 1

log_info "Converting to template"
qm template "$DEBIAN_VMID"

# ===================== 9. Set template description =====================
log_info "Setting template description: $DESCRIPTION_HEX"
qm set "$DEBIAN_VMID" --description "$DESCRIPTION_HEX"

log_info "Done: template $DEBIAN_VMID updated to $IMAGE_FILE ($DISK_SIZE)"
}

main "$@"
