#!/bin/bash
set -euo pipefail

# === SCRIPT DESCRIPTION ===
# Purpose:
#   Creates an encrypted raw disk image from an unencrypted Ubuntu 22.04 raw disk
#   image with EFI, boot, and root partitions. Copies EFI and boot partitions as-is,
#   encrypts the root partition with LUKS2, and optionally enrolls a LUKS key for
#   TPM2-based auto-unlocking. The output is a raw disk image suitable for VMs or
#   physical disks.
#
# Improvements:
#   - Precise size calculations with explicit sector alignment.
#   - Enhanced error handling with cleanup on failure.
#   - Progress indicators for long-running operations.
#   - Option to skip TPM2 enrollment via flag.
#   - Validation of output file path and overwrite protection.
#   - Detailed logging with color output (optional).
#   - Support for custom LUKS cipher and key size.
#   - Robust EFI partition validation with partition type check.
#
# Usage:
#   export LUKS_PASSWORD='your_secure_password'
#   ./script.sh [-n] [-c cipher] [-k key_size] <input_raw_image> <output_encrypted_raw>
#   Options:
#     -n: Skip TPM2 enrollment.
#     -c: LUKS cipher (default: aes-xts-plain64).
#     -k: LUKS key size in bits (default: 512).
#   Example:
#     export LUKS_PASSWORD='secure123'
#     ./script.sh -n ubuntu-2204-efi-kube-v1.32.4.raw encrypted-ubuntu-2204.raw

# === CONFIGURATION ===
MAPPER_NAME="encrypted_root"
LUKS_HEADER_SIZE=$((16 * 1024 * 1024))  # 16 MiB for LUKS2 header
SECTOR_SIZE=512
ALIGNMENT=$((1 * 1024 * 1024))  # 1 MiB alignment
LUKS_CIPHER="aes-xts-plain64"
LUKS_KEY_SIZE=512
SKIP_TPM2=false

# === COLOR LOGGING ===
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
else
    RED='' GREEN='' YELLOW='' NC=''
fi

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $1"; }

# === CLEANUP FUNCTION ===
cleanup() {
    log "Cleaning up..."
    if [[ -n "${LOOP_INPUT:-}" && -e "$LOOP_INPUT" ]]; then
        sudo losetup -d "$LOOP_INPUT" 2>/dev/null || true
    fi
    if [[ -n "${LOOP_OUTPUT:-}" && -e "$LOOP_OUTPUT" ]]; then
        sudo losetup -d "$LOOP_OUTPUT" 2>/dev/null || true
    fi
    if [[ -e "/dev/mapper/$MAPPER_NAME" ]]; then
        sudo cryptsetup luksClose "$MAPPER_NAME" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# === DEPENDENCY CHECK ===
check_and_install() {
    local cmd="$1" pkg="$2"
    if ! command -v "$cmd" &>/dev/null; then
        log "Installing $pkg for $cmd..."
        sudo apt-get update -qq && sudo apt-get install -y "$pkg" || {
            error "Failed to install $pkg"; exit 1
        }
    fi
}
for dep in jq:jq qemu-img:qemu-utils cryptsetup:cryptsetup expect:expect partx:util-linux kpartx:kpartx blkid:util-linux parted:parted fdisk:util-linux; do
    check_and_install "${dep%%:*}" "${dep##*:}"
done

# === PARSE ARGUMENTS ===
while getopts "nc:k:" opt; do
    case "$opt" in
        n) SKIP_TPM2=true ;;
        c) LUKS_CIPHER="$OPTARG" ;;
        k) LUKS_KEY_SIZE="$OPTARG" ;;
        *) error "Invalid option"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

INPUT_RAW="$1"
ENCRYPTED_RAW="$2"

# === VALIDATE INPUTS ===
[[ -n "$INPUT_RAW" && -n "$ENCRYPTED_RAW" ]] || { error "Usage: $0 [-n] [-c cipher] [-k key_size] <input_raw_image> <output_encrypted_raw>"; exit 1; }
[[ -f "$INPUT_RAW" ]] || { error "Input file '$INPUT_RAW' not found"; exit 1; }
[[ -z "${LUKS_PASSWORD:-}" ]] && { error "LUKS_PASSWORD not set. Use: export LUKS_PASSWORD='your_password'"; exit 1; }
[[ -e "$ENCRYPTED_RAW" ]] && { error "Output file '$ENCRYPTED_RAW' already exists"; exit 1; }
OUTPUT_DIR=$(dirname "$ENCRYPTED_RAW")
[[ -d "$OUTPUT_DIR" && -w "$OUTPUT_DIR" ]] || { error "Output directory '$OUTPUT_DIR' is not writable"; exit 1; }

