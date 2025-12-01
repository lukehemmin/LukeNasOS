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
