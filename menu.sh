#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Menú Principal v2.0
#  Autor: Henyer | Mejoras: Panel Xray + Detección dinámica
# ============================================================

set -uo pipefail

# ── Rutas base ───────────────────────────────────────────────
readonly INSTALL_DIR="/etc/vps-henyer"
readonly SCRIPTS_DIR="$INSTALL_DIR/scripts"
readonly LOG_FILE="/var/log/vps-henyer/menu.log"
readonly REPO_RAW="https://raw.githubusercontent.com/2025-0181-spec/vps-henyer/main"

# ── Paleta de colores ANSI ───────────────────────────────────
R='\033[0;31m';  G='\033[0;32m';  Y='\033[1;33m'
C='\033[0;36m';  B='\033[0;34m';  M='\033[0;35m'
W='\033[1;37m';  DIM='\033[2m';   BOLD='\033[1m'; NC='\033[0m'

# ── Logging ──────────────────────────────────────────────────
_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }

# ── Funciones de UI ──────────────────────────────────────────
_header_line() { echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

_press_enter() {
    echo ""
    echo -e "  ${DIM}Presiona [Enter] para continuar...${NC}"
    read -r
}

_confirm() {
    local msg="${1:-¿Confirmar acción?}"
    echo -e "\n  ${Y}⚠  $msg${NC} [s/N]: \c"
    read -r ans
    [[ "${ans,,}" == "s" ]]
}

# ── Verificadores ────────────────────────────────────────────
_cmd_exists()     { command -v "$1" &>/dev/null; }
_service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
_service_exists() { systemctl list-unit-files "$1" &>/dev/null && systemctl list-unit-files "$1" | grep -q "$1"; }

# Puerto abierto: chequea tcp Y udp
_port_open() {
    ss -tlnp 2>/dev/null | grep -q ":${1}[[:space:]]" ||
    ss -ulnp 2>/dev/null | grep -q ":${1}[[:space:]]"
}

# ── Indicadores de estado ────────────────────────────────────
_status_svc() {
    if _service_active "$1" 2>/dev/null; then
        echo -e "${G}● ON${NC} "
    else
        echo -e "${R}● OFF${NC}"
    fi
}

_status_port() {
    # _status_port <puerto>  — verde si el puerto escucha
    if _port_open "$1" 2>/dev/null; then
        echo -e "${G}● :${1}${NC}"
    else
        echo -e "${R}● —${NC}   "
    fi
}

# ── Información del sistema ──────────────────────────────────
_get_public_ip() {
    curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null \
      || curl -s --max-time 4 https://api.ipify.org 2>/dev/null \
      || echo "N/A"
}

_get_cpu_load() { awk '{printf "%.2f", $1}' /proc/loadavg 2>/dev/null || echo "N/A"; }

_get_ram_usage() {
    if [[ -f /proc/meminfo ]]; then
        local total avail used pct
        total=$(awk '/MemTotal/{print $2}'     /proc/meminfo)
        avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
        used=$(( total - avail ))
        pct=$(( used * 100 / total ))
        printf "%s / %s (%d%%)" \
            "$(numfmt --to=iec --suffix=B $((used*1024))  2>/dev/null || echo "${used}kB")" \
            "$(numfmt --to=iec --suffix=B $((total*1024)) 2>/dev/null || echo "${total}kB")" \
            "$pct"
    else
        echo "N/A"
    fi
}

_get_cpu_model() {
    grep -m1 "model name" /proc/cpuinfo 2>/dev/null \
        | awk -F': ' '{print $2}' | sed 's/  */ /g' | cut -c1-36 \
        || echo "CPU desconocido"
}

_get_uptime()     { uptime -p 2>/dev/null || echo "N/A"; }

_get_disk_usage() {
    df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}' || echo "N/A"
}

# ── Lee puerto de Xray desde config.json ────────────────────
_xray_port() {
    local proto="$1"
    local cfg="/usr/local/etc/xray/config.json"
    [[ -f "$cfg" ]] || { echo 0; return; }
    python3 -c "
import json,sys
try:
    c=json.load(open('$cfg'))
    for ib in c.get('inbounds',[]):
        if ib.get('protocol','').lower()=='${proto}':
            print(ib.get('port',0)); sys.exit(0)
    print(0)
except: print(0)
" 2>/dev/null || echo 0
}

