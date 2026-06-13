#!/usr/bin/env bash
# ============================================================
#  vps-henyer — Instalador Completo Corregido
#  Uso: curl -sL https://raw.githubusercontent.com/2025-0181-spec/vps-henyer/main/setup.sh | bash
# ============================================================

set -euo pipefail

# Constantes con el usuario exacto y repositorio en minúsculas
readonly REPO_RAW="https://raw.githubusercontent.com/2025-0181-spec/vps-henyer/main"
readonly INSTALL_DIR="/etc/vps-henyer"
readonly SCRIPTS_DIR="/etc/vps-henyer/scripts"
readonly BIN_PATH="/usr/local/bin/vps"
readonly LOG_DIR="/var/log/vps-henyer"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || die "Ejecuta este script como root: sudo bash setup.sh"
}

check_arch() {
    local arch; arch=$(uname -m)
    [[ "$arch" == "x86_64" ]] || die "Arquitectura no soportada: $arch (requiere x86_64)"
    success "Arquitectura: $arch"
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "$ID" in
            ubuntu|debian) success "Sistema operativo: $PRETTY_NAME" ;;
            *) warn "Sistema no probado: $PRETTY_NAME — continuando de todas formas." ;;
        esac
    else
        warn "No se pudo detectar el SO. Continuing..."
    fi
}

check_internet() {
    info "Verificando conexión a internet..."
    curl -s --max-time 5 https://github.com > /dev/null 2>&1 || die "Sin acceso a internet o GitHub no responde."
    success "Conexión a internet OK"
}

install_dependencies() {
    info "Instalando dependencias base..."
    local deps=("curl" "wget" "git" "jq" "bc" "net-tools" "lsof" "ufw" "fail2ban" "iptables")
    local to_install=()
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || to_install+=("$dep")
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        apt-get update -qq
        apt-get install -y -qq "${to_install[@]}" || warn "Algunas dependencias fallaron: ${to_install[*]}"
        success "Dependencias installed: ${to_install[*]}"
    else
        success "Todas las dependencias ya están instaladas."
    fi
}

create_dirs() {
    info "Limpiando instalación previa..."
    rm -rf "$INSTALL_DIR"
    info "Creando estructura de directorios..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$SCRIPTS_DIR"
    mkdir -p "$LOG_DIR"
    chmod 755 "$INSTALL_DIR" "$SCRIPTS_DIR" "$LOG_DIR"
    success "Directorios creados en $INSTALL_DIR"
}

download_scripts() {
    info "Descargando componentes reales desde GitHub..."
    local failed=0

    # Archivos raíz
    declare -A root_files=(
        ["menu.sh"]="$INSTALL_DIR/menu.sh"
        ["version.txt"]="$INSTALL_DIR/version.txt"
    )

    # Archivos en /scripts
    declare -A script_files=(
        ["scripts/common.sh"]="$SCRIPTS_DIR/common.sh"
        ["scripts/ssh.sh"]="$SCRIPTS_DIR/ssh.sh"
        ["scripts/dropbear.sh"]="$SCRIPTS_DIR/dropbear.sh"
        ["scripts/openvpn.sh"]="$SCRIPTS_DIR/openvpn.sh"
        ["scripts/squid.sh"]="$SCRIPTS_DIR/squid.sh"
        ["scripts/trojan.sh"]="$SCRIPTS_DIR/trojan.sh"
        ["scripts/ssr.sh"]="$SCRIPTS_DIR/ssr.sh"
        ["scripts/websocket.sh"]="$SCRIPTS_DIR/websocket.sh"
        ["scripts/http_custom.sh"]="$SCRIPTS_DIR/http_custom.sh"
        ["scripts/psiphon.sh"]="$SCRIPTS_DIR/psiphon.sh"
        ["scripts/badvpn.sh"]="$SCRIPTS_DIR/badvpn.sh"
        ["scripts/v2ray.sh"]="$SCRIPTS_DIR/v2ray.sh"
        ["scripts/ssl.sh"]="$SCRIPTS_DIR/ssl.sh"
        ["scripts/slowdns.sh"]="$SCRIPTS_DIR/slowdns.sh"
        ["scripts/proxy_python.sh"]="$SCRIPTS_DIR/proxy_python.sh"
        ["scripts/tools.sh"]="$SCRIPTS_DIR/tools.sh"
        ["scripts/security.sh"]="$SCRIPTS_DIR/security.sh"
    )

    for remote in "${!root_files[@]}"; do
        local dest="${root_files[$remote]}"
        # Se removió la cabecera del token para acceso público directo
        if curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$REPO_RAW/$remote"; then
            chmod +x "$dest" 2>/dev/null || true
            success "Descargado con éxito: $remote"
        else
            warn "No disponible o error en repo: $remote (omitido)"
            ((failed++)) || true
        fi
    done

    for remote in "${!script_files[@]}"; do
        local dest="${script_files[$remote]}"
        # Se removió la cabecera del token para acceso público directo
        if curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$REPO_RAW/$remote" 2>/dev/null; then
            chmod +x "$dest"
            success "Descargado: $remote"
        else
            warn "No disponible en repo: $remote (se generará localmente)"
        fi
    done

    [[ $failed -eq 0 ]] || die "No se pudieron descargar los componentes esenciales de raíz."
}

