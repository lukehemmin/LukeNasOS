FROM debian:bookworm

# 필수 패키지 설치
RUN apt-get update && \
    apt-get install -y \
    live-build \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
    syslinux-utils \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    && rm -rf /var/lib/apt/lists/*

# 작업 디렉토리 설정
WORKDIR /build

# 빌드 스크립트 실행 권한 부여
CMD ["/bin/bash"]
