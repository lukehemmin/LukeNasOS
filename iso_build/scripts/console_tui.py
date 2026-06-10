#!/usr/bin/env python3

import curses
import datetime
import json
import os
import shutil
import socket
import subprocess
import threading
import time


FAST_INTERVAL = 2   # 가벼운 항목(네트워크/서비스/시스템 지표) 수집 주기 (초)
SLOW_INTERVAL = 15  # 무거운 항목(rauc D-Bus 조회) 수집 주기 (초)
WEB_SERVICE = "lukenasos-web.service"
RAUC_SERVICE = "rauc.service"

# 부팅 모드 (boot-mode generator 가 /run/lukenasos/boot-mode 에 기록):
#   installer = 설치 미디어(live)로 부팅, 아직 미설치 → 웹 Setup 안내 화면
#   recovery  = 복구 슬롯 C 로 부팅 → 웹 복구/재설치 안내 화면
#   system    = 설치된 시스템 정상 부팅 → 운영 대시보드
BOOT_MODE_FILE = "/run/lukenasos/boot-mode"


def detect_boot_mode():
    mode = read_first_line(BOOT_MODE_FILE)
    if mode in ("installer", "recovery", "system"):
        return mode

    # generator 가 없거나 실패한 경우 커널 cmdline 으로 직접 판별
    args = read_first_line("/proc/cmdline").split()
    if "boot=live" in args:
        return "installer"
    if "lukenasos.recovery=1" in args:
        return "recovery"
    if any(arg.startswith("rauc.slot=") for arg in args):
        return "system"
    if os.path.exists("/run/live/medium"):  # live-boot 마커
        return "installer"
    return "system"


class StatusCollector(threading.Thread):
    """백그라운드 상태 수집기.

    UI 루프에서 subprocess 를 직접 부르면 (예: rauc 가 D-Bus 에서 수 초
    막히는 경우) 키 입력까지 멈춘다. 수집을 데몬 스레드로 분리하고 비용에
    따라 주기를 차등(FAST/SLOW)해 폴링한다. 값이 실제로 바뀌었을 때만
    version 을 올려, TUI 는 변경이 있을 때만 다시 그린다.
    """

    def __init__(self, mode):
        super().__init__(daemon=True)
        self.mode = mode
        self.lock = threading.Lock()
        self.data = {}
        self.version = 0
        self.last_collect = 0.0  # 마지막 수집 완료 시각 (monotonic)
        self._refresh_now = threading.Event()

    def snapshot(self):
        with self.lock:
            return self.version, dict(self.data)

    def request_refresh(self):
        """R 키 등에서 호출: 다음 틱을 기다리지 않고 즉시 전체 수집."""
        self._refresh_now.set()

    def run(self):
        fast_due = 0.0
        slow_due = 0.0
        slow_part = {}
        while True:
            now = time.monotonic()
            if self._refresh_now.is_set():
                self._refresh_now.clear()
                fast_due = slow_due = now

            if now >= fast_due:
                merged = collect_fast(self.mode)
                fast_due = now + FAST_INTERVAL
                if self.mode == "system":
                    if now >= slow_due:
                        slow_part = collect_slow()
                        slow_due = now + SLOW_INTERVAL
                    merged.update(slow_part)

                with self.lock:
                    if merged != self.data:
                        self.data = merged
                        self.version += 1
                self.last_collect = time.monotonic()

            self._refresh_now.wait(timeout=0.5)


