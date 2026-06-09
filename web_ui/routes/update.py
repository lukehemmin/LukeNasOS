import os
from flask import Blueprint, jsonify, request, current_app
from werkzeug.utils import secure_filename
from update_engine import update_engine
from utils.auth import login_required

update_bp = Blueprint('update', __name__)

@update_bp.route('/api/update/status')
@login_required
def update_status():
    """대시보드 업데이트 진행 상태 (active/inactive slot, status, message, progress)."""
    return jsonify(update_engine.get_status())

@update_bp.route('/api/update', methods=['POST'])
@login_required
def update_system():
    """
    A/B 파티션 기반 시스템 업데이트 (온라인/시뮬레이션)
    """
    try:
        # 테스트용 가짜 이미지 경로도 데이터 파티션 쪽으로 변경
        fake_image_path = os.path.join(current_app.config['DATA_DIR'], "update.img")
        
        success, message = update_engine.install_update(fake_image_path)
        
        if success:
            return jsonify({'status': 'success', 'message': message})
        else:
            return jsonify({'status': 'error', 'message': message}), 409 # 409 Conflict (if already running)

    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500

@update_bp.route('/api/upload_update', methods=['POST'])
@login_required
def upload_update():
    """
    업데이트 파일(.img/.iso)을 업로드받아 설치합니다.
    """
    if 'update_file' not in request.files:
        return jsonify({'status': 'error', 'message': '파일이 없습니다.'}), 400
    
    file = request.files['update_file']
    if file.filename == '':
        return jsonify({'status': 'error', 'message': '선택된 파일이 없습니다.'}), 400
    
    if file:
        filename = secure_filename(file.filename)
        filepath = os.path.join(current_app.config['UPLOAD_FOLDER'], filename)
        
        try:
            # 로깅 모듈 사용 권장 (print -> logger)
            # logger.info(f"Uploading file to {filepath}...")
            file.save(filepath)
            
            success, message = update_engine.install_update(filepath)
            
            if success:
                # 주의: 비동기 설치이므로 여기서 바로 삭제하면 설치 프로세스가 파일을 못 찾을 수 있음
                # UpdateEngine 내부에서 설치 완료/실패 후 정리하도록 위임하거나,
                # 별도 정리 스레드가 필요함. 현재는 간단히 유지.
                return jsonify({'status': 'success', 'message': message})
            else:
                # 시작 실패 시 파일 정리
                try:
                    os.remove(filepath)
                except:
                    pass
                return jsonify({'status': 'error', 'message': message}), 500
                
        except Exception as e:
            return jsonify({'status': 'error', 'message': f'오류 발생: {str(e)}'}), 500
