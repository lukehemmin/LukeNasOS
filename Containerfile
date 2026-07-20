# LukeNasOS — a recovery-first personal NAS as a bootable container image.
#
# Build:  podman build -t lukenasos:dev .
# The base is pinned by digest: an OS that promises safe updates cannot
# itself update from a mutable tag. Bump the digest deliberately (CI has a
# scheduled rebuild that proposes bumps).
#
# NEVER bake credentials into this file. First-boot credentials come from
# the installer (installer/luke.ks). CI greps for leaked keys.

# fedora-bootc:44 as of 2026-07-17 11:30 UTC (SUPPORT_END=2027-05-19),
# pinned via OUR MIRROR — since 2026-07-18 this pin is a guarantee, not a
# record. quay.io/fedora/fedora-bootc deletes a manifest the moment the tag
# moves off it (measured: 27 minutes from tag move to "manifest unknown"),
# which made the old quay pin break the build roughly daily and every past
# release unrebuildable. mirror-base.yml copies the base digest-preservingly
# into ghcr.io/lukehemmin/fedora-bootc-mirror (the digest below is
# byte-identical to upstream's) and keeps every mirrored digest tagged, so it
# can never be garbage-collected out from under this line. Weekly, an hour
# before scheduled-rebuild; the release bump stays a deliberate act, because
# it is never just a digest — see the greenboot note at the enable list
# below, and the EOL watch in rebuild.yml.
ARG BASE_IMAGE=ghcr.io/lukehemmin/fedora-bootc-mirror@sha256:451ab491a197c41ba07277bad6a72f6d8458d4dd9fb189b242419031aa9ea840
FROM ${BASE_IMAGE}

ARG VERSION=0.1.0-dev
LABEL org.opencontainers.image.title="LukeNasOS"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.source="https://github.com/lukehemmin/LukeNasOS"
LABEL org.opencontainers.image.description="Recovery-first personal NAS: atomic updates, hands-off rollback, data-preserving factory reset"

# greenboot drives the headline feature (hands-off rollback). jq/skopeo are
# luke's plumbing. samba-client stays out: Samba runs as a container.
# Cockpit is the product's web surface (SPEC §6): ws serves and terminates
# TLS, bridge runs the privileged side of a session, system brings the shell
# the wizard plugin mounts into. Named individually rather than via the
# `cockpit` metapackage, which would drag in the storage and networking pages
# this image deliberately ships hidden.
# avahi answers <hostname>.local so a headless NAS is findable without
# hunting the router's client list — deliberately AFTER the firewall existed
# (the install-UX review's condition for any new network service), with
# 5353/udp opened by name in the policy.
RUN dnf install -y \
        greenboot greenboot-default-health-checks \
        cockpit-ws cockpit-bridge cockpit-system \
        avahi \
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
#
# The second include is how a port opens without editing the policy: `luke setup
# share` drops a rule file in that directory when the first share exists and
# removes it with the last (SPEC §9). A wildcard include matching nothing is not
# an error in nft, so a fresh install needs no file there.
RUN printf '# LukeNasOS: the policy lives in the image (see SPEC §9).\n# Local additions can go below the include.\ninclude "/usr/share/lukenasos/lukenasos.nft"\ninclude "/etc/lukenasos/nftables.d/*.nft"\n' \
        > /etc/sysconfig/nftables.conf

# ── Cockpit: the wizard's room, with the machine room locked ─────────────
# 9090 was opened by the firewall and probed by the banner before Cockpit
# existed in the image — both written to become true the day this section
# landed. Product mode hides the stock pages (SPEC §6, decision 5.3A): one
# click in the storage pages can repartition the contract disk, one in the
# systemd page can disable greenboot — the exact guarantees this OS exists to
# keep, voidable from a browser. The hiding is menu overrides in /etc/cockpit;
# `luke unlock-console` removes them deliberately, with an event logged, and
# reads the same list written here so the verb and this file can never
# disagree about what "locked" means. A factory reset ships the overrides
# back with the fresh /etc: locked is the factory state.
#
# The list is generous on purpose: an override for a page that is not
# installed is ignored, and a page someone later layers in arrives hidden
# rather than open. TLS needs nothing here — cockpit-ws mints a self-signed
# certificate on first use, and the banner already tells the owner the
# browser warning is expected on a device with no domain name.
RUN printf '%s\n' systemd users metrics networkmanager storaged \
        packagekit kdump selinux sosreport apps playground \
        > /usr/share/lukenasos/cockpit-hidden-pages \
    && mkdir -p /etc/cockpit \
    && while read -r p; do \
           printf '{"menu": null, "tools": null, "dashboard": null}\n' \
               > "/etc/cockpit/$p.override.json"; \
       done < /usr/share/lukenasos/cockpit-hidden-pages
