#!/bin/bash
set -euo pipefail

IMAGE="ubuntu-2204-efi-kube-v1.30.1"
MOUNT_BOOT="/mnt/boot"
MOUNT_ROOT="/mnt/root"
LOOP_DEVICE=""
CRYPT_NAME="luks-root"
ROOT_PASSWORD="Arm@1234"
EC2_USER_PASSWORD="Arm@1234"

cleanup() {
    echo "[*] Cleaning up..."
    for mount in "${MOUNT_ROOT}/boot/efi" "${MOUNT_ROOT}/boot" "${MOUNT_ROOT}" "${MOUNT_BOOT}"; do
        if mountpoint -q "$mount"; then
            sudo umount "$mount" 2>/dev/null || true
        fi
    done
    [[ -e "/dev/mapper/${CRYPT_NAME}" ]] && sudo cryptsetup luksClose "${CRYPT_NAME}" || true
    [[ -n "$LOOP_DEVICE" ]] && sudo losetup -d "$LOOP_DEVICE" || true
    echo "[*] Done."
}

trap cleanup EXIT

echo "[*] Setting up loop device..."
LOOP_DEVICE=$(sudo losetup --partscan --find --show "$IMAGE")
echo "[+] Loop device: $LOOP_DEVICE"

echo "[*] Mounting /boot partition..."
sudo mkdir -p "${MOUNT_BOOT}"
sudo mount -t ext4 "${LOOP_DEVICE}p2" "${MOUNT_BOOT}"

KEYFILE="${MOUNT_BOOT}/root_crypt.key"
if [[ ! -f "$KEYFILE" ]]; then
    echo "[!] Keyfile not found: $KEYFILE"
    exit 1
fi

echo "[*] Unlocking LUKS root partition..."
sudo cryptsetup luksOpen --key-file="$KEYFILE" "${LOOP_DEVICE}p3" "$CRYPT_NAME"

echo "[*] Mounting decrypted root partition..."
sudo mkdir -p "${MOUNT_ROOT}"
sudo mount "/dev/mapper/${CRYPT_NAME}" "${MOUNT_ROOT}"

echo "[*] Mounting /boot and /boot/efi..."
sudo mount -t ext4 "${LOOP_DEVICE}p2" "${MOUNT_ROOT}/boot"
sudo mount "${LOOP_DEVICE}p1" "${MOUNT_ROOT}/boot/efi"

# Remove machine-id for unique instance ID
echo "[*] Regenerating machine-id..."
sudo rm -f "${MOUNT_ROOT}/etc/machine-id"
sudo touch "${MOUNT_ROOT}/etc/machine-id"

# Set root password
echo "[*] Changing root password..."
echo "root:$ROOT_PASSWORD" | sudo chroot "${MOUNT_ROOT}" chpasswd
sudo chroot "${MOUNT_ROOT}" passwd -e root

# Create necessary directories
sudo mkdir -p "${MOUNT_ROOT}/etc/netplan"
sudo mkdir -p "${MOUNT_ROOT}/etc/cloud/cloud.cfg.d"
sudo mkdir -p "${MOUNT_ROOT}/usr/local/bin"

# Default Netplan config
echo "[*] Creating default Netplan config..."
sudo tee "${MOUNT_ROOT}/etc/netplan/01-netcfg.yaml" >/dev/null <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      dhcp6: false
      optional: false
EOF

# Systemd service file
echo "[*] Writing systemd service..."
sudo tee "${MOUNT_ROOT}/etc/systemd/system/first-boot-config.service" >/dev/null <<'EOF'
[Unit]
Description=First Boot Configuration Service
After=network.target systemd-networkd-wait-online.service
Wants=systemd-networkd-wait-online.service
ConditionFirstBoot=yes

[Service]
Type=oneshot
ExecStart=/usr/local/bin/first-boot-config.sh
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=yes
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF

# Enhanced first-boot script
echo "[*] Writing first-boot-config.sh..."
sudo tee "${MOUNT_ROOT}/usr/local/bin/first-boot-config.sh" >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail

