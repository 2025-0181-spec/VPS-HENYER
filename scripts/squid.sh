#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo Squid Proxy
# ============================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

handle_squid() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── Squid Proxy ──────────────────────────────────────${NC}\n"
        if ! _cmd_exists "squid"; then
            echo -e "  ${W}[1]${NC} Instalar Squid  ${DIM}[0]${NC} Volver"
            echo -e "  Selección: \c"; read -r o
            [[ "$o" == "1" ]] && _apt_install "squid" || return
            _press_enter; continue
        fi
        _service_active "squid" && local st="${G}● ACTIVO${NC}" || local st="${R}● INACTIVO${NC}"
        local sq_port; sq_port=$(grep -E "^http_port" /etc/squid/squid.conf 2>/dev/null | awk '{print $2}' | head -1 || echo "3128")
        echo -e "  Estado: $st  Puerto: ${W}${sq_port}${NC}\n"
        echo -e "  ${W}[1]${NC} Activar/Desactivar  ${W}[2]${NC} Cambiar puerto  ${DIM}[0]${NC} Volver"
        echo -e "  Selección: \c"; read -r o
        case "$o" in
            1) _toggle_service "squid" "Squid"; _press_enter ;;
            2)
                echo -e "  Nuevo puerto: \c"; read -r port
                [[ "$port" =~ ^[0-9]+$ ]] && {
                    sed -i "s/^http_port.*/http_port $port/" /etc/squid/squid.conf 2>/dev/null
                    systemctl restart squid 2>/dev/null; success "Squid en puerto $port"
                } || error "Puerto inválido."
                _press_enter
                ;;
            0) return ;;
        esac
    done
}

handle_squid
