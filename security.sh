#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo de Seguridad
#  Llamado desde menu.sh: bash security.sh <accion>
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

_press_enter()    { echo -e "\n  ${DIM}[Enter] para continuar...${NC}"; read -r; }
_cmd_exists()     { command -v "$1" &>/dev/null; }
_service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

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
#  FAIL2BAN
# ╚══════════════════════════════════════════════════════════╝
handle_fail2ban() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── Fail2Ban ─────────────────────────────────────────${NC}\n"

        if ! _cmd_exists "fail2ban-client"; then
            echo -e "  Fail2Ban no está instalado."
            echo -e "  ${W}[1]${NC} Instalar Fail2Ban  ${DIM}[0]${NC} Volver"
            echo -e "  Selección: \c"; read -r opt
            case "$opt" in
                1) _apt_install "fail2ban"
                   systemctl enable fail2ban && systemctl start fail2ban
                   success "Fail2Ban instalado e iniciado." ;;
                0) return ;;
            esac
            _press_enter; continue
        fi

        local estado
        if _service_active "fail2ban"; then
            estado="${G}● ACTIVO${NC}"
        else
            estado="${R}● INACTIVO${NC}"
        fi
        echo -e "  Estado: $estado"
        echo ""
        echo -e "  ${W}[1]${NC} Activar / Desactivar Fail2Ban"
        echo -e "  ${W}[2]${NC} Ver IPs baneadas (SSH)"
        echo -e "  ${W}[3]${NC} Desbanear una IP"
        echo -e "  ${W}[4]${NC} Ver log de actividad"
        echo -e "  ${W}[5]${NC} Ver estadísticas"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""
        echo -e "  Selección: \c"; read -r opt

        case "$opt" in
            1)
                if _service_active "fail2ban"; then
                    systemctl stop fail2ban && systemctl disable fail2ban
                    success "Fail2Ban → DETENIDO"
                else
                    systemctl enable fail2ban && systemctl start fail2ban
                    success "Fail2Ban → ACTIVO"
                fi
                _press_enter
                ;;
            2)
                echo ""
                echo -e "  ${Y}${BOLD}IPs baneadas en jail SSH:${NC}"
                echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
                fail2ban-client status sshd 2>/dev/null || \
                fail2ban-client status ssh 2>/dev/null || \
                warn "No se pudo obtener el estado del jail SSH."
                _press_enter
                ;;
            3)
                echo -e "  IP a desbanear: \c"; read -r ip
                if [[ -n "$ip" ]]; then
                    fail2ban-client set sshd unbanip "$ip" 2>/dev/null || \
                    fail2ban-client set ssh unbanip "$ip" 2>/dev/null || \
                    error "No se pudo desbanear $ip"
                    success "IP $ip desbaneada."
                fi
                _press_enter
                ;;
            4)
                echo ""
                tail -30 /var/log/fail2ban.log 2>/dev/null | while read -r line; do
                    echo -e "  ${DIM}$line${NC}"
                done || warn "Log no disponible."
                _press_enter
                ;;
            5)
                echo ""
                fail2ban-client status 2>/dev/null | while read -r line; do
                    echo -e "  $line"
                done
                _press_enter
                ;;
            0) return ;;
            *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  FIREWALL (UFW)
# ╚══════════════════════════════════════════════════════════╝
handle_firewall() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── Firewall UFW ─────────────────────────────────────${NC}\n"

        if ! _cmd_exists "ufw"; then
            _apt_install "ufw"
        fi

        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1 || echo "Status: unknown")
        echo -e "  Estado UFW: ${W}${ufw_status}${NC}"
        echo ""
        echo -e "  ${W}[1]${NC} Activar / Desactivar UFW"
        echo -e "  ${W}[2]${NC} Ver reglas actuales"
        echo -e "  ${W}[3]${NC} Permitir puerto"
        echo -e "  ${W}[4]${NC} Bloquear puerto"
        echo -e "  ${W}[5]${NC} Eliminar regla"
        echo -e "  ${W}[6]${NC} Configuración básica segura (SSH + puertos esenciales)"
        echo -e "  ${W}[7]${NC} Bloquear IP"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""
        echo -e "  Selección: \c"; read -r opt

        case "$opt" in
            1)
                if ufw status | grep -q "Status: active"; then
                    ufw --force disable
                    success "UFW → DESACTIVADO"
                else
                    ufw --force enable
                    success "UFW → ACTIVADO"
                fi
                _press_enter
                ;;
            2)
                echo ""
                ufw status verbose 2>/dev/null | while read -r line; do
                    echo -e "  $line"
                done
                _press_enter
                ;;
            3)
                echo -e "  Puerto a permitir (ej: 80, 443, 8080/tcp): \c"; read -r port
                if [[ -n "$port" ]]; then
                    ufw allow "$port"
                    success "Puerto $port permitido."
                fi
                _press_enter
                ;;
            4)
                echo -e "  Puerto a bloquear: \c"; read -r port
                if [[ -n "$port" ]]; then
                    ufw deny "$port"
                    success "Puerto $port bloqueado."
                fi
                _press_enter
                ;;
            5)
                echo ""
                ufw status numbered 2>/dev/null | while read -r line; do
                    echo -e "  $line"
                done
                echo ""
                echo -e "  Número de regla a eliminar: \c"; read -r num
                if [[ "$num" =~ ^[0-9]+$ ]]; then
                    ufw --force delete "$num"
                    success "Regla $num eliminada."
                fi
                _press_enter
                ;;
            6)
                info "Aplicando configuración básica segura..."
                ufw --force reset > /dev/null 2>&1
                ufw default deny incoming > /dev/null
                ufw default allow outgoing > /dev/null
                ufw allow 22/tcp  > /dev/null
                ufw allow 80/tcp  > /dev/null
                ufw allow 443/tcp > /dev/null
                ufw --force enable > /dev/null
                success "Reglas básicas aplicadas: SSH(22), HTTP(80), HTTPS(443)"
                _press_enter
                ;;
            7)
                echo -e "  IP a bloquear: \c"; read -r ip
                if [[ -n "$ip" ]]; then
                    ufw deny from "$ip"
                    success "IP $ip bloqueada."
                fi
                _press_enter
                ;;
            0) return ;;
            *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  BLOQUEO DE TORRENTS