# === SETUP INPUT LOOP DEVICE ===
log "Setting up input loop device..."
LOOP_INPUT=$(sudo losetup --show --find --partscan "$INPUT_RAW") || { error "Failed to set up loop device for input"; exit 1; }
sudo partx -u "$LOOP_INPUT" || { error "Failed to update partition table for input"; exit 1; }
EFI_PART="${LOOP_INPUT}p1"
BOOT_PART="${LOOP_INPUT}p2"
ROOT_PART="${LOOP_INPUT}p3"

# === VALIDATE PARTITIONS ===
for part in "$EFI_PART" "$BOOT_PART" "$ROOT_PART"; do
    [[ -e "$part" ]] || { error "Missing partition $part"; exit 1; }
done
# Check EFI partition type and filesystem
EFI_PART_TYPE=$(sudo fdisk -l "$LOOP_INPUT" | grep "^${EFI_PART}" | awk '{print $5,$6,$7}' | grep -i "EFI System")
if [[ -z "$EFI_PART_TYPE" ]]; then
    EFI_PART_TYPE=$(sudo fdisk -l "$LOOP_INPUT" | grep "^${EFI_PART}" | awk '{print $5,$6,$7}')
    warn "EFI partition type is not EFI System (found: $EFI_PART_TYPE); proceeding, but may not be UEFI-compatible"
else
    log "EFI partition confirmed as EFI System type"
fi
EFI_FSTYPE=$(sudo parted -s "$LOOP_INPUT" print | grep "^ 1" | awk '{print $5}')
if [[ "$EFI_FSTYPE" != "fat32" ]]; then
    error "EFI partition is not fat32 (parted reports: $EFI_FSTYPE)"; exit 1
fi
BLKID_FSTYPE=$(sudo blkid -s TYPE -o value "$EFI_PART" 2>/dev/null || echo "")
if [[ "$BLKID_FSTYPE" != "vfat" ]]; then
    warn "blkid did not detect vfat for EFI partition (found: $BLKID_FSTYPE), but parted confirms fat32; proceeding"
else
    log "EFI partition confirmed as vfat by blkid"
fi
# Optional: Verify FAT32 with file command
if ! sudo file -s "$EFI_PART" | grep -q "FAT (32-bit)"; then
    warn "file command did not confirm FAT32, but parted reports fat32; proceeding"
else
    log "EFI partition confirmed as FAT32 by file command"
fi
[[ "$(lsblk -no FSTYPE "$BOOT_PART")" == "ext4" ]] || { error "Boot partition is not ext4"; exit 1; }
[[ "$(lsblk -no FSTYPE "$ROOT_PART")" == "ext4" ]] || { error "Root partition is not ext4"; exit 1; }

# === CALCULATE SIZES ===
EFI_SIZE=$(sudo blockdev --getsize64 "$EFI_PART")
BOOT_SIZE=$(sudo blockdev --getsize64 "$BOOT_PART")
ROOT_SIZE=$(sudo blockdev --getsize64 "$ROOT_PART")

# Align sizes to SECTOR_SIZE for precision
align_size() {
    local size=$1
    echo $(( (size + SECTOR_SIZE - 1) / SECTOR_SIZE * SECTOR_SIZE ))
}
EFI_SIZE=$(align_size "$EFI_SIZE")
BOOT_SIZE=$(align_size "$BOOT_SIZE")
ROOT_SIZE=$(align_size "$ROOT_SIZE")
TOTAL_SIZE=$((ALIGNMENT + EFI_SIZE + BOOT_SIZE + ROOT_SIZE + LUKS_HEADER_SIZE + ALIGNMENT))

log "Partition sizes: EFI=$((EFI_SIZE/1024/1024)) MiB, Boot=$((BOOT_SIZE/1024/1024)) MiB, Root=$((ROOT_SIZE/1024/1024)) MiB"
log "LUKS header: $((LUKS_HEADER_SIZE/1024/1024)) MiB, Alignment: $((ALIGNMENT/1024/1024)) MiB x 2"
log "Total size: $((TOTAL_SIZE/1024/1024/1024)) GiB ($TOTAL_SIZE bytes)"

# === SPACE CHECK ===
FREE_SPACE=$(df --output=avail -B1 "$OUTPUT_DIR" | tail -n1)
[[ "$FREE_SPACE" -gt "$TOTAL_SIZE" ]] || { error "Not enough disk space: need $((TOTAL_SIZE/1024/1024)) MiB, available $((FREE_SPACE/1024/1024)) MiB"; exit 1; }