# ── Control de versión ───────────────────────────────────────
_get_local_version() { cat "$INSTALL_DIR/version.txt" 2>/dev/null || echo "0.0.0"; }

_check_update() {
    local local_ver remote_ver
    local_ver=$(_get_local_version)
    remote_ver=$(curl -fsSL --max-time 5 "$REPO_RAW/version.txt" 2>/dev/null || echo "$local_ver")
    if [[ "$remote_ver" != "$local_ver" ]]; then
        echo -e "  ${Y}${BOLD}⟳  Nueva versión disponible: v$remote_ver${NC} ${DIM}(actual: v$local_ver)${NC}"
    else
        echo -e "  ${DIM}  Versión: v$local_ver — actualizado ✓${NC}"
    fi
}

# ── Ejecutar sub-script de forma segura ─────────────────────
_run_module() {
    local script_path="$1"; shift
    local args=("$@")
    if [[ ! -f "$script_path" ]]; then
        echo -e "\n  ${R}✖  Módulo no encontrado: $script_path${NC}"
        echo -e "  ${DIM}Intenta actualizar con la opción [U].${NC}"
        _press_enter; return 1
    fi
    [[ ! -x "$script_path" ]] && chmod +x "$script_path"
    _log "Ejecutando módulo: $script_path ${args[*]:-}"
    bash "$script_path" "${args[@]:-}" || {
        echo -e "\n  ${R}✖  El módulo terminó con error (código $?).${NC}"
        _log "ERROR en módulo: $script_path"
        _press_enter; return 1
    }
}

# ── Actualización desde GitHub ───────────────────────────────
_do_update() {
    clear
    echo -e "\n  ${C}${BOLD}Actualizando VPS-HENYER desde GitHub...${NC}\n"
    _log "Inicio de actualización"
    local scripts=("menu.sh" "scripts/protocols.sh" "scripts/tools.sh" "scripts/security.sh" "scripts/xray_panel.sh")
    local failed=0
    for script in "${scripts[@]}"; do
        local dest="$INSTALL_DIR/$script"
        mkdir -p "$(dirname "$dest")"
        echo -e "  ${DIM}Descargando $script...${NC} \c"
        if curl -fsSL --retry 3 -o "$dest" "$REPO_RAW/$script" 2>/dev/null; then
            chmod +x "$dest"; echo -e "${G}✓${NC}"
        else
            echo -e "${R}✗${NC}"; (( failed++ )) || true
        fi
    done
    local new_ver; new_ver=$(curl -fsSL "$REPO_RAW/version.txt" 2>/dev/null || echo "?")
    echo "$new_ver" > "$INSTALL_DIR/version.txt"
    echo ""
    if [[ $failed -eq 0 ]]; then
        echo -e "  ${G}${BOLD}✔  Actualización completada — v$new_ver${NC}"
        _log "Actualización exitosa a v$new_ver"
    else
        echo -e "  ${Y}⚠  Actualización parcial ($failed errores).${NC}"
    fi
    _press_enter
}

_do_remove() {
    clear
    echo -e "\n  ${R}${BOLD}DESINSTALAR VPS-HENYER${NC}\n"
    _confirm "Esto eliminará todos los archivos de VPS-HENYER. ¿Continuar?" || return 0
    rm -rf "$INSTALL_DIR" /var/log/vps-henyer "$BIN_PATH" 2>/dev/null || true
    echo -e "\n  ${G}✔  VPS-HENYER eliminado correctamente.${NC}\n"
    exit 0
}
readonly BIN_PATH="/usr/local/bin/vps"

