#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo SSL/Stunnel
#  Instalar, configurar y gestionar Stunnel4
#  Llamado desde menu.sh: bash ssl.sh
# ============================================================

set -uo pipefail

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'
C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'
BOLD='\033[1m'

info()    { echo -e "  ${C}[INFO]${NC} $*"; }
success() { echo -e "  ${G}[OK]${NC}   $*"; }
warn()    { echo -e "  ${Y}[WARN]${NC}  $*"; }
error()   { echo -e "  ${R}[ERR]${NC}  $*"; }

_press_enter() { echo -e "\n  ${DIM}[Enter] para continuar...${NC}"; read -r; }
_cmd_exists()  { command -v "$1" &>/dev/null; }
_svc_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }

STUNNEL_CONF="/etc/stunnel/stunnel.conf"
STUNNEL_PEM="/etc/stunnel/stunnel.pem"

_ssl_status() {
    _svc_active "stunnel4" && echo "${G}● ACTIVO${NC}" || echo "${R}● INACTIVO${NC}"
}

_ssl_get_port() {
    [[ -f "$STUNNEL_CONF" ]] && grep "^accept" "$STUNNEL_CONF" | awk '{print $3}' || echo "N/A"
}

_ssl_get_local() {
    [[ -f "$STUNNEL_CONF" ]] && grep "^connect" "$STUNNEL_CONF" | awk -F: '{print $NF}' || echo "N/A"
}

_get_listening_ports() {
    lsof -V -i tcp -P -n 2>/dev/null \
        | grep -v ESTABLISHED | grep -v COMMAND | grep LISTEN \
        | awk '{print $1, $9}' \
        | awk -F'[ :]' '{print $1, $NF}' \
        | grep -E "sshd|dropbear|squid|openvpn" \
        | sort -u
}

