from flask import Flask, send_from_directory, jsonify, session
import os
import secrets
from routes.system import system_bp
from routes.update import update_bp
from routes.auth import auth_bp
from routes.install import install_bp
from routes.apps import apps_bp
from utils.config_manager import ConfigManager
from utils.logger import logger

def _read_cmdline():
    """Return the kernel command line, or '' if unreadable."""
    try:
        if os.path.exists('/proc/cmdline'):
            with open('/proc/cmdline', 'r') as f:
                return f.read()
    except Exception:
        pass
    return ''


def is_live_mode():
    """
    Check if running in Live Boot mode via /proc/cmdline
    """
    return 'boot=live' in _read_cmdline()


def is_recovery_mode():
    """
    Check if booted into the recovery slot (C).
    GRUB 의 복구 메뉴 엔트리는 커널 cmdline 에 lukenasos.recovery=1 을 넘긴다.
    A/B 가 모두 부팅 불가일 때 자동 폴백되며, 이때 설치/복구 UI 를 노출한다.
    """
    return 'lukenasos.recovery=1' in _read_cmdline()

def create_app():
    # Determine location of React build artifacts
    # Priority: 1. /opt/lukenasos... (Production ISO) 2. ./frontend/dist (Local Dev)
    if os.path.exists('/opt/lukenasos/web_ui/frontend_dist'):
        static_folder = '/opt/lukenasos/web_ui/frontend_dist'
    else:
        static_folder = os.path.abspath(os.path.join(os.path.dirname(__file__), 'frontend/dist'))
        
    # Ensure the directory exists to prevent Flask error
    is_frontend_built = False
    if not os.path.exists(static_folder):
        os.makedirs(static_folder, exist_ok=True)
        # Create a dummy index.html for dev if missing
        with open(os.path.join(static_folder, 'index.html'), 'w') as f:
            f.write('<h1>Frontend not built. Run npm run build in frontend/</h1>')
    else:
        # Check if it looks like a real React build
        is_frontend_built = os.path.exists(os.path.join(static_folder, 'index.html')) and \
                            os.path.exists(os.path.join(static_folder, 'assets'))

    logger.info(f"Serving frontend from: {static_folder}")

    app = Flask(__name__, static_folder=static_folder, static_url_path='')
    app.config['IS_FRONTEND_BUILT'] = is_frontend_built
    
    # System Configuration
    # 설치/복구 UI 는 live(설치 미디어)와 recovery(복구 슬롯 C) 양쪽에서 노출한다.
    app.config['IS_RECOVERY_MODE'] = is_recovery_mode()
    app.config['IS_INSTALLER_MODE'] = is_live_mode() or app.config['IS_RECOVERY_MODE']
    if app.config['IS_RECOVERY_MODE']:
        logger.info("Running in RECOVERY MODE (Recovery slot C detected)")
    elif app.config['IS_INSTALLER_MODE']:
        logger.info("Running in INSTALLER MODE (Live Boot Detected)")
    
    DATA_DIR = os.environ.get('LUKENASOS_DATA_DIR', '/var/lib/lukenasos/data')
    UPLOAD_FOLDER = os.path.join(DATA_DIR, 'uploads')
    CONFIG_FILE = os.path.join(DATA_DIR, 'config', 'settings.json')

    os.makedirs(UPLOAD_FOLDER, exist_ok=True)
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)

    app.config['DATA_DIR'] = DATA_DIR
    app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER
    app.config['CURRENT_VERSION'] = "1.0.0" 
    
    config_manager = ConfigManager(CONFIG_FILE)
    app.config['config_manager'] = config_manager

    # 세션 서명 키: ① 환경변수 → ② config(NAS-DATA 영구 저장) → ③ 신규 생성·저장.
    # NAS-DATA 에 저장되므로 재부팅·A/B 업데이트에도 안정(세션 유지)하며 설치마다 고유·예측 불가.
    secret_key = os.environ.get('SECRET_KEY') or config_manager.get('secret_key')
    if not secret_key:
        secret_key = secrets.token_hex(32)
        config_manager.set('secret_key', secret_key)
        logger.info("Generated a new persistent secret_key.")
    app.secret_key = secret_key

    # Register Blueprints
    app.register_blueprint(system_bp)
    app.register_blueprint(update_bp)
    app.register_blueprint(auth_bp)
    app.register_blueprint(install_bp)
    app.register_blueprint(apps_bp)

    logger.info(f"LukeNasOS Web UI Started (Data Dir: {DATA_DIR})")

    # API: System Status for Frontend
    @app.route('/api/system/status')
    def system_status():
        config = app.config['config_manager']
        return jsonify({
            'is_installer_mode': app.config.get('IS_INSTALLER_MODE', False),
            'is_recovery_mode': app.config.get('IS_RECOVERY_MODE', False),
            'setup_completed': config.get('setup_completed', False),
            'logged_in': 'user' in session,
            'version': app.config.get('CURRENT_VERSION', '1.0.0')
        })

    # SPA Catch-All Route
    @app.route('/', defaults={'path': ''})
    @app.route('/<path:path>')
    def serve(path):
        if path != "" and os.path.exists(os.path.join(app.static_folder, path)):
            return send_from_directory(app.static_folder, path)
        else:
            return send_from_directory(app.static_folder, 'index.html')

    # SPA fallback: static_url_path='' 의 내장 static 라우트가 /apps 같은 클라이언트 경로를
    # 가려 404 를 내므로, API 가 아닌 경로의 404 는 index.html 로 되돌려 React Router 가 처리하게 한다.
    @app.errorhandler(404)
    def spa_fallback(e):
        from flask import request
        if request.path.startswith('/api/'):
            return jsonify({'status': 'error', 'message': 'Not found'}), 404
        return send_from_directory(app.static_folder, 'index.html')

    return app

if __name__ == '__main__':
    app = create_app()
    debug_mode = os.environ.get('LUKENASOS_DEBUG', 'False').lower() == 'true'
    if debug_mode:
        logger.warning("Running in DEBUG mode")
    app.run(host='0.0.0.0', port=80, debug=debug_mode)