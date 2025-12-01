#!/bin/bash
# LukeNasOS Persistence Script
# This script ensures system configurations persist across A/B updates
# by binding files from the data partition to /etc.

DATA_ETC="/var/lib/lukenasos/data/etc"
SYSTEM_ETC="/etc"

echo "Starting LukeNasOS Persistence Layer..."

# Ensure data partition is mounted
if ! mountpoint -q /var/lib/lukenasos/data; then
    echo "Error: Data partition not mounted!"
    exit 1
fi

mkdir -p "$DATA_ETC"

# List of files/directories to persist
# Add more as needed (e.g., samba, network, ssh keys)
PERSIST_ITEMS=(
    "hostname"
    "hosts"
    "timezone"
    "localtime"
    "samba"  # Entire directory
    "NetworkManager" # Network settings
    "ssh"    # SSH Host keys
)

for ITEM in "${PERSIST_ITEMS[@]}"; do
    SRC="$DATA_ETC/$ITEM"
    DEST="$SYSTEM_ETC/$ITEM"

    # 1. If source exists in Data, bind mount it to System
    if [ -e "$SRC" ]; then
        echo "Restoring persistence for: $ITEM"
        
        # If it's a directory, ensure destination exists
        if [ -d "$SRC" ] && [ ! -d "$DEST" ]; then
             mkdir -p "$DEST"
        fi
        
        # Bind mount (creates a transparent link)
        # Using bind mount is safer than symlink for some system services
        mount --bind "$SRC" "$DEST"
        
    # 2. If source doesn't exist yet (First Boot), copy System -> Data
    elif [ -e "$DEST" ]; then
        echo "Initializing persistence for: $ITEM"
        cp -r "$DEST" "$SRC"
        
        # Now bind mount it back so future writes go to Data
        mount --bind "$SRC" "$DEST"
    fi
done

# Special handling for machine-id (needed for DHCP/logs consistency)
if [ ! -f "$DATA_ETC/machine-id" ] && [ -f /etc/machine-id ]; then
    cp /etc/machine-id "$DATA_ETC/machine-id"
fi
if [ -f "$DATA_ETC/machine-id" ]; then
    mount --bind "$DATA_ETC/machine-id" /etc/machine-id
fi

echo "Persistence Layer Applied."
