#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo ShadowsocksR
# ============================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

handle_ssr() {
    while true; do
        clear
        local ssr_status ssr_port
        if _service_active "shadowsocksr" || _service_active "ssrmu"; then
            ssr_status="${G}● ACTIVO${NC}"
        else
            ssr_status="${R}● INACTIVO${NC}"
        fi
        ssr_port=$(ss -tlnp 2>/dev/null | grep -E "python|ssserver" | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
        [[ -z "$ssr_port" ]] && ssr_port="N/A"

        local LN="══════════════════════════════════════════════════════"
        echo -e ""
        echo -e "  ${C}${BOLD}╔${LN}╗${NC}"
        echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}ShadowsocksR — Panel de Control${NC}        ${C}${BOLD}║${NC}"
        echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
        echo -e "  ${C}${BOLD}║${NC}  Estado  : $ssr_status"
        echo -e "  ${C}${BOLD}║${NC}  Puerto  : ${W}${ssr_port}${NC}"
        echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[1]${NC}  Instalar ShadowsocksR"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[2]${NC}  Activar / Desactivar"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[3]${NC}  Reiniciar"
        echo -e "  ${C}${BOLD}║${NC}  ${W}[4]${NC}  Ver configuración"
        echo -e "  ${C}${BOLD}║${NC}  ${DIM}[0]  Volver${NC}"
        echo -e "  ${C}${BOLD}╚${LN}╝${NC}"
        echo ""
        echo -e "  Opción : \c"; read -r opt

        case "$opt" in
        1)
            info "Instalando ShadowsocksR (ssrmu)..."
            wget -q -O /tmp/ssr_install.sh \
                https://raw.githubusercontent.com/ToyoDAdoubleR/ShadowsocksR-v3.2.2/master/install.sh 2>/dev/null \
                && bash /tmp/ssr_install.sh \
                && success "ShadowsocksR instalado." \
                || error "No se pudo instalar."
            _press_enter
            ;;
        2)
            local svc="shadowsocksr"
            _service_active "ssrmu" && svc="ssrmu"
            if _service_active "$svc"; then
                systemctl stop "$svc" 2>/dev/null && success "SSR → DETENIDO"
            else
                systemctl start "$svc" 2>/dev/null
                sleep 1
                _service_active "$svc" && success "SSR → ACTIVO" || error "No pudo iniciar."
            fi
            _press_enter
            ;;
        3)
            local svc="shadowsocksr"; _service_active "ssrmu" && svc="ssrmu"
            systemctl restart "$svc" 2>/dev/null
            sleep 1
            _service_active "$svc" && success "Reiniciado." || error "No pudo reiniciar."
            _press_enter
            ;;
        4)
            echo ""
            local cfg="/etc/shadowsocksr/config.json"
            [[ -f "$cfg" ]] || cfg="/etc/shadowsocks-r/config.json"
            if [[ -f "$cfg" ]]; then
                cat "$cfg" | while read -r line; do echo -e "  ${DIM}$line${NC}"; done
            else
                warn "No se encontró archivo de configuración."
            fi
            _press_enter
            ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

handle_ssr
