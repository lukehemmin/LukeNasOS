import os
import subprocess
import json
import time
import shutil
import threading
from utils.logger import logger

# 파티션 레이아웃 (MiB). A/B 슬롯은 15GiB 로 상향(실측 rootfs ~2.7GB 대비 충분한 성장 여유).
# C(복구)는 RAUC 로테이션 밖의 고정 슬롯. OS 영역 합 ≈ 34.5GiB.
PART_ESP_START = 2
PART_ESP_END = 514          # 512MiB ESP
PART_A_START = 514
PART_A_END = 15874          # 15GiB
PART_B_START = 15874
PART_B_END = 31234          # 15GiB
PART_C_START = 31234
PART_C_END = 35330          # 4GiB (recovery)
# DATA: PART_C_END ~ 100%

# 설치 가능한 최소 디스크 크기. OS 영역(≈34.5GiB) + 최소 DATA 여유.
MIN_DISK_BYTES = 40 * 1024 ** 3   # 40 GiB

# rsync 공통 제외 목록 (live 시스템 -> 슬롯 복제용)
RSYNC_EXCLUDES = [
    '--exclude=/proc/*',
    '--exclude=/sys/*',
    '--exclude=/dev/*',
    '--exclude=/run/*',
    '--exclude=/tmp/*',
    '--exclude=/mnt/*',
    '--exclude=/media/*',
    '--exclude=/cdrom/*',
    '--exclude=/live/*',   # Live 시스템 관련
]

# 슬롯 비종속 fstab. root(/) 은 GRUB 의 root=PARTUUID=... 로 마운트되므로 적지 않는다.
SLOT_FSTAB = """# /etc/fstab (LukeNasOS, slot-agnostic)
# root(/) 은 GRUB 의 root=PARTUUID=... 로 마운트됨 (여기에 적지 않음)
LABEL=NAS-BOOT  /boot/efi                vfat   umask=0077                 0 1
LABEL=NAS-DATA  /var/lib/lukenasos/data  ext4   defaults,nofail            0 2
tmpfs           /tmp                     tmpfs  defaults,noatime,mode=1777 0 0
"""


