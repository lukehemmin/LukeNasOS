from functools import wraps
from flask import session, jsonify

# 세션에 'user' 가 있어야 통과하는 인증 가드.
# app.py 의 /api/system/status 가 노출하는 logged_in = ('user' in session) 과 동일 기준.
# 인증 실패 시 401 을 주면 프론트(Dashboard)가 이를 받아 /login 으로 보낸다.
def login_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if 'user' not in session:
            return jsonify({'status': 'error', 'message': 'Unauthorized'}), 401
        return f(*args, **kwargs)
    return wrapper
