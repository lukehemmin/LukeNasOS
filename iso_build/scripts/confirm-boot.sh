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

echo "confirm-boot: marking current slot good..."
rauc status mark-good
echo "confirm-boot: done."
