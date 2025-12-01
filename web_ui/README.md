# LukeNasOS Web Interface

이 디렉토리는 LukeNasOS의 관리 대시보드를 위한 Python Flask 애플리케이션입니다. 사용자는 이 웹 인터페이스를 통해 시스템 상태를 확인하고 업데이트를 관리할 수 있습니다.

## 📂 구조

*   **`app.py`**: Flask 앱의 진입점(Entry point)입니다. 앱을 초기화하고 Blueprints를 등록합니다.
*   **`update_engine.py`**: RAUC와 상호작용하여 시스템 업데이트를 비동기적으로 처리하는 핵심 엔진입니다.
*   **`routes/`**: URL 라우팅 및 API 핸들러가 위치합니다.
    *   `system.py`: 시스템 정보(CPU, 메모리 등) 관련 API.
    *   `update.py`: 업데이트 번들 업로드 및 설치 관련 API.
*   **`utils/`**:
    *   `config_manager.py`: 설정 파일 저장/로드 관리.
    *   `logger.py`: 로깅 유틸리티.
*   **`templates/`**: HTML 프론트엔드 템플릿.

## 🚀 개발 및 실행 가이드

### 로컬 개발 환경 설정

실제 NAS 하드웨어가 아닌 개발 PC에서 UI를 테스트할 수 있습니다.

```bash
# 가상 환경 생성 및 활성화
python3 -m venv venv
source venv/bin/activate

# 의존성 설치
pip install -r requirements.txt

# 앱 실행
python app.py
```

앱은 기본적으로 `http://localhost:5000`에서 실행됩니다.

### 시뮬레이션 모드
`update_engine.py`는 로컬 환경에서 실행될 때 자동으로 **시뮬레이션 모드**로 동작합니다. 실제 `rauc` 명령을 실행하는 대신, 로그를 출력하고 성공/실패를 시뮬레이션하여 안전하게 개발할 수 있습니다.

## 📡 API 명세

### 1. 시스템 상태

*   **URL**: `/api/system/status`
*   **Method**: `GET`
*   **Response**:
    ```json
    {
      "cpu_percent": 15.5,
      "memory_percent": 40.2,
      "disk_usage": { ... },
      "uptime": "2 days, 4:32:01"
    }
    ```

### 2. 업데이트

*   **URL**: `/api/update/upload`
*   **Method**: `POST`
*   **Body**: `file` (Form-data, .raucb 파일)
*   **Description**: 업데이트 번들을 업로드하고 설치 프로세스를 시작합니다.

*   **URL**: `/api/update/status`
*   **Method**: `GET`
*   **Response**: 현재 업데이트 진행 상황(%) 및 상태 메시지 반환.

## ⚙️ 설정 관리

설정은 `utils/config_manager.py`를 통해 JSON 파일로 관리됩니다. 실제 OS에서는 데이터 파티션에 저장되어 업데이트 후에도 설정이 유지되도록 설계되었습니다.
