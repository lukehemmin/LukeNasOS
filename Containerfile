# LukeNasOS — a recovery-first personal NAS as a bootable container image.
#
# Build:  podman build -t lukenasos:dev .
# The base is pinned by digest: an OS that promises safe updates cannot
# itself update from a mutable tag. Bump the digest deliberately (CI has a
# scheduled rebuild that proposes bumps).
#
# NEVER bake credentials into this file. First-boot credentials come from
# the installer (installer/luke.ks). CI greps for leaked keys.

# fedora-bootc:44 as of 2026-07-17 (SUPPORT_END=2027-05-19). The scheduled
# rebuild workflow proposes digest bumps within the tag; the release bump is a
# deliberate act, because it is never just a digest — see the greenboot note
# at the enable list below, and the EOL watch in rebuild.yml.
ARG BASE_IMAGE=quay.io/fedora/fedora-bootc@sha256:d5a4f1265d5b0f27a75c91b8b16d19a647d09b712beb4312135eb53ce2c257ac
FROM ${BASE_IMAGE}

ARG VERSION=0.1.0-dev
LABEL org.opencontainers.image.title="LukeNasOS"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.source="https://github.com/lukehemmin/LukeNasOS"
LABEL org.opencontainers.image.description="Recovery-first personal NAS: atomic updates, hands-off rollback, data-preserving factory reset"

# greenboot drives the headline feature (hands-off rollback). jq/skopeo are
# luke's plumbing. samba-client stays out: Samba runs as a container.
RUN dnf install -y \
        greenboot greenboot-default-health-checks \
        jq skopeo btrfs-progs \
    && dnf clean all \
    && rm -rf /var/cache/* /var/lib/dnf /var/log/* /run/dnf

# ── the luke CLI ──────────────────────────────────────────────────────────
COPY luke/ /usr/libexec/lukenasos/
RUN chmod 0755 /usr/libexec/lukenasos/* \
    && ln -s /usr/libexec/lukenasos/luke /usr/bin/luke

# ── health checks and the rollback-cause recorder ────────────────────────
COPY config/greenboot/check/required/ /etc/greenboot/check/required.d/
COPY config/greenboot/red.d/          /etc/greenboot/red.d/
RUN chmod 0755 /etc/greenboot/check/required.d/*.sh /etc/greenboot/red.d/*.sh
# Two failed boots, then GRUB falls back to the previous deployment.
RUN printf 'GREENBOOT_MAX_BOOT_ATTEMPTS=2\n' > /etc/greenboot/greenboot.conf

# systemd-remount-fs fails on every composefs boot ("overlay: No changes
# allowed in reconfigure") — / is a read-only overlay and fstab's root
# options cannot be reapplied. Harmless, but it lands in systemctl --failed
# on every boot and pollutes the recorded rollback causes. Mask it.
RUN systemctl mask systemd-remount-fs.service

# ── the firewall ──────────────────────────────────────────────────────────
# SPEC §9 has said "nftables is required before any network-facing service
# ships" since the beginning; sshd shipped anyway, so this machine has been
# answering on 22 with no filter. nftables.service runs
# `nft -f /etc/sysconfig/nftables.conf`, so /etc holds one include line and
# the policy itself stays in /usr where the image owns it.
COPY config/network/lukenasos.nft /usr/share/lukenasos/lukenasos.nft
RUN printf '# LukeNasOS: the policy lives in the image (see SPEC §9).\n# Local additions can go below the include.\ninclude "/usr/share/lukenasos/lukenasos.nft"\n' \
        > /etc/sysconfig/nftables.conf

# The banner is the only place a fresh machine shows its setup address and
# token. It renders once at boot — before DHCP has necessarily answered — so
# a dispatcher hook re-renders it whenever the addresses change.
COPY config/network/50-lukenasos-banner /usr/lib/NetworkManager/dispatcher.d/50-lukenasos-banner
RUN chmod 0755 /usr/lib/NetworkManager/dispatcher.d/50-lukenasos-banner

# ── systemd units, timers, and the Samba quadlet ─────────────────────────
COPY config/systemd/ /usr/lib/systemd/system/
COPY config/containers/samba.container /usr/share/containers/systemd/samba.container
# greenboot ships DISABLED by Fedora preset. Without these enables the
# headline feature silently does not exist: no boot counter is set, checks
# never run, and a broken deployment boots to a green banner (verified the
# hard way in the first full lifecycle run).
#
# greenboot 0.16 (F43+) is a Rust rewrite that consolidated nine units into
# three. The eight names this list used to carry — loading-message, status,
# task-runner, grub2-set-counter, grub2-set-success,
# rpm-ostree-grub2-check-fallback, redboot-auto-reboot, redboot-task-runner —
# do not exist any more; their work moved inside the `greenboot` binary.
# `systemctl enable` fails loudly on a name it cannot find, which is the only
# reason this migration announced itself instead of silently disarming the
# rollback. greenboot-healthcheck.service pulls the other two in via its
# Also=, but they are listed anyway: this list is where a reader learns what
# the headline feature is made of.
#
# sshd is already on by the base preset; the enable here is deliberate, not
# redundant. A headless appliance whose recovery path depends on ssh should
# say so in one place rather than inherit it (SPEC §9). It is only defensible
# with a firewall in front of it, which is why nftables is on this list.
RUN systemctl enable \
        greenboot-healthcheck.service \
        greenboot-set-rollback-trigger.service \
        greenboot-success.target \
        lukenasos-boot-check.service \
        lukenasos-banner.service \
        lukenasos-scrub.timer \
        lukenasos-space-watchdog.timer \
        lukenasos-balance.timer \
        var-mnt-data.mount \
        nftables.service \
        sshd.service

# ── the data contract ─────────────────────────────────────────────────────
# @data mounts at /var/mnt/data (the bootc-sanctioned place for machine-local
# mounts); /data is the human-facing symlink. The share directory and the
# luke state directory are created by tmpfiles on first boot.
RUN ln -s var/mnt/data /data
RUN printf 'd /var/mnt 0755 root root -\nd /var/mnt/data 0755 root root -\nd /var/mnt/data/share 0770 root root -\nd /var/lib/lukenasos 0755 root root -\n' \
        > /usr/lib/tmpfiles.d/lukenasos.conf

# ── update identity ───────────────────────────────────────────────────────
RUN mkdir -p /etc/lukenasos \
    && printf 'IMAGE_REF=ghcr.io/lukehemmin/lukenasos:stable\n' > /etc/lukenasos/luke.conf

# ── container signature policy ────────────────────────────────────────────
# The policy ships inside the image, which means one malicious update could
# disable verification for every update after it — the pinned reset seed is
# the last line of defense (see docs/threat-model.md). localhost:5000 stays
# unverified: it is the CI lifecycle registry, unreachable in production.
COPY config/containers/policy.json /etc/containers/policy.json

# bootc lint catches contract violations (files in /var, missing labels)
# at build time instead of first boot.
RUN bootc container lint
