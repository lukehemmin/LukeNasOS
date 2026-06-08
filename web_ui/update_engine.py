import os
import subprocess
import json
import threading
import time
from utils.logger import logger

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
            result = subprocess.run(['rauc', 'status', '--output-format=json'], capture_output=True, text=True)
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
                                    capture_output=True, text=True)
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
            slot_bytes = int(subprocess.check_output(['blockdev', '--getsize64', target_dev], text=True).strip())
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

    def install_update(self, bundle_path):
        """
        비동기로 업데이트 설치를 시작합니다.
        """
        with self.lock:
            if self.status == 'installing':
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
