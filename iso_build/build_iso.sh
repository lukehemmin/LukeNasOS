#!/bin/bash

# ISO 빌드 스크립트 (Debian Live Build 기반)
# 이 스크립트는 Docker 컨테이너 내부 또는 호스트(필수 패키지 설치 시)에서 실행할 수 있습니다.

set -e

# 1. 경로 설정
# 스크립트가 위치한 디렉토리 (iso_build)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 프로젝트 루트 (LukeNasOS)
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# Live Build 작업 디렉토리
WORK_DIR="$SCRIPT_DIR/live-build-work"

echo "=== LukeNasOS ISO Build Script ==="
echo "Project Root: $PROJECT_ROOT"
echo "Work Dir:     $WORK_DIR"

# 2. 필수 패키지 확인 (호스트 실행 시 방어 로직)
if ! command -v lb >/dev/null 2>&1; then
    echo "Error: 'lb' command not found. Please install 'live-build' package."
    exit 1
fi

# 3. 작업 디렉토리 초기화
if [ -d "$WORK_DIR" ]; then
    echo "Cleaning up existing work directory..."
    rm -rf "$WORK_DIR"
fi
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "Initializing Live Build configuration..."
lb config \
    --distribution bookworm \
    --architectures amd64 \
    --linux-flavours amd64 \
    --archive-areas "main contrib non-free-firmware" \
    --bootappend-live "boot=live components quiet splash hostname=lukenasos" \
    --iso-volume "LukeNasOS" \
    --mirror-bootstrap "http://deb.debian.org/debian/" \
    --mirror-chroot "http://deb.debian.org/debian/" \
    --mirror-chroot-security "http://security.debian.org/debian-security/" \
    --mirror-binary "http://deb.debian.org/debian/" \
    --mirror-binary-security "http://security.debian.org/debian-security/" \
    --keyring-packages "debian-archive-keyring"

# 3.5 커스텀 부트로더 설정 적용 (LukeNasOS 브랜딩)
echo "Applying custom bootloader branding..."
BOOTLOADER_SRC="$SCRIPT_DIR/bootloaders"

# ISOLINUX/SYSLINUX (BIOS boot)
if [ -d "$BOOTLOADER_SRC/syslinux_common" ]; then
    mkdir -p config/bootloaders/isolinux
    mkdir -p config/bootloaders/syslinux_common
    cp -v "$BOOTLOADER_SRC/syslinux_common/"* config/bootloaders/syslinux_common/
    # isolinux도 syslinux_common의 splash를 참조하지만, 별도 복사로 안전하게
    cp -v "$BOOTLOADER_SRC/syslinux_common/splash.png" config/bootloaders/isolinux/ 2>/dev/null || true
fi

# GRUB (UEFI boot)
if [ -d "$BOOTLOADER_SRC/grub-pc" ]; then
    mkdir -p config/bootloaders/grub-pc/live-theme
    cp -v "$BOOTLOADER_SRC/grub-pc/splash.png" config/bootloaders/grub-pc/ 2>/dev/null || true
    cp -v "$BOOTLOADER_SRC/grub-pc/live-theme/theme.txt" config/bootloaders/grub-pc/live-theme/ 2>/dev/null || true
fi

# 4. 커스텀 패키지 리스트 추가
echo "Adding custom packages..."
mkdir -p config/package-lists
cat <<EOF > config/package-lists/nas.list.chroot
python3
python3-pip
python3-flask
python3-psutil
openssh-server
samba
net-tools
curl
vim
htop
rauc
rauc-service
dbus
parted
dosfstools
e2fsprogs
grub-pc-bin
grub-efi-amd64-bin
rsync
efibootmgr
docker.io
iptables
uidmap
EOF

