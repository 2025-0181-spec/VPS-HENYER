#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Menú Principal
#  Autor: Henyer | GitHub: TU_USUARIO/vps-henyer
# ============================================================

set -uo pipefail

# ── Rutas base ───────────────────────────────────────────────
readonly INSTALL_DIR="/etc/vps-henyer"
readonly SCRIPTS_DIR="$INSTALL_DIR/scripts"
readonly LOG_FILE="/var/log/vps-henyer/menu.log"
readonly REPO_RAW="https://raw.githubusercontent.com/2025-0181-spec/vps-henyer/main"

# ── Paleta de colores ANSI ───────────────────────────────────
R='\033[0;31m'    # Rojo
G='\033[0;32m'    # Verde
Y='\033[1;33m'    # Amarillo
C='\033[0;36m'    # Cian
B='\033[0;34m'    # Azul
M='\033[0;35m'    # Magenta
W='\033[1;37m'    # Blanco brillante
DIM='\033[2m'     # Tenue
BOLD='\033[1m'
NC='\033[0m'      # Reset

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
    # Uso: _confirm "¿Deseas instalar X?" && do_something
    local msg="${1:-¿Confirmar acción?}"
    echo -e "\n  ${Y}⚠  $msg${NC} [s/N]: \c"
    read -r ans
    [[ "${ans,,}" == "s" ]]
}

# ── Verificar si un binario/servicio está disponible ─────────
_cmd_exists()     { command -v "$1" &>/dev/null; }
_service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
_service_exists() { systemctl list-unit-files "$1" &>/dev/null && systemctl list-unit-files "$1" | grep -q "$1"; }
_port_open()      { ss -tlnp 2>/dev/null | grep -q ":${1} " || lsof -i :"$1" &>/dev/null 2>&1; }

# ── Indicador de estado ON / OFF ─────────────────────────────
#  Uso: _status <comando_o_servicio> [puerto_opcional]
#  Devuelve la cadena con color lista para imprimir
_status() {
    local svc="${1:-}"
    local port="${2:-}"
    local active=false

    # Verificar por binario
    if _cmd_exists "$svc"; then
        active=true
    fi

    # Verificar por servicio systemd (tiene mayor peso)
    if _service_exists "$svc"; then
        if _service_active "$svc"; then
            active=true
        else
            active=false
        fi
    fi

    # Verificar por puerto si se provee
    if [[ -n "$port" ]]; then
        if _port_open "$port"; then
            active=true
        else
            active=false
        fi
    fi

    if $active; then
        echo -e "${G}●${NC} ${G}ON ${NC}"
    else
        echo -e "${R}●${NC} ${R}OFF${NC}"
    fi
}

# Versión simplificada para servicio puro
_status_svc() {
    local svc="$1"
    if _service_active "$svc" 2>/dev/null; then
        echo -e "${G}●${NC} ${G}ON ${NC}"
    else
        echo -e "${R}●${NC} ${R}OFF${NC}"
    fi
}

# ── Información del sistema ──────────────────────────────────
_get_public_ip() {
    local ip
    ip=$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null \
      || curl -s --max-time 4 https://api.ipify.org 2>/dev/null \
      || echo "N/A")
    echo "$ip"
}

_get_cpu_load() {
    # Carga del último minuto
    awk '{printf "%.2f", $1}' /proc/loadavg 2>/dev/null || echo "N/A"
}

_get_ram_usage() {
    # Devuelve "usada / total (porcentaje%)"
    if [[ -f /proc/meminfo ]]; then
        local total used avail pct
        total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
        avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
        used=$(( total - avail ))
        pct=$(( used * 100 / total ))
        printf "%s / %s (%d%%)" \
            "$(numfmt --to=iec --suffix=B $((used*1024)) 2>/dev/null || echo "${used}kB")" \
            "$(numfmt --to=iec --suffix=B $((total*1024)) 2>/dev/null || echo "${total}kB")" \
            "$pct"
    else
        echo "N/A"
    fi
}

