# LukeNasOS Architecture

이 문서는 LukeNasOS의 전체적인 시스템 설계와 컴포넌트 간의 상호작용을 설명합니다.

## 🏗️ High-Level Design

LukeNasOS는 **불변 인프라(Immutable Infrastructure)** 철학을 따릅니다. OS 영역은 읽기 전용(Read-only)에 가깝게 관리되며, 사용자 설정과 데이터만 별도의 파티션에 저장됩니다.

```mermaid
graph TD
    User[User / Admin] -->|HTTP/HTTPS| WebUI[Web Management UI]
    WebUI -->|System Calls| Systemd[Systemd Services]
    WebUI -->|DBus/CLI| RAUC[RAUC Update Service]
    
    subgraph "Storage Layout"
        Boot[Bootloader (GRUB)]
        SlotA[System Slot A (Active)]
        SlotB[System Slot B (Inactive)]
        Data[Data Partition (Config/Logs)]
    end
    
    RAUC -->|Writes Update| SlotB
    Systemd -->|Reads Config| Data
    Boot -->|Selects| SlotA
```

## 🧩 Core Components

### 1. The Build System (`iso_build/`)
*   **역할:** 소스 코드와 설정을 하나의 부팅 가능한 ISO 이미지로 변환.
*   **기술:** Debian Live-Build, Docker.
*   **핵심 산출물:**
    *   `kernel`: 리눅스 커널.
    *   `initrd`: 초기 램 디스크.
    *   `filesystem.squashfs`: 읽기 전용 루트 파일 시스템.

### 2. The Web Interface (`web_ui/`)
*   **역할:** 시스템 상태 모니터링 및 관리 작업을 위한 사용자 인터페이스.
*   **기술:** Python Flask, Gunicorn(예정), HTML/JS.
*   **동작 방식:**
    *   `systemd` 서비스로 부팅 시 자동 실행됩니다.
    *   `psutil` 라이브러리를 통해 커널 정보를 읽어옵니다.
    *   `config_manager.py`를 통해 `/mnt/data/config.json` (예시) 경로의 설정을 영구 보존합니다.

### 3. Update Mechanism (RAUC)
*   **위치:** `iso_build/UPDATE_MECHANISM.md` 참조.
*   **설계:** A/B 파티션 슬롯을 사용하여 업데이트 실패 시 원자적(Atomic) 롤백을 보장합니다.
*   **흐름:**
    1.  사용자가 Web UI에 `.raucb` 번들 업로드.
    2.  Web UI 백엔드가 번들 서명 검증.
    3.  현재 사용하지 않는 슬롯에 이미지 설치.
    4.  재부팅 및 부트로더 플래그 전환.

## 💾 Storage Strategy

시스템의 안정성을 위해 파티션은 엄격하게 분리됩니다.

| 파티션 | 파일 시스템 | 용도 | 특이사항 |
| :--- | :--- | :--- | :--- |
| **BOOT** | VFAT/Ext4 | 부트로더, 커널 | 업데이트 시 변경될 수 있음 |
| **SYSTEM-A** | SquashFS/Ext4 | OS 이미지 (Slot A) | Read-Only 권장 |
| **SYSTEM-B** | SquashFS/Ext4 | OS 이미지 (Slot B) | Read-Only 권장 |
| **DATA** | Ext4/Btrfs | 사용자 설정, 로그, DB | **영구 저장소 (Persistence)** |

*   **OS 업데이트 시:** `SYSTEM-A`와 `SYSTEM-B`만 교체됩니다.
*   **설정 보존:** `DATA` 파티션은 건드리지 않으므로 사용자 설정은 유지됩니다.

## 🛡️ Security Design

*   **Isolation:** Web UI는 일반 유저 권한(가능한 경우)으로 실행되며, 필요한 경우에만 `sudo` 또는 `polkit`을 통해 권한을 상승시킵니다(현재는 개발 편의를 위해 root로 실행될 수 있음).
*   **Signed Updates:** 모든 업데이트 번들은 개인키로 서명되어야 하며, 기기 내의 공개키로 검증되지 않으면 설치되지 않습니다.
