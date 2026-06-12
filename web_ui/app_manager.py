import os
import re
import json
import socket
import shutil
import subprocess
import threading
import time
from utils.logger import logger

# app_id 는 인증된 사용자의 요청(body/URL)에서 와서 카탈로그/프로젝트 디렉토리 경로 조각으로
# 쓰인다. 검증이 없으면 '../x' 같은 값이 경로 탈출(rmtree/makedirs 대상 이탈)을 일으킬 수 있다.
# 카탈로그 디렉토리명 컨벤션(영숫자 + - _)만 허용하고 첫 글자는 영숫자로 고정해 '.'/'..'/'/' 를 차단.
_APP_ID_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_-]*$')


def _valid_app_id(app_id):
    return isinstance(app_id, str) and _APP_ID_RE.match(app_id) is not None

# 영구 저장 경로(DATA 파티션). dev 에서는 LUKENASOS_DATA_DIR 로 override.
#  app.py 와 동일한 기본값을 사용한다.
DATA_DIR = os.environ.get('LUKENASOS_DATA_DIR', '/var/lib/lukenasos/data')
APPS_DIR = os.path.join(DATA_DIR, 'apps')         # 앱별 compose 프로젝트(.yml/.env)
APPDATA_DIR = os.path.join(DATA_DIR, 'appdata')   # 앱별 영구 볼륨(bind mount 대상)
INSTALLED_JSON = os.path.join(APPS_DIR, 'installed.json')

# 카탈로그(이미지에 동봉): web_ui 와 함께 배포되므로 이 파일 기준 상대 경로.
#  production: /opt/lukenasos/web_ui/apps_catalog, dev: ./apps_catalog
CATALOG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'apps_catalog')

# host 점유 금지 포트: 웹 UI(80), https(443), ssh(22), samba(139/445).
RESERVED_HOST_PORTS = {22, 80, 443, 139, 445}

# 설치 전 DATA 최소 여유. 이미지 pull 실패/디스크 꽉참 방지용 보수적 가드.
MIN_FREE_BYTES = 2 * 1024 ** 3  # 2 GiB


