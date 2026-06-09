from flask import Blueprint, jsonify, request
from app_manager import app_manager
from utils.auth import login_required

apps_bp = Blueprint('apps', __name__)


@apps_bp.route('/api/apps/catalog')
@login_required
def catalog():
    """설치 가능한 앱 카탈로그."""
    return jsonify({'apps': app_manager.load_catalog()})


@apps_bp.route('/api/apps/installed')
@login_required
def installed():
    """설치된 앱 목록(실행 상태 포함)."""
    return jsonify({'apps': app_manager.list_installed()})


@apps_bp.route('/api/apps/install', methods=['POST'])
@login_required
def install():
    """카탈로그 앱을 비동기로 설치한다. body: {app_id, config?}"""
    data = request.get_json(silent=True) or {}
    app_id = data.get('app_id')
    if not app_id:
        return jsonify({'status': 'error', 'message': 'app_id 가 필요합니다.'}), 400
    ok, message = app_manager.install_app(app_id, data.get('config'))
    if ok:
        return jsonify({'status': 'success', 'message': message})
    return jsonify({'status': 'error', 'message': message}), 409


@apps_bp.route('/api/apps/install/status')
@login_required
def install_status():
    """설치 진행 상태(폴링)."""
    return jsonify(app_manager.get_install_status())


@apps_bp.route('/api/apps/<app_id>/start', methods=['POST'])
@login_required
def start(app_id):
    ok, message = app_manager.start(app_id)
    return jsonify({'status': 'success' if ok else 'error', 'message': message}), (200 if ok else 500)


@apps_bp.route('/api/apps/<app_id>/stop', methods=['POST'])
@login_required
def stop(app_id):
    ok, message = app_manager.stop(app_id)
    return jsonify({'status': 'success' if ok else 'error', 'message': message}), (200 if ok else 500)


@apps_bp.route('/api/apps/<app_id>/restart', methods=['POST'])
@login_required
def restart(app_id):
    ok, message = app_manager.restart(app_id)
    return jsonify({'status': 'success' if ok else 'error', 'message': message}), (200 if ok else 500)


@apps_bp.route('/api/apps/<app_id>', methods=['DELETE'])
@login_required
def uninstall(app_id):
    delete_data = request.args.get('delete_data') in ('1', 'true', 'yes')
    ok, message = app_manager.uninstall(app_id, delete_data=delete_data)
    return jsonify({'status': 'success' if ok else 'error', 'message': message}), (200 if ok else 500)


@apps_bp.route('/api/apps/<app_id>/logs')
@login_required
def logs(app_id):
    try:
        tail = int(request.args.get('tail', 200))
    except ValueError:
        tail = 200
    return jsonify({'logs': app_manager.get_logs(app_id, tail=tail)})
