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
dbus
parted
dosfstools
e2fsprogs
grub-pc-bin
grub-efi-amd64-bin
rsync
efibootmgr
EOF

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
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
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
cat <<EOF > config/includes.chroot/etc/rauc/system.conf
[system]
compatible=LukeNasOS
bootloader=grub

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

# 8. ISO 빌드 실행
echo "Starting ISO build..."
lb build

echo "=== Build Complete ==="
echo "ISO location: $WORK_DIR"
ls -lh *.iso 2>/dev/null || true