# ╔══════════════════════════════════════════════════════════╗
#  BLOQUE DE SERVICIOS ACTIVOS  (detección en tiempo real)
#  Se inserta dentro de _draw_header
# ╚══════════════════════════════════════════════════════════╝
_draw_services_row() {
    # Imprime una fila de 2 columnas: "NOMBRE :PUERTO  ● estado"
    local left_name="$1" left_port="$2"
    local right_name="$3" right_port="$4"

    local ldot rdot
    { [[ "$left_port"  -gt 0 ]] 2>/dev/null && _port_open "$left_port";  } \
        && ldot="${G}●${NC}" || ldot="${R}●${NC}"
    { [[ "$right_port" -gt 0 ]] 2>/dev/null && _port_open "$right_port"; } \
        && rdot="${G}●${NC}" || rdot="${R}●${NC}"

    printf "  ${C}${BOLD}║${NC}  %b ${W}%-12s${NC}${DIM}:%-5s${NC}   %b ${W}%-12s${NC}${DIM}:%-5s${NC}${C}${BOLD}║${NC}\n" \
           "$ldot" "$left_name"  "$left_port" \
           "$rdot" "$right_name" "$right_port"
}

# ╔══════════════════════════════════════════════════════════╗
#  HEADER PRINCIPAL  (con bloque de servicios dinámico)
# ╚══════════════════════════════════════════════════════════╝
_draw_header() {
    local ip cpu_load ram cpu_model uptime_str disk
    ip=$(_get_public_ip)
    cpu_load=$(_get_cpu_load)
    ram=$(_get_ram_usage)
    cpu_model=$(_get_cpu_model)
    uptime_str=$(_get_uptime)
    disk=$(_get_disk_usage)

    # Puertos Xray desde config.json
    local p_vl p_vm p_tr
    p_vl=$(_xray_port vless  2>/dev/null || echo 0)
    p_vm=$(_xray_port vmess  2>/dev/null || echo 0)
    p_tr=$(_xray_port trojan 2>/dev/null || echo 0)

    # Puerto SSH
    local p_ssh; p_ssh=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo 22)
    # Puerto Squid
    local p_squid; p_squid=$(grep -E "^http_port" /etc/squid/squid.conf 2>/dev/null | awk '{print $2}' | head -1 || echo 3128)

    clear
    echo ""
    echo -e "  ${C}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}${W}${BOLD}         🛡  VPS-HENYER  —  Panel de Control          ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
    printf  "  ${C}${BOLD}║${NC}  ${DIM}IP Pública  :${NC} ${W}%-38s${NC}${C}${BOLD}║${NC}\n" "$ip"
    printf  "  ${C}${BOLD}║${NC}  ${DIM}CPU         :${NC} ${W}%-38s${NC}${C}${BOLD}║${NC}\n" "$cpu_model"
    printf  "  ${C}${BOLD}║${NC}  ${DIM}Carga CPU   :${NC} ${Y}%-38s${NC}${C}${BOLD}║${NC}\n" "$cpu_load"
    printf  "  ${C}${BOLD}║${NC}  ${DIM}RAM         :${NC} ${G}%-38s${NC}${C}${BOLD}║${NC}\n" "$ram"
    printf  "  ${C}${BOLD}║${NC}  ${DIM}Disco (/)   :${NC} ${G}%-38s${NC}${C}${BOLD}║${NC}\n" "$disk"
    printf  "  ${C}${BOLD}║${NC}  ${DIM}Uptime      :${NC} ${W}%-38s${NC}${C}${BOLD}║${NC}\n" "$uptime_str"
    printf  "  ${C}${BOLD}║${NC}  ${DIM}Fecha/Hora  :${NC} ${W}%-38s${NC}${C}${BOLD}║${NC}\n" "$(date '+%d-%m-%Y  %H:%M:%S')"
    echo -e "  ${C}${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${Y}${BOLD}Servicios Activos                                 ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${DIM}──────────────────────────────────────────────────${NC}${C}${BOLD}║${NC}"
    # Fila 1: SSH  y  Xray VLESS
    _draw_services_row "SSH"        "$p_ssh" "VLESS"     "$p_vl"
    # Fila 2: Dropbear y Xray VMess
    _draw_services_row "Dropbear"   "2222"   "VMess"     "$p_vm"
    # Fila 3: Squid y Trojan
    _draw_services_row "Squid"      "$p_squid" "Trojan"  "$p_tr"
    # Fila 4: HTTP-Proxy y BadVPN
    _draw_services_row "HTTP-Proxy" "8880"   "BadVPN"    "7300"
    echo -e "  ${C}${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  $(_check_update)                     ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ╔══════════════════════════════════════════════════════════╗
