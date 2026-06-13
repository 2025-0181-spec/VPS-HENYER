#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Librería común (colores, helpers)
#  Este archivo debe ser cargado (source) por todos los
#  módulos de protocolos: ssh.sh, dropbear.sh, openvpn.sh, etc.
# ============================================================

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'
C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'
BOLD='\033[1m'

info()    { echo -e "  ${C}[INFO]${NC} $*"; }
success() { echo -e "  ${G}[OK]${NC}   $*"; }
warn()    { echo -e "  ${Y}[WARN]${NC}  $*"; }
error()   { echo -e "  ${R}[ERR]${NC}  $*"; }
die()     { error "$*"; exit 1; }

_press_enter()    { echo -e "\n  ${DIM}[Enter] para continuar...${NC}"; read -r; }
_service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
_cmd_exists()     { command -v "$1" &>/dev/null; }
_port_in_use()    { ss -tlnp 2>/dev/null | grep -q ":${1} "; }

_apt_install() {
    local pkg="$1"
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        info "$pkg ya está instalado."; return 0
    fi
    info "Instalando $pkg..."
    apt-get update -qq && apt-get install -y -qq "$pkg" || die "No se pudo instalar $pkg"
    success "$pkg instalado."
}

_toggle_service() {
    local svc="$1" friendly="${2:-$1}"
    if _service_active "$svc"; then
        systemctl stop "$svc" && systemctl disable "$svc" 2>/dev/null
        success "$friendly → DETENIDO"
    else
        systemctl enable "$svc" && systemctl start "$svc" 2>/dev/null
        _service_active "$svc" && success "$friendly → ACTIVO" || error "$friendly no pudo iniciar."
    fi
}

# Obtiene la IP pública del VPS
_get_ip() {
    curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null \
        || curl -s --max-time 4 https://api.ipify.org 2>/dev/null \
        || echo "TU_IP"
}
