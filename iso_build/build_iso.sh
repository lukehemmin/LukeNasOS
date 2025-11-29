#!/bin/bash

# ISO 빌드 스크립트 (Debian Live Build 기반)
# 주의: 이 스크립트는 root 권한이 필요하며, live-build 패키지가 설치된 Debian/Ubuntu 환경에서 실행해야 합니다.

set -e

# 작업 디렉토리 설정
WORK_DIR="live-build-work"
NAS_ROOT="$(pwd)/.."

# 필수 패키지 확인
if ! command -v lb >/dev/null 2>&1; then
    echo "Error: 'lb' command not found. Please install 'live-build' package."
    exit 1
fi

# 작업 디렉토리 초기화
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

# 커스텀 패키지 리스트 추가
echo "Adding custom packages..."
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
EOF

# Web UI 파일 복사 (chroot hooks 사용)
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

# Web UI 소스 파일을 빌드 컨텍스트로 복사 (includes.chroot)
echo "Copying Web UI source files to build context..."
mkdir -p config/includes.chroot/opt/lukenasos/web_ui
cp -r "$NAS_ROOT/web_ui/"* config/includes.chroot/opt/lukenasos/web_ui/

echo "Building ISO image (this may take a while)..."
# 실제 빌드 명령어 (주석 처리: 실제 실행 시 시간이 오래 걸리고 root 권한 필요)
# sudo lb build

echo "Build configuration complete. Run 'sudo lb build' inside '$WORK_DIR' to generate the ISO."
