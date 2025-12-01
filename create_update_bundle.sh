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

# (예시) 여기에 실제로 업데이트할 파일들을 넣습니다.
# 보통은 전체 rootfs 이미지를 넣거나, 변경된 파일만 넣습니다.
# 여기서는 데모용으로 더미 파일과 Web UI 코드를 넣습니다.
mkdir -p "$TEMP_DIR/opt/lukenasos/web_ui"
cp -r "$PROJECT_ROOT/web_ui/"* "$TEMP_DIR/opt/lukenasos/web_ui/"

# manifest.raucm 생성
cat <<MANIFEST > "$TEMP_DIR/manifest.raucm"
[update]
compatible=LukeNasOS
version=$VERSION

[image.rootfs]
filename=rootfs.img
MANIFEST

# (데모용) 더미 rootfs 이미지 생성 (실제로는 빌드된 rootfs를 사용해야 함)
# 10MB 더미 파일
dd if=/dev/zero of="$TEMP_DIR/rootfs.img" bs=1M count=10

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

# 정리
rm -rf "$TEMP_DIR"

echo "=== Update Bundle Created ==="
echo "File: $OUTPUT_FILE"
ls -lh "$OUTPUT_FILE"