# ╚══════════════════════════════════════════════════════════╝
handle_torrent() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── Bloqueo de Torrents ──────────────────────────────${NC}\n"

        # Verificar si ya hay reglas de torrent
        local bloqueado=false
        if iptables -L OUTPUT 2>/dev/null | grep -q "6881\|6969\|bittorrent"; then
            bloqueado=true
        fi

        if $bloqueado; then
            echo -e "  Estado: ${G}● Bloqueo ACTIVO${NC}"
        else
            echo -e "  Estado: ${R}● Sin bloqueo${NC}"
        fi
        echo ""
        echo -e "  ${W}[1]${NC} Activar bloqueo de torrents"
        echo -e "  ${W}[2]${NC} Desactivar bloqueo de torrents"
        echo -e "  ${W}[3]${NC} Ver reglas actuales"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""
        echo -e "  Selección: \c"; read -r opt

        case "$opt" in
            1)
                info "Aplicando reglas de bloqueo torrent..."
                # Puertos comunes de BitTorrent
                local torrent_ports=("6881:6889" "6969" "6881" "51413" "25565")
                for port in "${torrent_ports[@]}"; do
                    iptables -A OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
                    iptables -A OUTPUT -p udp --dport "$port" -j DROP 2>/dev/null || true
                    iptables -A INPUT  -p tcp --dport "$port" -j DROP 2>/dev/null || true
                    iptables -A INPUT  -p udp --dport "$port" -j DROP 2>/dev/null || true
                done

                # Bloquear por string (requiere módulo string)
                iptables -A FORWARD -m string --algo bm --string "BitTorrent" -j DROP 2>/dev/null || true
                iptables -A FORWARD -m string --algo bm --string "BitTorrent protocol" -j DROP 2>/dev/null || true

                # Guardar reglas
                if _cmd_exists "iptables-save"; then
                    iptables-save > /etc/iptables.rules 2>/dev/null || true
                fi

                success "Bloqueo de torrents activado."
                warn "Las reglas se perderán al reiniciar. Instala iptables-persistent para mantenerlas."
                _press_enter
                ;;
            2)
                info "Eliminando reglas de bloqueo torrent..."
                local torrent_ports=("6881:6889" "6969" "6881" "51413" "25565")
                for port in "${torrent_ports[@]}"; do
                    iptables -D OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
                    iptables -D OUTPUT -p udp --dport "$port" -j DROP 2>/dev/null || true
                    iptables -D INPUT  -p tcp --dport "$port" -j DROP 2>/dev/null || true
                    iptables -D INPUT  -p udp --dport "$port" -j DROP 2>/dev/null || true
                done
                iptables -D FORWARD -m string --algo bm --string "BitTorrent" -j DROP 2>/dev/null || true
                iptables -D FORWARD -m string --algo bm --string "BitTorrent protocol" -j DROP 2>/dev/null || true
                success "Bloqueo de torrents desactivado."
                _press_enter
                ;;
            3)
                echo ""
                echo -e "  ${Y}${BOLD}Reglas INPUT:${NC}"
                iptables -L INPUT --line-numbers 2>/dev/null | grep -E "6881|6969|51413|DROP" | while read -r line; do
                    echo -e "  ${DIM}$line${NC}"
                done || echo -e "  ${DIM}(sin reglas relevantes)${NC}"
                echo ""
                echo -e "  ${Y}${BOLD}Reglas OUTPUT:${NC}"
                iptables -L OUTPUT --line-numbers 2>/dev/null | grep -E "6881|6969|51413|DROP" | while read -r line; do
                    echo -e "  ${DIM}$line${NC}"
                done || echo -e "  ${DIM}(sin reglas relevantes)${NC}"
                _press_enter
                ;;
            0) return ;;
            *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ── Router principal ─────────────────────────────────────────
ACTION="${1:-}"
case "$ACTION" in
    fail2ban) handle_fail2ban ;;
    firewall) handle_firewall ;;
    torrent)  handle_torrent  ;;
    *)
        error "Acción no reconocida: '$ACTION'"
        echo -e "  Válidas: fail2ban firewall torrent"
        exit 1
        ;;
esac