class AppManager:
    """
    Compose-per-app 모델로 Docker 앱을 설치/제어한다.
    update_engine.UpdateEngine 와 동일한 싱글톤 + lock + 비동기 스레드 + 상태 폴링 패턴.
    docker / 'docker compose' 가 없으면 시뮬레이션 모드로 동작(개발 PC·live 모드 대비).
    """

    def __init__(self):
        self.lock = threading.Lock()
        # 설치는 한 번에 하나만(업데이트 엔진과 동일 정책).
        self.install_status = 'idle'   # idle|pulling|starting|success|error
        self.install_message = ''
        self.install_progress = 0
        self.install_app_id = None
        self.is_simulation = self._check_simulation_mode()
        self._ensure_dirs()

    # ----------------------------------------------------------------- 환경

    def _check_simulation_mode(self):
        if os.environ.get('APPS_SIMULATION', '0') == '1':
            logger.info("AppManager initialized in SIMULATION mode (env var)")
            return True
        # live(설치 미디어) 부팅: DATA 파티션이 없어 docker 데몬이 mask 된다.
        try:
            with open('/proc/cmdline', 'r') as f:
                if 'boot=live' in f.read():
                    logger.info("AppManager initialized in SIMULATION mode (live boot)")
                    return True
        except OSError:
            pass
        if subprocess.call(['which', 'docker'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
            logger.info("AppManager initialized in SIMULATION mode (docker not found)")
            return True
        # compose v2 플러그인 존재 확인
        if subprocess.call(['docker', 'compose', 'version'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
            logger.info("AppManager initialized in SIMULATION mode (docker compose not found)")
            return True
        logger.info("AppManager initialized in REAL mode (docker + compose)")
        return False

    def _ensure_dirs(self):
        for d in (APPS_DIR, APPDATA_DIR):
            try:
                os.makedirs(d, exist_ok=True)
            except Exception as e:
                logger.warning(f"Could not create {d}: {e}")

    # ----------------------------------------------------------------- 카탈로그

    def load_catalog(self):
        """apps_catalog/<id>/app.json 들을 읽어 카탈로그 목록을 만든다."""
        catalog = []
        if not os.path.isdir(CATALOG_DIR):
            logger.warning(f"Catalog dir not found: {CATALOG_DIR}")
            return catalog
        for app_id in sorted(os.listdir(CATALOG_DIR)):
            meta_path = os.path.join(CATALOG_DIR, app_id, 'app.json')
            if not os.path.isfile(meta_path):
                continue
            try:
                with open(meta_path, 'r') as f:
                    meta = json.load(f)
                meta['id'] = app_id  # 디렉토리명을 신뢰
                catalog.append(meta)
            except Exception as e:
                logger.error(f"Failed to load catalog entry {app_id}: {e}")
        return catalog

    def _get_catalog_entry(self, app_id):
        if not _valid_app_id(app_id):
            return None
        meta_path = os.path.join(CATALOG_DIR, app_id, 'app.json')
        if not os.path.isfile(meta_path):
            return None
        with open(meta_path, 'r') as f:
            meta = json.load(f)
        meta['id'] = app_id
        return meta

    # ----------------------------------------------------------------- installed.json

    def _read_installed(self):
        if not os.path.isfile(INSTALLED_JSON):
            return []
        try:
            with open(INSTALLED_JSON, 'r') as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Failed to read {INSTALLED_JSON}: {e}")
            return []

    def _write_installed(self, entries):
        os.makedirs(APPS_DIR, exist_ok=True)
        with open(INSTALLED_JSON, 'w') as f:
            json.dump(entries, f, indent=2)

    def _upsert_installed(self, entry):
        entries = [e for e in self._read_installed() if e.get('id') != entry['id']]
        entries.append(entry)
        self._write_installed(entries)

    def _remove_installed(self, app_id):
        entries = [e for e in self._read_installed() if e.get('id') != app_id]
        self._write_installed(entries)

    # ----------------------------------------------------------------- compose 래퍼

    def _project_dir(self, app_id):
        # 경로 탈출 안전벨트: 공개 진입점에서 이미 검증하지만, 모든 디스크 접근
        # (makedirs/rmtree/compose cwd)이 여기로 수렴하므로 마지막 방어선을 둔다.
        if not _valid_app_id(app_id):
            raise ValueError(f"Invalid app_id: {app_id!r}")
        return os.path.join(APPS_DIR, app_id)

    def _compose(self, app_id, *args, timeout=600):
        """docker compose -p <id> <args> 를 프로젝트 디렉토리에서 실행."""
        cmd = ['docker', 'compose', '-p', app_id, *args]
        logger.info(f"[apps] {' '.join(cmd)} (cwd={self._project_dir(app_id)})")
        return subprocess.run(cmd, cwd=self._project_dir(app_id),
                              capture_output=True, text=True, timeout=timeout)

    # ----------------------------------------------------------------- 포트/용량 가드

    def _used_ports(self, exclude_app_id=None):
        used = set()
        for e in self._read_installed():
            if e.get('id') == exclude_app_id:
                continue
            for p in e.get('ports', []):
                used.add(int(p))
        return used

    @staticmethod
    def _port_free_on_host(port):
        """호스트에서 해당 TCP 포트를 바인드할 수 있으면 True."""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(('0.0.0.0', port))
            return True
        except OSError:
            return False
        finally:
            s.close()

    def _validate_ports(self, ports, app_id):
        used = self._used_ports(exclude_app_id=app_id)
        for p in ports:
            p = int(p)
            if p in RESERVED_HOST_PORTS:
                return False, f"포트 {p} 은(는) 시스템 예약 포트라 사용할 수 없습니다."
            if p in used:
                return False, f"포트 {p} 은(는) 이미 다른 앱이 사용 중입니다."
            if not self.is_simulation and not self._port_free_on_host(p):
                return False, f"포트 {p} 이(가) 호스트에서 이미 사용 중입니다."
        return True, "ok"

    def _check_data_capacity(self):
        try:
            free = shutil.disk_usage(DATA_DIR).free
        except Exception:
            return True, "capacity check skipped"
        if free < MIN_FREE_BYTES:
            gib = 1024 ** 3
            return False, (f"데이터 저장공간이 부족합니다 "
                           f"(여유 {free / gib:.1f} GiB, 최소 {MIN_FREE_BYTES / gib:.0f} GiB 권장).")
        return True, "ok"

    def _resolve_vars(self, entry, user_config):
        """변수 스키마 기본값 + 사용자 입력을 병합하고, 포트 목록을 반환한다."""
        user_config = user_config or {}
        resolved = {}
        ports = []
        for var in entry.get('variables', []):
            key = var['key']
            val = user_config.get(key, var.get('default'))
            resolved[key] = val
            if var.get('type') == 'port':
                ports.append(int(val))
        return resolved, ports

    # ----------------------------------------------------------------- 상태 조회

    def get_install_status(self):
        return {
            'status': self.install_status,
            'message': self.install_message,
            'progress': self.install_progress,
            'app_id': self.install_app_id,
        }

    def _container_state(self, app_id):
        """compose 프로젝트의 컨테이너 상태를 집계한다: running|stopped|error|unknown."""
        if self.is_simulation:
            return 'running'
        try:
            result = subprocess.run(
                ['docker', 'ps', '-a',
                 '--filter', f'label=com.docker.compose.project={app_id}',
                 '--format', '{{.State}}'],
                capture_output=True, text=True, timeout=15)
            states = [s.strip() for s in result.stdout.splitlines() if s.strip()]
            if not states:
                return 'stopped'
            if any(s == 'running' for s in states):
                return 'running'
            if any(s in ('exited', 'dead') for s in states):
                return 'stopped'
            return states[0]
        except Exception as e:
            logger.warning(f"state query failed for {app_id}: {e}")
            return 'unknown'

    def list_installed(self):
        items = []
        for e in self._read_installed():
            item = dict(e)
            item['state'] = self._container_state(e['id'])
            items.append(item)
        return items

    # ----------------------------------------------------------------- 설치(비동기)

    def install_app(self, app_id, user_config=None):
        entry = self._get_catalog_entry(app_id)
        if not entry:
            return False, f"알 수 없는 앱입니다: {app_id}"

        resolved, ports = self._resolve_vars(entry, user_config)

        ok, msg = self._validate_ports(ports, app_id)
        if not ok:
            return False, msg
        ok, msg = self._check_data_capacity()
        if not ok:
            return False, msg

        with self.lock:
            if self.install_status in ('pulling', 'starting'):
                return False, "다른 앱 설치가 진행 중입니다."
            self.install_status = 'pulling'
            self.install_message = '설치 준비 중...'
            self.install_progress = 0
            self.install_app_id = app_id

        thread = threading.Thread(target=self._run_install,
                                  args=(entry, resolved, ports))
        thread.start()
        return True, "설치를 시작했습니다."

    def _run_install(self, entry, resolved, ports):
        app_id = entry['id']
        try:
            if self.is_simulation:
                for i in range(0, 101, 10):
                    time.sleep(0.3)
                    self.install_progress = i
                    self.install_message = f"(시뮬레이션) 설치 중... {i}%"
                self._record_installed(entry, resolved, ports)
                self.install_status = 'success'
                self.install_message = f"{entry.get('name', app_id)} 설치 완료 (시뮬레이션)."
                return

            # 1) 프로젝트 디렉토리 구성: compose 복사 + .env 생성 + appdata 준비
            self.install_message = '구성 파일 준비 중...'
            self.install_progress = 5
            proj_dir = self._project_dir(app_id)
            appdata = os.path.join(APPDATA_DIR, app_id)
            os.makedirs(proj_dir, exist_ok=True)
            os.makedirs(appdata, exist_ok=True)
            shutil.copyfile(os.path.join(CATALOG_DIR, app_id, 'docker-compose.yml'),
                            os.path.join(proj_dir, 'docker-compose.yml'))
            self._write_env(proj_dir, resolved, appdata)

            # 2) 이미지 받기
            self.install_message = '이미지 받는 중... (수 분 걸릴 수 있습니다)'
            self.install_progress = 20
            pull = self._compose(app_id, 'pull')
            if pull.returncode != 0:
                raise Exception(f"이미지 받기 실패: {pull.stderr.strip()[:500]}")

            # 3) 컨테이너 시작
            self.install_status = 'starting'
            self.install_message = '앱 시작 중...'
            self.install_progress = 80
            up = self._compose(app_id, 'up', '-d')
            if up.returncode != 0:
                raise Exception(f"앱 시작 실패: {up.stderr.strip()[:500]}")

            self._record_installed(entry, resolved, ports)
            self.install_progress = 100
            self.install_status = 'success'
            self.install_message = f"{entry.get('name', app_id)} 설치 완료."
            logger.info(f"[apps] installed {app_id}")

        except Exception as e:
            logger.error(f"[apps] install failed for {app_id}: {e}")
            self.install_status = 'error'
            self.install_message = str(e)
            # 실패 시 부분 구성 정리(데이터는 남겨 재시도 가능)
            try:
                self._compose(app_id, 'down', timeout=120)
            except Exception:
                pass

    def _write_env(self, proj_dir, resolved, appdata):
        """compose 가 cwd 의 .env 를 자동 로드한다. APPDATA + 변수들을 기록."""
        lines = [f"APPDATA={appdata}"]
        for k, v in resolved.items():
            lines.append(f"{k}={v}")
        with open(os.path.join(proj_dir, '.env'), 'w') as f:
            f.write('\n'.join(lines) + '\n')

    def _record_installed(self, entry, resolved, ports):
        web_ui = entry.get('web_ui', {})
        port_var = web_ui.get('port_var')
        web_port = resolved.get(port_var) if port_var else (ports[0] if ports else None)
        self._upsert_installed({
            'id': entry['id'],
            'name': entry.get('name', entry['id']),
            'icon': entry.get('icon'),
            'color': entry.get('color'),
            'category': entry.get('category'),
            'web_ui_port': web_port,
            'web_ui_path': web_ui.get('path', '/'),
            'ports': ports,
            'dir': self._project_dir(entry['id']),
            'config': resolved,
            'installed_at': int(time.time()),
        })

    # ----------------------------------------------------------------- 제어

    def _lifecycle(self, app_id, action):
        if not _valid_app_id(app_id):
            return False, "잘못된 앱 ID 입니다."
        if self.is_simulation:
            return True, f"(시뮬레이션) {action} 완료"
        if not os.path.isdir(self._project_dir(app_id)):
            return False, "설치되지 않은 앱입니다."
        result = self._compose(app_id, action)
        if result.returncode == 0:
            return True, f"{action} 완료"
        return False, result.stderr.strip()[:500] or f"{action} 실패"

    def start(self, app_id):
        return self._lifecycle(app_id, 'start')

    def stop(self, app_id):
        return self._lifecycle(app_id, 'stop')

    def restart(self, app_id):
        return self._lifecycle(app_id, 'restart')

    def uninstall(self, app_id, delete_data=False):
        if not _valid_app_id(app_id):
            return False, "잘못된 앱 ID 입니다."
        if not any(e.get('id') == app_id for e in self._read_installed()):
            return False, "설치되지 않은 앱입니다."
        if not self.is_simulation:
            down_args = ['down', '-v'] if delete_data else ['down']
            if os.path.isdir(self._project_dir(app_id)):
                result = self._compose(app_id, *down_args, timeout=180)
                if result.returncode != 0:
                    logger.warning(f"[apps] down warning for {app_id}: {result.stderr.strip()}")
        # 프로젝트 디렉토리 제거(항상), appdata 는 delete_data 일 때만
        shutil.rmtree(self._project_dir(app_id), ignore_errors=True)
        if delete_data:
            shutil.rmtree(os.path.join(APPDATA_DIR, app_id), ignore_errors=True)
        self._remove_installed(app_id)
        logger.info(f"[apps] uninstalled {app_id} (delete_data={delete_data})")
        return True, "삭제 완료"

    def get_logs(self, app_id, tail=200):
        if not _valid_app_id(app_id):
            return ""
        if self.is_simulation:
            return f"(시뮬레이션) {app_id} 로그 없음"
        if not os.path.isdir(self._project_dir(app_id)):
            return ""
        result = self._compose(app_id, 'logs', '--no-color', '--tail', str(tail), timeout=30)
        return result.stdout or result.stderr


app_manager = AppManager()