save_version() {
    local ver
    # Descarga pública directa sin cabeceras de autorización
    ver=$(curl -fsSL --max-time 5 "$REPO_RAW/version.txt" 2>/dev/null || echo "1.0.0")
    echo "$ver" > "$INSTALL_DIR/version.txt"
    success "Versión instalada: $ver"
}

generate_missing_scripts() {
    # ── tools.sh ────────────────────────────────────────────
    if [[ ! -s "$SCRIPTS_DIR/tools.sh" ]]; then
        info "Generando tools.sh localmente..."
        curl -fsSL --retry 3 "${REPO_RAW}/scripts/tools.sh" \
            -o "$SCRIPTS_DIR/tools.sh" 2>/dev/null || \
        cat > "$SCRIPTS_DIR/tools.sh" << 'TOOLS'
#!/usr/bin/env bash
G='\033[0;32m';R='\033[0;31m';Y='\033[1;33m';C='\033[0;36m';W='\033[1;37m';DIM='\033[2m';NC='\033[0m';BOLD='\033[1m'
info(){ echo -e "  ${C}[INFO]${NC} $*"; }
success(){ echo -e "  ${G}[OK]${NC}   $*"; }
warn(){ echo -e "  ${Y}[WARN]${NC}  $*"; }
error(){ echo -e "  ${R}[ERR]${NC}  $*"; }
_press_enter(){ echo -e "\n  ${DIM}[Enter] para continuar...${NC}"; read -r; }
_cmd_exists(){ command -v "$1" &>/dev/null; }
_apt_install(){ local p="$1"; dpkg -l "$p" 2>/dev/null|grep -q "^ii" && { info "$p ya instalado."; return; }; apt-get update -qq && apt-get install -y -qq "$p"; success "$p instalado."; }

handle_bbr(){
    clear; echo -e "\n  ${W}${BOLD}── TCP BBR ──────────────────────────────────────────${NC}\n"
    local cur; cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null||echo "cubic")
    info "Algoritmo actual: ${W}${cur}${NC}"; echo ""
    if [[ "$cur" == "bbr" ]]; then
        echo -e "  ${G}✔ BBR ya activo.${NC}\n  ${W}[1]${NC} Desactivar  ${DIM}[0]${NC} Volver"; read -r o
        [[ "$o" == "1" ]] && { sysctl -w net.ipv4.tcp_congestion_control=cubic>/dev/null; sed -i '/tcp_congestion_control/d;/default_qdisc/d' /etc/sysctl.conf; success "BBR desactivado."; }
    else
        echo -e "  ${W}[1]${NC} Activar BBR  ${DIM}[0]${NC} Volver"; read -r o
        [[ "$o" == "1" ]] && { modprobe tcp_bbr 2>/dev/null||true; sysctl -w net.ipv4.tcp_congestion_control=bbr>/dev/null; sysctl -w net.core.default_qdisc=fq>/dev/null; sed -i '/tcp_congestion_control/d;/default_qdisc/d' /etc/sysctl.conf; echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr">>/etc/sysctl.conf; success "BBR activado."; }
    fi; _press_enter; }

handle_kernel_opt(){
    clear; echo -e "\n  ${W}${BOLD}── Optimización Kernel ──────────────────────────────${NC}\n"
    echo -e "  ${W}[1]${NC} Aplicar optimización  ${DIM}[0]${NC} Volver"; read -r o
    [[ "$o" == "1" ]] && { cat>>/etc/sysctl.conf<<'S'
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=250000
vm.swappiness=10
fs.file-max=1000000
S
sysctl -p>/dev/null 2>&1; success "Optimización aplicada."; }; _press_enter; }

handle_monitor(){
    clear; echo -e "\n  ${W}${BOLD}── Monitor de Usuarios ──────────────────────────────${NC}\n"
    echo -e "  ${Y}${BOLD}Sesiones activas:${NC}"; who 2>/dev/null||echo "  (ninguna)"
    echo -e "\n  ${Y}${BOLD}Últimos accesos:${NC}"; last -n 8 2>/dev/null|head -9
    echo -e "\n  ${Y}${BOLD}Conexiones establecidas:${NC}"; ss -tnp 2>/dev/null|grep ESTAB|head -10||echo "  (ninguna)"
    _press_enter; }

handle_speedtest(){
    clear; echo -e "\n  ${W}${BOLD}── Speedtest ────────────────────────────────────────${NC}\n"
    if _cmd_exists speedtest-cli; then speedtest-cli
    else echo -e "  ${W}[1]${NC} Instalar speedtest-cli  ${DIM}[0]${NC} Cancelar"; read -r o
        [[ "$o" == "1" ]] && { _apt_install speedtest-cli; speedtest-cli; }; fi
    _press_enter; }

handle_dns(){
    clear; echo -e "\n  ${W}${BOLD}── DNS Personalizado ────────────────────────────────${NC}\n"
    local cur; cur=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null|grep -v "127.0.0.53"|awk '{print $2}'|tr '\n' ' ')
    info "DNS actual: ${W}${cur:-ninguno}${NC}"; echo ""
    echo -e "  ${W}[1]${NC} Google (8.8.8.8)\n  ${W}[2]${NC} Cloudflare (1.1.1.1)\n  ${W}[3]${NC} OpenDNS\n  ${W}[4]${NC} Manual\n  ${W}[5]${NC} Restaurar\n  ${DIM}[0]${NC} Volver"
    read -r o; local d1="" d2=""
    case "$o" in
        1) d1="8.8.8.8"; d2="8.8.4.4";;
        2) d1="1.1.1.1"; d2="1.0.0.1";;
        3) d1="208.67.222.222"; d2="208.67.220.220";;
        4) echo -e "  DNS1: \c"; read -r d1; echo -e "  DNS2: \c"; read -r d2;;
        5) [[ -f /etc/resolv.conf.bak ]] && cp /etc/resolv.conf.bak /etc/resolv.conf && success "Restaurado." || warn "Sin backup."; _press_enter; return;;
        0) return;;
    esac
    [[ -n "$d1" ]] && { cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null||true; printf "nameserver %s\nnameserver %s\n" "$d1" "$d2">/etc/resolv.conf; success "DNS: $d1 / $d2"; }
    _press_enter; }

