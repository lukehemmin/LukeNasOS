from flask import Blueprint, jsonify, current_app, request
import psutil
import platform
import subprocess
from update_engine import update_engine
from utils.logger import logger
from utils.auth import login_required
from utils.system_settings import apply_timezone, valid_hostname

system_bp = Blueprint('system', __name__)

@system_bp.route('/api/system/root-password', methods=['POST'])
@login_required
def set_root_password():
    data = request.get_json()
    if not data or 'password' not in data:
        return jsonify({'status': 'error', 'message': 'Password is required'}), 400
    
    password = data['password']
    
    # Validate password length/complexity if needed (Skipped for now)
    
    try:
        # Use chpasswd to set the password for root
        # Input format: "user:password"
        payload = f"root:{password}"
        
        process = subprocess.run(
            ['chpasswd'], 
            input=payload, 
            text=True, 
            capture_output=True
        )
        
        if process.returncode == 0:
            logger.info("Root password changed successfully via Web UI")
            return jsonify({'status': 'success', 'message': 'Root password updated successfully'})
        else:
            logger.error(f"Failed to change root password: {process.stderr}")
            return jsonify({'status': 'error', 'message': 'Failed to update password'}), 500
            
    except Exception as e:
        logger.error(f"Exception during password change: {e}")
        return jsonify({'status': 'error', 'message': str(e)}), 500

@system_bp.route('/api/status')
@login_required
def status():
    cpu_percent = psutil.cpu_percent(interval=1)
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    
    # 설정된 데이터 디렉토리의 사용량도 확인하면 좋음
    try:
        data_disk = psutil.disk_usage(current_app.config['DATA_DIR'])
        data_free = f"{data_disk.free / (1024**3):.2f} GB"
        data_total = f"{data_disk.total / (1024**3):.2f} GB"
    except:
        data_free = "N/A"
        data_total = "N/A"

    update_status = update_engine.get_status()
    config = current_app.config['config_manager']

    return jsonify({
        'system': platform.system(),
        'release': platform.release(),
        'hostname': config.get('hostname', platform.node()),
        'version': current_app.config.get('CURRENT_VERSION', 'Unknown'),
        'active_slot': update_status['active_slot'],
        'cpu_percent': cpu_percent,
        'memory_percent': memory.percent,
        'disk_percent': disk.percent,
        'disk_free': f"{disk.free / (1024**3):.2f} GB",
        'disk_total': f"{disk.total / (1024**3):.2f} GB",
        'data_free': data_free,
        'data_total': data_total
    })

@system_bp.route('/api/settings', methods=['GET', 'POST'])
@login_required
def settings():
    """일반 설정 조회/변경 (호스트명·언어·시간대).

    셋업 때 한 번 정한 값을 운영 중에도 바꿀 수 있게 한다. 저장소는 셋업과 동일하게
    NAS-DATA 의 settings.json (config_manager) — A/B 업데이트·재부팅에도 영속.
    """
    config = current_app.config['config_manager']

    if request.method == 'GET':
        return jsonify({
            'hostname': config.get('hostname', platform.node()),
            'language': config.get('language', 'en'),
            'timezone': config.get('timezone'),
        })

    data = request.get_json() or {}
    hostname = data.get('hostname')
    language = data.get('language')
    timezone = data.get('timezone')

    if timezone and timezone != config.get('timezone'):
        if not apply_timezone(timezone):
            return jsonify({'status': 'error', 'message': 'Invalid timezone'}), 400
        config.set('timezone', timezone)

    if hostname is not None and hostname != config.get('hostname'):
        if not valid_hostname(hostname):
            return jsonify({'status': 'error', 'message': 'Invalid hostname'}), 400
        # 시스템 반영 실패(컨테이너 등)해도 표시용 설정은 저장한다 (셋업과 동일한 관용)
        try:
            subprocess.run(['hostnamectl', 'set-hostname', hostname],
                           check=True, capture_output=True)
        except Exception as e:
            logger.warning(f"Failed to set hostname: {e}")
        config.set('hostname', hostname)

    if language:
        config.set('language', language)

    logger.info("Settings updated via Web UI")
    return jsonify({'status': 'success'})

@system_bp.route('/api/system/reboot', methods=['POST'])
@login_required
def reboot_system():
    """
    시스템을 재부팅합니다.
    """
    try:
        logger.info("System reboot requested via Web UI")
        # 즉시 재부팅을 비동기적으로 실행하거나, 응답 후 실행되도록 해야 함.
        # 여기서는 응답을 먼저 보내기 위해 약간의 지연을 줄 수도 있지만,
        # 보통은 명령 실행 후 즉시 리턴합니다.
        
        # 'reboot' 명령 실행 (sudo 권한 필요할 수 있음)
        subprocess.Popen(['sudo', 'reboot'])
        
        return jsonify({'status': 'success', 'message': 'System is rebooting...'})
    except Exception as e:
        logger.error(f"Failed to reboot system: {e}")
        return jsonify({'status': 'error', 'message': str(e)}), 500
