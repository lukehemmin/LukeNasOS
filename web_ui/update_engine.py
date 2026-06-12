import os
import re
import shutil
import subprocess
import json
import threading
import time
import urllib.error
import urllib.request
from utils.logger import logger

# 온라인 업데이트를 가져올 GitHub 저장소 (릴리즈 자산: lukenasos-update-{version}.raucb)
GITHUB_REPO = os.environ.get('LUKENASOS_UPDATE_REPO', 'lukehemmin/LukeNasOS')
VERSION_FILE = '/etc/lukenasos-version'
BUNDLE_ASSET_RE = re.compile(r'^lukenasos-update-(.+)\.raucb$')


def get_current_version():
    """
    빌드 시 이미지에 구워진 /etc/lukenasos-version 을 읽는다.
    (CI 가 LUKENASOS_VERSION 으로 전달 → build_iso.sh 가 includes.chroot 에 기록)
    개발 환경 등 파일이 없으면 환경변수 → '0.0.0-dev' 순으로 폴백.
    """
    try:
        with open(VERSION_FILE, 'r') as f:
            v = f.read().strip()
            if v:
                return v
    except OSError:
        pass
    return os.environ.get('LUKENASOS_VERSION', '0.0.0-dev')


def _parse_version(v):
    """'v1.0.0' / '0.0.0.12' / '0.0.0-dev' → 숫자 튜플. 프리릴리즈 접미사는 무시."""
    v = re.split(r'[-+]', v.strip().lstrip('vV'))[0]
    parts = []
    for p in v.split('.'):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    return tuple(parts)


def _version_newer(latest, current):
    a, b = _parse_version(latest), _parse_version(current)
    n = max(len(a), len(b))
    return a + (0,) * (n - len(a)) > b + (0,) * (n - len(b))