handle_restart_all(){
    clear; echo -e "\n  ${W}${BOLD}── Reiniciar Servicios ──────────────────────────────${NC}\n"
    echo -e "  ${W}[1]${NC} Confirmar  ${DIM}[0]${NC} Cancelar"; read -r o; [[ "$o" == "1" ]] || return
    for s in ssh dropbear openvpn squid xray fail2ban ufw; do
        systemctl is-active --quiet "$s" 2>/dev/null && { systemctl restart "$s" 2>/dev/null && success "Reiniciado: $s" || warn "Error: $s"; }
    done; success "Listo."; _press_enter; }

handle_passwd(){
    clear; echo -e "\n  ${W}${BOLD}── Cambiar Contraseña Root ──────────────────────────${NC}\n"
    echo -e "  Nueva contraseña: \c"; read -rs p1; echo
    echo -e "  Confirmar: \c"; read -rs p2; echo
    [[ -z "$p1" ]] && { error "Vacía."; _press_enter; return; }
    [[ "$p1" != "$p2" ]] && { error "No coinciden."; _press_enter; return; }
    echo "root:$p1"|chpasswd; success "Contraseña actualizada."; _press_enter; }

case "${1:-}" in
    bbr) handle_bbr;; kernel-opt) handle_kernel_opt;; monitor) handle_monitor;;
    speedtest) handle_speedtest;; dns) handle_dns;; restart-all) handle_restart_all;;
    passwd) handle_passwd;; *) echo "Válidas: bbr kernel-opt monitor speedtest dns restart-all passwd"; exit 1;;
