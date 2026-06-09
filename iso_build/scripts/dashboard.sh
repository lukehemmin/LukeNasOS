#!/usr/bin/env python3
# LukeNasOS: 콘솔(Alt+F2 등)에서 tty1의 상태 대시보드 화면으로 복귀시키는 커맨드.
#
# 배너(show_banner.sh)는 lukenasos-banner.service 가 /dev/tty1 에 항상 띄워두고 있다.
# Alt+F2 로 콘솔(tty2)로 넘어온 뒤 이 명령을 실행하면 다시 tty1 로 화면이 전환된다.
# (키보드만으로는 Alt+F1 로도 같은 효과)
#
# kbd 패키지(chvt)가 없어도 동작하도록, 커널 VT ioctl 을 직접 호출한다.
#   VT_ACTIVATE  = 0x5606  지정한 VT 를 전면(foreground)으로
#   VT_WAITACTIVE= 0x5607  전환 완료까지 대기

import fcntl
import sys

VT_ACTIVATE = 0x5606
VT_WAITACTIVE = 0x5607
TARGET_VT = 1  # tty1 = 배너 대시보드

def main():
    try:
        # /dev/tty0 = 현재 전면 콘솔의 컨트롤러. VT 전환은 여기로 ioctl 한다.
        with open("/dev/tty0", "wb") as fd:
            fcntl.ioctl(fd, VT_ACTIVATE, TARGET_VT)
            fcntl.ioctl(fd, VT_WAITACTIVE, TARGET_VT)
    except PermissionError:
        sys.stderr.write("dashboard: VT 전환 권한이 없습니다. root 로 실행하세요.\n")
        return 1
    except OSError as e:
        sys.stderr.write("dashboard: 화면 전환 실패: %s\n" % e)
        sys.stderr.write("           키보드에서 Alt+F1 을 직접 눌러 보세요.\n")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
