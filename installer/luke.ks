# LukeNasOS kickstart — the primary install path.
#
# Anaconda owns partitioning, mkfs, SELinux labelling, and the bootloader;
# `ostreecontainer` deploys our bootc image straight from a registry. This
# is the lowest-risk installer: everything custom about LukeNasOS is the
# btrfs subvolume layout and the post-install safety rig (pin + seed).
#
# Disk contract (SPEC.md §2 — the ext4 /boot is NOT negotiable: GRUB cannot
# write grubenv on btrfs, and greenboot's automatic rollback depends on the
# boot counter living there):
#
#   ESP   512 MiB  FAT32   /boot/efi
#   BOOT    1 GiB  ext4    /boot        (grubenv, boot_counter)
#   ROOT    rest   btrfs   subvolumes: root (@sysroot), @data, @seed

text
lang en_US.UTF-8
keyboard us
timezone Etc/UTC --utc
network --bootproto=dhcp --device=link --activate

# First login must exist: a machine you can boot but not enter is a failed
# install. The password below is a well-known INSTALLER DEFAULT, is flagged
# as expired so the first login forces a change, and sshd refuses password
# auth for root. Replace via --kickstart in automated installs.
rootpw --lock
user --name=luke --groups=wheel --password=lukenasos --plaintext

# The update source. The environment-provided REGISTRY makes the same
# kickstart serve CI (localhost registry) and real installs (GHCR).
ostreecontainer --url=ghcr.io/lukehemmin/lukenasos:stable --no-signature-verification

zerombr
clearpart --all --initlabel --disklabel=gpt

part /boot/efi --fstype=efi   --size=512
part /boot     --fstype=ext4  --size=1024 --label=lukenasos-boot
part btrfs.01  --fstype=btrfs --grow      --label=lukenasos-root

btrfs none --label=lukenasos-root btrfs.01
btrfs /             --subvol --name=root  LABEL=lukenasos-root
btrfs /var/mnt/data --subvol --name=@data LABEL=lukenasos-root
btrfs /var/mnt/seed --subvol --name=@seed LABEL=lukenasos-root

reboot

%post --erroronfail
set -euo pipefail

# 1. Pin the install deployment. This is the factory-reset target; pinning
#    means ostree cleanup can never garbage-collect it. No pin, no reset.
ostree admin pin 0

# 2. Expire the default password so first login forces a change.
chage -d 0 luke

# 3. @seed: the disaster-recovery fallback — an OCI archive of the exact
#    installed image on its own subvolume, for when even the ostree repo is
#    damaged. Captured on first boot with network (the installer environment
#    may be offline); the unit disarms itself when done.
cat > /etc/systemd/system/lukenasos-seed.service <<'EOF'
[Unit]
Description=LukeNasOS: capture the install image as the @seed recovery archive
After=network-online.target var-mnt-seed.mount
Wants=network-online.target
ConditionPathExists=!/var/lib/lukenasos/seed-captured

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'ref=$(. /etc/lukenasos/luke.conf && echo $IMAGE_REF); \
  skopeo copy docker://$ref oci-archive:/var/mnt/seed/seed.oci-archive && \
  mkdir -p /var/lib/lukenasos && touch /var/lib/lukenasos/seed-captured'
[Install]
WantedBy=multi-user.target
EOF
systemctl enable lukenasos-seed.service

# 4. Event zero.
mkdir -p /var/lib/lukenasos
printf '{"ts":"%s","type":"installed","detail":{}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /var/lib/lukenasos/events.jsonl
%end
