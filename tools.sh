#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo de Herramientas
#  Llamado desde menu.sh: bash tools.sh <accion>
# ============================================================

set -uo pipefail

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'
C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'
BOLD='\033[1m'

info()    { echo -e "  ${C}[INFO]${NC} $*"; }
success() { echo -e "  ${G}[OK]${NC}   $*"; }
warn()    { echo -e "  ${Y}[WARN]${NC}  $*"; }
error()   { echo -e "  ${R}[ERR]${NC}  $*"; }
die()     { error "$*"; exit 1; }

_press_enter() { echo -e "\n  ${DIM}[Enter] para continuar...${NC}"; read -r; }
_cmd_exists()  { command -v "$1" &>/dev/null; }

_apt_install() {
    local pkg="$1"
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        info "$pkg ya está instalado."; return 0
    fi
    info "Instalando $pkg..."
    apt-get update -qq && apt-get install -y -qq "$pkg" || die "No se pudo instalar $pkg"
    success "$pkg instalado."
}

# ╔══════════════════════════════════════════════════════════╗
#  BBR
# ╚══════════════════════════════════════════════════════════╝
handle_bbr() {
    clear
    echo -e "\n  ${W}${BOLD}── TCP BBR / BBR Plus ───────────────────────────────${NC}\n"

    local current
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "desconocido")
    info "Algoritmo actual: ${W}${current}${NC}"
    echo ""

    if [[ "$current" == "bbr" ]]; then
        echo -e "  ${G}✔ BBR ya está activo.${NC}"
        echo ""
        echo -e "  ${W}[1]${NC} Desactivar BBR (volver a cubic)"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo -e "  Selección: \c"; read -r opt
        case "$opt" in
            1)
                sysctl -w net.ipv4.tcp_congestion_control=cubic > /dev/null
                sed -i '/tcp_congestion_control/d' /etc/sysctl.conf
                sed -i '/tcp_available_congestion_control/d' /etc/sysctl.conf
                success "BBR desactivado. Algoritmo: cubic"
                ;;
            0) return ;;
        esac
    else
        echo -e "  ${W}[1]${NC} Activar BBR"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo -e "  Selección: \c"; read -r opt
        case "$opt" in
            1)
                # Verificar soporte del kernel
                if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q "bbr"; then
                    modprobe tcp_bbr 2>/dev/null || warn "Módulo BBR no disponible en este kernel."
                fi
                sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null
                sysctl -w net.core.default_qdisc=fq > /dev/null

                # Persistir
                sed -i '/tcp_congestion_control/d' /etc/sysctl.conf
                sed -i '/default_qdisc/d' /etc/sysctl.conf
                echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
                echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

                local check
                check=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
                if [[ "$check" == "bbr" ]]; then
                    success "BBR activado correctamente."
                else
                    error "No se pudo activar BBR. Kernel: $(uname -r)"
                fi
                ;;
            0) return ;;
        esac
    fi
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  OPTIMIZACIÓN DEL KERNEL
# ╚══════════════════════════════════════════════════════════╝
handle_kernel_opt() {
    clear
    echo -e "\n  ${W}${BOLD}── Optimización del Kernel ──────────────────────────${NC}\n"
    echo -e "  Esto aplicará parámetros de red optimizados para VPS."
    echo -e "  ${Y}⚠  Se modificará /etc/sysctl.conf${NC}"
    echo ""
    echo -e "  ${W}[1]${NC} Aplicar optimización"
    echo -e "  ${W}[2]${NC} Ver parámetros actuales"
    echo -e "  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r opt

    case "$opt" in
        1)
            cat >> /etc/sysctl.conf << 'SYSCTL'

