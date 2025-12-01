import os
import subprocess
import json
import time
import shutil
import threading
from utils.logger import logger

class Installer:
    def __init__(self):
        self.lock = threading.Lock()
        self.status = 'idle'
        self.message = ''
        self.progress = 0
        self.error = None

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
            # 1. 초기화 및 언마운트 (5%)
            self._update_status(5, "Unmounting target disk...")
            # 파티션들이 마운트되어 있을 수 있으므로 언마운트 시도 (실패해도 무시)
            subprocess.run(f"umount {target_disk}*", shell=True, stderr=subprocess.DEVNULL)
            
            # 2. 파티셔닝 (10%)
            self._update_status(10, f"Partitioning {target_disk}...")
            # Universal Partition Layout (GPT)
            # 1. BIOS Boot (1MB) - For Legacy BIOS/GPT
            # 2. EFI System (512MB) - For UEFI
            # 3. ROOT-A (4GB)
            # 4. ROOT-B (4GB)
            # 5. DATA (Rest)
            
            cmds = [
                ['parted', '-s', target_disk, 'mklabel', 'gpt'],
                # 1. BIOS Boot Partition (1MB ~ 2MB)
                ['parted', '-s', target_disk, 'mkpart', 'non-fs', '1MiB', '2MiB'],
                ['parted', '-s', target_disk, 'set', '1', 'bios_grub', 'on'],
                # 2. EFI System Partition (2MB ~ 514MB)
                ['parted', '-s', target_disk, 'mkpart', 'ESP', 'fat32', '2MiB', '514MiB'],
                ['parted', '-s', target_disk, 'set', '2', 'esp', 'on'],
                # 3. Root A
                ['parted', '-s', target_disk, 'mkpart', 'NAS-SYSTEM-A', 'ext4', '514MiB', '4610MiB'],
                # 4. Root B
                ['parted', '-s', target_disk, 'mkpart', 'NAS-SYSTEM-B', 'ext4', '4610MiB', '8706MiB'],
                # 5. Data
                ['parted', '-s', target_disk, 'mkpart', 'NAS-DATA', 'ext4', '8706MiB', '100%']
            ]
            
            for cmd in cmds:
                self._run_command(cmd)

            # 파티션 디바이스 이름 결정
            p_prefix = f"{target_disk}p" if target_disk[-1].isdigit() else f"{target_disk}"
            
            # Universal Layout Indices
            p_bios_grub = f"{p_prefix}1" # Not mounted, used by GRUB in Legacy mode
            p_efi = f"{p_prefix}2"
            p_root_a = f"{p_prefix}3"
            p_root_b = f"{p_prefix}4"
            p_data = f"{p_prefix}5"

            # 디바이스 노드 생성 대기
            time.sleep(2)
            subprocess.run(['partprobe', target_disk])
            time.sleep(2)

            # 3. 포맷팅 (20%)
            self._update_status(20, "Formatting partitions...")
            self._run_command(['mkfs.vfat', '-F32', '-n', 'NAS-BOOT', p_efi])
            self._run_command(['mkfs.ext4', '-F', '-L', 'NAS-SYSTEM-A', p_root_a])
            self._run_command(['mkfs.ext4', '-F', '-L', 'NAS-SYSTEM-B', p_root_b])
            self._run_command(['mkfs.ext4', '-F', '-L', 'NAS-DATA', p_data])

            # 4. 마운트 및 시스템 복제 (30% ~ 70%)
            self._update_status(30, "Mounting filesystems...")
            target_mnt = "/mnt/lukenasos_install"
            os.makedirs(target_mnt, exist_ok=True)
            
            # Root A 마운트
            self._run_command(['mount', p_root_a, target_mnt])
            
            # EFI 마운트
            os.makedirs(f"{target_mnt}/boot/efi", exist_ok=True)
            self._run_command(['mount', p_efi, f"{target_mnt}/boot/efi"])
            
            # Data 마운트 (디렉토리 생성용)
            os.makedirs(f"{target_mnt}/var/lib/lukenasos/data", exist_ok=True)

            self._update_status(40, "Copying system files (This may take a while)...")
            
            # rsync로 현재 시스템 복제
            # 제외 목록: /proc, /sys, /dev, /run, /tmp, /mnt, /media, /cdrom
            rsync_cmd = [
                'rsync', '-axHAX',
                '--info=progress2',
                '--exclude=/proc/*',
                '--exclude=/sys/*',
                '--exclude=/dev/*',
                '--exclude=/run/*',
                '--exclude=/tmp/*',
                '--exclude=/mnt/*',
                '--exclude=/media/*',
                '--exclude=/cdrom/*',
                '--exclude=/live/*', # Live 시스템 관련
                '/', f"{target_mnt}/"
            ]
            
            # rsync 실행 (출력 로그는 너무 많으니 생략하거나 파일로 저장)
            subprocess.run(rsync_cmd, check=True)

            # 필수 디렉토리 생성
            for d in ['proc', 'sys', 'dev', 'run', 'tmp']:
                os.makedirs(f"{target_mnt}/{d}", exist_ok=True)

            # 5. 설정 파일 구성 (80%)
            self._update_status(80, "Configuring system...")

            # /etc/fstab 생성
            # UUID로 마운트하는 것이 안전함
            uuid_efi = self._get_uuid(p_efi)
            uuid_root_a = self._get_uuid(p_root_a)
            uuid_root_b = self._get_uuid(p_root_b) # 마운트는 안하지만 기록용
            uuid_data = self._get_uuid(p_data)

            fstab_content = f"""
# /etc/fstab: static file system information.
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID={uuid_root_a}  /               ext4    errors=remount-ro 0       1
UUID={uuid_efi}     /boot/efi       vfat    umask=0077      0       1
UUID={uuid_data}    /var/lib/lukenasos/data ext4    defaults        0       2
tmpfs              /tmp            tmpfs   defaults,noatime,mode=1777 0 0
"""
            with open(f"{target_mnt}/etc/fstab", 'w') as f:
                f.write(fstab_content)

            # Hostname 설정
            with open(f"{target_mnt}/etc/hostname", 'w') as f:
                f.write(config.get('hostname', 'lukenasos'))
                
            # Hosts 설정
            with open(f"{target_mnt}/etc/hosts", 'w') as f:
                f.write(f"127.0.0.1\tlocalhost\n127.0.1.1\t{config.get('hostname', 'lukenasos')}\n")

            # RAUC system.conf 설정 (실제 UUID 기반)
            self._configure_rauc(target_mnt, target_disk)

            # 6. 부트로더 설치 (90%)
            self._update_status(90, "Installing bootloader...")
            
            # GRUB 설정 (A/B 부팅 로직)
            self._install_grub(target_mnt, target_disk)

            # 7. 정리 (99%)
            self._update_status(99, "Finalizing...")
            
            # 언마운트
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

    def _get_uuid(self, device):
        cmd = ['blkid', '-s', 'UUID', '-o', 'value', device]
        return subprocess.check_output(cmd, text=True).strip()

    def _configure_rauc(self, root_mnt, device):
        # RAUC 설정 파일 생성
        rauc_conf_path = f"{root_mnt}/etc/rauc/system.conf"
        os.makedirs(os.path.dirname(rauc_conf_path), exist_ok=True)
        
        # 파티션 이름 결정
        p_prefix = f"{device}p" if device[-1].isdigit() else f"{device}"
        
        # Universal Layout: RootA is p3, RootB is p4
        conf_content = f"""
[system]
compatible=LukeNasOS
bootloader=grub

[keyring]
path=/etc/rauc/keyring.pem

[slot.rootfs.0]
device={p_prefix}3
type=ext4
bootname=A

[slot.rootfs.1]
device={p_prefix}4
type=ext4
bootname=B
"""
        with open(rauc_conf_path, 'w') as f:
            f.write(conf_content)

    def _install_grub(self, root_mnt, device):
        # Check Boot Mode (Legacy vs UEFI)
        is_efi = os.path.exists("/sys/firmware/efi")
        mode_str = "UEFI" if is_efi else "Legacy BIOS"
        logger.info(f"Detected Boot Mode: {mode_str}")

        # GRUB 설치를 위해 필요한 가상 파일시스템 바인드 마운트
        for d in ['dev', 'proc', 'sys']:
            self._run_command(['mount', '--bind', f"/{d}", f"{root_mnt}/{d}"])
        
        try:
            # GRUB 기본 설정 파일 생성 (/etc/default/grub)
            grub_default = """
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="LukeNasOS"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="rauc.slot=A"
GRUB_DISABLE_OS_PROBER=true
"""
            with open(f"{root_mnt}/etc/default/grub", 'w') as f:
                f.write(grub_default)

            # GRUB 설치 명령 실행 (Chroot 내부)
            chroot_cmd = ['chroot', root_mnt, '/bin/bash', '-c']
            
            if is_efi:
                # UEFI Installation
                logger.info("Installing GRUB for x86_64-efi...")
                self._run_command(chroot_cmd + [f"grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=LukeNasOS --recheck {device}"])
            else:
                # Legacy BIOS Installation (i386-pc)
                # Installs to the MBR and the 'bios_grub' partition (Part 1)
                logger.info("Installing GRUB for i386-pc (Legacy)...")
                self._run_command(chroot_cmd + [f"grub-install --target=i386-pc --recheck {device}"])
            
            # 공통: grub config 생성
            self._run_command(chroot_cmd + ["update-grub"])

        finally:
            # 바인드 마운트 해제
            for d in ['sys', 'proc', 'dev']:
                subprocess.run(['umount', f"{root_mnt}/{d}"], stderr=subprocess.DEVNULL)

installer = Installer()
