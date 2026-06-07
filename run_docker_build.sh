#!/bin/bash

# Docker 기반 ISO 빌드 래퍼 스크립트
# 이 스크립트는 'iso_build/build_iso.sh'를 격리된 Docker 환경에서 실행합니다.

set -e

# 프로젝트 루트
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_OUTPUT_DIR="$PROJECT_ROOT/iso_build/live-build-work"

# 빌드 모드 인자 (기본 fast). 예) ./run_docker_build.sh release
BUILD_MODE="${1:-fast}"

# 호스트 사용자 ID/그룹 ID (빌드 후 소유권 복구용)
HOST_UID=$(id -u)
HOST_GID=$(id -g)

echo "=== LukeNasOS Docker Build Wrapper ==="
echo "Project Root: $PROJECT_ROOT"

# 1. Docker 이미지 빌드 (BuildKit: 변경 없으면 레이어 캐시로 수초 내 스킵)
echo "Building Builder Image..."
export DOCKER_BUILDKIT=1
docker build -t lukenasos-builder iso_build/

# 2. 컨테이너 실행 및 빌드 스크립트 위임
echo "Running Build in Container..."
# --privileged: live-build는 마운트/chroot 작업 등을 위해 높은 권한 필요
docker run --rm --privileged \
    -e BUILD_MODE="$BUILD_MODE" \
    -v "$PROJECT_ROOT:/project" \
    lukenasos-builder \
    /project/iso_build/build_iso.sh

# 3. 소유권 복구
echo "Fixing file permissions..."
if [ -d "$BUILD_OUTPUT_DIR" ]; then
    sudo chown -R $HOST_UID:$HOST_GID "$BUILD_OUTPUT_DIR"
    echo "Permissions restored for $BUILD_OUTPUT_DIR"
fi

echo "=== Docker Build Finished ==="