# VPS-HENYER — Optimización de red
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=10240 65535
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=250000
net.ipv4.tcp_max_syn_backlog=8192
vm.swappiness=10
fs.file-max=1000000
SYSCTL
            sysctl -p > /dev/null 2>&1
            success "Optimización del kernel aplicada."
            ;;
        2)
            echo ""
            sysctl net.ipv4.tcp_congestion_control \
                   net.ipv4.tcp_fastopen \
                   net.core.rmem_max \
                   net.core.wmem_max \
                   vm.swappiness 2>/dev/null | while read -r line; do
                echo -e "  ${DIM}$line${NC}"
            done
            ;;
        0) return ;;
    esac
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  MONITOR DE USUARIOS ONLINE
# ╚══════════════════════════════════════════════════════════╝
handle_monitor() {
    clear
    echo -e "\n  ${W}${BOLD}── Monitor de Usuarios Online ───────────────────────${NC}\n"

    # Usuarios SSH conectados
    echo -e "  ${Y}${BOLD}Sesiones SSH activas:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    local ssh_users
    ssh_users=$(who 2>/dev/null | grep -v "^$" || true)
    if [[ -n "$ssh_users" ]]; then
        echo "$ssh_users" | while read -r line; do
            echo -e "  ${G}●${NC} $line"
        done
    else
        echo -e "  ${DIM}  (ninguna sesión activa)${NC}"
    fi

    echo ""
    echo -e "  ${Y}${BOLD}Últimos 10 accesos:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    last -n 10 2>/dev/null | head -11 | while read -r line; do
        echo -e "  ${DIM}$line${NC}"
    done

    echo ""
    echo -e "  ${Y}${BOLD}Conexiones de red activas:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    ss -tnp 2>/dev/null | grep ESTAB | head -15 | while read -r line; do
        echo -e "  ${C}$line${NC}"
    done || echo -e "  ${DIM}(sin conexiones establecidas)${NC}"

    echo ""
    echo -e "  ${Y}${BOLD}Usuarios del sistema con sesión:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    w 2>/dev/null | tail -n +2 | while read -r line; do
        echo -e "  $line"
    done

    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  SPEEDTEST
# ╚══════════════════════════════════════════════════════════╝
handle_speedtest() {
    clear
    echo -e "\n  ${W}${BOLD}── Speedtest de Red ─────────────────────────────────${NC}\n"

    if _cmd_exists "speedtest"; then
        info "Ejecutando speedtest..."
        speedtest 2>/dev/null || speedtest-cli 2>/dev/null || error "Speedtest falló."
    elif _cmd_exists "speedtest-cli"; then
        info "Ejecutando speedtest-cli..."
        speedtest-cli
    else
        echo -e "  Speedtest no está instalado."
        echo -e "  ${W}[1]${NC} Instalar speedtest-cli  ${DIM}[0]${NC} Cancelar"
        echo -e "  Selección: \c"; read -r opt
        case "$opt" in
            1)
                _apt_install "speedtest-cli"
                info "Ejecutando speedtest..."
                speedtest-cli
                ;;
            0) return ;;
        esac
    fi
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  DNS PERSONALIZADO
# ╚══════════════════════════════════════════════════════════╝
handle_dns() {
    clear
    echo -e "\n  ${W}${BOLD}── DNS Personalizado ────────────────────────────────${NC}\n"

    local current_dns
    current_dns=$(cat /etc/resolv.conf 2>/dev/null | grep "^nameserver" | awk '{print $2}' | tr '\n' ' ')
    info "DNS actual: ${W}${current_dns:-ninguno}${NC}"
    echo ""
    echo -e "  ${W}[1]${NC} Google (8.8.8.8 / 8.8.4.4)"
    echo -e "  ${W}[2]${NC} Cloudflare (1.1.1.1 / 1.0.0.1)"
    echo -e "  ${W}[3]${NC} OpenDNS (208.67.222.222 / 208.67.220.220)"
    echo -e "  ${W}[4]${NC} DNS personalizado"
    echo -e "  ${W}[5]${NC} Restaurar DNS del sistema"
    echo -e "  ${DIM}[0]${NC} Volver"
    echo ""
    echo -e "  Selección: \c"; read -r opt

    local dns1="" dns2=""
    case "$opt" in
        1) dns1="8.8.8.8";          dns2="8.8.4.4" ;;
        2) dns1="1.1.1.1";          dns2="1.0.0.1" ;;
        3) dns1="208.67.222.222";   dns2="208.67.220.220" ;;
        4)
            echo -e "  DNS primario: \c";   read -r dns1
            echo -e "  DNS secundario: \c"; read -r dns2
            ;;
        5)
            if [[ -f /etc/resolv.conf.bak ]]; then
                cp /etc/resolv.conf.bak /etc/resolv.conf
                success "DNS restaurado desde backup."
            else
                warn "No hay backup disponible."
            fi
            _press_enter; return
            ;;
        0) return ;;
        *) warn "Opción inválida."; _press_enter; return ;;
    esac

    if [[ -n "$dns1" ]]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
        {
            echo "nameserver $dns1"
            [[ -n "$dns2" ]] && echo "nameserver $dns2"
        } > /etc/resolv.conf
        success "DNS configurado: ${dns1} / ${dns2}"
        info "Probando resolución..."
        if nslookup google.com > /dev/null 2>&1; then
            success "DNS funcionando correctamente."
        else
            warn "El DNS no resuelve. Revisa la configuración."
        fi
    fi
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  REINICIAR TODOS LOS SERVICIOS
# ╚══════════════════════════════════════════════════════════╝
handle_restart_all() {
    clear
    echo -e "\n  ${W}${BOLD}── Reiniciar Servicios ──────────────────────────────${NC}\n"
    echo -e "  ${Y}⚠  Reiniciará todos los servicios VPS activos.${NC}"
    echo -e "  ${Y}   La sesión SSH puede interrumpirse brevemente.${NC}"
    echo ""
    echo -e "  ${W}[1]${NC} Confirmar  ${DIM}[0]${NC} Cancelar"
    echo -e "  Selección: \c"; read -r opt
    [[ "$opt" == "1" ]] || return

    local services=("ssh" "dropbear" "openvpn" "squid" "xray" "fail2ban" "ufw")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl restart "$svc" 2>/dev/null && \
                success "Reiniciado: $svc" || \
                warn "Error al reiniciar: $svc"
        fi
    done
    success "Proceso completado."
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  CAMBIAR CONTRASEÑA ROOT
# ╚══════════════════════════════════════════════════════════╝
handle_passwd() {
    clear
    echo -e "\n  ${W}${BOLD}── Cambiar Contraseña Root ──────────────────────────${NC}\n"
    echo -e "  ${Y}⚠  Esto cambiará la contraseña del usuario root.${NC}"
    echo ""
    echo -e "  Nueva contraseña: \c"; read -rs pass1; echo
    echo -e "  Confirmar contraseña: \c"; read -rs pass2; echo

    if [[ -z "$pass1" ]]; then
        error "La contraseña no puede estar vacía."; _press_enter; return
    fi
    if [[ "$pass1" != "$pass2" ]]; then
        error "Las contraseñas no coinciden."; _press_enter; return
    fi

    echo "root:$pass1" | chpasswd
    success "Contraseña de root actualizada correctamente."
    _press_enter
}

# ── Router principal ─────────────────────────────────────────
ACTION="${1:-}"
case "$ACTION" in
    bbr)         handle_bbr         ;;
    kernel-opt)  handle_kernel_opt  ;;
    monitor)     handle_monitor     ;;
    speedtest)   handle_speedtest   ;;
    dns)         handle_dns         ;;
    restart-all) handle_restart_all ;;
    passwd)      handle_passwd      ;;
    *)
        error "Acción no reconocida: '$ACTION'"
        echo -e "  Válidas: bbr kernel-opt monitor speedtest dns restart-all passwd"
        exit 1
        ;;
esac