# 4.5 OS 버전 파일
#  CI 가 LUKENASOS_VERSION 으로 빌드 버전을 전달한다. 웹 UI 가 이 파일을 읽어
#  현재 버전을 표시하고, GitHub 릴리즈와 비교해 온라인 업데이트 가능 여부를 판단한다.
#  같은 chroot 가 RAUC 번들 rootfs 로도 쓰이므로 업데이트 후 버전도 자동 반영된다.
echo "Writing OS version file (${LUKENASOS_VERSION:-0.0.0-dev})..."
mkdir -p config/includes.chroot/etc
echo "${LUKENASOS_VERSION:-0.0.0-dev}" > config/includes.chroot/etc/lukenasos-version

# 5. Web UI 설치 훅 생성
echo "Setting up Web UI installation hook..."
mkdir -p config/hooks/normal
cat <<EOF > config/hooks/normal/01-install-web-ui.hook.chroot
#!/bin/bash
set -e

# Web UI 디렉토리 생성
mkdir -p /opt/lukenasos/web_ui

# systemd 서비스 파일 생성
cat <<SERVICE > /etc/systemd/system/lukenasos-web.service
[Unit]
Description=LukeNasOS Web Dashboard
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/lukenasos/web_ui/app.py
WorkingDirectory=/opt/lukenasos/web_ui
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SERVICE

# 서비스 활성화
systemctl enable lukenasos-web.service
EOF
chmod +x config/hooks/normal/01-install-web-ui.hook.chroot

# 5.5 Web UI 접속 정보 표시 (Banner) 설정
echo "Setting up Web UI Banner..."

# 스크립트 파일 복사 (호스트 -> 이미지)
mkdir -p config/includes.chroot/opt/lukenasos/scripts
if [ -f "$SCRIPT_DIR/scripts/show_banner.sh" ]; then
    cp "$SCRIPT_DIR/scripts/show_banner.sh" config/includes.chroot/opt/lukenasos/scripts/
    chmod +x config/includes.chroot/opt/lukenasos/scripts/show_banner.sh
else
    echo "Error: Banner script not found at $SCRIPT_DIR/scripts/show_banner.sh"
    exit 1
fi

if [ -f "$SCRIPT_DIR/scripts/console_tui.py" ]; then
    cp "$SCRIPT_DIR/scripts/console_tui.py" config/includes.chroot/opt/lukenasos/scripts/
    chmod +x config/includes.chroot/opt/lukenasos/scripts/console_tui.py
else
    echo "Error: Console TUI script not found at $SCRIPT_DIR/scripts/console_tui.py"
    exit 1
fi

# Hook: systemd 서비스 설정만 수행
cat <<EOF > config/hooks/normal/02-install-banner.hook.chroot
#!/bin/bash
set -e

# systemd 서비스 생성
cat <<SERVICE > /etc/systemd/system/lukenasos-banner.service
[Unit]
Description=Show LukeNasOS Access Banner
After=network-online.target
Wants=network-online.target
# 기존 getty(로그인)와 충돌 방지
Conflicts=getty@tty1.service

[Service]
Type=simple
ExecStart=/opt/lukenasos/scripts/show_banner.sh
Environment=TERM=linux
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVTDisallocate=yes
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SERVICE

# 기본 TTY1 로그인 프롬프트 비활성화 (배너가 독점하기 위해)
systemctl disable getty@tty1.service
# 배너 서비스 활성화
systemctl enable lukenasos-banner.service
EOF
chmod +x config/hooks/normal/02-install-banner.hook.chroot

# 'dashboard' 커맨드 설치: 콘솔(Alt+F2)에서 tty1 상태 화면으로 복귀.
#  - /usr/local/bin/dashboard 로 PATH 에 올림 (kbd 없이 VT ioctl 로 전환)
#  - 콘솔 로그인 시 복귀 방법을 안내 (/etc/profile.d)
if [ -f "$SCRIPT_DIR/scripts/dashboard.py" ]; then
    cp "$SCRIPT_DIR/scripts/dashboard.py" config/includes.chroot/opt/lukenasos/scripts/
    chmod +x config/includes.chroot/opt/lukenasos/scripts/dashboard.py
else
    echo "Error: dashboard script not found at $SCRIPT_DIR/scripts/dashboard.py"
    exit 1
fi

