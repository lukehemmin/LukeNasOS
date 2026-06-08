#!/bin/bash
# LukeNasOS 개발용 서명 인증서 생성기
#
# RAUC 업데이트 번들은 서명되고, 시스템은 keyring(공개 인증서)으로 검증한다.
#  - certs/devel.key       : 개발용 개인키 (번들 서명용)  ← 저장소에 커밋하지 않음(.gitignore)
#  - certs/devel.cert.pem  : 개발용 공개 인증서 (keyring) ← build_iso.sh 가 이미지에 baking
#
# 사용:
#   ./generate_dev_certs.sh
#
# !! 주의: 이것은 개발/테스트 전용 키다. 배포 시 반드시 별도의 프로덕션 서명 키로 교체할 것.

set -e
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
CERT_DIR="$PROJECT_ROOT/certs"
mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/devel.key" ] && [ -f "$CERT_DIR/devel.cert.pem" ]; then
    echo "Dev certs already exist in $CERT_DIR (skip). Delete them to regenerate."
    exit 0
fi

echo "Generating development signing key/cert in $CERT_DIR ..."
openssl req -x509 -newkey rsa:4096 -nodes \
    -keyout "$CERT_DIR/devel.key" \
    -out "$CERT_DIR/devel.cert.pem" \
    -subj "/O=LukeNasOS/CN=LukeNasOS Development" \
    -days 3650

chmod 600 "$CERT_DIR/devel.key"
echo "Done:"
ls -l "$CERT_DIR"
