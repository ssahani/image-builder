#!/bin/bash
set -euo pipefail

# === CONFIGURATION ===
MAPPER_NAME="encrypted_root"
EXTRA_SPACE=$((20 * 1024 * 1024 * 1024))  # 20GB extra

# === DEPENDENCY CHECK ===
check_and_install() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ $cmd not found, installing $pkg..."
        sudo apt update && sudo apt install -y "$pkg"
    fi
}
check_and_install "jq" "jq"
check_and_install "qemu-img" "qemu-utils"
check_and_install "cryptsetup" "cryptsetup"
check_and_install "expect" "expect"
check_and_install "partx" "util-linux"
check_and_install "kpartx" "kpartx"

# === PASSWORD CHECK ===
if [ -z "${LUKS_PASSWORD:-}" ]; then
    echo "❌ LUKS_PASSWORD not set. Use: export LUKS_PASSWORD='your_password'"
    exit 1
fi

# === ARGUMENT PARSING ===
INPUT_RAW="$1"
ENCRYPTED_RAW="$2"

if [ -z "$INPUT_RAW" ] || [ -z "$ENCRYPTED_RAW" ]; then
    echo "Usage: $0 <input_raw_image> <output_encrypted_raw>"
    exit 1
fi

[ -f "$INPUT_RAW" ] || { echo "❌ Input file '$INPUT_RAW' not found."; exit 1; }

# === MOUNT INPUT DISK ===
echo "🔍 Mapping partitions from input image..."
LOOP_INPUT=$(sudo losetup --show --find --partscan "$INPUT_RAW")
sudo partx -u "$LOOP_INPUT"

EFI_PART="${LOOP_INPUT}p1"
BOOT_PART="${LOOP_INPUT}p2"
ROOT_PART="${LOOP_INPUT}p3"

[ -e "$EFI_PART" ] && [ -e "$BOOT_PART" ] && [ -e "$ROOT_PART" ] || {
    echo "❌ One or more partitions not found. Expecting EFI (p1), /boot (p2), and / (p3)."
    sudo losetup -d "$LOOP_INPUT"
    exit 1
}

# === SIZE CALCULATION ===
ROOT_SIZE=$(sudo blockdev --getsize64 "$ROOT_PART")
TOTAL_SIZE=$((ROOT_SIZE + 1024 * 1024 * 1024 + 1024 * 1024 * 512 + EXTRA_SPACE))  # +boot+efi+extra

echo "📏 Calculating image size..."
echo "📌 Creating target raw image of size: $TOTAL_SIZE bytes"
qemu-img create -f raw "$ENCRYPTED_RAW" "$TOTAL_SIZE"

# === PARTITION TARGET IMAGE ===
LOOP_OUTPUT=$(sudo losetup --show --find "$ENCRYPTED_RAW")
sudo parted -s "$LOOP_OUTPUT" mklabel gpt \
    mkpart EFI fat32 1MiB 513MiB \
    mkpart boot ext4 513MiB 1025MiB \
    mkpart root ext4 1025MiB 100%
sudo partx -u "$LOOP_OUTPUT"

TARGET_EFI="${LOOP_OUTPUT}p1"
TARGET_BOOT="${LOOP_OUTPUT}p2"
TARGET_ROOT="${LOOP_OUTPUT}p3"

# === COPY EFI + BOOT ===
echo "🗂️ Copying EFI and /boot partitions..."
sudo dd if="$EFI_PART" of="$TARGET_EFI" bs=1M status=progress conv=fsync
sudo dd if="$BOOT_PART" of="$TARGET_BOOT" bs=1M status=progress conv=fsync

# === ENCRYPT ROOT ===
echo "🔒 Encrypting root partition..."
if sudo cryptsetup status "$MAPPER_NAME" &>/dev/null; then
    echo "⚠️  Mapping $MAPPER_NAME already exists, closing..."
    sudo cryptsetup luksClose "$MAPPER_NAME" || sudo dmsetup remove --force "$MAPPER_NAME"
fi

echo "$LUKS_PASSWORD" | sudo cryptsetup luksFormat "$TARGET_ROOT" --type luks2 --batch-mode
echo "$LUKS_PASSWORD" | sudo cryptsetup luksOpen "$TARGET_ROOT" "$MAPPER_NAME"

# === COPY ROOT DATA ===
echo "🔄 Copying root partition..."
sudo dd if="$ROOT_PART" of=/dev/mapper/"$MAPPER_NAME" bs=4M status=progress conv=fsync

echo "🧹 Flushing and syncing..."
sudo sync
sudo blockdev --flushbufs /dev/mapper/"$MAPPER_NAME"
sudo udevadm settle

echo "🔒 Closing LUKS mapper..."
sudo cryptsetup luksClose "$MAPPER_NAME" || {
    echo "⚠️ Retrying with dmsetup..."
    sudo dmsetup remove --force "$MAPPER_NAME"
}

# === TPM2 ENROLL ===
echo "🔐 TPM2 auto-unlock enrollment..."
/usr/bin/expect <<EOF
spawn sudo systemd-cryptenroll --wipe-slot=1 --tpm2-device=auto --tpm2-pcrs=1+3+5+7+11+12+14+15 "$TARGET_ROOT"
expect "Please enter current passphrase for disk $TARGET_ROOT:"
send "$LUKS_PASSWORD\\r"
expect {
    "New TPM2 token enrolled as key slot 1." {exit 0}
    timeout {exit 1}
}
EOF

# === CLEANUP ===
echo "🧼 Cleaning up loop devices..."
sudo losetup -d "$LOOP_INPUT"
sudo losetup -d "$LOOP_OUTPUT"

echo "✅ Done! Encrypted image created at: $ENCRYPTED_RAW"