#  MENÚ DE PROTOCOLOS
# ╚══════════════════════════════════════════════════════════╝
menu_protocols() {
    while true; do
        _draw_header

        # Estados dinámicos
        local s_ssh s_dropbear s_ovpn s_squid s_xray s_trojan s_ssr
        local s_slowdns s_sslh s_socks5 s_badvpn
        s_ssh=$(_status_svc "ssh")
        s_dropbear=$(_status_svc "dropbear")
        s_ovpn=$(_status_svc "openvpn")
        s_squid=$(_status_svc "squid")
        s_xray=$(_status_svc "xray")
        s_trojan=$(_status_svc "trojan-go")
        s_ssr=$(_status_svc "shadowsocksr")
        s_slowdns=$(_status_port "5300")
        s_sslh=$(_status_port "8443")
        s_socks5=$(_status_port "1080")
        s_badvpn=$(_status_port "7300")

        echo -e "  ${M}${BOLD}┌─ MÓDULO: PROTOCOLOS ─────────────────────────────────┐${NC}"
        echo -e "  ${M}│${NC}"
        printf  "  ${M}│${NC}  ${W}[1]${NC}  OpenSSH / SSH          %b\n" "$s_ssh"
        printf  "  ${M}│${NC}  ${W}[2]${NC}  Dropbear               %b\n" "$s_dropbear"
        printf  "  ${M}│${NC}  ${W}[3]${NC}  OpenVPN                %b\n" "$s_ovpn"
        printf  "  ${M}│${NC}  ${W}[4]${NC}  Squid Proxy            %b\n" "$s_squid"
        printf  "  ${M}│${NC}  ${W}[5]${NC}  ${C}${BOLD}V2Ray / Xray  🔷${NC}          %b\n" "$s_xray"
        printf  "  ${M}│${NC}  ${W}[6]${NC}  Trojan-GO              %b\n" "$s_trojan"
        printf  "  ${M}│${NC}  ${W}[7]${NC}  ShadowsocksR           %b\n" "$s_ssr"
        echo -e "  ${M}│${NC}  ${W}[8]${NC}  WebSocket + SSL/TLS"
        echo -e "  ${M}│${NC}  ${W}[9]${NC}  Psiphon"
        echo -e "  ${M}│${NC}  ${W}[A]${NC}  HTTP Custom / Injector"
        echo -e "  ${M}│${NC}"
        echo -e "  ${M}│${NC}  ${Y}${BOLD}— Protocolos Adicionales ─────────────────────────${NC}"
        printf  "  ${M}│${NC}  ${W}[B]${NC}  SlowDNS (UDP :5300)    %b\n" "$s_slowdns"
        printf  "  ${M}│${NC}  ${W}[C]${NC}  SSLH Multiplex         %b\n" "$s_sslh"
        printf  "  ${M}│${NC}  ${W}[D]${NC}  SOCKS5 Proxy           %b\n" "$s_socks5"
        printf  "  ${M}│${NC}  ${W}[E]${NC}  BadVPN UDP Ports       %b\n" "$s_badvpn"
        echo -e "  ${M}│${NC}  ${W}[F]${NC}  Generar config Clash"
        echo -e "  ${M}│${NC}"
        echo -e "  ${M}│${NC}  ${DIM}[0] Volver al menú principal${NC}"
        echo -e "  ${M}└──────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  Selección: \c"; read -r opt

        case "${opt,,}" in
            1) _run_module "$SCRIPTS_DIR/protocols.sh" "ssh"        ;;
            2) _run_module "$SCRIPTS_DIR/protocols.sh" "dropbear"   ;;
            3) _run_module "$SCRIPTS_DIR/protocols.sh" "openvpn"    ;;
            4) _run_module "$SCRIPTS_DIR/protocols.sh" "squid"      ;;
            5) _run_module "$SCRIPTS_DIR/xray_panel.sh"             ;;
            6) _run_module "$SCRIPTS_DIR/protocols.sh" "trojan"     ;;
            7) _run_module "$SCRIPTS_DIR/protocols.sh" "ssr"        ;;
            8) _run_module "$SCRIPTS_DIR/protocols.sh" "websocket"  ;;
            9) _run_module "$SCRIPTS_DIR/protocols.sh" "psiphon"    ;;
            a) _run_module "$SCRIPTS_DIR/protocols.sh" "http-custom";;
            b) _run_module "$SCRIPTS_DIR/protocols.sh" "slowdns"    ;;
            c) _run_module "$SCRIPTS_DIR/protocols.sh" "sslh"       ;;
            d) _run_module "$SCRIPTS_DIR/protocols.sh" "socks5"     ;;
            e) _run_module "$SCRIPTS_DIR/protocols.sh" "badvpn"     ;;
            f) _run_module "$SCRIPTS_DIR/protocols.sh" "clash"      ;;
            0) return ;;
            *) echo -e "  ${R}Opción inválida.${NC}"; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  MENÚ DE HERRAMIENTAS
