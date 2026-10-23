# scripts

A collection of shell configs and system initialization scripts.

## sysinit/macos/macos-init.sh

macOS initialization: downloads and installs `zsh.zshrc` (idempotent).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/windypaddy/scripts/refs/heads/main/sysinit/macos/macos-init.sh)
```

## sysinit/debian/debian-init.sh

Debian initialization (requires root, idempotent): deploys `bash.bashrc`, configures the timezone (`Asia/Singapore`), apt mirrors and sources, SSH hardening (`sshd_config.d/03-mira.conf`), removes the `debian` user, and sets the locale (`LC_TIME=en_DK.UTF-8`) and `/etc/environment` defaults.

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/windypaddy/scripts/refs/heads/main/sysinit/debian/debian-init.sh)
```

## pve/update-template/debian/update-debian-template.sh

Builds (or rebuilds) the Debian cloud-image VM template on a Proxmox (PVE) host (requires root, idempotent, verifies the image checksum automatically).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/windypaddy/scripts/refs/heads/main/pve/update-template/debian/update-debian-template.sh)
```

## pve/update-template/fedora/update-fedora-template.sh

Builds (or rebuilds) the Fedora cloud-image VM template on a Proxmox (PVE) host (requires root, idempotent, verifies the image checksum automatically).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/windypaddy/scripts/refs/heads/main/pve/update-template/fedora/update-fedora-template.sh)
```

> All scripts are fetched online from the GitHub `main` branch. Local uncommitted changes have no effect until pushed.
