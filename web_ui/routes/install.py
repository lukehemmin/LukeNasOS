from flask import Blueprint, render_template, jsonify, request
from installer import installer

install_bp = Blueprint('install', __name__)

@install_bp.route('/install')
def index():
    return render_template('install.html')

@install_bp.route('/api/disks')
def get_disks():
    disks = installer.get_disks()
    return jsonify(disks)

@install_bp.route('/api/install/start', methods=['POST'])
def start_install():
    data = request.json
    target_disk = data.get('disk')
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
        'progress': installer.progress
    })