mkdir -p config/includes.chroot/usr/local/bin
ln -sf /opt/lukenasos/scripts/dashboard.py config/includes.chroot/usr/local/bin/dashboard

mkdir -p config/includes.chroot/etc/profile.d
cat <<'HINT' > config/includes.chroot/etc/profile.d/99-lukenasos-dashboard-hint.sh
# 콘솔 로그인 시 상태 화면 복귀 방법 안내 (대화형 셸에서만)
case "$-" in *i*)
    printf '\n\033[0;36m  상태 대시보드 화면으로 돌아가려면: \033[1;33mdashboard\033[0;36m 입력 (또는 Alt+F1)\033[0m\n\n'
;; esac
HINT
chmod +x config/includes.chroot/etc/profile.d/99-lukenasos-dashboard-hint.sh

# 5.6 Persistence (Data Preservation) 설정
echo "Setting up Persistence Layer..."

# 스크립트 파일 복사
if [ -f "$SCRIPT_DIR/scripts/persistence.sh" ]; then
    cp "$SCRIPT_DIR/scripts/persistence.sh" config/includes.chroot/opt/lukenasos/scripts/
    chmod +x config/includes.chroot/opt/lukenasos/scripts/persistence.sh
else
    echo "Error: Persistence script not found at $SCRIPT_DIR/scripts/persistence.sh"
    exit 1
fi

# Hook: Persistence Service
cat <<EOF > config/hooks/normal/03-install-persistence.hook.chroot
#!/bin/bash
set -e

cat <<SERVICE > /etc/systemd/system/lukenasos-persistence.service
[Unit]
Description=LukeNasOS Data Persistence Layer
# 데이터 파티션 마운트 이후 실행 (fstab에 의해 마운트됨)
# 구체적인 마운트 유닛 이름은 경로 기반임: var-lib-lukenasos-data.mount
RequiresMountsFor=/var/lib/lukenasos/data
# 네트워크 등 주요 서비스 시작 전에 실행되어야 함
Before=network-pre.target smbd.service nmbd.service ssh.service

[Service]
Type=oneshot
ExecStart=/opt/lukenasos/scripts/persistence.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
SERVICE

systemctl enable lukenasos-persistence.service
EOF
chmod +x config/hooks/normal/03-install-persistence.hook.chroot

# 5.7 Boot Confirmation (RAUC mark-good) 설정
echo "Setting up Boot Confirmation Service..."

# 스크립트 파일 복사
if [ -f "$SCRIPT_DIR/scripts/confirm-boot.sh" ]; then
    cp "$SCRIPT_DIR/scripts/confirm-boot.sh" config/includes.chroot/opt/lukenasos/scripts/
    chmod +x config/includes.chroot/opt/lukenasos/scripts/confirm-boot.sh
else
    echo "Error: Confirm-boot script not found at $SCRIPT_DIR/scripts/confirm-boot.sh"
    exit 1
fi

# Hook: Boot Confirmation Service
#  부팅이 multi-user 까지 도달하면 현재 A/B 슬롯을 good 으로 확정(rauc status mark-good).
#  도중에 실패하면 mark-good 가 호출되지 않아 grubenv 의 _TRY 가 남고 다음 부팅에 자동 롤백된다.
cat <<EOF > config/hooks/normal/04-install-confirm-boot.hook.chroot
#!/bin/bash
set -e

cat <<SERVICE > /etc/systemd/system/lukenasos-confirm-boot.service
[Unit]
Description=LukeNasOS Confirm Boot (RAUC mark-good)
# rauc 는 D-Bus 데몬(rauc-service)을 통해 동작하므로 dbus 이후,
# 그리고 핵심 서비스(web)가 올라온 뒤에 슬롯을 good 으로 확정한다.
After=dbus.service lukenasos-web.service

[Service]
Type=oneshot
ExecStart=/opt/lukenasos/scripts/confirm-boot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable lukenasos-confirm-boot.service
EOF
chmod +x config/hooks/normal/04-install-confirm-boot.hook.chroot