class ConsoleDashboard:
    def __init__(self, screen, mode="system"):
        self.screen = screen
        self.mode = mode
        self.selected = 0
        self.data = {}
        self.data_version = -1
        self.message = ""
        self.refresh_requested_at = None  # R 키로 즉시 갱신을 요청한 시각
        self.collector = StatusCollector(mode)
        self.pages = [
            ("Overview", self.draw_overview),
            ("Network", self.draw_network),
            ("System", self.draw_system),
            ("Services", self.draw_services),
            ("Update", self.draw_update),
            ("Help", self.draw_help),
        ]

    def run(self):
        curses.curs_set(0)
        self.screen.nodelay(True)
        self.screen.timeout(250)
        self.init_colors()
        self.collector.start()

        last_drawn = None
        while True:
            version, data = self.collector.snapshot()
            if version != self.data_version:
                self.data_version = version
                self.data = data

            # R 키로 요청한 갱신이 끝나면 (값 변화가 없었어도) 메시지를 정리한다.
            if (self.refresh_requested_at is not None
                    and self.collector.last_collect >= self.refresh_requested_at):
                self.refresh_requested_at = None
                self.message = "Refreshed."

            # 데이터 변경, 시계(초), 선택, 메시지가 바뀔 때만 다시 그린다.
            state = (version, int(time.time()), self.selected, self.message)
            if state != last_drawn:
                self.draw()
                last_drawn = state

            key = self.screen.getch()
            if key != -1:
                self.handle_key(key)
                last_drawn = None  # 키 입력은 즉시 화면에 반영

    def init_colors(self):
        self.colors = {
            "normal": curses.A_NORMAL,
            "title": curses.A_BOLD,
            "muted": curses.A_DIM,
            "accent": curses.A_BOLD,
            "ok": curses.A_BOLD,
            "warn": curses.A_BOLD,
            "bad": curses.A_BOLD,
            "selected": curses.A_REVERSE,
        }
        if not curses.has_colors():
            return

        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_CYAN, -1)
        curses.init_pair(2, curses.COLOR_GREEN, -1)
        curses.init_pair(3, curses.COLOR_YELLOW, -1)
        curses.init_pair(4, curses.COLOR_RED, -1)
        curses.init_pair(5, curses.COLOR_BLACK, curses.COLOR_CYAN)

        self.colors.update(
            {
                "title": curses.color_pair(2) | curses.A_BOLD,
                "accent": curses.color_pair(1) | curses.A_BOLD,
                "ok": curses.color_pair(2) | curses.A_BOLD,
                "warn": curses.color_pair(3) | curses.A_BOLD,
                "bad": curses.color_pair(4) | curses.A_BOLD,
                "selected": curses.color_pair(5) | curses.A_BOLD,
            }
        )

    def handle_key(self, key):
        if key in (-1,):
            return
        if self.mode != "system":
            # Setup/Recovery 화면은 단일 화면: 새로고침만 받는다.
            if key in (ord("r"), ord("R")):
                self.refresh_requested_at = time.monotonic()
                self.collector.request_refresh()
                self.message = "Refreshing..."
            return
        if key in (curses.KEY_UP, ord("k")):
            self.selected = (self.selected - 1) % len(self.pages)
        elif key in (curses.KEY_DOWN, ord("j")):
            self.selected = (self.selected + 1) % len(self.pages)
        elif key in (ord("r"), ord("R")):
            self.collector.request_refresh()
            self.message = "Refreshing..."
        elif key in (ord("q"), ord("Q")):
            self.message = "Dashboard stays on tty1. Use Alt+F2 for shell."
        elif ord("1") <= key <= ord(str(len(self.pages))):
            self.selected = key - ord("1")

    def draw(self):
        self.screen.erase()
        height, width = self.screen.getmaxyx()
        if height < 20 or width < 72:
            self.add_text(0, 0, "LukeNasOS Console", self.colors["title"])
            self.add_text(2, 0, "Terminal is too small. Resize to at least 72x20.")
            self.screen.refresh()
            return

        if self.mode != "system":
            self.draw_setup_screen(height, width)
            self.screen.refresh()
            return

        self.draw_header(width)
        self.draw_menu(2, 1, 22)
        self.draw_panel(2, 25, height - 5, width - 27)
        self.draw_footer(height - 2, width)
        self.screen.refresh()

    def draw_setup_screen(self, height, width):
        """installer/recovery 모드 전용 화면: 웹 Setup 으로 유도한다."""
        now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        if self.mode == "installer":
            title = "LukeNasOS Setup"
            badge = "  INSTALL MODE - booted from install media  "
            headline = "LukeNasOS is NOT installed yet."
            action = "Install it from another computer using a web browser:"
            steps = [
                "1. Open the URL above in a web browser on the same network.",
                "2. Follow the Setup wizard to choose a disk and install.",
                "3. When it finishes, remove the install media and reboot.",
            ]
        else:
            title = "LukeNasOS Recovery"
            badge = "  RECOVERY MODE - booted from recovery slot  "
            headline = "The system booted into the recovery environment."
            action = "Repair or reinstall from another computer using a web browser:"
            steps = [
                "1. Open the URL above in a web browser on the same network.",
                "2. Use the wizard to repair or reinstall the system.",
                "3. Reboot when finished.",
            ]

        self.add_text(0, 1, title, self.colors["title"])
        self.add_text(0, max(1, width - len(now) - 1), now, self.colors["muted"])
        self.hline(1, 0, width)

        self.add_text(3, 3, badge, self.colors["selected"])
        self.add_text(5, 3, headline, self.colors["title"])
        self.add_text(6, 3, action)

        urls = self.data.get("urls", [])
        row = 8
        if urls:
            for entry in urls[:3]:
                line = ">>>  %s  <<<  (%s)" % (entry["url"], entry["iface"])
                self.add_text(row, 7, line[: width - 8], self.colors["ok"])
                row += 1
        else:
            self.add_text(row, 7, "No IPv4 address detected.", self.colors["bad"])
            self.add_text(row + 1, 7, "Check cable, DHCP, or VM network settings, then press R.")
            row += 2

        row += 1
        for step in steps:
            self.add_text(row, 3, step)
            row += 1

        row += 1
        self.add_text(row, 3, "Status", self.colors["accent"])
        self.kv(row + 1, 3, "Web installer", service_label(self.data.get("web_service", "unknown")))
        self.kv(row + 2, 3, "Network", network_label(urls))

        row += 4
        self.add_text(row, 3, "If the URL does not load:", self.colors["muted"])
        self.add_text(row + 1, 3, "  Alt+F2 opens a shell. Check: systemctl status lukenasos-web", self.colors["muted"])

        self.hline(height - 2, 0, width)
        footer = self.message or "R: refresh   Alt+F2: shell   dashboard: return to this screen"
        self.add_text(height - 1, 1, footer[: width - 2], self.colors["muted"])

    def draw_header(self, width):
        now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        title = "LukeNasOS Console"
        host = self.data.get("hostname", "unknown")
        slot = self.data.get("booted_slot", "unknown")
        self.add_text(0, 1, title, self.colors["title"])
        self.add_text(0, max(1, width - len(now) - 1), now, self.colors["muted"])
        self.add_text(1, 1, "Host: %s    Mode: installed (slot %s)" % (host, slot), self.colors["muted"])
        self.hline(2, 0, width)

    def draw_menu(self, top, left, width):
        self.add_text(top, left, "Menu", self.colors["accent"])
        for index, (name, _draw_fn) in enumerate(self.pages):
            attr = self.colors["selected"] if index == self.selected else self.colors["normal"]
            label = " %d. %-16s " % (index + 1, name)
            self.add_text(top + 2 + index, left, label[:width], attr)

        self.add_text(top + 11, left, "Web Dashboard", self.colors["accent"])
        urls = self.data.get("urls", [])
        if urls:
            for offset, entry in enumerate(urls[:3]):
                self.add_text(top + 13 + offset, left, entry["iface"], self.colors["muted"])
                self.add_text(top + 14 + offset, left, entry["url"][:width], self.colors["ok"])
        else:
            self.add_text(top + 13, left, "No IPv4 address", self.colors["bad"])

    def draw_panel(self, top, left, height, width):
        title, draw_fn = self.pages[self.selected]
        self.vline(top, left - 2, height)
        self.add_text(top, left, title, self.colors["title"])
        self.hline(top + 1, left, width)
        draw_fn(top + 3, left, height - 3, width)

    def draw_footer(self, row, width):
        self.hline(row - 1, 0, width)
        help_text = "Up/Down: move  1-6: jump  R: refresh  Alt+F2: shell  dashboard: return"
        if self.message:
            help_text = self.message
        self.add_text(row, 1, help_text[: width - 2], self.colors["muted"])

    def draw_overview(self, top, left, _height, width):
        self.kv(top, left, "Web UI", service_label(self.data.get("web_service", "unknown")))
        self.kv(top + 1, left, "Network", network_label(self.data.get("urls", [])))
        self.kv(top + 2, left, "Update slot", self.data.get("booted_slot", "unknown"))
        self.kv(top + 3, left, "Uptime", self.data.get("uptime", "unknown"))

        self.add_text(top + 6, left, "Dashboard URLs", self.colors["accent"])
        urls = self.data.get("urls", [])
        if not urls:
            self.add_text(top + 8, left, "No network connection detected.", self.colors["bad"])
            self.add_text(top + 9, left, "Check cable, bridge, DHCP, or VM network settings.")
            return
        for offset, entry in enumerate(urls):
            line = "%s  %s" % (entry["iface"], entry["url"])
            self.add_text(top + 8 + offset, left, line[:width], self.colors["ok"])

    def draw_network(self, top, left, _height, width):
        urls = self.data.get("urls", [])
        if not urls:
            self.add_text(top, left, "No IPv4 addresses found.", self.colors["bad"])
            return
        for index, entry in enumerate(urls):
            row = top + index * 3
            self.add_text(row, left, entry["iface"], self.colors["accent"])
            self.add_text(row + 1, left, "IP:  %s" % entry["ip"])
            self.add_text(row + 2, left, "URL: %s" % entry["url"], self.colors["ok"])

    def draw_system(self, top, left, _height, _width):
        sysinfo = self.data.get("system", {})
        self.kv(top, left, "Load average", sysinfo.get("load", "unknown"))
        self.kv(top + 1, left, "Memory", sysinfo.get("memory", "unknown"))
        self.kv(top + 2, left, "Root disk", sysinfo.get("disk", "unknown"))
        self.kv(top + 3, left, "Uptime", self.data.get("uptime", "unknown"))

    def draw_services(self, top, left, _height, _width):
        self.kv(top, left, WEB_SERVICE, service_label(self.data.get("web_service", "unknown")))
        self.kv(top + 1, left, RAUC_SERVICE, service_label(self.data.get("rauc_service", "unknown")))
        self.kv(top + 4, left, "Note", "Service actions will be added after menu scope is finalized.")

    def draw_update(self, top, left, _height, width):
        rauc = self.data.get("rauc", {})
        if rauc.get("error"):
            self.add_text(top, left, "RAUC status unavailable", self.colors["warn"])
            self.add_text(top + 1, left, rauc["error"][:width])
        else:
            self.kv(top, left, "Compatible", rauc.get("compatible", "unknown"))
            self.kv(top + 1, left, "Booted slot", rauc.get("booted", "unknown"))
            self.kv(top + 2, left, "Inactive slot", inactive_slot(rauc.get("booted")))

            slots = normalize_slots(rauc.get("slots", []))
            self.add_text(top + 5, left, "Slots", self.colors["accent"])
            row = top + 7
            for slot in slots[:8]:
                name = slot.get("name") or slot.get("bootname") or "slot"
                state = slot.get("state") or slot.get("status") or "unknown"
                device = slot.get("device") or ""
                self.add_text(row, left, ("%s  %s  %s" % (name, state, device))[:width])
                row += 1

        self.add_text(top + 14, left, "Install updates from the Web Dashboard for now.", self.colors["muted"])
        self.add_text(top + 15, left, "CLI path: sudo rauc install /path/to/update.raucb", self.colors["muted"])

    def draw_help(self, top, left, _height, _width):
        lines = [
            "This console stays on tty1 and shows local management status.",
            "Status updates automatically (network/services every %ds," % FAST_INTERVAL,
            "update info every %ds). Press R to refresh immediately." % SLOW_INTERVAL,
            "Use Alt+F2 to open a command line.",
            "Run 'dashboard' from a shell to return to this screen.",
            "Future menu actions can include updates, network setup, logs, reboot, and shutdown.",
        ]
        for offset, line in enumerate(lines):
            self.add_text(top + offset, left, line)

    def kv(self, row, left, key, value):
        self.add_text(row, left, ("%-16s" % key), self.colors["muted"])
        attr = self.value_attr(str(value))
        self.add_text(row, left + 18, str(value), attr)

    def value_attr(self, value):
        value = value.lower()
        if "active" in value or "connected" in value or "running" in value or "ok" in value:
            return self.colors["ok"]
        if "failed" in value or "error" in value or "not" in value:
            return self.colors["bad"]
        if "unknown" in value or "unavailable" in value:
            return self.colors["warn"]
        return self.colors["normal"]

    def add_text(self, row, col, text, attr=None):
        height, width = self.screen.getmaxyx()
        if row < 0 or row >= height or col >= width:
            return
        if attr is None:
            attr = self.colors["normal"]
        safe = str(text).replace("\t", "    ")
        safe = safe[: max(0, width - col - 1)]
        try:
            self.screen.addstr(row, col, safe, attr)
        except curses.error:
            pass

    def hline(self, row, col, width):
        try:
            self.screen.hline(row, col, curses.ACS_HLINE, max(0, width - col - 1))
        except curses.error:
            pass

    def vline(self, row, col, height):
        try:
            self.screen.vline(row, col, curses.ACS_VLINE, max(0, height))
        except curses.error:
            pass


