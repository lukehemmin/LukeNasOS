#!/bin/bash

# TTY 화면 정리 및 색상 코드
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

while true; do
    clear
    echo -e "${GREEN}"
    echo "======================================================="
    echo "              LukeNasOS System Ready                   "
    echo "======================================================="
    echo -e "${NC}"
    echo "   To install or manage the system, please access"
    echo "   the Web Dashboard via any of the following URLs:"
    echo ""

    # 네트워크 인터페이스 및 IP 파싱 (Loopback 제외)
    # ip -4 -o addr show 결과 예시:
    # 2: eth0    inet 192.168.1.5/24 brd ...
    found_ip=0
    # Process substitution을 사용하여 while 루프 내 변수 보존
    while read -r line; do
        iface=$(echo "$line" | awk '{print $2}')
        ip_cidr=$(echo "$line" | awk '{print $4}')
        # CIDR 제거
        ip_addr=${ip_cidr%/*}
        
        echo -e "   ${CYAN}▶ Interface [${iface}]:${NC} ${YELLOW}http://${ip_addr}${NC}"
        found_ip=1
    done < <(ip -4 -o addr show | grep -v " lo ")

    if [ "$found_ip" -eq 0 ]; then
        echo -e "   ${RED}[!] No network connection detected.${NC}"
        echo -e "       Check your network cable or DHCP server."
    fi

    echo ""
    echo "======================================================="
    echo ""
    echo "   [DashBoard Running] - Refreshes every 10 seconds"
    echo ""
    echo -e "   ${CYAN}>> Press [Alt] + [F2] to access Command Line <<${NC}"
    
    sleep 10
done