# 5.75 SSH 호스트 키 생성 서비스
#  live-build 의 8050-remove-openssh-server-host-keys 훅이 이미지에서 호스트 키를 제거한다.
#  live 모드에서는 live-config 가 부팅 시 재생성하지만, 설치된 시스템(rauc.slot=A/B/복구)은
#  live-config 가 안 돌아 키가 영영 없어 sshd 가 무한 재시작한다. 설치 시스템에서 부팅 때
#  키가 없으면 생성하도록 서비스를 추가한다(ssh 시작 전, persistence 이후 → /etc/ssh 영속 반영).
cat <<EOF > config/hooks/normal/05-install-sshkeygen.hook.chroot
#!/bin/bash
set -e

cat <<SERVICE > /etc/systemd/system/lukenasos-sshkeygen.service
[Unit]
Description=LukeNasOS Generate SSH host keys if missing
# persistence 가 /etc/ssh 를 데이터 파티션에 바인드한 이후 생성 → 키가 영속·슬롯 간 공유
After=lukenasos-persistence.service
Before=ssh.service
# 키가 이미 있으면(영속 복원 등) 건너뛴다
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable lukenasos-sshkeygen.service
EOF
chmod +x config/hooks/normal/05-install-sshkeygen.hook.chroot

# 5.78 부팅 모드 인지 (boot-mode generator)
#  커널 cmdline 으로 installer(live)/recovery/system 모드를 판별해 /run/lukenasos/boot-mode 에
#  기록하고, installer 모드에서는 설치본 전용 유닛(NAS-BOOT/NAS-DATA 마운트, persistence,
#  docker 등)을 mask 한다 → live 부팅에서 90초 디바이스 대기·콘솔 에러 스팸 제거.
echo "Setting up Boot Mode Generator..."
if [ -f "$SCRIPT_DIR/scripts/boot-mode-generator.sh" ]; then
    mkdir -p config/includes.chroot/usr/lib/systemd/system-generators
    cp "$SCRIPT_DIR/scripts/boot-mode-generator.sh" \
       config/includes.chroot/usr/lib/systemd/system-generators/lukenasos-boot-mode-generator
    chmod +x config/includes.chroot/usr/lib/systemd/system-generators/lukenasos-boot-mode-generator
else
    echo "Error: Boot mode generator not found at $SCRIPT_DIR/scripts/boot-mode-generator.sh"
    exit 1
fi

# 5.8 슬롯 비종속(slot-agnostic) /etc/fstab
#  A/B/C 어느 슬롯으로 부팅되든 동일하게 동작해야 한다.
#   - root(/) 은 GRUB 가 root=PARTUUID=... 로 마운트하므로 fstab 에 적지 않는다
#     (슬롯마다 PARTUUID 가 다르고, RAUC 가 슬롯을 재포맷하면 fs-UUID 도 바뀌기 때문).
#   - ESP/DATA 는 RAUC 가 건드리지 않는 고정 파티션이라 LABEL 로 안정적으로 마운트한다.
#   - ESP 는 필수 마운트(nofail 없음): RAUC grubenv(_TRY)가 ESP 에 있어, 마운트
#     실패를 무시한 채 mark-good 하면 루트 FS 의 엉뚱한 경로에 쓰고 실제 _TRY 는
#     남아 멀쩡한 슬롯이 롤백된다. live 부팅은 boot-mode generator 가
#     boot-efi.mount 를 mask 하므로 이 줄의 영향을 받지 않는다.
#   - DATA 는 live/복구 등 없을 수 있으므로 nofail (부팅 지연·실패 방지).
echo "Writing slot-agnostic /etc/fstab..."
mkdir -p config/includes.chroot/etc
cat <<EOF > config/includes.chroot/etc/fstab
# /etc/fstab (LukeNasOS, slot-agnostic)
# root(/) 은 GRUB 의 root=PARTUUID=... 로 마운트됨 (여기에 적지 않음)
# tmpfs /tmp 는 systemd 의 tmp.mount 가 자동 처리하므로 여기에 적지 않음
# ESP 는 필수(RAUC grubenv 위치), live 부팅은 generator 가 boot-efi.mount 를 mask 함
LABEL=NAS-BOOT  /boot/efi                vfat   umask=0077                 0 1
LABEL=NAS-DATA  /var/lib/lukenasos/data  ext4   defaults,nofail            0 2
EOF