#
# The login page must say what to type: Cockpit's stock "Wrong user name or
# password" would never hint that the setup token IS the password (design
# finding 2.5). Its Banner hook is the one sanctioned way to put words on
# that page. This is the fresh-install text; `luke setup account` and
# identity-apply rewrite it the moment "sign in as luke" stops being true.
RUN printf '[Session]\nBanner = /etc/cockpit/issue.cockpit\n' \
        > /etc/cockpit/cockpit.conf \
    && printf "Sign in as 'luke'. The password is the setup token shown on this machine's own screen.\nThe certificate warning your browser gave is expected for a device with no public domain name.\n" \
        > /etc/cockpit/issue.cockpit

# ── the first-boot wizard (Cockpit plugin) ───────────────────────────────
# Step 1 of the setup flow (SPEC §6): a static page over `luke setup` — it
# renders luke output and spawns luke verbs, never useradd/nft/smbpasswd.
# With the stock pages hidden above, this is the only menu entry a fresh
# machine shows, which makes it the landing page without any shell
# configuration.
COPY web/lukenasos-setup/ /usr/share/cockpit/lukenasos-setup/

# ── the ssh door policy ───────────────────────────────────────────────────
# Deliberate, not inherited. SPEC §9 claimed passwords over ssh were refused
# while the console banner told a new owner to type the setup token at an ssh
# prompt — first login IS password auth, so it is switched on here by name,
# where a reader can find it, and the lifecycle asserts it against the running
# machine. Root is refused outright: the inherited default (prohibit-password)
# would still let root in with a key, and this machine's administrator is a
# wheel account (§10). 40- sorts before Fedora's 50-redhat.conf and sshd takes
# the first value it sees, so these two lines win.
RUN printf 'PasswordAuthentication yes\nPermitRootLogin no\n' \
        > /etc/ssh/sshd_config.d/40-lukenasos.conf

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
#
# cockpit.socket is the web surface's front door (SPEC §6): socket-activated,
# so cockpit-ws runs only while a browser is actually connected.
RUN systemctl enable \
        greenboot-healthcheck.service \
        greenboot-set-rollback-trigger.service \
        greenboot-success.target \
        lukenasos-boot-check.service \
        lukenasos-banner.service \
        lukenasos-identity.service \
        cockpit.socket \
        avahi-daemon.service \
        lukenasos-scrub.timer \
        lukenasos-space-watchdog.timer \
        lukenasos-health.timer \
        lukenasos-balance.timer \
        var-mnt-data.mount \
        nftables.service \
        sshd.service

# ── the data contract ─────────────────────────────────────────────────────
# @data mounts at /var/mnt/data (the bootc-sanctioned place for machine-local
# mounts); /data is the human-facing symlink. The share directory and the
# luke state directory are created by tmpfiles on first boot.
#
# /var/mnt/data/share is the root the Samba container binds; each share the
# wizard creates is a directory under it. The identity capsule beside it holds
# password hashes, hence 0700 — see lib.sh's LUKE_CAPSULE note for why it is on
# /data and not in /etc.
RUN ln -s var/mnt/data /data
#
# /var/mnt/data/share is 0755 and not 0770, which is load-bearing: it is the
# parent every share hangs under, and Samba serves a file AS the user who
# authenticated. At 0770 root:root nobody but root could traverse it, so every
# share answered NT_STATUS_ACCESS_DENIED on every file — the port open, the
# credential accepted, the share listed, and not one byte readable. Found by
# mounting it (lifecycle phase 1c); no amount of local testing would have.
#
# Listing the names of the shares is not the secret; their contents are, and
# each share directory is 0770 owned by the account that may open it. Creating
# one still needs root.
RUN printf 'd /var/mnt 0755 root root -\nd /var/mnt/data 0755 root root -\nd /var/mnt/data/share 0755 root root -\nd /var/lib/lukenasos 0755 root root -\nd /etc/lukenasos/nftables.d 0755 root root -\n' \
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
