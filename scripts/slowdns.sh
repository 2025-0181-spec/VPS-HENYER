#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo SlowDNS
#  Basado en VPS-MX, reescrito al estilo VPS-HENYER
#  Llamado desde menu.sh: bash slowdns.sh
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

SLOW_DIR="/etc/vps-henyer/slowdns"
SLOW_KEY_DIR="$SLOW_DIR/keys"
SLOW_BIN="$SLOW_DIR/dns-server"
SLOW_NS_FILE="$SLOW_KEY_DIR/domain_ns"
SLOW_PUB_FILE="$SLOW_KEY_DIR/server.pub"
SLOW_KEY_FILE="$SLOW_KEY_DIR/server.key"
SLOW_PORT_FILE="$SLOW_KEY_DIR/puerto"

_slow_is_running() {
    screen -ls 2>/dev/null | grep -q "slowdns"
}

_slow_status() {
    _slow_is_running && echo "${G}● ACTIVO${NC}" || echo "${R}● INACTIVO${NC}"
}

_slow_get_ns()   { [[ -f "$SLOW_NS_FILE"  ]] && cat "$SLOW_NS_FILE"  || echo "N/A"; }
_slow_get_key()  { [[ -f "$SLOW_PUB_FILE" ]] && cat "$SLOW_PUB_FILE" || echo "N/A"; }
_slow_get_port() { [[ -f "$SLOW_PORT_FILE" ]] && cat "$SLOW_PORT_FILE" || echo "N/A"; }

_slow_init() {
    mkdir -p "$SLOW_DIR" "$SLOW_KEY_DIR"
}

_slow_get_ports() {
    # Devuelve lista de servicios:puerto escuchando
    lsof -V -i tcp -P -n 2>/dev/null \
        | grep -v "ESTABLISHED" | grep -v "COMMAND" | grep "LISTEN" \
        | awk '{print $1, $9}' \
        | awk -F'[ :]' '{print $(NF-0)" "$1}' \
        | awk '{print $NF, $1}' \
        | grep -E "sshd|dropbear|stunnel|python|python3" \
        | sort -u
}

_slow_download_bin() {
    if [[ -f "$SLOW_BIN" ]]; then
        info "Binario dns-server ya existe."; return 0
    fi
    info "Descargando binario dns-server..."
    if wget -q -O "$SLOW_BIN" \
        "https://raw.githubusercontent.com/NetVPS/VPS-MX_Oficial/master/LINKS-LIBRERIAS/dns-server" 2>/dev/null; then
        chmod +x "$SLOW_BIN"
        success "Binario descargado."
    else
        error "No se pudo descargar el binario. Verifica conexión."
        return 1
    fi
}