# 5.85 부트 cmdline 조각 (슬롯 rootfs 에 동봉 → RAUC 업데이트로 갱신 가능)
#  ESP 의 grub.cfg(A/B 메뉴)가 슬롯에서 이 파일을 source 해 luke_extra 를 덮어쓴다.
#  새 릴리스에서 커널 부트옵션을 바꾸려면 이 값만 고치면 ESP 를 건드리지 않고 업데이트로 반영된다.
#  파일이 없거나 깨지면 grub.cfg 의 기본값으로 안전 부팅한다(복구 C 는 이 조각을 참조하지 않음).
echo "Writing boot cmdline fragment (/boot/lukenasos.cfg)..."
mkdir -p config/includes.chroot/boot
cat <<'EOF' > config/includes.chroot/boot/lukenasos.cfg
# LukeNasOS boot cmdline fragment (GRUB script). RAUC 업데이트로 갱신됨.
set luke_extra="quiet panic=60"
EOF

# 5.9 React Frontend Build
echo "Building React Frontend..."
FRONTEND_DIR="$PROJECT_ROOT/web_ui/frontend"
if [ -d "$FRONTEND_DIR" ]; then
    # Install dependencies and build
    # Using --prefix to run npm inside the directory
    echo "Running npm install..."
    npm install --prefix "$FRONTEND_DIR"
    echo "Running npm run build..."
    npm run build --prefix "$FRONTEND_DIR"
    
    # Copy build artifacts to ISO context
    echo "Copying frontend build artifacts..."
    mkdir -p config/includes.chroot/opt/lukenasos/web_ui/frontend_dist
    cp -r "$FRONTEND_DIR/dist/"* config/includes.chroot/opt/lukenasos/web_ui/frontend_dist/
else
    echo "Warning: Frontend directory not found at $FRONTEND_DIR"
fi

# 6. Web UI 소스 파일을 빌드 컨텍스트로 복사
echo "Copying Web UI source files to build context..."
mkdir -p config/includes.chroot/opt/lukenasos/web_ui
if [ -d "$PROJECT_ROOT/web_ui" ]; then
    # Copy Python backend files, excluding the frontend source directory
    rsync -av --exclude='frontend' --exclude='__pycache__' "$PROJECT_ROOT/web_ui/" config/includes.chroot/opt/lukenasos/web_ui/
else
    echo "Warning: Web UI source directory not found at $PROJECT_ROOT/web_ui"
fi

# 7. RAUC 설정 및 인증서 복사
echo "Configuring RAUC (Certificates & System Config)..."
mkdir -p config/includes.chroot/etc/rauc

# 인증서 복사
CERT_PATH="$PROJECT_ROOT/certs/devel.cert.pem"
if [ -f "$CERT_PATH" ]; then
    cp "$CERT_PATH" config/includes.chroot/etc/rauc/keyring.pem
    echo "  - Copied devel.cert.pem"
else
    echo "  ! Warning: Certificate not found at $CERT_PATH"
fi

# system.conf 생성
#  grubenv 는 ESP 의 grub 디렉토리에 둔다(슬롯과 분리). installer.py 의 _configure_rauc 와
#  반드시 동일해야 한다 — 이 conf 가 업데이트 번들 rootfs 에 구워지므로, grubenv 경로가
#  빠지면 업데이트된 슬롯에서 mark-good 이 ESP 의 grubenv(_TRY) 를 못 지워 다음 부팅에
#  정상 업데이트인데도 롤백/복구된다.
cat <<EOF > config/includes.chroot/etc/rauc/system.conf
[system]
compatible=LukeNasOS
bootloader=grub
grubenv=/boot/efi/grub/grubenv

[keyring]
path=/etc/rauc/keyring.pem

