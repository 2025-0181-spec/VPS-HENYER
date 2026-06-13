#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo Trojan-GO
# ============================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

handle_trojan() {
    while true; do
        clear
        local t_status t_port
        if _service_active "trojan-go"; then
            t_status="${G}● ACTIVO${NC}"
        elif _service_active "trojan"; then
            t_status="${G}● ACTIVO (trojan)${NC}"
        else
            t_status="${R}● INACTIVO${NC}"
        fi
        t_port=$(ss -tlnp 2>/dev/null | grep -E "trojan" | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
        [[ -z "$t_port" ]] && t_port="N/A"

        local LN="══════════════════════════════════════════════════════"
        echo -e ""
        echo -e "  ${C}${BOLD}╔${LN}╗${NC}"
        echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}Trojan-GO — Panel de Control${NC}           ${C}${BOLD}║${NC}"
        echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
        echo -e "  ${C}${BOLD}║${NC}  Estado  : $t_status"
        echo -e "  ${C}${BOLD}║${NC}  Puerto  : ${W}${t_port}${NC}"
        echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[1]${NC}  Instalar Trojan-GO"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[2]${NC}  Activar / Desactivar"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[3]${NC}  Reiniciar"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[4]${NC}  Ver configuración"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[5]${NC}  Ver log"
        echo -e "  ${C}${BOLD}║${NC}  ${DIM}[0]  Volver${NC}"
        echo -e "  ${C}${BOLD}╚${LN}╝${NC}"
        echo ""
        echo -e "  Opción : \c"; read -r opt

        case "$opt" in
        1)
            info "Instalando Trojan-GO..."
            bash <(curl -fsSL https://raw.githubusercontent.com/p4gefau1t/trojan-go/master/install.sh) 2>/dev/null \
                && success "Trojan-GO instalado." \
                || error "No se pudo instalar. Verifica conexión."
            _press_enter
            ;;
        2)
            local svc="trojan-go"
            _service_active "trojan" && svc="trojan"
            if _service_active "$svc"; then
                systemctl stop "$svc" && systemctl disable "$svc" 2>/dev/null
                success "Trojan → DETENIDO"
            else
                systemctl enable "$svc" && systemctl start "$svc" 2>/dev/null
                sleep 1
                _service_active "$svc" && success "Trojan → ACTIVO" || error "No pudo iniciar."
            fi
            _press_enter
            ;;
        3)
            local svc="trojan-go"; _service_active "trojan" && svc="trojan"
            systemctl restart "$svc" 2>/dev/null
            sleep 1
            _service_active "$svc" && success "Reiniciado." || error "No pudo reiniciar."
            _press_enter
            ;;
        4)
            echo ""
            local cfg="/usr/local/etc/trojan-go/config.json"
            [[ -f "$cfg" ]] || cfg="/etc/trojan-go/config.json"
            [[ -f "$cfg" ]] || cfg="/etc/trojan/config.json"
            if [[ -f "$cfg" ]]; then
                cat "$cfg" | while read -r line; do echo -e "  ${DIM}$line${NC}"; done
            else
                warn "No se encontró archivo de configuración."
            fi
            _press_enter
            ;;
        5)
            local svc="trojan-go"; _service_active "trojan" && svc="trojan"
            echo -e "\n  ${DIM}Log (Ctrl+C para salir)...${NC}\n"
            journalctl -u "$svc" -f --no-pager 2>/dev/null || warn "journalctl no disponible."
            ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

handle_trojan