# ╚══════════════════════════════════════════════════════════╝
menu_tools() {
    while true; do
        _draw_header

        local s_fail2ban s_ufw s_bbr s_badvpn
        s_fail2ban=$(_status_svc "fail2ban")
        s_ufw=$(_status_svc "ufw")
        s_badvpn=$(_status_port "7300")
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
            s_bbr="${G}● ON${NC} "
        else
            s_bbr="${R}● OFF${NC}"
        fi

        echo -e "  ${B}${BOLD}┌─ MÓDULO: HERRAMIENTAS ───────────────────────────────┐${NC}"
        echo -e "  ${B}│${NC}"
        echo -e "  ${B}│${NC}  ${Y}${BOLD}— Optimización ──────────────────────────────────${NC}"
        printf  "  ${B}│${NC}  ${W}[1]${NC}  TCP BBR / BBR Plus         %b\n" "$s_bbr"
        echo -e "  ${B}│${NC}  ${W}[2]${NC}  Optimización del kernel"
        echo -e "  ${B}│${NC}"
        echo -e "  ${B}│${NC}  ${Y}${BOLD}— Seguridad ─────────────────────────────────────${NC}"
        printf  "  ${B}│${NC}  ${W}[3]${NC}  Fail2ban                   %b\n" "$s_fail2ban"
        printf  "  ${B}│${NC}  ${W}[4]${NC}  Firewall (UFW/Iptables)    %b\n" "$s_ufw"
        echo -e "  ${B}│${NC}  ${W}[5]${NC}  Bloqueo de Torrents"
        echo -e "  ${B}│${NC}"
        echo -e "  ${B}│${NC}  ${Y}${BOLD}— Utilidades ────────────────────────────────────${NC}"
        echo -e "  ${B}│${NC}  ${W}[6]${NC}  Monitor de usuarios online"
        echo -e "  ${B}│${NC}  ${W}[7]${NC}  Speedtest de red"
        echo -e "  ${B}│${NC}  ${W}[8]${NC}  DNS Personalizado"
        echo -e "  ${B}│${NC}  ${W}[9]${NC}  Reiniciar todos los servicios"
        echo -e "  ${B}│${NC}  ${W}[c]${NC}  Cambiar contraseña root"
        echo -e "  ${B}│${NC}"
        echo -e "  ${B}│${NC}  ${Y}${BOLD}— Extras ────────────────────────────────────────${NC}"
        printf  "  ${B}│${NC}  ${W}[G]${NC}  BadVPN ON/OFF              %b\n" "$s_badvpn"
        echo -e "  ${B}│${NC}  ${W}[H]${NC}  Block ADS (/etc/hosts)"
        echo -e "  ${B}│${NC}  ${W}[I]${NC}  Brook Server"
        echo -e "  ${B}│${NC}  ${W}[J]${NC}  Archivo Online (HTTP server)"
        echo -e "  ${B}│${NC}"
        echo -e "  ${B}│${NC}  ${DIM}[0] Volver al menú principal${NC}"
        echo -e "  ${B}└──────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  Selección: \c"; read -r opt

        case "${opt,,}" in
            1) _run_module "$SCRIPTS_DIR/tools.sh"    "bbr"          ;;
            2) _run_module "$SCRIPTS_DIR/tools.sh"    "kernel-opt"   ;;
            3) _run_module "$SCRIPTS_DIR/security.sh" "fail2ban"     ;;
            4) _run_module "$SCRIPTS_DIR/security.sh" "firewall"     ;;
            5) _run_module "$SCRIPTS_DIR/security.sh" "torrent"      ;;
            6) _run_module "$SCRIPTS_DIR/tools.sh"    "monitor"      ;;
            7) _run_module "$SCRIPTS_DIR/tools.sh"    "speedtest"    ;;
            8) _run_module "$SCRIPTS_DIR/tools.sh"    "dns"          ;;
            9) _run_module "$SCRIPTS_DIR/tools.sh"    "restart-all"  ;;
            c) _run_module "$SCRIPTS_DIR/tools.sh"    "passwd"       ;;
            g) _run_module "$SCRIPTS_DIR/tools.sh"    "badvpn-toggle";;
            h) _run_module "$SCRIPTS_DIR/tools.sh"    "block-ads"    ;;
            i) _run_module "$SCRIPTS_DIR/tools.sh"    "brook"        ;;
            j) _run_module "$SCRIPTS_DIR/tools.sh"    "archivo-online";;
            0) return ;;
            *) echo -e "  ${R}Opción inválida.${NC}"; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  MENÚ DE USUARIOS SSH (mejorado — acceso directo)