def collect_fast(mode):
    """가벼운 항목: /proc 읽기, ip/systemctl 단발 호출. FAST_INTERVAL 주기."""
    data = {
        "hostname": socket.gethostname(),
        "urls": web_urls(),
        "web_service": service_state(WEB_SERVICE),
    }
    if mode == "system":
        data["system"] = system_status()
        data["uptime"] = uptime_label()
    return data


def collect_slow():
    """무거운 항목: rauc D-Bus 조회. SLOW_INTERVAL 주기, system 모드 전용.
    (installer/recovery 는 슬롯 디바이스가 없어 rauc 조회가 무의미하다.)"""
    rauc = rauc_status()
    return {
        "rauc_service": service_state(RAUC_SERVICE),
        "rauc": rauc,
        "booted_slot": rauc.get("booted") or boot_slot_from_cmdline(),
    }


def run_cmd(command, timeout=2):
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        return None, "command not found: %s" % command[0]
    except subprocess.TimeoutExpired:
        return None, "command timed out: %s" % " ".join(command)
    output = (result.stdout or result.stderr or "").strip()
    return result.returncode, output


def web_urls():
    code, output = run_cmd(["ip", "-4", "-o", "addr", "show", "scope", "global"])
    if code != 0 or not output:
        return []

    urls = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        iface = fields[1]
        ip_addr = fields[3].split("/", 1)[0]
        if iface == "lo" or ip_addr.startswith("127."):
            continue
        urls.append({"iface": iface, "ip": ip_addr, "url": "http://%s" % ip_addr})
    return urls