[slot.rootfs.0]
device=/dev/disk/by-partlabel/NAS-SYSTEM-A
type=ext4
bootname=A

[slot.rootfs.1]
device=/dev/disk/by-partlabel/NAS-SYSTEM-B
type=ext4
bootname=B
EOF

# 7.5 Docker + Compose (앱 기능)
#  불변 A/B OS 에서 앱(컨테이너)·이미지는 영구 DATA 파티션에 저장해야 업데이트/재부팅에도 유지된다.
#  daemon.json 의 data-root 를 DATA 파티션으로 돌리고, docker 가 DATA 마운트 이후 뜨게 한다.
echo "Setting up Docker + Compose (Apps feature)..."

# (a) daemon.json: data-root → DATA 파티션 (이미지·컨테이너·볼륨 영속)
mkdir -p config/includes.chroot/etc/docker
cat <<'EOF' > config/includes.chroot/etc/docker/daemon.json
{
  "data-root": "/var/lib/lukenasos/data/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF

# (b) docker.service drop-in: DATA 마운트 + persistence 이후에만 기동
#     (DATA 없는 live/복구 모드에선 docker 가 뜨지 않지만 부팅·웹UI 는 정상)
mkdir -p config/includes.chroot/etc/systemd/system/docker.service.d
cat <<'EOF' > config/includes.chroot/etc/systemd/system/docker.service.d/10-lukenasos.conf
[Unit]
RequiresMountsFor=/var/lib/lukenasos/data
After=lukenasos-persistence.service
EOF

# (c) 커널 모듈 (overlay 스토리지 / 브리지 네트워킹)
mkdir -p config/includes.chroot/etc/modules-load.d
cat <<'EOF' > config/includes.chroot/etc/modules-load.d/docker.conf
overlay
br_netfilter
EOF

# (d) Compose v2 플러그인 (벤더링)
#     우선순위: 1) iso_build/vendor/docker-compose (오프라인·결정적) 2) 핀고정 버전 다운로드(+sha256 검증)
#     필요 시 COMPOSE_VERSION 환경변수로 버전을 바꾼다.
COMPOSE_VERSION="${COMPOSE_VERSION:-v2.32.4}"
mkdir -p config/includes.chroot/usr/lib/docker/cli-plugins
COMPOSE_DEST="config/includes.chroot/usr/lib/docker/cli-plugins/docker-compose"
if [ -f "$SCRIPT_DIR/vendor/docker-compose" ]; then
    echo "  - Using vendored compose binary (iso_build/vendor/docker-compose)"
    cp "$SCRIPT_DIR/vendor/docker-compose" "$COMPOSE_DEST"
else
    COMPOSE_URL="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64"
    echo "  - Downloading docker compose $COMPOSE_VERSION ..."
    curl -fsSL -o "$COMPOSE_DEST" "$COMPOSE_URL"
    # 업스트림이 게시한 sha256 로 무결성 검증 (부분/손상 다운로드 방지)
    if curl -fsSL -o /tmp/compose.sha256 "${COMPOSE_URL}.sha256"; then
        EXPECTED=$(awk '{print $1}' /tmp/compose.sha256)
        ACTUAL=$(sha256sum "$COMPOSE_DEST" | awk '{print $1}')
        if [ "$EXPECTED" != "$ACTUAL" ]; then
            echo "Error: docker-compose checksum mismatch ($ACTUAL != $EXPECTED)"; exit 1
        fi
        echo "  - compose sha256 verified"
    fi
fi
chmod +x "$COMPOSE_DEST"

# (e) docker/containerd 서비스 활성화 훅
cat <<'EOF' > config/hooks/normal/06-install-docker.hook.chroot
#!/bin/bash
set -e
systemctl enable docker.service || true
systemctl enable containerd.service || true
EOF
chmod +x config/hooks/normal/06-install-docker.hook.chroot

# 8. ISO 빌드 실행
echo "Starting ISO build..."
lb build

echo "=== Build Complete ==="
echo "ISO location: $WORK_DIR"
ls -lh *.iso 2>/dev/null || true
