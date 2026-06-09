from flask import Blueprint, render_template, request, jsonify, session, redirect, url_for, current_app, send_from_directory
from werkzeug.security import generate_password_hash, check_password_hash
import subprocess
from utils.logger import logger

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
        hostname = data.get('hostname', 'lukenas')

        if not username or not password:
            return jsonify({'status': 'error', 'message': 'ID와 비밀번호는 필수입니다.'}), 400

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

@auth_bp.route('/logout')
def logout():
    session.pop('user', None)
    return redirect(url_for('auth.login'))
