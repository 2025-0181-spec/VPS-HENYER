#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo Dropbear
# ============================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

handle_dropbear() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── Dropbear SSH ─────────────────────────────────────${NC}\n"

        if ! _cmd_exists "dropbear"; then
            echo -e "  Dropbear no instalado.  ${W}[1]${NC} Instalar  ${DIM}[0]${NC} Volver"
            echo -e "  Selección: \c"; read -r o
            [[ "$o" == "1" ]] && _apt_install "dropbear" || return
            _press_enter; continue
        fi

        local db_port; db_port=$(grep "^DROPBEAR_PORT" /etc/default/dropbear 2>/dev/null | cut -d= -f2 || echo "2222")
        _service_active "dropbear" && local st="${G}● ACTIVO${NC}" || local st="${R}● INACTIVO${NC}"
        echo -e "  Estado: $st  Puerto: ${W}${db_port}${NC}\n"
        echo -e "  ${W}[1]${NC} Activar / Desactivar  ${W}[2]${NC} Cambiar puerto  ${DIM}[0]${NC} Volver"
        echo -e "  Selección: \c"; read -r o

        case "$o" in
            1) _toggle_service "dropbear" "Dropbear"; _press_enter ;;
            2)
                echo -e "  Nuevo puerto: \c"; read -r port
                [[ "$port" =~ ^[0-9]+$ ]] && {
                    sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$port/" /etc/default/dropbear 2>/dev/null || true
                    systemctl restart dropbear 2>/dev/null; success "Dropbear en puerto $port"
                } || error "Puerto inválido."
                _press_enter
                ;;
            0) return ;;
        esac
    done
}

handle_dropbear