_get_cpu_model() {
    grep -m1 "model name" /proc/cpuinfo 2>/dev/null \
        | awk -F': ' '{print $2}' \
        | sed 's/  */ /g' \
        | cut -c1-36 \
        || echo "CPU desconocido"
}

_get_uptime() {
    uptime -p 2>/dev/null || echo "N/A"
}

_get_disk_usage() {
    df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}' || echo "N/A"
}

# ── Control de versión ───────────────────────────────────────
_get_local_version() {
    cat "$INSTALL_DIR/version.txt" 2>/dev/null || echo "0.0.0"
}

_check_update() {
    local local_ver remote_ver
    local_ver=$(_get_local_version)
    remote_ver=$(curl -fsSL --max-time 5 "$REPO_RAW/version.txt" 2>/dev/null || echo "$local_ver")

    if [[ "$remote_ver" != "$local_ver" ]]; then
        echo -e "  ${Y}${BOLD}⟳  Nueva versión disponible: v$remote_ver${NC} ${DIM}(actual: v$local_ver)${NC}"
        echo -e "  ${DIM}  Elige la opción [U] para actualizar.${NC}"
    else
        echo -e "  ${DIM}  Versión: v$local_ver — actualizado ✓${NC}"
    fi
}

# ── Ejecutar sub-script de forma segura ─────────────────────
_run_module() {
    local script_path="$1"
    shift
    local args=("$@")

    if [[ ! -f "$script_path" ]]; then
        echo -e "\n  ${R}✖  Módulo no encontrado: $script_path${NC}"
        echo -e "  ${DIM}Intenta actualizar con la opción [U] del menú.${NC}"
        _press_enter
        return 1
    fi

    if [[ ! -x "$script_path" ]]; then
        chmod +x "$script_path"
    fi

    _log "Ejecutando módulo: $script_path ${args[*]:-}"
    bash "$script_path" "${args[@]:-}" || {
        echo -e "\n  ${R}✖  El módulo terminó con error (código $?).${NC}"
        _log "ERROR en módulo: $script_path"
        _press_enter
        return 1
    }
}

# ── Actualización desde GitHub ───────────────────────────────
_do_update() {
    clear
    echo -e "\n  ${C}${BOLD}Actualizando VPS-HENYER desde GitHub...${NC}\n"
    _log "Inicio de actualización"

    local scripts=(
        "menu.sh"
        "scripts/common.sh"
        "scripts/ssh.sh"
        "scripts/dropbear.sh"
        "scripts/openvpn.sh"
        "scripts/squid.sh"
        "scripts/trojan.sh"
        "scripts/ssr.sh"
        "scripts/websocket.sh"
        "scripts/http_custom.sh"
        "scripts/psiphon.sh"
        "scripts/badvpn.sh"
        "scripts/v2ray.sh"
        "scripts/ssl.sh"
        "scripts/slowdns.sh"
        "scripts/proxy_python.sh"
        "scripts/tools.sh"
        "scripts/security.sh"
    )
    local failed=0

    for script in "${scripts[@]}"; do
        local url="$REPO_RAW/$script"
        local dest="$INSTALL_DIR/$script"
        mkdir -p "$(dirname "$dest")"

        echo -e "  ${DIM}Descargando $script...${NC} \c"
        if curl -fsSL --retry 3 -o "$dest" "$url" 2>/dev/null; then
            chmod +x "$dest"
            echo -e "${G}✓${NC}"
        else
            echo -e "${R}✗${NC}"
            ((failed++)) || true
        fi
    done

    # Actualizar versión
    local new_ver
    new_ver=$(curl -fsSL "$REPO_RAW/version.txt" 2>/dev/null || echo "?")
    echo "$new_ver" > "$INSTALL_DIR/version.txt"

    echo ""
    if [[ $failed -eq 0 ]]; then
        echo -e "  ${G}${BOLD}✔  Actualización completada — v$new_ver${NC}"
        _log "Actualización exitosa a v$new_ver"
    else
        echo -e "  ${Y}⚠  Actualización parcial ($failed errores). Revisa tu conexión.${NC}"
        _log "Actualización parcial. Errores: $failed"
    fi
    _press_enter
}

