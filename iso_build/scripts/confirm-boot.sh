#!/bin/bash
# LukeNasOS Boot Confirmation
#
# RAUC + GRUB A/B 부팅에서 "이번 부팅이 끝까지 성공했다"를 확정하는 스크립트.
# grub.cfg 는 슬롯을 고를 때마다 해당 슬롯의 _TRY 를 1 증가시킨다. 끝까지 부팅에 성공하면
# 여기서 `rauc status mark-good` 로 현재 슬롯을 good 으로 표시하고 _TRY 를 리셋한다.
# 만약 부팅 도중 죽으면 mark-good 가 호출되지 않아 _TRY 가 남고, 다음 부팅에서 grubenv 가
# 다른(이전) 슬롯을 자동 선택한다 = 자동 롤백.

set -e

# A/B 실제 슬롯으로 부팅된 경우에만 의미가 있다.
# - 복구 슬롯(rauc.slot=R)이나 live(boot=live)에서는 건너뛴다.
if ! grep -qE 'rauc\.slot=(A|B)' /proc/cmdline; then
    echo "confirm-boot: not booted from an A/B slot, skipping mark-good."
    exit 0
fi

if ! command -v rauc >/dev/null 2>&1; then
    echo "confirm-boot: rauc not available, skipping."
    exit 0
fi

# RAUC 의 grubenv(_TRY)는 ESP(/boot/efi) 위에 있다. ESP 가 마운트되지 않은 채
# mark-good 하면 루트 FS 의 엉뚱한 경로에 grubenv 를 쓰고 실제 _TRY 는 남아
# 다음 부팅에서 멀쩡한 슬롯이 롤백된다 → 마운트 확인 후에만 진행.
if ! mountpoint -q /boot/efi; then
    echo "confirm-boot: /boot/efi (ESP) is not mounted, NOT marking slot good." >&2
    exit 1
fi

# mark-good 전에 핵심 서비스(웹 UI)가 실제로 살아있는지 확인한다.
# After=lukenasos-web.service 는 시작 "순서"만 보장할 뿐(Type=simple 은 fork 즉시 started),
# 프로세스가 곧바로 죽어도 이 스크립트는 실행된다. 응답까지 확인해야
# 고장난 슬롯을 good 으로 확정하는 일을 막을 수 있다.
WEB_URL="http://127.0.0.1:80/"
HEALTH_TIMEOUT=120   # seconds
HEALTH_INTERVAL=3    # seconds

echo "confirm-boot: waiting for web UI at ${WEB_URL} (timeout ${HEALTH_TIMEOUT}s)..."
elapsed=0
until curl -fsS --max-time 5 -o /dev/null "$WEB_URL"; do
    elapsed=$((elapsed + HEALTH_INTERVAL))
    if [ "$elapsed" -ge "$HEALTH_TIMEOUT" ]; then
        # mark-good 를 호출하지 않고 실패로 끝낸다 → grubenv 의 _TRY 가 남아
        # 다음 부팅에서 이전 슬롯으로 자동 롤백된다.
        echo "confirm-boot: web UI did not become healthy within ${HEALTH_TIMEOUT}s, NOT marking slot good." >&2
        exit 1
    fi
    sleep "$HEALTH_INTERVAL"
done
echo "confirm-boot: web UI is healthy."

echo "confirm-boot: marking current slot good..."
rauc status mark-good
echo "confirm-boot: done."