esac
TOOLS
        chmod +x "$SCRIPTS_DIR/tools.sh"
        success "tools.sh generado."
    fi

    # ── security.sh ─────────────────────────────────────────
    if [[ ! -s "$SCRIPTS_DIR/security.sh" ]]; then
        info "Generando security.sh localmente..."
        curl -fsSL --retry 3 "${REPO_RAW}/scripts/security.sh" \
            -o "$SCRIPTS_DIR/security.sh" 2>/dev/null || \
        cat > "$SCRIPTS_DIR/security.sh" << 'SECURITY'
#!/usr/bin/env bash
G='\033[0;32m';R='\033[0;31m';Y='\033[1;33m';C='\033[0;36m';W='\033[1;37m';DIM='\033[2m';NC='\033[0m';BOLD='\033[1m'
info(){ echo -e "  ${C}[INFO]${NC} $*"; }; success(){ echo -e "  ${G}[OK]${NC}   $*"; }
warn(){ echo -e "  ${Y}[WARN]${NC}  $*"; }; error(){ echo -e "  ${R}[ERR]${NC}  $*"; }
_press_enter(){ echo -e "\n  ${DIM}[Enter] para continuar...${NC}"; read -r; }
_service_active(){ systemctl is-active --quiet "$1" 2>/dev/null; }
_apt_install(){ local p="$1"; dpkg -l "$p" 2>/dev/null|grep -q "^ii"&&return; apt-get update -qq&&apt-get install -y -qq "$p"; success "$p instalado."; }

handle_fail2ban(){
    while true; do
        clear; echo -e "\n  ${W}${BOLD}── Fail2Ban ─────────────────────────────────────────${NC}\n"
        if ! command -v fail2ban-client &>/dev/null; then
            echo -e "  ${W}[1]${NC} Instalar Fail2Ban  ${DIM}[0]${NC} Volver"; read -r o
            [[ "$o" == "1" ]]&&{ _apt_install fail2ban; systemctl enable fail2ban&&systemctl start fail2ban; success "Instalado."; }||return
            _press_enter; continue; fi
        _service_active fail2ban&&est="${G}● ACTIVO${NC}"||est="${R}● INACTIVO${NC}"
        echo -e "  Estado: $est\n"
        echo -e "  ${W}[1]${NC} Activar/Desactivar\n  ${W}[2]${NC} IPs baneadas\n  ${W}[3]${NC} Desbanear IP\n  ${W}[4]${NC} Ver log\n  ${DIM}[0]${NC} Volver"
        read -r o
        case "$o" in
            1) _service_active fail2ban&&{ systemctl stop fail2ban&&systemctl disable fail2ban&&success "Detenido."; }||{ systemctl enable fail2ban&&systemctl start fail2ban&&success "Activo."; }; _press_enter;;
            2) echo ""; fail2ban-client status sshd 2>/dev/null||fail2ban-client status ssh 2>/dev/null||warn "Sin jail SSH activo."; _press_enter;;
            3) echo -e "  IP: \c"; read -r ip; fail2ban-client set sshd unbanip "$ip" 2>/dev/null||fail2ban-client set ssh unbanip "$ip" 2>/dev/null||error "No se pudo desbanear."; success "IP $ip desbaneada."; _press_enter;;
            4) tail -30 /var/log/fail2ban.log 2>/dev/null|while read -r l; do echo -e "  ${DIM}$l${NC}"; done; _press_enter;;
            0) return;;
        esac
    done; }