def service_state(name):
    code, output = run_cmd(["systemctl", "is-active", name])
    if code is None:
        return "unavailable"
    if code == 0:
        return output or "active"
    return output or "inactive"


def rauc_status():
    code, output = run_cmd(["rauc", "status", "--output-format=json"], timeout=3)
    if code is None:
        return {"error": output or "rauc command not found"}
    if code != 0:
        return {"error": output or "rauc status failed"}
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        return {"error": "invalid rauc JSON: %s" % exc}


def system_status():
    load = read_first_line("/proc/loadavg")
    load_text = " ".join(load.split()[:3]) if load else "unknown"

    mem = memory_label()
    disk = disk_label("/")
    return {"load": load_text, "memory": mem, "disk": disk}


def memory_label():
    meminfo = {}
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as handle:
            for line in handle:
                key, value = line.split(":", 1)
                meminfo[key] = int(value.strip().split()[0])
    except (OSError, ValueError):
        return "unknown"

    total = meminfo.get("MemTotal")
    available = meminfo.get("MemAvailable")
    if not total or available is None:
        return "unknown"
    used = total - available
    pct = used * 100 / total
    return "%.1f%% used (%s / %s)" % (pct, bytes_label(used * 1024), bytes_label(total * 1024))


def disk_label(path):
    try:
        usage = shutil.disk_usage(path)
    except OSError:
        return "unknown"
    pct = usage.used * 100 / usage.total if usage.total else 0
    return "%.1f%% used (%s / %s)" % (pct, bytes_label(usage.used), bytes_label(usage.total))