# ╚══════════════════════════════════════════════════════════╝
menu_users() {
    _run_module "$SCRIPTS_DIR/protocols.sh" "ssh-users"
}

# ╔══════════════════════════════════════════════════════════╗
#  MENÚ PRINCIPAL
# ╚══════════════════════════════════════════════════════════╝
menu_main() {
    while true; do
        _draw_header

        # Contador de usuarios SSH conectados
        local online_count; online_count=$(who 2>/dev/null | wc -l || echo 0)

        echo -e "  ${W}${BOLD}┌─ MENÚ PRINCIPAL ─────────────────────────────────────┐${NC}"
        echo -e "  ${W}│${NC}"
        echo -e "  ${W}│${NC}  ${C}${BOLD}[1]${NC}  🔌  Gestión de Protocolos"
        echo -e "  ${W}│${NC}  ${C}${BOLD}[2]${NC}  🔧  Herramientas & Seguridad"
        printf  "  ${W}│${NC}  ${C}${BOLD}[3]${NC}  👥  Gestión de Usuarios SSH       ${G}${online_count} online${NC}\n"
        echo -e "  ${W}│${NC}  ${C}${BOLD}[4]${NC}  🔷  Panel V2Ray/Xray (acceso rápido)"
        echo -e "  ${W}│${NC}"
        _header_line
        echo -e "  ${W}│${NC}  ${Y}${BOLD}[U]${NC}  ⟳   Actualizar VPS-HENYER"
        echo -e "  ${W}│${NC}  ${R}${BOLD}[X]${NC}  ✕   Desinstalar VPS-HENYER"
        echo -e "  ${W}│${NC}  ${DIM}[0]  Salir${NC}"
        echo -e "  ${W}└──────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  Selección: \c"; read -r opt

        case "${opt,,}" in
            1) menu_protocols ;;
            2) menu_tools     ;;
            3) menu_users     ;;
            4) _run_module "$SCRIPTS_DIR/xray_panel.sh" ;;
            u) _do_update     ;;
            x) _do_remove     ;;
            0|q) echo -e "\n  ${DIM}Hasta luego.${NC}\n"; exit 0 ;;
            *) echo -e "  ${R}Opción inválida.${NC}"; sleep 1 ;;
        esac
    done
}

# ── Verificar root ───────────────────────────────────────────
[[ $EUID -eq 0 ]] || {
    echo -e "\n  ${R}✖  Este menú requiere permisos de root.${NC}"
    echo -e "  Usa: ${Y}sudo vps${NC}\n"
    exit 1
}

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

menu_main