# === CREATE AND PARTITION OUTPUT IMAGE ===
log "Creating encrypted image..."
qemu-img create -f raw "$ENCRYPTED_RAW" "$TOTAL_SIZE" || { error "Failed to create output image"; exit 1; }
LOOP_OUTPUT=$(sudo losetup --show --find "$ENCRYPTED_RAW") || { error "Failed to set up loop device for output"; exit 1; }

# Calculate partition boundaries in sectors
EFI_START=$((ALIGNMENT / SECTOR_SIZE))
EFI_END=$((EFI_START + EFI_SIZE / SECTOR_SIZE - 1))
BOOT_START=$((EFI_END + 1))
BOOT_END=$((BOOT_START + BOOT_SIZE / SECTOR_SIZE - 1))
ROOT_START=$((BOOT_END + 1))
ROOT_END=$((ROOT_START + (ROOT_SIZE + LUKS_HEADER_SIZE) / SECTOR_SIZE - 1))

sudo parted -s "$LOOP_OUTPUT" -- mklabel gpt \
    mkpart EFI fat32 ${EFI_START}s ${EFI_END}s \
    set 1 esp on \
    set 1 boot on \
    mkpart boot ext4 ${BOOT_START}s ${BOOT_END}s \
    mkpart root ext4 ${ROOT_START}s ${ROOT_END}s || { error "Failed to create partition table"; exit 1; }
sudo partx -u "$LOOP_OUTPUT" || { error "Failed to update partition table for output"; exit 1; }

TARGET_EFI="${LOOP_OUTPUT}p1"
TARGET_BOOT="${LOOP_OUTPUT}p2"
TARGET_ROOT="${LOOP_OUTPUT}p3"

# === COPY EFI + BOOT ===
log "Copying EFI and /boot partitions..."
sudo dd if="$EFI_PART" of="$TARGET_EFI" bs=4M status=progress conv=fsync || { error "Failed to copy EFI partition"; exit 1; }
sudo dd if="$BOOT_PART" of="$TARGET_BOOT" bs=4M status=progress conv=fsync || { error "Failed to copy boot partition"; exit 1; }

# === ENCRYPT ROOT ===
log "Encrypting root partition with LUKS2..."
echo "$LUKS_PASSWORD" | sudo cryptsetup luksFormat \
    --type luks2 \
    --cipher "$LUKS_CIPHER" \
    --key-size "$LUKS_KEY_SIZE" \
    --batch-mode "$TARGET_ROOT" || { error "Failed to format LUKS partition"; exit 1; }

echo "$LUKS_PASSWORD" | sudo cryptsetup luksOpen "$TARGET_ROOT" "$MAPPER_NAME" || { error "Failed to open LUKS volume"; exit 1; }
sudo dd if="$ROOT_PART" of="/dev/mapper/$MAPPER_NAME" bs=4M status=progress conv=fsync || { error "Failed to copy root partition"; exit 1; }
sudo cryptsetup luksClose "$MAPPER_NAME" || { error "Failed to close LUKS volume"; exit 1; }

# === TPM2 ENROLLMENT ===
if [[ "$SKIP_TPM2" == "false" ]]; then
    log "Checking TPM2 availability..."
    if sudo systemd-cryptenroll --tpm2-device=auto &>/dev/null; then
        log "Enrolling TPM2 key..."
        /usr/bin/expect <<EOF
spawn sudo systemd-cryptenroll --wipe-slot=1 --tpm2-device=auto --tpm2-pcrs=1+3+5+7+11+12+14+15 "$TARGET_ROOT"
expect "Please enter current passphrase for disk $TARGET_ROOT:"
send "$LUKS_PASSWORD\r"
expect {
    "New TPM2 token enrolled" {exit 0}
    timeout {exit 1}
}
EOF
        [[ $? -eq 0 ]] || { error "Failed to enroll TPM2 key"; exit 1; }
    else
        warn "TPM2 not available, skipping enrollment"
    fi
else
    log "Skipping TPM2 enrollment as requested"
fi

# === DONE ===
log "Encrypted image created: $ENCRYPTED_RAW"
log "Sizes: EFI=$((EFI_SIZE/1024/1024)) MiB, Boot=$((BOOT_SIZE/1024/1024)) MiB, Root=$((ROOT_SIZE/1024/1024)) MiB + LUKS header ($((LUKS_HEADER_SIZE/1024/1024)) MiB)"
log "Total: $((TOTAL_SIZE/1024/1024/1024)) GiB ($TOTAL_SIZE bytes)"
