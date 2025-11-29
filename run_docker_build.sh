#!/bin/bash

# Docker 기반 ISO 빌드 스크립트
# 이 스크립트는 로컬의 설정 파일들을 Docker 컨테이너 내부로 마운트하여 ISO를 빌드합니다.

set -e

# 프로젝트 루트 디렉토리 (LukeNasOS)
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_ROOT/iso_build/live-build-work"

# 호스트 사용자 ID/그룹 ID 가져오기 (빌드 후 파일 소유권 변경용)
HOST_UID=$(id -u)
HOST_GID=$(id -g)

# 작업 디렉토리 준비 (깨끗하게 시작)
if [ -d "$BUILD_DIR" ]; then
    echo "Cleaning up previous build directory (requires sudo due to Docker files)..."
    sudo rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

echo "=== LukeNasOS ISO Build with Docker ==="
echo "Project Root: $PROJECT_ROOT"
echo "Build Dir: $BUILD_DIR"

# 1. Docker 이미지 빌드
echo "Building Docker image..."
docker build -t lukenasos-builder iso_build/

# 2. 컨테이너 실행 및 빌드
echo "Running build inside Docker container..."
docker run --rm --privileged \
    -v "$PROJECT_ROOT:/project" \
    -w /project/iso_build/live-build-work \
    lukenasos-builder \
    /bin/bash -c "
        set -e
        echo 'Inside Docker: Configuring build...'
        
        # lb config 실행
        lb config \
            --distribution bookworm \
            --architectures amd64 \
            --linux-flavours amd64 \
            --archive-areas 'main contrib non-free-firmware' \
            --bootappend-live 'boot=live components quiet splash hostname=lukenasos' \
            --iso-volume 'LukeNasOS' \
            --mirror-bootstrap 'http://deb.debian.org/debian/' \
            --mirror-chroot 'http://deb.debian.org/debian/' \
            --mirror-chroot-security 'http://security.debian.org/debian-security/' \
            --mirror-binary 'http://deb.debian.org/debian/' \
            --mirror-binary-security 'http://security.debian.org/debian-security/'

        # 패키지 리스트 복사
        echo 'Adding custom packages...'
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
EOF

        # Web UI 설치 훅 생성
        echo 'Setting up Web UI installation hook...'
        mkdir -p config/hooks/normal
        cat <<HOOK > config/hooks/normal/01-install-web-ui.hook.chroot
#!/bin/bash
set -e
mkdir -p /opt/lukenasos/web_ui
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
systemctl enable lukenasos-web.service
HOOK
        chmod +x config/hooks/normal/01-install-web-ui.hook.chroot

        # Web UI 소스 복사
        echo 'Copying Web UI source files...'
        mkdir -p config/includes.chroot/opt/lukenasos/web_ui
        cp -r /project/web_ui/* config/includes.chroot/opt/lukenasos/web_ui/

        # 실제 빌드 시작
        echo 'Starting build process...'
        lb build
        
        # 빌드 완료 후 소유권 변경 (호스트 사용자가 파일을 다룰 수 있게)
        echo 'Fixing file permissions...'
        chown -R $HOST_UID:$HOST_GID .
    "

echo "=== Build Complete! ==="
echo "ISO file should be in: $BUILD_DIR"
ls -lh "$BUILD_DIR"/*.iso
