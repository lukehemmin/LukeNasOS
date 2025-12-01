import logging
import os
from logging.handlers import RotatingFileHandler

def setup_logging(log_dir='/var/log/lukenasos', log_level=logging.INFO):
    """
    애플리케이션 로깅 설정
    - 콘솔 출력
    - 파일 저장 (RotatingFileHandler)
    """
    os.makedirs(log_dir, exist_ok=True)
    log_file = os.path.join(log_dir, 'web_ui.log')

    # 로거 생성
    logger = logging.getLogger('LukeNasOS')
    logger.setLevel(log_level)

    # 포맷 설정
    formatter = logging.Formatter(
        '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )

    # 파일 핸들러 (10MB 씩 5개 보관)
    file_handler = RotatingFileHandler(
        log_file, maxBytes=10*1024*1024, backupCount=5
    )
    file_handler.setFormatter(formatter)
    file_handler.setLevel(log_level)

    # 콘솔 핸들러
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)
    console_handler.setLevel(log_level)

    # 핸들러 추가 (중복 방지)
    if not logger.handlers:
        logger.addHandler(file_handler)
        logger.addHandler(console_handler)

    return logger

# 전역 로거 인스턴스
logger = setup_logging()
