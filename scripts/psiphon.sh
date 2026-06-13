#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo Psiphon
# ============================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

handle_psiphon() {
    while true; do
        clear
        local p_status
        if pgrep -x "psiphond" &>/dev/null || _service_active "psiphon"; then
            p_status="${G}● ACTIVO${NC}"
        else
            p_status="${R}● INACTIVO${NC}"
        fi

        local LN="══════════════════════════════════════════════════════"
        echo -e ""
        echo -e "  ${C}${BOLD}╔${LN}╗${NC}"
        echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}Psiphon — Panel de Control${NC}             ${C}${BOLD}║${NC}"
        echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
        echo -e "  ${C}${BOLD}║${NC}  Estado  : $p_status"
        echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[1]${NC}  Instalar Psiphon Server"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[2]${NC}  Activar / Desactivar"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[3]${NC}  Reiniciar"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[4]${NC}  Ver log"
        echo -e "  ${C}${BOLD}║${NC}  ${DIM}[0]  Volver${NC}"
        echo -e "  ${C}${BOLD}╚${LN}╝${NC}"
        echo ""
        echo -e "  Opción : \c"; read -r opt

        case "$opt" in
        1)
            info "Descargando Psiphon Server..."
            local arch; arch=$(uname -m)
            local url="https://github.com/Psiphon-Labs/psiphon-tunnel-core/releases/latest/download/psiphond"
            [[ "$arch" == "aarch64" ]] && url="${url}-arm64"
            wget -q -O /usr/local/bin/psiphond "$url" 2>/dev/null \
                && chmod +x /usr/local/bin/psiphond \
                && success "Psiphon descargado en /usr/local/bin/psiphond" \
                || error "No se pudo descargar."
            _press_enter
            ;;
        2)
            if pgrep -x "psiphond" &>/dev/null; then
                pkill -x "psiphond" && success "Psiphon → DETENIDO"
            elif _service_active "psiphon"; then
                systemctl stop psiphon 2>/dev/null && success "Psiphon → DETENIDO"
            else
                if [[ -f /usr/local/bin/psiphond ]]; then
                    screen -dmS psiphon /usr/local/bin/psiphond 2>/dev/null \
                        && success "Psiphon → ACTIVO" \
                        || error "No pudo iniciar."
                else
                    error "Psiphon no está instalado. Usa [1] primero."
                fi
            fi
            _press_enter
            ;;
        3)
            pkill -x "psiphond" 2>/dev/null || true
            sleep 1
            screen -dmS psiphon /usr/local/bin/psiphond 2>/dev/null \
                && success "Psiphon reiniciado." \
                || error "No pudo reiniciar."
            _press_enter
            ;;
        4)
            echo -e "\n  ${DIM}Log Psiphon (Ctrl+C para salir)...${NC}\n"
            journalctl -u psiphon -f --no-pager 2>/dev/null \
                || tail -f /var/log/psiphon.log 2>/dev/null \
                || warn "No hay log disponible."
            ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

handle_psiphon
