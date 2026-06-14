#!/bin/sh
# LukeNasOS boot-mode generator (systemd system generator)
#
# systemd 가 유닛 로드 전, 부팅 극초반에 실행하는 generator.
# 커널 cmdline 으로 "지금이 어떤 부팅인지"를 판별해 OS 전체의 단일 소스로 만든다.
#
#   판별 규칙 (우선순위 순):
#     boot=live            → installer (설치 미디어로 부팅, 아직 미설치)
#     lukenasos.recovery=1 → recovery  (복구 슬롯 C)
#     그 외(rauc.slot=A/B) → system    (설치된 시스템 정상 부팅)
#
#   하는 일:
#     1) /run/lukenasos/boot-mode 에 모드 기록
#        → TUI(console_tui.py)·웹 UI 등 유저스페이스가 참조
#     2) installer 모드에서는 설치된 시스템 전용 유닛을 mask
#        → 존재하지 않는 NAS-BOOT/NAS-DATA 디바이스 90초 대기,
#          dependency-failed 콘솔 에러 스팸(TUI 화면 덮어씀)을 원천 차단
#
# /run/* 은 설치(installer.py 의 rsync)에서 제외되므로 설치본에는 영향이 없다.

EARLY_DIR="${2:-/run/systemd/generator.early}"

mode=system
for arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        boot=live)            mode=installer ;;
        lukenasos.recovery=1) [ "$mode" = system ] && mode=recovery ;;
    esac
done

mkdir -p /run/lukenasos
printf '%s\n' "$mode" > /run/lukenasos/boot-mode

if [ "$mode" = installer ]; then
    # 설치본 전용 유닛: live 부팅에는 대상 파티션(NAS-BOOT/NAS-DATA/슬롯)이 없다.
    # mask(/dev/null 심볼릭링크, generator.early 는 최우선)하면 fstab generator 가
    # 만든 마운트 유닛까지 덮어써서 디바이스 대기 자체가 생기지 않는다.
    mkdir -p "$EARLY_DIR"
    for unit in \
        boot-efi.mount \
        var-lib-lukenasos-data.mount \
        lukenasos-persistence.service \
        lukenasos-sshkeygen.service \
        lukenasos-confirm-boot.service \
        docker.service \
        docker.socket \
        containerd.service
    do
        ln -sf /dev/null "$EARLY_DIR/$unit"
    done
fi

exit 0