def uptime_label():
    line = read_first_line("/proc/uptime")
    if not line:
        return "unknown"
    seconds = int(float(line.split()[0]))
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, _seconds = divmod(remainder, 60)
    if days:
        return "%dd %dh %dm" % (days, hours, minutes)
    if hours:
        return "%dh %dm" % (hours, minutes)
    return "%dm" % minutes


def read_first_line(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.readline().strip()
    except OSError:
        return ""


def bytes_label(value):
    value = float(value)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return "%.1f %s" % (value, unit)
        value /= 1024
    return "%.1f TiB" % value


def boot_slot_from_cmdline():
    line = read_first_line("/proc/cmdline")
    for part in line.split():
        if part.startswith("rauc.slot="):
            return part.split("=", 1)[1]
    return "unknown"


def inactive_slot(active):
    if active == "A":
        return "B"
    if active == "B":
        return "A"
    return "unknown"


def normalize_slots(slots):
    if isinstance(slots, dict):
        slots = [{name: info} for name, info in slots.items()]
    if not isinstance(slots, list):
        return []

    normalized = []
    for entry in slots:
        if not isinstance(entry, dict):
            continue
        if "device" in entry or "bootname" in entry:
            normalized.append(entry)
            continue
        for name, info in entry.items():
            if isinstance(info, dict):
                merged = dict(info)
                merged.setdefault("name", name)
                normalized.append(merged)
    return normalized


def service_label(value):
    if value == "active":
        return "running"
    if not value:
        return "unknown"
    return value


def network_label(urls):
    if urls:
        return "connected (%d IPv4)" % len(urls)
    return "not connected"


def main(screen):
    dashboard = ConsoleDashboard(screen, mode=detect_boot_mode())
    dashboard.run()


if __name__ == "__main__":
    os.environ.setdefault("TERM", "linux")
    curses.wrapper(main)
