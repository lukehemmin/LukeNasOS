#!/bin/bash

# Docker 기반 업데이트 번들 (.raucb) 생성 스크립트
# 사용법: ./create_update_bundle.sh [버전]
# 예: ./create_update_bundle.sh 1.0.1

set -e

# 프로젝트 루트
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION=${1:-"1.0.0"}
BUNDLE_DIR="$PROJECT_ROOT/update_bundles"
OUTPUT_FILE="$BUNDLE_DIR/lukenasos-update-${VERSION}.raucb"

# 1. 필수 파일 확인
if [ ! -f "$PROJECT_ROOT/certs/devel.key" ] || [ ! -f "$PROJECT_ROOT/certs/devel.cert.pem" ]; then
    echo "Error: Certificates not found in certs/ directory."
    echo "Please run: mkdir -p certs && openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 ..."
    exit 1
fi

mkdir -p "$BUNDLE_DIR"

# 2. 업데이트 콘텐츠 준비 (임시 디렉토리)
TEMP_DIR=$(mktemp -d)
echo "Preparing update content in $TEMP_DIR..."

# 실제 RootFS 소스 위치 (Live Build 작업 결과물)
CHROOT_DIR="$PROJECT_ROOT/iso_build/live-build-work/chroot"

if [ ! -d "$CHROOT_DIR" ]; then
    echo "Error: Build chroot directory not found at $CHROOT_DIR"
    echo "Please run './run_docker_build.sh' first to build the base system."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# manifest.raucm 생성
#  - 슬롯은 system.conf 에서 type=ext4 로 선언된다. tar 아카이브를 주면 RAUC 가 설치 시
#    슬롯을 mkfs.ext4 로 포맷한 뒤 tar 를 풀어준다 → 매번 깨끗한 전체 교체(기존 SW 자동 제거).
#    (squashfs 이미지를 ext4 슬롯에 raw 로 쓰면 fstab/부팅과 어긋나므로 tar 로 일치시킨다.)
cat <<MANIFEST > "$TEMP_DIR/manifest.raucm"
[update]
compatible=LukeNasOS
version=$VERSION

[image.rootfs]
filename=rootfs.tar.gz
MANIFEST

# 실제 RootFS 이미지 생성 (tar 아카이브)
echo "Archiving rootfs from $CHROOT_DIR..."
# Docker를 사용하여 tar 실행 (호스트 의존성 제거 및 권한/소유권 보존)
#  --numeric-owner: 호스트의 사용자/그룹 이름 매핑에 의존하지 않고 UID/GID 보존
#  --xattrs/--acls : 확장 속성·ACL 보존 (samba 등에서 필요할 수 있음)
docker run --rm \
    -v "$PROJECT_ROOT:/project" \
    -v "$TEMP_DIR:/update-content" \
    lukenasos-builder \
    tar --numeric-owner --xattrs --acls \
        -czf /update-content/rootfs.tar.gz \
        -C /project/iso_build/live-build-work/chroot .

# 3. Docker를 사용하여 번들 생성 (호스트에 rauc가 없을 수 있으므로)
echo "Creating bundle using Docker..."
docker run --rm \
    -v "$PROJECT_ROOT:/project" \
    -v "$TEMP_DIR:/update-content" \
    -w /project \
    lukenasos-builder \
    rauc bundle \
        --cert /project/certs/devel.cert.pem \
        --key /project/certs/devel.key \
        /update-content \
        /project/update_bundles/$(basename "$OUTPUT_FILE")

# 4. 생성된 번들 검증 (rauc info)
echo "Verifying bundle..."
docker run --rm --privileged \
    -v "$PROJECT_ROOT:/project" \
    -w /project \
    lukenasos-builder \
    rauc info --keyring /project/certs/devel.cert.pem /project/update_bundles/$(basename "$OUTPUT_FILE")

# 정리
rm -rf "$TEMP_DIR"

echo "=== Update Bundle Created ==="
echo "File: $OUTPUT_FILE"
ls -lh "$OUTPUT_FILE"
