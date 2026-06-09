# LukeNasOS — 앱(App) 기능

CasaOS / ZimaOS 스타일의 앱 설치·관리 기능. 큐레이션된 카탈로그에서 클릭으로 Docker 앱을
설치하고, 시작/중지/삭제/열기를 웹 UI에서 관리한다. 설치한 앱과 데이터는 **재부팅·A/B
업데이트 후에도 유지**된다.

## 설계 요지

- **실행 모델: Compose-per-app** — 앱마다 하나의 `docker compose` 프로젝트(`-p <app_id>`).
- **불변 A/B OS 대응** — Docker `data-root` 와 앱 데이터를 영구 **DATA 파티션**으로 이전.
  - `/var/lib/lukenasos/data/docker` — Docker data-root (이미지·컨테이너·볼륨)
  - `/var/lib/lukenasos/data/appdata/<id>` — 앱별 영구 볼륨 (compose `${APPDATA}`)
  - `/var/lib/lukenasos/data/apps/<id>/` — 앱별 compose 프로젝트(`docker-compose.yml` + `.env`)
  - `/var/lib/lukenasos/data/apps/installed.json` — 설치 메타데이터
- **백엔드는 `docker compose` CLI 를 subprocess 호출** (기존 `update_engine` 이 `rauc` 를 호출하는 방식과 동일). Python docker SDK 의존성 없음.
- **Compose v2 전달: 벤더링 플러그인 바이너리** — `docker.io`(Debian) + compose v2 단일 바이너리를 `/usr/lib/docker/cli-plugins/` 에 배치.

## 구성 파일

### 백엔드 (`web_ui/`)
- `app_manager.py` — `AppManager` 싱글톤(lock + 비동기 스레드 + 상태 폴링, `update_engine` 패턴).
  카탈로그 로드, 포트/용량 가드, compose pull/up/down/start/stop/restart, 로그, installed.json.
  docker/compose 부재 시 시뮬레이션 모드.
- `routes/apps.py` — `apps_bp`, 전부 `@login_required`:
  - `GET /api/apps/catalog`, `GET /api/apps/installed`
  - `POST /api/apps/install` (`{app_id, config?}`), `GET /api/apps/install/status`
  - `POST /api/apps/<id>/start|stop|restart`, `DELETE /api/apps/<id>?delete_data=1`
  - `GET /api/apps/<id>/logs?tail=N`
- `app.py` — `apps_bp` 등록 + **SPA 404 fallback**(클라이언트 라우트 `/apps` 등이 static 라우트에 가려 404 나던 문제 해결; `/api/*` 는 JSON 404 유지).
- `apps_catalog/<id>/` — `app.json`(메타·변수 스키마·`web_ui`) + `docker-compose.yml`.
  초기 시드: **jellyfin / qbittorrent / nextcloud**.

### 프론트엔드 (`web_ui/frontend/src/`)
- `components/Layout.tsx` — 인증 영역 공통 셸(헤더 + 탭 내비: 대시보드/앱/앱스토어).
- `components/AppCard.tsx` — 앱 타일(아이콘 맵 기반; lucide 전체 import 금지 → 번들 슬림).
- `pages/MyApps.tsx` — 설치 앱 그리드(5초 폴링) + 열기/시작/중지/재시작/삭제.
- `pages/AppStore.tsx` — 카탈로그 그리드 + 설치 모달(변수 폼 + 진행 폴링/막대).
- `App.tsx` — `/`(Dashboard)·`/apps`·`/apps/store` 를 `Layout` 으로 래핑.
- `pages/Dashboard.tsx` — 헤더/로그아웃을 `Layout` 으로 이관(중복 제거).

### OS 빌드 (`iso_build/build_iso.sh`)
- 패키지: `docker.io`, `iptables`, `uidmap` 추가.
- `etc/docker/daemon.json` — data-root → DATA 파티션.
- `docker.service.d/10-lukenasos.conf` — `RequiresMountsFor=/var/lib/lukenasos/data` + `After=lukenasos-persistence.service`.
- `etc/modules-load.d/docker.conf` — `overlay`, `br_netfilter`.
- Compose v2 플러그인 벤더링: `iso_build/vendor/docker-compose` 가 있으면 사용(오프라인·결정적), 없으면 `COMPOSE_VERSION` 핀고정 다운로드 + sha256 검증.
- `06-install-docker.hook.chroot` — docker/containerd enable.

## 카탈로그 앱 추가법

`web_ui/apps_catalog/<id>/` 에 두 파일을 만든다.

`app.json`:
```json
{
  "name": "표시 이름",
  "tagline": "한 줄 설명",
  "category": "분류",
  "icon": "Film",           // AppCard.tsx 의 ICONS 맵 키 (없으면 맵에 추가)
  "color": "#7c3aed",
  "web_ui": { "port_var": "WEBUI_PORT", "path": "/" },
  "variables": [
    { "key": "WEBUI_PORT", "label": "웹 포트", "default": 8096, "type": "port" }
  ]
}
```

`docker-compose.yml` (compose 네이티브 `${VAR}` 치환; `${APPDATA}` 는 자동 주입):
```yaml
services:
  app:
    image: vendor/image:tag
    restart: unless-stopped
    ports:
      - "${WEBUI_PORT}:8096"
    volumes:
      - ${APPDATA}/config:/config
```
> 예약 포트(80·443·22·139·445)와 다른 앱의 포트는 설치 시 자동 거부된다.

## 검증 상태

- **백엔드(실제 docker)**: 카탈로그 로드, 미지의 앱/예약포트 가드, 실설치(pull→up)·상태 폴링·
  HTTP 응답·중지/시작·로그·삭제(down -v) 전 흐름 통과.
- **프론트(빌드)**: `tsc` 타입체크 + `vite build` 통과(번들 gzip ~78KB).
- **라이브 HTTP**: setup→세션→catalog, `/apps`·`/apps/store` SPA 서빙(200), `/assets/*` 서빙,
  미인증 401 / `/api/*` JSON 404 확인.
- **Phase 0(OS 통합) — 미검증**: ISO 재빌드가 필요하므로 빌드 머신/VM 에서 아래를 확인할 것.

### Phase 0 부팅 검증 체크리스트 (VM)
- [ ] `docker info` 의 Docker Root Dir = `/var/lib/lukenasos/data/docker`
- [ ] `docker compose version` 동작 (벤더링 플러그인)
- [ ] 앱스토어에서 1개 설치 → `열기` 로 접속 → **재부팅 후 유지**
- [ ] (가능하면) A/B 업데이트 후에도 앱·데이터 유지
- [ ] 슬롯 용량 확인 (docker.io+compose ≈ +0.4GB; 8GiB 슬롯/4GiB 복구 여유)

> **주의 — DATA 용량**: 최소 30GB 디스크에선 DATA ≈ 9.5GiB 로 이미지+appdata 가 빠듯하다.
> 앱을 적극 쓰려면 ≥64GB 디스크 권장. 설치 전 DATA 여유를 가드/표시한다(앱스토어 모달).