_ssl_instalar() {
    clear
    echo -e "\n  ${W}${BOLD}── Instalar SSL/Stunnel ──────────────────────────────${NC}\n"

    # Si ya está activo, preguntar si desinstalar
    if _svc_active "stunnel4"; then
        warn "Stunnel4 ya está activo."
        echo -e "  ${W}[1]${NC} Desinstalar Stunnel  ${DIM}[0]${NC} Cancelar"
        echo -e "  Selección: \c"; read -r o
        [[ "$o" == "1" ]] && _ssl_desinstalar
        return
    fi

    # Mostrar puertos disponibles
    echo -e "  ${Y}${BOLD}Puertos locales disponibles:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    local i=1
    declare -A port_map
    while IFS=' ' read -r svc port; do
        [[ -z "$port" ]] && continue
        echo -e "  ${W}[$i]${NC} ${G}${svc}${NC} : ${W}${port}${NC}"
        port_map[$i]="$port"
        ((i++))
    done < <(_get_listening_ports)

    if [[ ${#port_map[@]} -eq 0 ]]; then
        warn "No hay servicios SSH/Dropbear escuchando."
        _press_enter; return
    fi

    echo ""
    echo -e "  Selecciona el puerto local a proteger con SSL: \c"; read -r sel
    local local_port="${port_map[$sel]:-}"
    [[ -z "$local_port" ]] && { error "Selección inválida."; _press_enter; return; }

    echo ""
    echo -e "  Puerto SSL externo (ej: 443, 8443, 8080): \c"; read -r ssl_port
    [[ "$ssl_port" =~ ^[0-9]+$ ]] || { error "Puerto inválido."; _press_enter; return; }

    # Instalar stunnel4
    info "Instalando stunnel4..."
    apt-get install -y -qq stunnel4 2>/dev/null || { error "No se pudo instalar stunnel4."; _press_enter; return; }

    # Generar certificado autofirmado
    info "Generando certificado SSL..."
    local domain; domain=$(hostname -f 2>/dev/null || hostname)
    openssl req -new -x509 -days 3650 -nodes \
        -subj "/C=DO/ST=VPS/L=Server/O=VPS-HENYER/CN=${domain}" \
        -keyout /tmp/stunnel.key \
        -out /tmp/stunnel.crt 2>/dev/null
    cat /tmp/stunnel.crt /tmp/stunnel.key > "$STUNNEL_PEM"
    rm -f /tmp/stunnel.key /tmp/stunnel.crt

    # Escribir config
    cat > "$STUNNEL_CONF" << CONF
client  = no
[SSL-VPS-HENYER]
cert    = ${STUNNEL_PEM}
accept  = ${ssl_port}
connect = 127.0.0.1:${local_port}
CONF

    # Habilitar stunnel4
    sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4 2>/dev/null || true

    systemctl enable stunnel4 2>/dev/null
    systemctl restart stunnel4 2>/dev/null
    sleep 1

    if _svc_active "stunnel4"; then
        success "Stunnel4 activo. Puerto SSL: ${W}${ssl_port}${NC} → Local: ${W}${local_port}${NC}"
    else
        error "Stunnel4 no pudo iniciar. Revisa: journalctl -u stunnel4"
    fi

    # Abrir puerto en UFW
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q active; then
        ufw allow "${ssl_port}/tcp" > /dev/null 2>&1
        info "UFW: puerto $ssl_port abierto."
    fi

    _press_enter
}

_ssl_desinstalar() {
    systemctl stop stunnel4 2>/dev/null || true
    systemctl disable stunnel4 2>/dev/null || true
    apt-get purge -y -qq stunnel4 2>/dev/null || true
    rm -rf /etc/stunnel/
    success "Stunnel4 desinstalado."
    _press_enter
}

_ssl_ver_config() {
    clear
    echo -e "\n  ${W}${BOLD}── Configuración Stunnel ─────────────────────────────${NC}\n"
    if [[ -f "$STUNNEL_CONF" ]]; then
        cat "$STUNNEL_CONF" | while read -r line; do
            echo -e "  ${DIM}$line${NC}"
        done
    else
        warn "No hay configuración instalada."
    fi
    _press_enter
}

# ── Panel principal ──────────────────────────────────────────
LN="══════════════════════════════════════════════════════"

while true; do
    clear

    ssl_status=$(_ssl_status)
    ssl_port=$(_ssl_get_port)
    ssl_local=$(_ssl_get_local)
    ssl_installed="NO"
    _cmd_exists "stunnel4" || dpkg -l stunnel4 2>/dev/null | grep -q "^ii" && ssl_installed="SÍ"
    echo -e ""
    echo -e "  ${C}${BOLD}╔${LN}╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}SSL/Stunnel — Panel de Control${NC}         ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  Estado      : $ssl_status"
    echo -e "  ${C}${BOLD}║${NC}  Puerto SSL  : ${W}${ssl_port}${NC}"
    echo -e "  ${C}${BOLD}║${NC}  Puerto local: ${W}${ssl_local}${NC}"
    echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[1]${NC}  Instalar / Reconfigurar SSL"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[2]${NC}  Ver configuración"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[3]${NC}  Reiniciar Stunnel"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[4]${NC}  Detener Stunnel"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[5]${NC}  Desinstalar Stunnel"
    echo -e "  ${C}${BOLD}║${NC}  ${DIM}[0]  Volver al menú principal${NC}"
    echo -e "  ${C}${BOLD}╚${LN}╝${NC}"
    echo ""
    echo -e "  Opción : \c"; read -r opt

    case "$opt" in
        1) _ssl_instalar   ;;
        2) _ssl_ver_config ;;
        3)
            systemctl restart stunnel4 2>/dev/null
            sleep 1
            _svc_active "stunnel4" && success "Stunnel reiniciado." || error "No pudo reiniciar."
            _press_enter
            ;;
        4)
            systemctl stop stunnel4 2>/dev/null && success "Stunnel detenido." || warn "No estaba activo."
            _press_enter
            ;;
        5) _ssl_desinstalar ;;
        0) exit 0 ;;
        *) warn "Opción inválida."; sleep 1 ;;
    esac
done