class Installer:
    def __init__(self):
        self.lock = threading.Lock()
        self.status = 'idle'
        self.message = ''
        self.progress = 0
        self.error = None
        # 슬롯 복제 원본. 실제 설치에서는 현재 live 시스템 '/'. (테스트에서 다른 rootfs 로 교체 가능)
        self.rsync_source = '/'

    def get_disks(self):
        """
        lsblk -J -o NAME,SIZE,TYPE,MODEL 명령어를 사용하여 디스크 목록을 가져옵니다.
        """
        try:
            cmd = ['lsblk', '-J', '-o', 'NAME,SIZE,TYPE,MODEL,RO']
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                logger.error(f"Failed to list disks: {result.stderr}")
                return []

            data = json.loads(result.stdout)
            disks = []
            for device in data.get('blockdevices', []):
                # 읽기 전용(RO)이 아니고, 디스크 타입인 경우만
                if device.get('type') == 'disk' and not device.get('ro', False):
                    disks.append({
                        'name': f"/dev/{device['name']}",
                        'model': device.get('model', 'Unknown'),
                        'size': device.get('size', 'Unknown')
                    })
            return disks
        except Exception as e:
            logger.error(f"Error getting disks: {e}")
            return []

    def start_install(self, target_disk, config):
        """
        별도 스레드에서 설치 프로세스를 시작합니다.
        config: {'hostname': '...', 'password': '...'}
        """
        with self.lock:
            if self.status == 'installing':
                return False, "Installation already in progress"

            self.status = 'installing'
            self.message = 'Initializing installation...'
            self.progress = 0
            self.error = None

        thread = threading.Thread(target=self._run_install, args=(target_disk, config))
        thread.start()
        return True, "Installation started"

    def _update_status(self, progress, message):
        with self.lock:
            self.progress = progress
            self.message = message
            logger.info(f"[Installer] {progress}% - {message}")

    def _run_command(self, cmd):
        logger.info(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise Exception(f"Command failed: {' '.join(cmd)}\nStderr: {result.stderr}")
        return result

    def _run_install(self, target_disk, config):
        try:
            # 0. 디스크 크기 가드 (A/B 15GiB + C 4GiB + DATA 여유)
            self._update_status(3, "Checking disk size...")
            try:
                disk_bytes = int(subprocess.check_output(
                    ['blockdev', '--getsize64', target_disk], text=True).strip())
            except Exception as e:
                raise Exception(f"Cannot read disk size for {target_disk}: {e}")
            if disk_bytes < MIN_DISK_BYTES:
                gib = 1024 ** 3
                raise Exception(
                    f"Disk too small: {disk_bytes / gib:.1f} GiB available, "
                    f"need at least {MIN_DISK_BYTES / gib:.0f} GiB "
                    f"(A/B 15GiB each + recovery 4GiB + data).")

            # 1. 초기화 및 언마운트 (5%)
            self._update_status(5, "Unmounting target disk...")
            # 파티션들이 마운트되어 있을 수 있으므로 언마운트 시도 (실패해도 무시)
            subprocess.run(f"umount {target_disk}*", shell=True, stderr=subprocess.DEVNULL)

            # 2. 파티셔닝 (10%)
            self._update_status(10, f"Partitioning {target_disk}...")
            # Universal Partition Layout (GPT)
            # 1. BIOS Boot (1MiB)            - Legacy BIOS/GPT
            # 2. EFI System (512MiB)         - UEFI
            # 3. ROOT-A (15GiB)              - RAUC slot A
            # 4. ROOT-B (15GiB)              - RAUC slot B
            # 5. RECOVERY-C (4GiB)           - 복구 전용 (RAUC 비등록, freeze)
            # 6. DATA (Rest)
            cmds = [
                ['parted', '-s', target_disk, 'mklabel', 'gpt'],
                # 1. BIOS Boot Partition (1MiB ~ 2MiB)
                ['parted', '-s', target_disk, 'mkpart', 'non-fs', '1MiB', '2MiB'],
                ['parted', '-s', target_disk, 'set', '1', 'bios_grub', 'on'],
                # 2. EFI System Partition
                ['parted', '-s', target_disk, 'mkpart', 'ESP', 'fat32',
                 f'{PART_ESP_START}MiB', f'{PART_ESP_END}MiB'],
                ['parted', '-s', target_disk, 'set', '2', 'esp', 'on'],
                # 3. Root A
                ['parted', '-s', target_disk, 'mkpart', 'NAS-SYSTEM-A', 'ext4',
                 f'{PART_A_START}MiB', f'{PART_A_END}MiB'],
                # 4. Root B
                ['parted', '-s', target_disk, 'mkpart', 'NAS-SYSTEM-B', 'ext4',
                 f'{PART_B_START}MiB', f'{PART_B_END}MiB'],
                # 5. Recovery C
                ['parted', '-s', target_disk, 'mkpart', 'NAS-RECOVERY-C', 'ext4',
                 f'{PART_C_START}MiB', f'{PART_C_END}MiB'],
                # 6. Data
                ['parted', '-s', target_disk, 'mkpart', 'NAS-DATA', 'ext4',
                 f'{PART_C_END}MiB', '100%'],
            ]

            for cmd in cmds:
                self._run_command(cmd)

            # 파티션 디바이스 이름 결정
            p_prefix = f"{target_disk}p" if target_disk[-1].isdigit() else f"{target_disk}"

            # Universal Layout Indices
            p_bios_grub = f"{p_prefix}1"   # Not mounted, used by GRUB in Legacy mode
            p_efi = f"{p_prefix}2"
            p_root_a = f"{p_prefix}3"
            p_root_b = f"{p_prefix}4"
            p_recovery_c = f"{p_prefix}5"
            p_data = f"{p_prefix}6"

            # 디바이스 노드 생성 대기
            time.sleep(2)
            subprocess.run(['partprobe', target_disk])
            time.sleep(2)

            # 3. 포맷팅 (20%)
            self._update_status(20, "Formatting partitions...")
            self._run_command(['mkfs.vfat', '-F32', '-n', 'NAS-BOOT', p_efi])
            self._run_command(['mkfs.ext4', '-F', '-L', 'NAS-SYSTEM-A', p_root_a])
            self._run_command(['mkfs.ext4', '-F', '-L', 'NAS-SYSTEM-B', p_root_b])
            self._run_command(['mkfs.ext4', '-F', '-L', 'NAS-RECOVERY-C', p_recovery_c])
            self._run_command(['mkfs.ext4', '-F', '-L', 'NAS-DATA', p_data])

            # 슬롯/복구 파티션의 PARTUUID (GPT 속성 → mkfs/RAUC 재포맷에도 불변)
            #  → GRUB 의 root=PARTUUID=... 로 안정적으로 마운트
            partuuids = {
                'A': self._get_partuuid(p_root_a),
                'B': self._get_partuuid(p_root_b),
                'C': self._get_partuuid(p_recovery_c),
            }

            # 4. 마운트 및 시스템 복제 (30% ~ 70%)
            self._update_status(30, "Mounting filesystems...")
            target_mnt = "/mnt/lukenasos_install"
            os.makedirs(target_mnt, exist_ok=True)

            # Root A 마운트
            self._run_command(['mount', p_root_a, target_mnt])

            # EFI 마운트
            os.makedirs(f"{target_mnt}/boot/efi", exist_ok=True)
            self._run_command(['mount', p_efi, f"{target_mnt}/boot/efi"])

            # Data 마운트포인트 (디렉토리만 생성)
            os.makedirs(f"{target_mnt}/var/lib/lukenasos/data", exist_ok=True)

            self._update_status(40, "Copying system files to slot A (This may take a while)...")
            self._rsync_system(target_mnt)

            # 5. 설정 파일 구성 (75%)
            self._update_status(75, "Configuring system...")

            # 슬롯 비종속 fstab
            with open(f"{target_mnt}/etc/fstab", 'w') as f:
                f.write(SLOT_FSTAB)

            # Hostname 설정
            with open(f"{target_mnt}/etc/hostname", 'w') as f:
                f.write(config.get('hostname', 'lukenasos'))

            # Hosts 설정
            with open(f"{target_mnt}/etc/hosts", 'w') as f:
                f.write(f"127.0.0.1\tlocalhost\n127.0.1.1\t{config.get('hostname', 'lukenasos')}\n")

            # RAUC system.conf 설정 (A=p3, B=p4; C 는 비등록)
            self._configure_rauc(target_mnt, target_disk)

            # 6. 복구 슬롯 C 채우기 (80%)
            self._update_status(80, "Populating recovery slot C...")
            self._populate_recovery(p_recovery_c)

            # 7. 부트로더 설치 (90%) - grubenv 기반 A/B 선택 + 복구 폴백 + 숨김 메뉴
            self._update_status(90, "Installing bootloader...")
            self._install_grub(target_mnt, target_disk, partuuids)

            # 8. 정리 (99%)
            self._update_status(99, "Finalizing...")
            self._run_command(['umount', '-R', target_mnt])

            self._update_status(100, "Installation Complete!")
            self.status = 'success'
            self.message = "Installation finished successfully. System will reboot in 5 seconds."

        except Exception as e:
            logger.error(f"Installation failed: {e}")
            import traceback
            logger.error(traceback.format_exc())
            self.status = 'error'
            self.message = str(e)
            # 실패 시 언마운트 시도
            subprocess.run(['umount', '-R', "/mnt/lukenasos_install"], stderr=subprocess.DEVNULL)
            subprocess.run(['umount', '-R', "/mnt/lukenasos_recovery"], stderr=subprocess.DEVNULL)

    def _rsync_system(self, dest_mnt):
        """현재(live) 시스템(self.rsync_source)을 dest_mnt 로 복제하고 필수 디렉토리를 만든다."""
        src = self.rsync_source.rstrip('/') + '/'
        rsync_cmd = ['rsync', '-axHAX', '--info=progress2'] + RSYNC_EXCLUDES + [src, f"{dest_mnt}/"]
        subprocess.run(rsync_cmd, check=True)
        for d in ['proc', 'sys', 'dev', 'run', 'tmp', 'boot/efi', 'var/lib/lukenasos/data']:
            os.makedirs(f"{dest_mnt}/{d}", exist_ok=True)

    def _populate_recovery(self, device):
        """
        복구 슬롯 C 를 현재 시스템 복제본으로 채운다(2a: 전체 rootfs 복제).
        C 는 RAUC 가 건드리지 않는 고정 known-good. 복구 모드는 GRUB 메뉴가 커널 cmdline 에
        lukenasos.recovery=1 을 넘기는 것으로 활성화되므로 별도 마커 파일은 불필요하다.
        """
        rec_mnt = "/mnt/lukenasos_recovery"
        os.makedirs(rec_mnt, exist_ok=True)
        self._run_command(['mount', device, rec_mnt])
        try:
            self._rsync_system(rec_mnt)
            with open(f"{rec_mnt}/etc/fstab", 'w') as f:
                f.write(SLOT_FSTAB)
        finally:
            subprocess.run(['umount', '-R', rec_mnt], stderr=subprocess.DEVNULL)

    def _get_uuid(self, device):
        cmd = ['blkid', '-s', 'UUID', '-o', 'value', device]
        return subprocess.check_output(cmd, text=True).strip()

    def _get_partuuid(self, device):
        cmd = ['blkid', '-s', 'PARTUUID', '-o', 'value', device]
        return subprocess.check_output(cmd, text=True).strip()

    def _configure_rauc(self, root_mnt, device):
        # RAUC 설정 파일 생성
        rauc_conf_path = f"{root_mnt}/etc/rauc/system.conf"
        os.makedirs(os.path.dirname(rauc_conf_path), exist_ok=True)

        # 슬롯은 GPT partlabel 로 참조한다(디바이스 이름 비종속: sda/vda/nvme 무관).
        #  partlabel 은 GPT 파티션 속성이라 RAUC 가 슬롯을 mkfs 재포맷해도 유지된다.
        #  C(NAS-RECOVERY-C)/DATA 는 RAUC 슬롯이 아니다.
        #  grubenv 는 ESP 의 grub 디렉토리에 둔다(슬롯과 분리). RAUC 는 이 파일에 ORDER/_OK 를 기록.
        conf_content = """
[system]
compatible=LukeNasOS
bootloader=grub
grubenv=/boot/efi/grub/grubenv

[keyring]
path=/etc/rauc/keyring.pem

[slot.rootfs.0]
device=/dev/disk/by-partlabel/NAS-SYSTEM-A
type=ext4
bootname=A

[slot.rootfs.1]
device=/dev/disk/by-partlabel/NAS-SYSTEM-B
type=ext4
bootname=B
"""
        with open(rauc_conf_path, 'w') as f:
            f.write(conf_content)

    def _grub_cfg(self, partuuids):
        """
        정적 grub.cfg 생성. grubenv(ORDER/_OK/_TRY) 기반 A/B 선택 + 복구(C) 폴백 + 숨김 메뉴.
        - 슬롯 참조는 불변 파티션 위치 (hd*,gptN) 로, root= 는 불변 PARTUUID 로 → RAUC 재포맷에도 안정.
        - 평소 메뉴 숨김(timeout_style=hidden), 부팅 중 키 입력(Esc 등) 시 메뉴 표시.
        - 커널/initrd 는 슬롯 내 버전 비종속 심볼릭 링크(/vmlinuz, /initrd.img) 사용 → 업데이트로
          커널 버전이 바뀌어도 동일 grub.cfg 로 부팅 가능.
        menuentry 인덱스: 0=Recovery(C), 1=Slot A, 2=Slot B (기본 폴백=0=복구).
        """
        return f"""# LukeNasOS GRUB - A/B slot selection + recovery fallback (RAUC managed)
insmod part_gpt
insmod ext2
insmod fat
insmod search
insmod regexp

# grubenv (ORDER, *_OK, *_TRY) 는 이 grub.cfg 와 같은 위치(ESP/grub)에 있다.
if [ -s ${{prefix}}/grubenv ]; then
  load_env
fi

# 부팅 디스크 식별: $root 는 GRUB 가 이 grub.cfg 를 읽은 파티션(ESP), 예) hd0,gpt2.
# 디스크명만 뽑아 슬롯 참조의 hd0 하드코딩을 피한다(실패 시 hd0 폴백).
set bootdisk=hd0
regexp --set=1:bootdisk '^([^,]+),' "${{root}}"

if [ -z "${{ORDER}}" ]; then
  set ORDER="A B"
fi

# 기본값 0 = Recovery(C). A/B 중 부팅 가능한 슬롯이 있으면 그쪽으로.
set default=0
set timeout=2
set timeout_style=hidden

for SLOT in ${{ORDER}}; do
  if [ "${{SLOT}}" = "A" ]; then
    if [ "${{A_OK}}" = "1" ]; then
      if [ "${{A_TRY}}" = "0" ]; then
        set A_TRY=1
        set default=1
        break
      fi
    fi
  fi
  if [ "${{SLOT}}" = "B" ]; then
    if [ "${{B_OK}}" = "1" ]; then
      if [ "${{B_TRY}}" = "0" ]; then
        set B_TRY=1
        set default=2
        break
      fi
    fi
  fi
done

# 이번 라운드에 부팅 가능한 슬롯이 없으면(_TRY 소진) → Recovery 로 가되,
# 다음 부팅을 위해 정상 슬롯의 _TRY 를 리셋해 재시도 기회를 준다.
if [ "${{default}}" = "0" ]; then
  if [ "${{A_OK}}" = "1" ]; then set A_TRY=0; fi
  if [ "${{B_OK}}" = "1" ]; then set B_TRY=0; fi
fi

save_env A_TRY A_OK B_TRY B_OK ORDER

menuentry "LukeNasOS Recovery (C)" {{
  set root="(${{bootdisk}},gpt5)"
  linux /vmlinuz root=PARTUUID={partuuids['C']} rw lukenasos.recovery=1 quiet panic=60
  initrd /initrd.img
}}

menuentry "LukeNasOS (Slot A)" {{
  set root="(${{bootdisk}},gpt3)"
  linux /vmlinuz root=PARTUUID={partuuids['A']} rw rauc.slot=A quiet panic=60
  initrd /initrd.img
}}

menuentry "LukeNasOS (Slot B)" {{
  set root="(${{bootdisk}},gpt4)"
  linux /vmlinuz root=PARTUUID={partuuids['B']} rw rauc.slot=B quiet panic=60
  initrd /initrd.img
}}
"""

    def _install_grub(self, root_mnt, device, partuuids):
        # Check Boot Mode (Legacy vs UEFI)
        is_efi = os.path.exists("/sys/firmware/efi")
        mode_str = "UEFI" if is_efi else "Legacy BIOS"
        logger.info(f"Detected Boot Mode: {mode_str}")

        # GRUB 설치를 위해 필요한 가상 파일시스템 바인드 마운트
        for d in ['dev', 'proc', 'sys']:
            self._run_command(['mount', '--bind', f"/{d}", f"{root_mnt}/{d}"])

        try:
            chroot_cmd = ['chroot', root_mnt, '/bin/bash', '-c']

            # GRUB 코어/모듈을 ESP 의 grub 디렉토리에 설치 → grub.cfg/grubenv 를 슬롯과 분리해
            # 단일 위치에서 공유(양 슬롯이 동일 부트 설정을 읽음). BIOS/UEFI 모두 ESP 기준.
            if is_efi:
                logger.info("Installing GRUB for x86_64-efi...")
                self._run_command(chroot_cmd + [
                    "grub-install --target=x86_64-efi --efi-directory=/boot/efi "
                    "--boot-directory=/boot/efi --bootloader-id=LukeNasOS --recheck " + device])
            else:
                logger.info("Installing GRUB for i386-pc (Legacy)...")
                self._run_command(chroot_cmd + [
                    "grub-install --target=i386-pc --boot-directory=/boot/efi --recheck " + device])

            # 정적 grub.cfg 작성 (update-grub 미사용)
            grub_dir = f"{root_mnt}/boot/efi/grub"
            os.makedirs(grub_dir, exist_ok=True)
            with open(f"{grub_dir}/grub.cfg", 'w') as f:
                f.write(self._grub_cfg(partuuids))

            # grubenv 초기화: A 만 설치된 상태이므로 A_OK=1, B 는 비어 있으므로 B_OK=0.
            #  첫 업데이트가 B 에 설치되면 RAUC 가 B_OK=1·ORDER 선두로 전환한다.
            #  A 가 부팅 실패하면 B_OK=0 이라 B(빈 슬롯)를 건너뛰고 곧장 복구(C)로 폴백한다.
            self._run_command(chroot_cmd + ["grub-editenv /boot/efi/grub/grubenv create"])
            self._run_command(chroot_cmd + [
                "grub-editenv /boot/efi/grub/grubenv set 'ORDER=A B' "
                "A_OK=1 B_OK=0 A_TRY=0 B_TRY=0"])

        finally:
            # 바인드 마운트 해제
            for d in ['sys', 'proc', 'dev']:
                subprocess.run(['umount', f"{root_mnt}/{d}"], stderr=subprocess.DEVNULL)

installer = Installer()
