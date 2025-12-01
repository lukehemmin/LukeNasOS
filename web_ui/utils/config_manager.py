import os
import json
from utils.logger import logger

class ConfigManager:
    def __init__(self, config_path):
        self.config_path = config_path
        self.config = {}
        self.load_config()

    def load_config(self):
        """설정 파일 로드 (없으면 기본값 사용)"""
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, 'r') as f:
                    self.config = json.load(f)
                logger.info(f"Config loaded from {self.config_path}")
            except Exception as e:
                logger.error(f"Error loading config from {self.config_path}: {e}")
                # 로드 실패 시 빈 설정
                self.config = {}
        else:
            logger.warning(f"Config file not found at {self.config_path}. Using empty config.")
            self.config = {}

    def save_config(self):
        """현재 설정을 파일에 저장"""
        try:
            # 디렉토리가 없으면 생성
            os.makedirs(os.path.dirname(self.config_path), exist_ok=True)
            with open(self.config_path, 'w') as f:
                json.dump(self.config, f, indent=4)
            logger.info(f"Config saved to {self.config_path}")
            return True
        except Exception as e:
            logger.error(f"Error saving config to {self.config_path}: {e}")
            return False

    def get(self, key, default=None):
        return self.config.get(key, default)

    def set(self, key, value):
        self.config[key] = value
        return self.save_config()