_slow_instalar() {
    clear
    echo -e "\n  ${W}${BOLD}── Instalar / Configurar SlowDNS ─────────────────────${NC}\n"

    _slow_init

    # Mostrar puertos disponibles
    echo -e "  ${Y}${BOLD}Servicios escuchando disponibles:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    local i=1
    declare -A port_map
    while IFS=' ' read -r port svc; do
        [[ -z "$port" ]] && continue
        echo -e "  ${W}[$i]${NC} ${G}${svc}${NC} : puerto ${W}${port}${NC}"
        port_map[$i]="$port"
        ((i++))
    done < <(_slow_get_ports)

    if [[ ${#port_map[@]} -eq 0 ]]; then
        warn "No hay servicios SSH/Dropbear/Stunnel escuchando."
        warn "Instala SSH o Dropbear primero."
        _press_enter; return
    fi

    echo ""
    echo -e "  Elige el número del puerto local a tunelar: \c"; read -r sel
    local local_port="${port_map[$sel]:-}"
    if [[ -z "$local_port" ]]; then
        error "Selección inválida."; _press_enter; return
    fi
    echo "$local_port" > "$SLOW_PORT_FILE"
    info "Puerto seleccionado: ${W}${local_port}${NC}"

    # Dominio NS
    echo ""
    echo -e "  Tu dominio NS (ej: ns1.tudominio.com): \c"; read -r ns
    [[ -z "$ns" ]] && { error "NS vacío."; _press_enter; return; }
    echo "$ns" > "$SLOW_NS_FILE"

    # Descargar binario
    _slow_download_bin || { _press_enter; return; }

    # Generar o reutilizar claves
    if [[ -f "$SLOW_PUB_FILE" ]]; then
        echo -e "\n  ${Y}Clave existente:${NC} $(cat "$SLOW_PUB_FILE")"
        echo -e "  ¿Usar clave existente? [S/n]: \c"; read -r reuse
        if [[ "${reuse,,}" == "n" ]]; then
            rm -f "$SLOW_KEY_FILE" "$SLOW_PUB_FILE"
            "$SLOW_BIN" -gen-key -privkey-file "$SLOW_KEY_FILE" -pubkey-file "$SLOW_PUB_FILE" 2>/dev/null
        fi
    else
        info "Generando par de claves..."
        "$SLOW_BIN" -gen-key -privkey-file "$SLOW_KEY_FILE" -pubkey-file "$SLOW_PUB_FILE" 2>/dev/null
    fi

    # Abrir puerto UDP 53 y 5300
    iptables -I INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || true
    iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null || true

    # Iniciar SlowDNS
    screen -ls | grep slowdns | cut -d. -f1 | awk '{print $1}' | xargs kill 2>/dev/null || true
    if screen -dmS slowdns "$SLOW_BIN" -udp :5300 \
        -privkey-file "$SLOW_KEY_FILE" "$ns" "127.0.0.1:${local_port}" 2>/dev/null; then
        success "SlowDNS iniciado."
    else
        error "SlowDNS no pudo iniciar."
    fi

    echo ""
    echo -e "  ${Y}${BOLD}── Datos de conexión SlowDNS:${NC}"
    echo -e "  ${W}NS     :${NC} ${G}${ns}${NC}"
    echo -e "  ${W}Clave  :${NC} ${G}$(cat "$SLOW_PUB_FILE" 2>/dev/null || echo 'N/A')${NC}"
    echo -e "  ${W}Puerto :${NC} ${W}${local_port}${NC}"
    _press_enter
}

_slow_reiniciar() {
    _slow_init
    local ns; ns=$(_slow_get_ns)
    local port; port=$(_slow_get_port)

    if [[ "$ns" == "N/A" || "$port" == "N/A" ]]; then
        error "SlowDNS no está configurado. Usa [1] para instalar."; _press_enter; return
    fi

    screen -ls | grep slowdns | cut -d. -f1 | awk '{print $1}' | xargs kill 2>/dev/null || true
    sleep 1
    if screen -dmS slowdns "$SLOW_BIN" -udp :5300 \
        -privkey-file "$SLOW_KEY_FILE" "$ns" "127.0.0.1:${port}" 2>/dev/null; then
        success "SlowDNS reiniciado."
    else
        error "No pudo reiniciar. Verifica configuración."
    fi
    _press_enter
}

_slow_detener() {
    screen -ls 2>/dev/null | grep slowdns | cut -d. -f1 | awk '{print $1}' | xargs kill 2>/dev/null \
        && success "SlowDNS detenido." \
        || warn "SlowDNS no estaba activo."
    _press_enter
}

_slow_info() {
    clear
    echo -e "\n  ${W}${BOLD}── Datos de Conexión SlowDNS ─────────────────────────${NC}\n"
    local ns; ns=$(_slow_get_ns)
    local key; key=$(_slow_get_key)
    local port; port=$(_slow_get_port)

    if [[ "$ns" == "N/A" ]]; then
        warn "SlowDNS no está configurado. Usa [1] para instalar."
        _press_enter; return
    fi

    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    echo -e "  ${Y}NS (Nameserver):${NC} ${G}${ns}${NC}"
    echo -e "  ${Y}Llave Pública  :${NC} ${G}${key}${NC}"
    echo -e "  ${Y}Puerto local   :${NC} ${W}${port}${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    echo ""
    info "Agrega el NS y la Llave en tu app (HTTP Injector, KPN Tunnel, etc.)"
    _press_enter
}

# ── Panel principal ──────────────────────────────────────────
LN="══════════════════════════════════════════════════════"

while true; do
    clear
    _slow_init

    local_status=$(_slow_status)
    local_ns=$(_slow_get_ns)
    local_key=$(_slow_get_key)
    local_port=$(_slow_get_port)

    echo -e ""
    echo -e "  ${C}${BOLD}╔${LN}╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}SlowDNS — Panel de Control${NC}              ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  Estado  : $local_status"
    echo -e "  ${C}${BOLD}║${NC}  NS      : ${W}${local_ns}${NC}"
    echo -e "  ${C}${BOLD}║${NC}  Llave   : ${DIM}${local_key:0:40}...${NC}"
    echo -e "  ${C}${BOLD}║${NC}  Puerto  : ${W}${local_port}${NC}"
    echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[1]${NC}  Instalar / Configurar SlowDNS"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[2]${NC}  Ver datos de conexión"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[3]${NC}  Reiniciar SlowDNS"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[4]${NC}  Detener SlowDNS"
    echo -e "  ${C}${BOLD}║${NC}  ${DIM}[0]  Volver al menú principal${NC}"
    echo -e "  ${C}${BOLD}╚${LN}╝${NC}"
    echo ""
    echo -e "  Opción : \c"; read -r opt

    case "$opt" in
        1) _slow_instalar  ;;
        2) _slow_info      ;;
        3) _slow_reiniciar ;;
        4) _slow_detener   ;;
        0) exit 0          ;;
        *) warn "Opción inválida."; sleep 1 ;;
    esac
done
