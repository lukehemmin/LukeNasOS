# LukeNasOS — a recovery-first personal NAS as a bootable container image.
#
# Build:  podman build -t lukenasos:dev .
# The base is pinned by digest: an OS that promises safe updates cannot
# itself update from a mutable tag. Bump the digest deliberately (CI has a
# scheduled rebuild that proposes bumps).
#
# NEVER bake credentials into this file. First-boot credentials come from
# the installer (installer/luke.ks). CI greps for leaked keys.

ARG BASE_IMAGE=quay.io/fedora/fedora-bootc:42
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
    && rm -rf /var/cache/dnf /var/lib/dnf

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

# ── systemd units, timers, and the Samba quadlet ─────────────────────────
COPY config/systemd/ /usr/lib/systemd/system/
COPY config/containers/samba.container /usr/share/containers/systemd/samba.container
RUN systemctl enable \
        lukenasos-boot-check.service \
        lukenasos-banner.service \
        lukenasos-scrub.timer \
        lukenasos-space-watchdog.timer \
        lukenasos-balance.timer \
        var-mnt-data.mount \
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
