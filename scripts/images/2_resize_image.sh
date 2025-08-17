#!/bin/bash

# VM Image Resize Script using apt-get -o options
# Usage: ./resize-method2.sh <image-file> <new-size>

set -e

IMAGE=$1
NEW_SIZE=$2


if [ -z "$IMAGE" ] || [ -z "$NEW_SIZE" ]; then
    echo "Usage: $0 <image-file> <new-size>"
    echo "Example: $0 ubuntu-24.04.qcow2 15G"
    echo "Example: $0 ubuntu-24.04.qcow2 +10G"
    exit 1
fi

if [ ! -f "$IMAGE" ]; then
    echo "Error: Image file '$IMAGE' not found!"
    exit 1
fi

# Check if the effective user ID is 0 (root)
if [[ "$EUID" -ne 0 ]]; then
    echo "This script needs to be run with sudo."
    echo "Please run: sudo $0"
    exit 1
fi

echo "Script is running with sudo privileges."

echo "=== VM Resize with apt-get -o options ==="
echo "Image: $IMAGE"
echo "New size: $NEW_SIZE"
echo ""

# Create backup
BACKUP_IMAGE="${IMAGE}.backup.$(date +%Y%m%d_%H%M%S)"
echo "Creating backup: $BACKUP_IMAGE"
cp "$IMAGE" "$BACKUP_IMAGE"
echo "✓ Backup created"
echo ""

# Resize image file
echo "1. Resizing image file..."
qemu-img resize "$IMAGE" "$NEW_SIZE"
echo "✓ Image file resized"
echo ""

# Extend filesystem
echo "2. Extending filesystem using apt-get -o options..."

virt-customize -a "$IMAGE" --run-command '
echo "=== Starting filesystem extension ==="

# Show current state
echo "Before resize:"
df -h / 2>/dev/null || echo "Cannot determine current size"
echo ""

# Use apt-get with explicit proxy override options
echo "Installing required tools ..."

# Update package lists with explicit no-proxy options
echo "Updating package lists..."
apt-get -o Acquire::http::Proxy="false" -o Acquire::https::Proxy="false" update -y

# Install required packages with explicit no-proxy options  
echo "Installing cloud-utils-growpart, e2fsprogs, parted..."
apt-get -o Acquire::http::Proxy="false" -o Acquire::https::Proxy="false" install -y cloud-utils-growpart e2fsprogs parted

echo "✓ Packages installed successfully"
echo ""

# Extend partition using growpart
echo "Extending partition with growpart..."
if growpart /dev/sda 1; then
    echo "✓ Partition extended successfully"
else
    echo "growpart failed, trying parted fallback..."
    parted /dev/sda --script resizepart 1 100%
    echo "✓ Partition extended with parted"
fi

# Extend filesystem
echo "Extending filesystem with resize2fs..."
resize2fs /dev/sda1
echo "✓ Filesystem extended successfully"
echo ""

# Show final state
echo "After resize:"
df -h /
echo ""

# Verification
echo "=== Verification ==="
TOTAL_SIZE=$(df -h / | tail -1 | awk "{print \$2}")
AVAIL_SIZE=$(df -h / | tail -1 | awk "{print \$4}")
echo "Total size: $TOTAL_SIZE"
echo "Available: $AVAIL_SIZE"
echo ""

echo "Final partition layout:"
fdisk -l /dev/sda 2>/dev/null | head -10 || parted /dev/sda --script print

echo "✓ Resize operation completed successfully"
'

echo ""
echo "3. Final verification..."
echo "New image info:"
qemu-img info "$IMAGE" | grep "virtual size"
echo ""

echo "=== Resize Complete ==="
echo "✓ Image resized using apt-get -o options)"
echo "✓ No proxy interference"
echo "✓ Packages installed successfully"
echo "✓ Filesystem extended"
echo ""
echo "Files:"
echo "  Image: $IMAGE"
echo "  Backup: $BACKUP_IMAGE"
echo ""
echo "Next steps:"
echo "1. Boot the VM"
echo "2. Verify with: df -h"
echo "3. If successful, delete backup: rm $BACKUP_IMAGE"
