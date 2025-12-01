# LukeNasOS Update System Architecture

LukeNasOS는 **RAUC (Robust Auto-Update Controller)**를 사용하여 엔터프라이즈급의 안정적인 A/B 파티션 업데이트 시스템을 제공합니다.

## 🔄 A/B 파티션 메커니즘

시스템은 두 개의 중복된 루트 파일 시스템 슬롯(`Slot A`, `Slot B`)을 가집니다.

1.  **부팅**: 시스템은 현재 활성화된(Active) 슬롯(예: A)으로 부팅합니다.
2.  **업데이트**: 새로운 업데이트가 도착하면, 시스템은 현재 사용 중이지 않은(Inactive) 슬롯(예: B)에 이미지를 씁니다.
3.  **전환**: 설치가 완료되면 부트로더 설정을 변경하여 다음 부팅 시 B 슬롯을 시도하도록 합니다.
4.  **검증 및 롤백**:
    *   재부팅 후 시스템이 정상적으로 시작되면 업데이트가 **확정(Commit)**됩니다.
    *   부팅에 실패하거나 워치독(Watchdog)에 의해 감지되면, 부트로더는 자동으로 이전 슬롯(A)으로 **롤백**합니다.

이 모든 과정은 `rauc` 데몬에 의해 관리됩니다.

## 📦 업데이트 번들 (.raucb)

업데이트는 단일 파일인 `.raucb` 번들로 배포됩니다.

### 번들 생성 (`create_update_bundle.sh`)

루트 디렉토리의 스크립트를 통해 번들을 생성할 수 있습니다.

```bash
./create_update_bundle.sh <path_to_rootfs_directory>
```

### 번들 구성 요소
*   **`manifest.raucm`**: 번들 메타데이터(버전, 호환성 정보, 설치할 슬롯 정의 등).
*   **`rootfs.img`**: SquashFS로 압축된 전체 루트 파일 시스템 이미지.
*   **서명 (Signature)**: 번들은 개발자의 개인키로 서명되어야 하며, 기기는 대응하는 공개키를 가지고 있어 위변조를 방지합니다.

## 🔌 Web UI 통합

Web UI의 `UpdateEngine`은 `rauc`의 D-Bus 인터페이스 또는 CLI 래퍼를 통해 업데이트 프로세스를 제어합니다.

1.  사용자가 Web UI에 `.raucb` 파일 업로드.
2.  `UpdateEngine`이 백그라운드 스레드에서 `rauc install <bundle>` 실행.
3.  설치 진행률을 Web UI로 스트리밍.
4.  완료 시 "재부팅" 버튼 활성화.

## 🛡️ 보안

*   **서명 검증**: RAUC는 설치 전 번들의 암호화 서명을 검증합니다. 서명이 유효하지 않으면 설치가 거부됩니다.
*   **인증서**: 인증서(`cert.pem`)와 키(`key.pem`)는 `certs/` 디렉토리에서 관리됩니다. (프로덕션 환경에서는 키 관리에 주의해야 합니다.)
