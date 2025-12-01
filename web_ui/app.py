from flask import Flask, render_template, jsonify
import psutil
import platform
import subprocess
import os
from flask import Flask, render_template, jsonify, request
from werkzeug.utils import secure_filename
from update_engine import update_engine

app = Flask(__name__)

# 파일 업로드 설정
UPLOAD_FOLDER = '/tmp/uploads'
os.makedirs(UPLOAD_FOLDER, exist_ok=True)
app.config['UPLOAD_FOLDER'] = UPLOAD_FOLDER

# 현재 버전 정보 (나중에 파일에서 읽어오도록 개선 가능)
CURRENT_VERSION = "1.0.0"

@app.route('/')
def index():
    update_status = update_engine.get_status()
    return render_template('index.html', version=CURRENT_VERSION, update_status=update_status)

@app.route('/api/status')
def status():
    cpu_percent = psutil.cpu_percent(interval=1)
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    update_status = update_engine.get_status()
    
    return jsonify({
        'system': platform.system(),
        'release': platform.release(),
        'version': CURRENT_VERSION,
        'active_slot': update_status['active_slot'],
        'cpu_percent': cpu_percent,
        'memory_percent': memory.percent,
        'disk_percent': disk.percent,
        'disk_free': f"{disk.free / (1024**3):.2f} GB",
        'disk_total': f"{disk.total / (1024**3):.2f} GB"
    })

@app.route('/api/update', methods=['POST'])
def update_system():
    """
    A/B 파티션 기반 시스템 업데이트 (온라인/시뮬레이션)
    """
    try:
        fake_image_path = "/tmp/update.img"
        
        if update_engine.install_update(fake_image_path):
            return jsonify({
                'status': 'success', 
                'message': f'업데이트가 슬롯 {update_engine.inactive_slot}에 설치되었습니다. 재부팅하면 적용됩니다.'
            })
        else:
            return jsonify({'status': 'error', 'message': '업데이트 설치 실패'}), 500

    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500

@app.route('/api/upload_update', methods=['POST'])
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
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        
        try:
            print(f"Uploading file to {filepath}...")
            file.save(filepath)
            
            print(f"Installing update from {filepath}...")
            if update_engine.install_update(filepath):
                # 설치 완료 후 파일 삭제 (용량 확보)
                os.remove(filepath)
                return jsonify({
                    'status': 'success', 
                    'message': f'업데이트({filename})가 슬롯 {update_engine.inactive_slot}에 설치되었습니다. 재부팅하면 적용됩니다.'
                })
            else:
                return jsonify({'status': 'error', 'message': '업데이트 설치에 실패했습니다.'}), 500
                
        except Exception as e:
            return jsonify({'status': 'error', 'message': f'오류 발생: {str(e)}'}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80, debug=True)