handle_firewall(){
    while true; do
        clear; echo -e "\n  ${W}${BOLD}── Firewall UFW ─────────────────────────────────────${NC}\n"
        command -v ufw &>/dev/null||_apt_install ufw
        local st; st=$(ufw status 2>/dev/null|head -1)
        echo -e "  Estado: ${W}${st}${NC}\n"
        echo -e "  ${W}[1]${NC} Activar/Desactivar\n  ${W}[2]${NC} Ver reglas\n  ${W}[3]${NC} Permitir puerto\n  ${W}[4]${NC} Bloquear puerto\n  ${W}[5]${NC} Eliminar regla\n  ${W}[6]${NC} Config básica (SSH+HTTP+HTTPS)\n  ${W}[7]${NC} Bloquear IP\n  ${DIM}[0]${NC} Volver"
        read -r o
        case "$o" in
            1) ufw status|grep -q "active"&&{ ufw --force disable&&success "UFW desactivado."; }||{ ufw --force enable&&success "UFW activado."; }; _press_enter;;
            2) ufw status verbose 2>/dev/null; _press_enter;;
            3) echo -e "  Puerto: \c"; read -r p; ufw allow "$p"&&success "Puerto $p permitido."; _press_enter;;
            4) echo -e "  Puerto: \c"; read -r p; ufw deny "$p"&&success "Puerto $p bloqueado."; _press_enter;;
            5) ufw status numbered; echo -e "\n  Número: \c"; read -r n; [[ "$n" =~ ^[0-9]+$ ]]&&ufw --force delete "$n"; _press_enter;;
            6) ufw --force reset>/dev/null 2>&1; ufw default deny incoming>/dev/null; ufw default allow outgoing>/dev/null; ufw allow 22/tcp>/dev/null; ufw allow 80/tcp>/dev/null; ufw allow 443/tcp>/dev/null; ufw --force enable>/dev/null; success "Reglas básicas aplicadas."; _press_enter;;
            7) echo -e "  IP: \c"; read -r ip; ufw deny from "$ip"&&success "IP $ip bloqueada."; _press_enter;;
            0) return;;
        esac
    done; }

handle_torrent(){
    while true; do
        clear; echo -e "\n  ${W}${BOLD}── Bloqueo de Torrents ──────────────────────────────${NC}\n"
        iptables -L OUTPUT 2>/dev/null|grep -q "6881"&&est="${G}● Activo${NC}"||est="${R}● Inactivo${NC}"
        echo -e "  Estado: $est\n"
        echo -e "  ${W}[1]${NC} Activar bloqueo\n  ${W}[2]${NC} Desactivar bloqueo\n  ${DIM}[0]${NC} Volver"; read -r o
        case "$o" in
            1) for p in 6881 6882 6883 6969 51413; do
                iptables -A OUTPUT -p tcp --dport $p -j DROP 2>/dev/null||true
                iptables -A OUTPUT -p udp --dport $p -j DROP 2>/dev/null||true
                iptables -A INPUT  -p tcp --dport $p -j DROP 2>/dev/null||true
                iptables -A INPUT  -p udp --dport $p -j DROP 2>/dev/null||true
               done; iptables -A FORWARD -m string --algo bm --string "BitTorrent" -j DROP 2>/dev/null||true
               success "Bloqueo activado."; _press_enter;;
            2) for p in 6881 6882 6883 6969 51413; do
                iptables -D OUTPUT -p tcp --dport $p -j DROP 2>/dev/null||true
                iptables -D OUTPUT -p udp --dport $p -j DROP 2>/dev/null||true
                iptables -D INPUT  -p tcp --dport $p -j DROP 2>/dev/null||true
                iptables -D INPUT  -p udp --dport $p -j DROP 2>/dev/null||true
               done; iptables -D FORWARD -m string --algo bm --string "BitTorrent" -j DROP 2>/dev/null||true
               success "Bloqueo desactivado."; _press_enter;;
            0) return;;
        esac
    done; }

case "${1:-}" in
    fail2ban) handle_fail2ban;; firewall) handle_firewall;; torrent) handle_torrent;;
    *) echo "Válidas: fail2ban firewall torrent"; exit 1;;
