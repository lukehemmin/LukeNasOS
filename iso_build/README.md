# LukeNasOS Build System

이 디렉토리는 LukeNasOS의 ISO 이미지를 생성하는 빌드 시스템을 포함하고 있습니다. Debian의 `live-build` 도구를 기반으로 하며, Docker 컨테이너 안에서 안전하게 실행됩니다.

## 📂 디렉토리 구조

*   **`Dockerfile`**: 빌드 환경을 정의합니다. `live-build`, `rauc`, `squashfs-tools` 등 빌드에 필요한 모든 의존성이 포함된 Docker 이미지를 생성합니다.
*   **`build_iso.sh`**: 실제 빌드 로직을 수행하는 스크립트입니다.
    *   `lb config`: Debian 라이브 시스템을 설정합니다.
    *   `lb build`: 설정을 바탕으로 ISO 이미지를 생성합니다.
    *   RAUC를 위한 파티션 레이아웃 및 부트로더 설정이 이 단계에서 통합됩니다.
*   **`live-build-work/`**: `live-build` 작업 디렉토리입니다.
    *   `config/`: 패키지 목록, 훅(hook), 부트 로더 설정 등이 위치합니다.

## 🛠️ 빌드 프로세스 상세

빌드 프로세스는 루트 디렉토리의 `run_docker_build.sh`에 의해 트리거되지만, 내부적으로는 다음과 같은 절차를 따릅니다.

1.  **환경 준비**: `Dockerfile`을 기반으로 `lukenasos-builder` 이미지가 생성됩니다.
2.  **설정 (Config)**: `build_iso.sh`가 실행되어 `lb config`를 호출합니다. 이때 아키텍처(amd64), 배포판 버전(bookworm) 등이 지정됩니다.
3.  **Web UI 통합**: 빌드 중 훅(Hook) 또는 스크립트를 통해 `../web_ui`의 소스 코드가 이미지 내부의 `/opt/lukenasos/web_ui`로 복사됩니다.
4.  **Systemd 설정**: Web UI가 부팅 시 자동으로 시작되도록 systemd 서비스 파일이 생성 및 활성화됩니다.
5.  **이미지 생성**: `lb build`가 실행되어 최종적으로 부팅 가능한 ISO 파일이 생성됩니다.

## 🔧 커스터마이징

### 패키지 추가/제거
OS에 기본 설치되는 패키지를 변경하려면 `live-build-work/config/package-lists/` 내의 목록 파일을 수정하십시오. (파일이 없다면 생성해야 할 수 있습니다.)

### Web UI 버전 변경
빌드 시점의 `../web_ui` 디렉토리 내용이 그대로 이미지에 포함됩니다. 코드를 수정한 후 다시 빌드하면 변경 사항이 반영됩니다.

## ⚠️ 주의사항

*   **Root 권한**: `live-build`는 파일 시스템을 조작하므로 컨테이너 내부에서 Root 권한으로 실행됩니다 (`--privileged` 플래그 필요).
*   **캐시**: 빌드 속도를 높이기 위해 `live-build`는 다운로드한 패키지를 캐시할 수 있습니다. 클린 빌드가 필요한 경우 `lb clean` 명령이 필요할 수 있습니다.
