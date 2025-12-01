from flask import Flask, render_template, session, redirect, url_for, request
import os
from routes.system import system_bp
from routes.update import update_bp
from routes.auth import auth_bp
from routes.install import install_bp  # Installer Blueprint
from utils.config_manager import ConfigManager
from utils.logger import logger
from update_engine import update_engine

def is_live_mode():
    """
    /proc/cmdline을 확인하여 Live 부팅 모드인지 확인합니다.
    'boot=live' 커널 파라미터가 있으면 Live 모드로 간주합니다.
    """
    try:
        if os.path.exists('/proc/cmdline'):
            with open('/proc/cmdline', 'r') as f:
                cmdline = f.read()
                if 'boot=live' in cmdline:
                    return True
    except Exception:
        pass
    return False

def create_app():
    app = Flask(__name__)
    
    # 설치 모드 확인
    app.config['IS_INSTALLER_MODE'] = is_live_mode()
    if app.config['IS_INSTALLER_MODE']:
        logger.info("Running in INSTALLER MODE (Live Boot Detected)")
    
    # 보안 키 설정 (세션 암호화용)
    app.secret_key = os.environ.get('SECRET_KEY', 'lukenasos-secret-key-dev')

    # 기본 설정
    # 데이터 저장소: 실제 파티션 마운트 위치 (환경변수로 오버라이드 가능)
    DATA_DIR = os.environ.get('LUKENASOS_DATA_DIR', '/var/lib/lukenasos/data')
    UPLOAD_FOLDER = os.path.join(DATA_DIR, 'uploads')
    CONFIG_FILE = os.path.join(DATA_DIR, 'config', 'settings.json')

    # 디렉토리 준비
    os.makedirs(UPLOAD_FOLDER, exist_ok=True)
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)

    # Flask Config 설정
    app.config['DATA_DIR'] = DATA_DIR
    app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
    app.config['CURRENT_VERSION'] = "1.0.0" # TODO: 버전 파일에서 읽어오기
    
    # 설정 매니저 초기화 및 주입
    config_manager = ConfigManager(CONFIG_FILE)
    app.config['config_manager'] = config_manager

    # Blueprint 등록
    app.register_blueprint(system_bp)
    app.register_blueprint(update_bp)
    app.register_blueprint(auth_bp)
    app.register_blueprint(install_bp)

    logger.info(f"LukeNasOS Web UI Started (Data Dir: {DATA_DIR})")
    
    @app.before_request
    def check_setup_and_auth():
        # 정적 파일(css, js 등)은 검사 제외
        if request.endpoint and 'static' in request.endpoint:
            return

        # 0. 설치 모드인 경우, /install로 강제 이동
        if app.config.get('IS_INSTALLER_MODE'):
            # install 관련 경로는 허용
            if request.endpoint and request.endpoint.startswith('install.'):
                return
            # 나머지는 모두 설치 페이지로 리다이렉트
            return redirect(url_for('install.index'))

        # 인증/설정 관련 페이지는 검사 제외 (무한 리다이렉트 방지)
        if request.endpoint and request.endpoint.startswith('auth.'):
            return
            
        config = app.config['config_manager']
        is_setup = config.get('setup_completed')

        # 1. 초기 설정이 안 되어 있으면 /setup으로 강제 이동
        if not is_setup:
            return redirect(url_for('auth.setup'))

        # 2. 설정은 되었으나 로그인이 안 되어 있으면 /login으로 강제 이동
        if 'user' not in session:
            return redirect(url_for('auth.login'))

    @app.route('/')
    def index():
        update_status = update_engine.get_status()
        return render_template('index.html', 
                             version=app.config['CURRENT_VERSION'], 
                             update_status=update_status)

    return app

if __name__ == '__main__':
    app = create_app()
    
    # 디버그 모드 설정 (환경변수 > 설정파일 > 기본값 False)
    # 유저나 개발자가 필요 시 활성화 가능
    debug_mode = os.environ.get('LUKENASOS_DEBUG', 'False').lower() == 'true'
    
    if debug_mode:
        logger.warning("Running in DEBUG mode")
    
    app.run(host='0.0.0.0', port=80, debug=debug_mode)