class UpdateEngine:
    def __init__(self):
        self.lock = threading.Lock()
        self.status = 'idle'
        self.message = ''
        self.progress = 0
        self.is_simulation = self._check_simulation_mode()
        
        # 초기 상태 로드
        self.active_slot = 'A'
        self.inactive_slot = 'B'
        self._refresh_slots()

    def _check_simulation_mode(self):
        """
        RAUC 실행 가능 여부 및 환경 변수 확인
        """
        if os.environ.get('RAUC_SIMULATION', '0') == '1':
            logger.info("UpdateEngine initialized in SIMULATION mode (env var)")
            return True

        # live(설치 미디어) 부팅: A/B 슬롯 파티션이 없어 rauc 가 정상 동작할 수 없다.
        # rauc D-Bus 대기로 웹 UI 시작이 지연되는 것도 막는다.
        try:
            with open('/proc/cmdline', 'r') as f:
                if 'boot=live' in f.read():
                    logger.info("UpdateEngine initialized in SIMULATION mode (live boot)")
                    return True
        except OSError:
            pass

        # rauc 명령어가 없으면 시뮬레이션 모드
        if subprocess.call(['which', 'rauc'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
            logger.info("UpdateEngine initialized in SIMULATION mode (rauc not found)")
            return True
            
        logger.info("UpdateEngine initialized in REAL mode")
        return False

    def _refresh_slots(self):
        """
        RAUC 상태를 확인하여 현재 슬롯 정보를 가져옵니다.
        """
        if self.is_simulation:
            self.active_slot = 'A'
            self.inactive_slot = 'B'
            return

        try:
            result = subprocess.run(['rauc', 'status', '--output-format=json'],
                                    capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                data = json.loads(result.stdout)
                
                # RAUC output parsing
                # Example structure: {"compatible": "...", "booted": "A", "slots": [...]}
                booted_slot = data.get('booted')
                
                if booted_slot:
                    self.active_slot = booted_slot
                    # Assuming simple A/B scheme
                    self.inactive_slot = 'B' if self.active_slot == 'A' else 'A'
                    logger.info(f"Slots refreshed: Active={self.active_slot}, Inactive={self.inactive_slot}")
                else:
                    logger.warning("Could not determine booted slot from RAUC status")

        except Exception as e:
            logger.error(f"Failed to refresh slots: {e}")

    def _slot_devices(self):
        """
        /etc/rauc/system.conf 를 파싱해 {bootname: device} 매핑을 반환한다.
        예: {'A': '/dev/sda3', 'B': '/dev/sda4'}
        """
        devices = {}
        conf_path = '/etc/rauc/system.conf'
        try:
            current_dev = None
            with open(conf_path, 'r') as f:
                for raw in f:
                    line = raw.strip()
                    if line.startswith('device='):
                        current_dev = line.split('=', 1)[1].strip()
                    elif line.startswith('bootname='):
                        bootname = line.split('=', 1)[1].strip()
                        if current_dev:
                            devices[bootname] = current_dev
                        current_dev = None
        except Exception as e:
            logger.warning(f"Could not parse {conf_path}: {e}")
        return devices

    def _bundle_image_bytes(self, bundle_path):
        """
        rauc info 로 번들 내 rootfs 이미지 크기(바이트)를 얻는다. 실패하면 None.
        주의: tar.gz 번들에서는 '압축된' 이미지 크기라 설치 후 실제 점유보다 작다.
        따라서 이 값이 슬롯보다 크면 '확실히 안 들어감'으로 판단하는 보수적 가드로만 쓴다
        (진짜 상한은 RAUC 가 추출 시점에 강제한다).
        """
        try:
            result = subprocess.run(['rauc', 'info', '--output-format=json', bundle_path],
                                    capture_output=True, text=True, timeout=30)
            if result.returncode != 0:
                return None
            data = json.loads(result.stdout)
            images = data.get('images', [])
            for entry in images:
                # 구조: [{"rootfs": {"filename": "...", "size": 123}}, ...]
                for _slot, info in entry.items():
                    size = info.get('size')
                    if size:
                        return int(size)
        except Exception as e:
            logger.warning(f"Could not read bundle image size: {e}")
        return None

    def _check_capacity(self, bundle_path):
        """
        업데이트 전 크기 가드. 비활성 슬롯에 번들이 들어갈 수 있는지 보수적으로 검사.
        반환: (ok: bool, message: str)
        """
        if self.is_simulation:
            return True, "simulation: capacity check skipped"

        devices = self._slot_devices()
        target_dev = devices.get(self.inactive_slot)
        if not target_dev:
            # 디바이스를 못 찾으면 가드를 건너뛰고 RAUC 에 위임 (가드가 업데이트를 막지 않도록)
            logger.warning(f"Slot device for '{self.inactive_slot}' not found; skipping capacity guard")
            return True, "capacity guard skipped (device unknown)"

        try:
            slot_bytes = int(subprocess.check_output(['blockdev', '--getsize64', target_dev],
                                                     text=True, timeout=10).strip())
        except Exception as e:
            logger.warning(f"blockdev failed for {target_dev}: {e}; skipping capacity guard")
            return True, "capacity guard skipped (size unknown)"

        image_bytes = self._bundle_image_bytes(bundle_path)
        if image_bytes is None:
            return True, "capacity guard skipped (bundle size unknown)"

        # 압축 이미지조차 슬롯의 95% 를 넘으면 풀었을 때 절대 안 들어감 → 사전 거부.
        if image_bytes > slot_bytes * 0.95:
            gib = 1024 ** 3
            return False, (f"Update image ({image_bytes / gib:.1f} GiB) does not fit "
                           f"slot {self.inactive_slot} ({slot_bytes / gib:.1f} GiB).")
        return True, "capacity ok"

    def get_status(self):
        return {
            'active_slot': self.active_slot,
            'inactive_slot': self.inactive_slot,
            'status': self.status,
            'message': self.message,
            'progress': self.progress
        }

    # ── 온라인 업데이트 (GitHub 릴리즈) ──────────────────────

    def _github_api(self, path):
        url = f'https://api.github.com/repos/{GITHUB_REPO}{path}'
        req = urllib.request.Request(url, headers={
            'User-Agent': 'LukeNasOS-Updater',
            'Accept': 'application/vnd.github+json',
        })
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode('utf-8'))

    def _find_latest_release(self):
        """
        정식 릴리즈(latest)를 우선 사용하고, 아직 정식 릴리즈가 없으면
        nightly 등 prerelease 중 최신을 사용한다.
        """
        try:
            return self._github_api('/releases/latest')
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
        for rel in self._github_api('/releases?per_page=10'):
            if not rel.get('draft'):
                return rel
        return None

    @staticmethod
    def _find_bundle_asset(release):
        for asset in release.get('assets', []):
            if BUNDLE_ASSET_RE.match(asset.get('name', '')):
                return asset
        return None

    def check_online_update(self):
        """
        GitHub 릴리즈를 조회해 업그레이드 가능 여부를 반환한다.
        반환 dict: current_version, latest_version, update_available,
                  release_name, prerelease, asset_name, asset_size, download_url
        """
        current = get_current_version()
        release = self._find_latest_release()
        asset = self._find_bundle_asset(release) if release else None
        if not release or not asset:
            return {
                'current_version': current,
                'latest_version': None,
                'update_available': False,
                'message': 'No update bundle found in GitHub releases.',
            }

        m = BUNDLE_ASSET_RE.match(asset['name'])
        latest = m.group(1) if m else release.get('tag_name', '').lstrip('vV')
        return {
            'current_version': current,
            'latest_version': latest,
            'update_available': _version_newer(latest, current),
            'release_name': release.get('name'),
            'prerelease': bool(release.get('prerelease')),
            'published_at': release.get('published_at'),
            'asset_name': asset['name'],
            'asset_size': asset.get('size'),
            'download_url': asset['browser_download_url'],
        }

    def download_and_install(self, dest_dir):
        """
        GitHub 릴리즈에서 최신 번들을 내려받아 설치한다 (비동기).
        클라이언트가 보낸 URL 을 신뢰하지 않고 서버가 직접 재조회한다.
        """
        with self.lock:
            if self.status in ('downloading', 'installing'):
                return False, "Update already in progress"
            self.status = 'downloading'
            self.message = 'Checking for updates...'
            self.progress = 0

        thread = threading.Thread(target=self._run_download_install, args=(dest_dir,))
        thread.start()
        return True, "Update started"

    def _run_download_install(self, dest_dir):
        dest = None
        try:
            info = self.check_online_update()
            if not info.get('update_available'):
                raise Exception(info.get('message') or 'Already up to date.')

            asset_size = info.get('asset_size') or 0
            os.makedirs(dest_dir, exist_ok=True)
            # 다운로드 전 여유 공간 가드 (검증 여유분 10%)
            free = shutil.disk_usage(dest_dir).free
            if asset_size and asset_size * 1.1 > free:
                gib = 1024 ** 3
                raise Exception(f"Not enough free space to download update "
                                f"({asset_size / gib:.1f} GiB needed, {free / gib:.1f} GiB free).")

            dest = os.path.join(dest_dir, info['asset_name'])
            logger.info(f"Downloading update {info['latest_version']} from {info['download_url']}")
            req = urllib.request.Request(info['download_url'],
                                         headers={'User-Agent': 'LukeNasOS-Updater'})
            with urllib.request.urlopen(req, timeout=60) as resp, open(dest, 'wb') as out:
                total = int(resp.headers.get('Content-Length') or asset_size or 0)
                done = 0
                while True:
                    chunk = resp.read(1024 * 1024)
                    if not chunk:
                        break
                    out.write(chunk)
                    done += len(chunk)
                    if total:
                        self.progress = int(done * 100 / total)
                        self.message = (f"Downloading update {info['latest_version']}... "
                                        f"{done // (1024 * 1024)} / {total // (1024 * 1024)} MiB")

            with self.lock:
                self.status = 'installing'
                self.message = 'Installing update...'
                self.progress = 0
            self._run_install(dest)
        except Exception as e:
            logger.error(f"Online update failed: {e}")
            self.status = 'error'
            self.message = str(e)
        finally:
            # 설치 성공/실패와 무관하게 내려받은 번들은 더 이상 필요 없다
            if dest:
                try:
                    os.remove(dest)
                except OSError:
                    pass

    def install_update(self, bundle_path):
        """
        비동기로 업데이트 설치를 시작합니다.
        """
        with self.lock:
            if self.status in ('downloading', 'installing'):
                return False, "Update already in progress"

            self.status = 'installing'
            self.message = 'Starting update...'
            self.progress = 0
        
        # 스레드 시작
        thread = threading.Thread(target=self._run_install, args=(bundle_path,))
        thread.start()
        return True, "Update started"

    def _run_install(self, bundle_path):
        """
        실제 설치 로직 (스레드 내부)
        """
        try:
            logger.info(f"Installing update bundle: {bundle_path}")
            
            if self.is_simulation:
                # 시뮬레이션 로직
                for i in range(1, 101):
                    time.sleep(0.1) # 10초 소요
                    self.progress = i
                    self.message = f"Installing... {i}%"
                
                self.status = 'success'
                self.message = f"Update installed to slot {self.inactive_slot}. Please reboot."
                logger.info("Simulation update complete")
                
            else:
                # 업데이트 전 크기 가드: 비활성 슬롯에 들어갈 수 있는지 먼저 확인
                self.message = "Checking slot capacity..."
                ok, cap_msg = self._check_capacity(bundle_path)
                if not ok:
                    raise Exception(cap_msg)
                logger.info(f"Capacity check: {cap_msg}")

                # 실제 RAUC 설치
                # RAUC install은 오래 걸리므로, 여기서 subprocess.run을 쓰면 블로킹되지만
                # 이 메서드 자체가 스레드이므로 괜찮음.
                # 진척도 표시를 위해 rauc install의 출력을 파싱하거나,
                # rauc status를 주기적으로 폴링하는 방법이 있음.
                # 여기서는 단순화하여 실행

                cmd = ['rauc', 'install', bundle_path]
                process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                stdout, stderr = process.communicate()
                
                if process.returncode == 0:
                    self.status = 'success'
                    self.message = "Update installed successfully. Please reboot."
                    logger.info(f"RAUC install success: {stdout}")
                else:
                    raise Exception(f"RAUC failed: {stderr}")

        except Exception as e:
            logger.error(f"Update failed: {e}")
            self.status = 'error'
            self.message = str(e)
        finally:
            # 파일 정리 등을 여기서 수행할 수도 있음
            pass

update_engine = UpdateEngine()
