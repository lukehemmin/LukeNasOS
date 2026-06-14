from flask import Blueprint, render_template, jsonify, request, current_app, send_from_directory
import subprocess
from installer import installer

install_bp = Blueprint('install', __name__)

@install_bp.route('/install')
def index():
    # 프론트엔드가 빌드되어 있다면 프론트엔드 앱을 서빙
    if current_app.config.get('IS_FRONTEND_BUILT', False):
        return send_from_directory(current_app.static_folder, 'index.html')
    # 아니면 기존 템플릿 (fallback)
    return render_template('install.html')

@install_bp.route('/api/disks')
def get_disks():
    disks = installer.get_disks()
    return jsonify(disks)

@install_bp.route('/api/install/start', methods=['POST'])
def start_install():
    data = request.json
    target_disk = data.get('disk')
    # 언어·시간대·NAS 이름은 설치 후 첫 부팅의 셋업 과정에서 설정한다 (설치는 영어 전용).
    hostname = data.get('hostname', 'lukenasos')

    if not target_disk:
        return jsonify({'success': False, 'message': 'Disk is required'}), 400

    config = {
        'hostname': hostname
        # Password 설정 등은 추후 추가 (shadow 파일 수정 필요)
    }

    success, message = installer.start_install(target_disk, config)
    return jsonify({'success': success, 'message': message})

@install_bp.route('/api/install/status')
def get_status():
    return jsonify({
        'status': installer.status,
        'message': installer.message,
        'progress': installer.progress,
        'log': installer.get_log()
    })

@install_bp.route('/api/install/reboot', methods=['POST'])
def reboot_system():
    """설치 완료 후 시스템 재부팅"""
    try:
        subprocess.Popen(['reboot'])
        return jsonify({'success': True, 'message': 'Rebooting...'})
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500
