#!/bin/bash

echo "========================================"
echo " Installing PDF/Image Script Dependencies"
echo "========================================"

# Check for root privileges up front
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo or as root."
  exit 1
fi

# Update package lists to ensure we get the latest versions
echo "[1/2] Updating package lists..."
apt update

# Install all required packages
# The -y flag automatically answers "yes" to prompts
echo "[2/2] Installing required packages..."
apt install -y \
    pdfarranger \
    poppler-utils \
    gimp \
    imagemagick \
    pdftk \
    xournalpp \
    flatpak

echo "========================================"
echo " Installation Complete!"
echo "========================================"