# ── Desinstalación ───────────────────────────────────────────
_do_remove() {
    clear
    echo -e "\n  ${R}${BOLD}DESINSTALAR VPS-HENYER${NC}"
    echo ""
    _confirm "Esto eliminará todos los archivos de VPS-HENYER. ¿Continuar?" || return 0

    rm -rf "$INSTALL_DIR" /var/log/vps-henyer "$BIN_PATH" 2>/dev/null || true
    echo -e "\n  ${G}✔  VPS-HENYER eliminado correctamente.${NC}\n"
    exit 0
}
readonly BIN_PATH="/usr/local/bin/vps"

# ╔══════════════════════════════════════════════════════════╗
#  MENÚ PRINCIPAL — BANNER + INFO DEL SISTEMA
# ╚══════════════════════════════════════════════════════════╝
_draw_header() {
    local ip cpu_load ram cpu_model uptime_str disk

    ip=$(_get_public_ip)
    cpu_load=$(_get_cpu_load)
    ram=$(_get_ram_usage)
    cpu_model=$(_get_cpu_model)
    uptime_str=$(_get_uptime)
    disk=$(_get_disk_usage)

    clear
    echo -e ""
    echo -e "  ${C}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}${W}${BOLD}         🛡  VPS-HENYER  —  Panel de Control          ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
    printf "  ${C}${BOLD}║${NC}  ${DIM}IP Pública  :${NC} ${W}%-38s${NC}${C}${BOLD}║${NC}\n" "$ip"
    printf "  ${C}${BOLD}║${NC}  ${DIM}CPU         :${NC} ${W}%-38s${NC}${C}${BOLD}║${NC}\n" "$cpu_model"
    printf "  ${C}${BOLD}║${NC}  ${DIM}Carga CPU   :${NC} ${Y}%-38s${NC}${C}${BOLD}║${NC}\n" "$cpu_load"
    printf "  ${C}${BOLD}║${NC}  ${DIM}RAM Usada   :${NC} ${G}%-38s${NC}${C}${BOLD}║${NC}\n" "$ram"
    printf "  ${C}${BOLD}║${NC}  ${DIM}Disco (/)   :${NC} ${G}%-38s${NC}${C}${BOLD}║${NC}\n" "$disk"
    printf "  ${C}${BOLD}║${NC}  ${DIM}Uptime      :${NC} ${W}%-38s${NC}${C}${BOLD}║${NC}\n" "$uptime_str"
    printf "  ${C}${BOLD}║${NC}  ${DIM}Fecha/Hora  :${NC} ${W}%-38s${NC}${C}${BOLD}║${NC}\n" "$(date '+%d-%m-%Y  %H:%M:%S')"
    echo -e "  ${C}${BOLD}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  $(_check_update)                   ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ── Estado del Proxy Python ──────────────────────────────────
_proxy_py_status() {
    local count; count=$(ss -tlnp 2>/dev/null | grep -c python || echo 0)
    if (( count > 0 )); then
        local ports; ports=$(ss -tlnp 2>/dev/null | grep python | grep -oP ':\K[0-9]+' | tr '\n' ',' | sed 's/,$//')
        echo -e "${G}● ON${NC} ${DIM}:${ports}${NC}"
    else
        echo -e "${R}● OFF${NC}"
    fi
}

# ╔══════════════════════════════════════════════════════════╗
#  MENÚ DE PROTOCOLOS
# ╚══════════════════════════════════════════════════════════╝
menu_protocols() {
    while true; do
        _draw_header

        # ── Estado de cada servicio ──────────────────────────
        local s_ssh s_dropbear s_ovpn s_squid s_xray s_trojan s_ssr s_stunnel s_slowdns s_badvpn
        local p_ssh p_dropbear p_ovpn p_squid p_trojan p_badvpn

        s_ssh=$(_status_svc "ssh")
        p_ssh=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")

        s_dropbear=$(_status_svc "dropbear")
        p_dropbear=$(grep "^DROPBEAR_PORT" /etc/default/dropbear 2>/dev/null | cut -d= -f2 || echo "2222")

        s_ovpn=$(_status_svc "openvpn")
        p_ovpn=$(grep -E "^port " /etc/openvpn/server.conf 2>/dev/null | awk '{print $2}' || echo "1194")

        s_squid=$(_status_svc "squid")
        p_squid=$(grep -E "^http_port" /etc/squid/squid.conf 2>/dev/null | awk '{print $2}' | head -1 || echo "3128")

        s_xray=$(_status_svc "xray")

        s_trojan=$(_status_svc "trojan-go")
        p_trojan=$(ss -tlnp 2>/dev/null | grep -E "trojan" | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
        [[ -z "$p_trojan" ]] && p_trojan="-"

        s_ssr=$(_status_svc "shadowsocksr")
        s_stunnel=$(_status_svc "stunnel4")
        screen -ls 2>/dev/null | grep -q "slowdns" \
            && s_slowdns="${G}● ON ${NC}" || s_slowdns="${R}● OFF${NC}"

        pgrep -x "badvpn-udpgw" &>/dev/null \
            && s_badvpn="${G}● ON ${NC}" || s_badvpn="${R}● OFF${NC}"
        p_badvpn=$(grep -oP -- '--listen-addr 127\.0\.0\.1:\K[0-9]+' \
            /etc/systemd/system/badvpn-udpgw.service 2>/dev/null || echo "7300")

        # Info extra Xray
        local xray_extra=""
        if [[ -f /usr/local/etc/xray/config.json ]]; then
            local xp; xp=$(python3 -c "
import json
try:
    d=json.load(open('/usr/local/etc/xray/config.json'))
    print(d['inbounds'][0].get('port','?'))
except: print('?')
" 2>/dev/null || echo "?")
            xray_extra=" ${DIM}:${NC}${W}${xp}${NC}"
        fi
        if [[ -f /etc/vps-henyer/xray_users.json ]]; then
            local xu; xu=$(python3 -c "
import json
try:
    d=json.load(open('/etc/vps-henyer/xray_users.json'))
    a=sum(1 for u in d.get('users',[]) if not u.get('locked',False))
    print(f' {a}usr')
except: print('')
" 2>/dev/null || echo "")
            xray_extra="${xray_extra}${G}${xu}${NC}"
        fi

        echo -e "  ${M}${BOLD}┌─ PROTOCOLOS ─────────────────────────────────────────┐${NC}"
        echo -e "  ${M}│${NC}"
        echo -e "  ${M}│${NC}  ${Y}── SSH / Tuneles ─────────────────────────${NC}"
        echo -e "  ${M}│${NC}  ${W}[1]${NC}  OpenSSH              $s_ssh ${DIM}:${p_ssh}${NC}"
        echo -e "  ${M}│${NC}  ${W}[2]${NC}  Dropbear             $s_dropbear ${DIM}:${p_dropbear}${NC}"
        echo -e "  ${M}│${NC}  ${W}[3]${NC}  SSL / Stunnel4       $s_stunnel"
        echo -e "  ${M}│${NC}  ${W}[4]${NC}  SlowDNS              $s_slowdns"
        echo -e "  ${M}│${NC}"
        echo -e "  ${M}│${NC}  ${Y}── VPN / Proxy ───────────────────────────${NC}"
        echo -e "  ${M}│${NC}  ${W}[5]${NC}  OpenVPN              $s_ovpn ${DIM}:${p_ovpn}${NC}"
        echo -e "  ${M}│${NC}  ${W}[6]${NC}  Squid Proxy          $s_squid ${DIM}:${p_squid}${NC}"
        echo -e "  ${M}│${NC}  ${W}[7]${NC}  ShadowsocksR         $s_ssr"
        echo -e "  ${M}│${NC}  ${W}[8]${NC}  Trojan-GO            $s_trojan ${DIM}:${p_trojan}${NC}"
        echo -e "  ${M}│${NC}"
        echo -e "  ${M}│${NC}  ${Y}── V2Ray / Xray ──────────────────────────${NC}"
        echo -e "  ${M}│${NC}  ${W}[9]${NC}  V2Ray / Xray         $s_xray$xray_extra"
        echo -e "  ${M}│${NC}"
        echo -e "  ${M}│${NC}  ${Y}── UDP / Llamadas ────────────────────────${NC}"
        echo -e "  ${M}│${NC}  ${W}[10]${NC} BadVPN-UDPGW         $s_badvpn ${DIM}:${p_badvpn}${NC}"
        echo -e "  ${M}│${NC}"
        echo -e "  ${M}│${NC}  ${Y}── Proxy / HTTP ──────────────────────────${NC}"
        echo -e "  ${M}│${NC}  ${W}[11]${NC} Proxy Python         $(_proxy_py_status)"
        echo -e "  ${M}│${NC}  ${W}[12]${NC} HTTP Custom/Injector"
        echo -e "  ${M}│${NC}"
        echo -e "  ${M}│${NC}  ${DIM}[0]  Volver al menú principal${NC}"
        echo -e "  ${M}└──────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  Selección: \c"
        read -r opt

        case "$opt" in
            1)  _run_module "$SCRIPTS_DIR/ssh.sh"          ;;
            2)  _run_module "$SCRIPTS_DIR/dropbear.sh"     ;;
            3)  _run_module "$SCRIPTS_DIR/ssl.sh"          ;;
            4)  _run_module "$SCRIPTS_DIR/slowdns.sh"      ;;
            5)  _run_module "$SCRIPTS_DIR/openvpn.sh"      ;;
            6)  _run_module "$SCRIPTS_DIR/squid.sh"        ;;
            7)  _run_module "$SCRIPTS_DIR/ssr.sh"          ;;
            8)  _run_module "$SCRIPTS_DIR/trojan.sh"       ;;
            9)  _run_module "$SCRIPTS_DIR/v2ray.sh"        ;;
            10) _run_module "$SCRIPTS_DIR/badvpn.sh"       ;;
            11) _run_module "$SCRIPTS_DIR/proxy_python.sh" ;;
            12) _run_module "$SCRIPTS_DIR/http_custom.sh"  ;;
            0)  return ;;
            *)  echo -e "  ${R}Opción inválida.${NC}"; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  MENÚ DE HERRAMIENTAS
