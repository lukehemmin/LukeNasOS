# LukeNasOS

**LukeNasOS**는 안정성과 관리 편의성에 초점을 맞춘 커스텀 NAS 운영체제 프로젝트입니다. Debian 기반의 경량 OS와 직관적인 웹 관리 인터페이스를 제공하며, RAUC를 이용한 강력한 A/B 파티션 업데이트 시스템을 갖추고 있습니다.

## 📚 문서 목록

프로젝트의 구조와 설계에 대한 상세 문서는 아래를 참조하세요.

*   **🏛️ [아키텍처 개요](ARCHITECTURE.md)**: 시스템 전체 설계, 컴포넌트 상호작용 및 데이터 흐름.
*   **🏗️ [빌드 시스템 가이드](iso_build/README.md)**: Docker 기반의 ISO 이미지 생성 방법.
*   **🔄 [업데이트 메커니즘](iso_build/UPDATE_MECHANISM.md)**: RAUC 기반 A/B 파티션 상세 및 번들 구조.
*   **🖥️ [Web UI 가이드](web_ui/README.md)**: 웹 인터페이스 사용법, API 명세 및 개발 환경.

## 🚀 빠른 시작

### 1. ISO 이미지 빌드
```bash
./run_docker_build.sh
```
빌드가 완료되면 `output/` 디렉토리에 부팅 가능한 ISO 파일이 생성됩니다.

### 2. 업데이트 번들 생성
```bash
./create_update_bundle.sh <source_directory>
```

### 3. Web UI 개발 실행
```bash
cd web_ui
pip install -r requirements.txt
python app.py
```
브라우저에서 `http://localhost:5000`으로 접속하여 UI를 확인할 수 있습니다.

## 🧩 프로젝트 개요

*   **목표**: 신뢰할 수 있는 홈/오피스 NAS OS 구축.
*   **핵심 기술**: Debian Live Build, Python Flask, RAUC, Docker.
*   **라이선스**: (해당 프로젝트의 라이선스 정보 기입)