esac
SECURITY
        chmod +x "$SCRIPTS_DIR/security.sh"
        success "security.sh generado."
    fi

}

save_version() {
    local ver
    ver=$(curl -fsSL --max-time 5 "$REPO_RAW/version.txt" 2>/dev/null || echo "1.0.0")
    echo "$ver" > "$INSTALL_DIR/version.txt"
    success "Versión instalada: $ver"
}

create_global_command() {
    cat > "$BIN_PATH" << 'CMD'
#!/usr/bin/env bash
exec bash /etc/vps-henyer/menu.sh "$@"
CMD
    chmod +x "$BIN_PATH"
    ln -sf "$BIN_PATH" /usr/local/bin/menu
    success "Comandos globales creados: 'vps' y 'menu'"
}

print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║         vps-henyer — INSTALADOR       ║"
    echo "  ╚═══════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_success() {
    echo ""
    echo -e "${GREEN}${BOLD}  ✔  Instalación completada exitosamente${RESET}"
    echo ""
    echo -e "  ${BOLD}Uso:${RESET} escribe ${CYAN}vps${RESET} o ${CYAN}menu${RESET} en tu terminal"
    echo -e "  ${BOLD}Directorio:${RESET} $INSTALL_DIR"
    echo -e "  ${BOLD}Scripts:${RESET}    $SCRIPTS_DIR"
    echo -e "  ${BOLD}Logs:${RESET}       $LOG_DIR"
    echo ""
    echo -e "  Para iniciar ahora: ${YELLOW}menu${RESET}"
    echo ""
}

verify_install() {
    info "Verificando instalación..."
    local ok=true
    local files=("$INSTALL_DIR/menu.sh" "$SCRIPTS_DIR/common.sh" "$SCRIPTS_DIR/ssh.sh" "$SCRIPTS_DIR/badvpn.sh" "$SCRIPTS_DIR/openvpn.sh")
    for f in "${files[@]}"; do
        if [[ -f "$f" && -s "$f" ]]; then
            success "OK: $f"
        else
            warn "FALTA: $f"
            ok=false
        fi
    done
    $ok && success "Todos los módulos base presentes." || warn "Algunos módulos faltan."
}


configure_ssh_compatibility() {
    info "Configurando SSH para compatibilidad con clientes móviles (Ubuntu 24)..."

    local cfg="/etc/ssh/sshd_config"
    local marker="# VPS-HENYER — Compatibilidad clientes móviles"

    # Evitar duplicados si se reinstala
    if grep -q "$marker" "$cfg" 2>/dev/null; then
        info "Compatibilidad SSH ya configurada. Omitiendo."
        return 0
    fi

    cat >> "$cfg" << 'SSHCOMPAT'

# VPS-HENYER — Compatibilidad clientes móviles
# (HTTP Custom, HTTP Injector, NapsternetV — Ubuntu 24 / OpenSSH 9+)
KexAlgorithms +diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1
PubkeyAcceptedAlgorithms +ssh-rsa
HostKeyAlgorithms +ssh-rsa
SSHCOMPAT

    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        success "SSH recargado con compatibilidad para clientes móviles."
    else
        # Si algo falla, remover las líneas que agregamos para no romper SSH
        sed -i "/$marker/,+4d" "$cfg"
        warn "No se pudo aplicar compatibilidad SSH. Config revertida."
    fi
}

configure_proxy_http() {
    info "Configurando proxy HTTP para HTTP Custom / HTTP Injector..."

    local proxy_dir="/etc/vps-henyer"
    local proxy_script="$proxy_dir/http_proxy.py"
    local svc="/etc/systemd/system/vps-http-proxy.service"
    local ssh_port
    ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo "22")

    mkdir -p "$proxy_dir"

    # Abrir puerto 8880 en UFW si está activo
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow 8880/tcp > /dev/null 2>&1 || true
        success "UFW: puerto 8880 abierto."
    fi

    # Escribir el proxy Python con soporte CONNECT + WebSocket
    cat > "$proxy_script" << PYEOF