# ╚══════════════════════════════════════════════════════════╝
menu_tools() {
    while true; do
        _draw_header

        local s_fail2ban s_ufw s_bbr
        s_fail2ban=$(_status_svc "fail2ban")
        s_ufw=$(_status_svc "ufw")
        # BBR: checar si está activo en el kernel
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
            s_bbr="${G}● ON ${NC}"
        else
            s_bbr="${R}● OFF${NC}"
        fi

        echo -e "  ${B}${BOLD}┌─ MÓDULO: HERRAMIENTAS ───────────────────────────────┐${NC}"
        echo -e "  ${B}│${NC}"
        echo -e "  ${B}│${NC}  ${Y}${BOLD}— Optimización ——————————————————${NC}"
        printf "  ${B}│${NC}  ${W}[1]${NC} TCP BBR / BBR Plus         %s\n" "$s_bbr"
        echo -e "  ${B}│${NC}  ${W}[2]${NC} Optimización del kernel"
        echo -e "  ${B}│${NC}"
        echo -e "  ${B}│${NC}  ${Y}${BOLD}— Seguridad ——————————————————————${NC}"
        printf "  ${B}│${NC}  ${W}[3]${NC} Fail2ban                   %s\n" "$s_fail2ban"
        printf "  ${B}│${NC}  ${W}[4]${NC} Firewall (UFW / Iptables)  %s\n" "$s_ufw"
        echo -e "  ${B}│${NC}  ${W}[5]${NC} Bloqueo de Torrents"
        echo -e "  ${B}│${NC}"
        echo -e "  ${B}│${NC}  ${Y}${BOLD}— Utilidades —————————————————————${NC}"
        echo -e "  ${B}│${NC}  ${W}[6]${NC} Monitor de usuarios online"
        echo -e "  ${B}│${NC}  ${W}[7]${NC} Speedtest de red"
        echo -e "  ${B}│${NC}  ${W}[8]${NC} DNS Personalizado (Netflix/streaming)"
        echo -e "  ${B}│${NC}  ${W}[9]${NC} Reiniciar todos los servicios"
        echo -e "  ${B}│${NC}  ${W}[c]${NC} Cambiar contraseña root"
        echo -e "  ${B}│${NC}"
        echo -e "  ${B}│${NC}  ${DIM}[0] Volver al menú principal${NC}"
        echo -e "  ${B}└──────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  Selección: \c"
        read -r opt

        case "$opt" in
            1) _run_module "$SCRIPTS_DIR/tools.sh"    "bbr"         ;;
            2) _run_module "$SCRIPTS_DIR/tools.sh"    "kernel-opt"  ;;
            3) _run_module "$SCRIPTS_DIR/security.sh" "fail2ban"    ;;
            4) _run_module "$SCRIPTS_DIR/security.sh" "firewall"    ;;
            5) _run_module "$SCRIPTS_DIR/security.sh" "torrent"     ;;
            6) _run_module "$SCRIPTS_DIR/tools.sh"    "monitor"     ;;
            7) _run_module "$SCRIPTS_DIR/tools.sh"    "speedtest"   ;;
            8) _run_module "$SCRIPTS_DIR/tools.sh"    "dns"         ;;
            9) _run_module "$SCRIPTS_DIR/tools.sh"    "restart-all" ;;
            c|C) _run_module "$SCRIPTS_DIR/tools.sh" "passwd"       ;;
            0) return ;;
            *) echo -e "  ${R}Opción inválida.${NC}"; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  MENÚ PRINCIPAL
