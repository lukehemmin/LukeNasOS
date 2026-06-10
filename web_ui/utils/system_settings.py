import os
import subprocess
from utils.logger import logger

# 언어/시간대 같은 시스템 설정은 NAS-DATA 의 settings.json(단일 진실 공급원)에 저장된다.
# 시간대는 OS 에도 반영해야 하므로 이 모듈이 적용을 담당한다.
#  - 셋업 완료 시 1회 적용
#  - 앱 시작 시마다 재적용: A/B 업데이트로 새 슬롯의 /etc 가 번들 기본값으로 돌아가도
#    NAS-DATA 의 설정이 항상 이긴다 (재부팅·업데이트에도 영속).


def _valid_timezone(tz):
    """zoneinfo 에 존재하는 안전한 시간대 이름인지 검증 (경로 탈출 차단)."""
    return (
        isinstance(tz, str) and tz
        and not tz.startswith('/') and '..' not in tz
        and os.path.isfile(f"/usr/share/zoneinfo/{tz}")
    )


def current_timezone(root='/'):
    """현재 적용된 시간대 이름을 반환 (모르면 None)."""
    try:
        target = os.path.realpath(os.path.join(root, 'etc/localtime'))
        prefix = '/usr/share/zoneinfo/'
        if prefix in target:
            return target.split(prefix, 1)[1]
    except Exception:
        pass
    return None


def apply_timezone(tz, root='/'):
    """
    시간대를 적용한다. 잘못된 값은 경고만 남기고 False 반환 (호출측 흐름은 계속).
    root='/' (실행 중 시스템)에서는 timedatectl 을 우선 사용하고,
    실패 시(또는 root 가 다른 마운트/테스트 디렉토리면) /etc/timezone + /etc/localtime 을 직접 기록한다.
    """
    if not _valid_timezone(tz):
        logger.warning(f"Invalid timezone '{tz}', not applied")
        return False

    if current_timezone(root) == tz:
        return True  # 이미 적용됨 (시작 시 재적용 경로에서 불필요한 쓰기 방지)

    if root == '/':
        try:
            subprocess.run(['timedatectl', 'set-timezone', tz],
                           check=True, capture_output=True, text=True)
            logger.info(f"Timezone set to {tz} (timedatectl)")
            return True
        except Exception as e:
            logger.warning(f"timedatectl failed ({e}), falling back to direct file write")

    try:
        etc_dir = os.path.join(root, 'etc')
        os.makedirs(etc_dir, exist_ok=True)
        with open(os.path.join(etc_dir, 'timezone'), 'w') as f:
            f.write(tz + "\n")
        localtime = os.path.join(etc_dir, 'localtime')
        try:
            os.remove(localtime)
        except FileNotFoundError:
            pass
        # 실행 중 시스템은 절대 경로, 별도 루트(마운트/테스트)는 내부에서 유효한 상대 경로
        target = f"/usr/share/zoneinfo/{tz}" if root == '/' else f"../usr/share/zoneinfo/{tz}"
        os.symlink(target, localtime)
        logger.info(f"Timezone set to {tz} in {root}")
        return True
    except Exception as e:
        logger.warning(f"Failed to apply timezone '{tz}': {e}")
        return False