#!/usr/bin/env python3
"""
VPS-HENYER — Proxy HTTP/WebSocket para SSH
Soporta: CONNECT, WebSocket (GET+Upgrade), HTTP generico
Compatible: HTTP Custom, HTTP Injector, NapsternetV
"""
import socket, threading, select, sys, datetime

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8880
SSH_HOST    = "127.0.0.1"
SSH_PORT    = int(sys.argv[2]) if len(sys.argv) > 2 else SSH_DEFAULT
BUFFER      = 65536

def log(msg):
    print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)

def bridge(src, dst):
    try:
        while True:
            r, _, _ = select.select([src, dst], [], [], 120)
            if not r:
                break
            for s in r:
                try:
                    data = s.recv(BUFFER)
                except:
                    return
                if not data:
                    return
                other = dst if s is src else src
                try:
                    other.sendall(data)
                except:
                    return
    except:
        pass
    finally:
        for s in (src, dst):
            try: s.close()
            except: pass

def handle_client(client):
    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    try:
        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = client.recv(BUFFER)
            if not chunk:
                return
            raw += chunk
            if len(raw) > 65536:
                return

        header_part = raw[:raw.find(b"\r\n\r\n")].decode("utf-8", errors="ignore")
        first_line  = header_part.split("\r\n")[0] if header_part else ""
        is_websocket = "upgrade: websocket" in header_part.lower()
        is_connect   = first_line.upper().startswith("CONNECT")

        ssh = socket.create_connection((SSH_HOST, SSH_PORT), timeout=10)
        ssh.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        if is_connect:
            client.sendall(b"HTTP/1.1 200 Connection Established\r\nProxy-agent: VPS-HENYER\r\n\r\n")
            log(f"[CONNECT] -> SSH:{SSH_PORT}")
        elif is_websocket:
            client.sendall(
                b"HTTP/1.1 101 Switching Protocols\r\n"
                b"Upgrade: websocket\r\n"
                b"Connection: Upgrade\r\n"
                b"\r\n"
            )
            log(f"[WS] -> SSH:{SSH_PORT}")
        else:
            client.sendall(b"HTTP/1.1 200 OK\r\nProxy-agent: VPS-HENYER\r\n\r\n")
            log(f"[HTTP] {first_line[:60]} -> SSH:{SSH_PORT}")

        tail = raw[raw.find(b"\r\n\r\n") + 4:]
        if tail:
            ssh.sendall(tail)

        threading.Thread(target=bridge, args=(client, ssh), daemon=True).start()

    except Exception as e:
        log(f"[ERR] {e}")
        try: client.close()
        except: pass

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(500)
    log(f"VPS-HENYER proxy :{LISTEN_PORT} -> SSH:{SSH_PORT}")
    while True:
        try:
            client, _ = srv.accept()
            threading.Thread(target=handle_client, args=(client,), daemon=True).start()
        except KeyboardInterrupt:
            break
        except Exception as e:
            log(f"[ACCEPT ERR] {e}")

if __name__ == "__main__":
    main()
PYEOF

    # Reemplazar SSH_DEFAULT con el puerto real
    sed -i "s/SSH_DEFAULT/${ssh_port}/" "$proxy_script"
    chmod +x "$proxy_script"

    # Crear servicio systemd
    cat > "$svc" << SVCEOF
[Unit]
Description=VPS-HENYER HTTP Proxy (HTTP Custom / Injector)
After=network.target ssh.service
Wants=ssh.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${proxy_script} 8880 ${ssh_port}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable vps-http-proxy 2>/dev/null
    systemctl restart vps-http-proxy 2>/dev/null

    if systemctl is-active --quiet vps-http-proxy; then
        success "Proxy HTTP activo en puerto 8880 → SSH:${ssh_port}"
    else
        warn "Proxy HTTP no pudo iniciar. Revisa: journalctl -u vps-http-proxy -n 20"
    fi
}

main() {
    print_banner
    check_root
    check_arch
    check_os
    check_internet
    install_dependencies
    create_dirs
    download_scripts
    generate_missing_scripts
    configure_ssh_compatibility
    configure_proxy_http
    save_version
    create_global_command
    verify_install
    print_success
}

main "$@"
