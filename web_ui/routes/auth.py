from flask import Blueprint, render_template, request, jsonify, session, redirect, url_for, current_app, send_from_directory
from werkzeug.security import generate_password_hash, check_password_hash
import subprocess
from utils.logger import logger
from utils.system_settings import apply_timezone, valid_hostname
from utils.auth import login_required

auth_bp = Blueprint('auth', __name__)

@auth_bp.route('/setup', methods=['GET', 'POST'])
def setup():
    config = current_app.config['config_manager']
    
    # 이미 설정된 경우 리다이렉트
    if config.get('setup_completed'):
        return redirect(url_for('auth.login'))

    if request.method == 'GET':
        # 프론트엔드 빌드 여부 확인
        if current_app.config.get('IS_FRONTEND_BUILT', False):
            return send_from_directory(current_app.static_folder, 'index.html')
        return render_template('setup.html')

    if request.method == 'POST':
        data = request.get_json()
        username = data.get('username')
        password = data.get('password')
        hostname = data.get('hostname', 'lukenasos')
        language = data.get('language', 'en')
        timezone = data.get('timezone')

        if not username or not password:
            return jsonify({'status': 'error', 'message': 'ID and password are required.'}), 400

        if not valid_hostname(hostname):
            return jsonify({'status': 'error', 'message': 'Invalid hostname'}), 400

        try:
            # 1. Web Admin 계정 생성 (config에 저장)
            # 실제 프로덕션에서는 DB나 System User를 사용하는 것이 좋으나,
            # 여기서는 간편함을 위해 Config에 해시된 비밀번호를 저장합니다.
            password_hash = generate_password_hash(password)
            
            config.set('admin_user', username)
            config.set('admin_password_hash', password_hash)
            
            # 2. 시스템 Hostname 설정 (Root 권한 필요)
            # Docker 등 컨테이너 환경에서는 실패할 수 있음
            try:
                subprocess.run(['hostnamectl', 'set-hostname', hostname], check=True)
                config.set('hostname', hostname)
            except Exception as e:
                logger.warning(f"Failed to set hostname: {e}")

            # 2.5 언어/시간대 저장 (NAS-DATA 의 settings.json → 재부팅·A/B 업데이트에도 영속).
            #  시간대는 OS 에도 즉시 적용하고, 이후 부팅마다 app 시작 시 재적용된다.
            config.set('language', language)
            if timezone:
                config.set('timezone', timezone)
                apply_timezone(timezone)  # 실패해도 셋업은 계속 (경고 로그만)

            # 3. 설정 완료 플래그 저장
            config.set('setup_completed', True)

            # 4. 자동 로그인: 계정 생성 직후 바로 대시보드로 진입하도록 세션 설정
            session['user'] = username

            logger.info(f"Initial setup completed. Admin user '{username}' created.")
            return jsonify({'status': 'success'})

        except Exception as e:
            logger.error(f"Setup failed: {e}")
            return jsonify({'status': 'error', 'message': str(e)}), 500

@auth_bp.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'GET':
        # 프론트엔드 빌드 여부 확인
        if current_app.config.get('IS_FRONTEND_BUILT', False):
            return send_from_directory(current_app.static_folder, 'index.html')
        return render_template('login.html')

    if request.method == 'POST':
        data = request.get_json()
        username = data.get('username')
        password = data.get('password')
        
        config = current_app.config['config_manager']
        stored_user = config.get('admin_user')
        stored_hash = config.get('admin_password_hash')

        if username == stored_user and stored_hash and check_password_hash(stored_hash, password):
            session['user'] = username
            logger.info(f"User '{username}' logged in.")
            return jsonify({'status': 'success'})
        else:
            logger.warning(f"Failed login attempt for user '{username}'")
            return jsonify({'status': 'error', 'message': '아이디 또는 비밀번호가 잘못되었습니다.'}), 401

@auth_bp.route('/api/account/password', methods=['POST'])
@login_required
def change_password():
    """관리자 비밀번호 변경 (설정 페이지). 현재 비밀번호 확인 후 해시 교체."""
    data = request.get_json() or {}
    current = data.get('current_password')
    new = data.get('new_password')

    if not current or not new:
        return jsonify({'status': 'error', 'message': 'Current and new passwords are required.'}), 400

    config = current_app.config['config_manager']
    stored_hash = config.get('admin_password_hash')
    if not stored_hash or not check_password_hash(stored_hash, current):
        logger.warning("Password change rejected: wrong current password")
        return jsonify({'status': 'error', 'message': 'Current password is incorrect.'}), 403

    config.set('admin_password_hash', generate_password_hash(new))
    logger.info("Admin password changed via Web UI")
    return jsonify({'status': 'success'})

@auth_bp.route('/logout')
def logout():
    session.pop('user', None)
    return redirect(url_for('auth.login'))