# ╚══════════════════════════════════════════════════════════╝
menu_main() {
    while true; do
        _draw_header

        echo -e "  ${W}${BOLD}┌─ MENÚ PRINCIPAL ─────────────────────────────────────┐${NC}"
        echo -e "  ${W}│${NC}"
        echo -e "  ${W}│${NC}  ${C}${BOLD}[1]${NC}  🔌  Gestión de Protocolos"
        echo -e "  ${W}│${NC}  ${C}${BOLD}[2]${NC}  🔧  Herramientas & Seguridad"
        echo -e "  ${W}│${NC}"
        _header_line
        echo -e "  ${W}│${NC}  ${Y}${BOLD}[U]${NC}  ⟳   Actualizar VPS-HENYER"
        echo -e "  ${W}│${NC}  ${R}${BOLD}[X]${NC}  ✕   Desinstalar VPS-HENYER"
        echo -e "  ${W}│${NC}  ${DIM}[0]  Salir${NC}"
        echo -e "  ${W}└──────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  Selección: \c"
        read -r opt

        case "${opt,,}" in
            1) menu_protocols ;;
            2) menu_tools     ;;
            u) _do_update     ;;
            x) _do_remove     ;;
            0|q|Q) echo -e "\n  ${DIM}Hasta luego.${NC}\n"; exit 0 ;;
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

# ── Crear log si no existe ───────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

# ── Punto de entrada ─────────────────────────────────────────
menu_main