# Debugging
exec > >(tee /var/log/first-boot.log) 2>&1
echo "Starting first boot configuration at $(date)"

# Network connectivity check
check_network() {
    for ((i=1; i<=5; i++)); do
        if ping -c 1 8.8.8.8 &>/dev/null; then
            echo "Network connectivity verified"
            return 0
        fi
        echo "Network not ready (attempt $i/5), retrying in 5 seconds..."
        sleep 5
    done
    return 1
}

# Set hostname from /boot/hostname if present
HOSTNAME_FILE="/boot/hostname"
if [[ -f "$HOSTNAME_FILE" ]]; then
    NEW_HOSTNAME=$(cat "$HOSTNAME_FILE" | tr -d '[:space:]')
    if [[ -n "$NEW_HOSTNAME" ]]; then
        echo "Setting hostname to: $NEW_HOSTNAME"
        hostnamectl set-hostname "$NEW_HOSTNAME"
        sed -i "1i 127.0.1.1\t$NEW_HOSTNAME" /etc/hosts
    fi
fi

# Apply Netplan config
NETPLAN_SRC="/boot/config.yaml"
NETPLAN_DEST="/etc/netplan/01-netcfg.yaml"

if [[ -f "$NETPLAN_SRC" ]]; then
    echo "Applying Netplan config from $NETPLAN_SRC"
    cp "$NETPLAN_SRC" "$NETPLAN_DEST"
    chmod 600 "$NETPLAN_DEST"
    netplan generate && netplan apply
fi

# Wait for network
echo "Waiting for network..."
check_network || echo "Warning: Network connectivity check failed"

# Cloud-init configs
CLOUD_INIT_NET_SRC="/boot/99-disable-network-config.cfg"
if [[ -f "$CLOUD_INIT_NET_SRC" ]]; then
    mkdir -p /etc/cloud/cloud.cfg.d
    cp "$CLOUD_INIT_NET_SRC" /etc/cloud/cloud.cfg.d/
    chmod 600 /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
fi

# System updates
echo "Updating package lists..."
apt-get update -q
echo "Upgrading installed packages..."
apt-get upgrade -y -q
apt-get autoremove -y -q

# User configuration
if ! id "ec2-user" &>/dev/null; then
    echo "Creating ec2-user..."
    useradd -m -s /bin/bash ec2-user
    echo "ec2-user:$EC2_USER_PASSWORD" | chpasswd
    usermod -aG sudo ec2-user
    echo "ec2-user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ec2-user
    chmod 440 /etc/sudoers.d/ec2-user
fi

# SSH key setup
SSH_SRC="/boot/ssh_key"
if [[ -f "$SSH_SRC" ]]; then
    mkdir -p /home/ec2-user/.ssh
    cp "$SSH_SRC" /home/ec2-user/.ssh/authorized_keys
    chmod 700 /home/ec2-user/.ssh
    chmod 600 /home/ec2-user/.ssh/authorized_keys
    chown -R ec2-user:ec2-user /home/ec2-user/.ssh
fi

# Completion marker
touch /var/lib/first-boot-config.done
echo "First boot configuration completed at $(date)"
EOF

# Set permissions
sudo chmod 755 "${MOUNT_ROOT}/usr/local/bin/first-boot-config.sh"

# Enable services
sudo chroot "${MOUNT_ROOT}" systemctl enable first-boot-config.service

# Default cloud-init configs if not present
if [[ ! -f "${MOUNT_BOOT}/99-disable-network-config.cfg" ]]; then
    sudo tee "${MOUNT_BOOT}/99-disable-network-config.cfg" >/dev/null <<'EOF'
network: {config: disabled}
EOF
fi

echo "[✓] Injection complete. First boot will:"
echo "    - Set hostname from /boot/hostname if present"
echo "    - Configure networking via Netplan"
echo "    - Update system packages"
echo "    - Create ec2-user with password $EC2_USER_PASSWORD"
echo "    - Set root password (expires on first login)"