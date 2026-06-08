#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo de Protocolos
#  Llamado desde menu.sh: bash protocols.sh <protocolo>
# ============================================================

set -uo pipefail

# ── Colores ──────────────────────────────────────────────────
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'
C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'
BOLD='\033[1m'

info()    { echo -e "  ${C}[INFO]${NC} $*"; }
success() { echo -e "  ${G}[OK]${NC}   $*"; }
warn()    { echo -e "  ${Y}[WARN]${NC}  $*"; }
error()   { echo -e "  ${R}[ERR]${NC}  $*"; }
die()     { error "$*"; exit 1; }

_press_enter() { echo -e "\n  ${DIM}[Enter] para continuar...${NC}"; read -r; }
_service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
_cmd_exists()     { command -v "$1" &>/dev/null; }

# ── Toggle genérico de servicio systemd ─────────────────────
_toggle_service() {
    local svc="$1"
    local friendly="${2:-$svc}"
    if _service_active "$svc"; then
        info "Deteniendo $friendly..."
        systemctl stop "$svc" && systemctl disable "$svc"
        success "$friendly → DETENIDO"
    else
        info "Iniciando $friendly..."
        systemctl enable "$svc" && systemctl start "$svc"
        if _service_active "$svc"; then
            success "$friendly → ACTIVO"
        else
            error "$friendly no pudo iniciar. Revisa: journalctl -u $svc -n 30"
        fi
    fi
}

# ── Instalación segura de paquete APT ───────────────────────
_apt_install() {
    local pkg="$1"
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        info "$pkg ya está instalado."
        return 0
    fi
    info "Instalando $pkg..."
    apt-get update -qq && apt-get install -y -qq "$pkg" || die "No se pudo instalar $pkg"
    success "$pkg instalado."
}

# ╔══════════════════════════════════════════════════════════╗
#  GESTIÓN DE USUARIOS SSH
# ╚══════════════════════════════════════════════════════════╝
handle_ssh_users() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── Gestión de Usuarios SSH ──────────────────────────${NC}\n"
        echo -e "  ${W}[1]${NC} Crear usuario"
        echo -e "  ${W}[2]${NC} Listar usuarios"
        echo -e "  ${W}[3]${NC} Eliminar usuario"
        echo -e "  ${W}[4]${NC} Cambiar contraseña de usuario"
        echo -e "  ${W}[5]${NC} Ver expiración de usuario"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""
        echo -e "  Selección: \c"; read -r opt

        case "$opt" in
            1)
                clear
                echo -e "\n  ${W}${BOLD}── Crear Usuario SSH ────────────────────────────────${NC}\n"
                echo -e "  Nombre de usuario: \c"; read -r username

                # Validar nombre
                if [[ -z "$username" || ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                    error "Nombre inválido. Solo letras minúsculas, números, - y _"
                    _press_enter; continue
                fi

                if id "$username" &>/dev/null; then
                    error "El usuario '$username' ya existe."
                    _press_enter; continue
                fi

                echo -e "  Contraseña: \c"; read -rs password; echo
                if [[ -z "$password" ]]; then
                    error "La contraseña no puede estar vacía."
                    _press_enter; continue
                fi

                echo -e "  Días hasta expiración (0 = sin límite): \c"; read -r days

                # Crear usuario con shell bash
                useradd -m -s /bin/bash "$username" 2>/dev/null || die "Error al crear usuario"
                echo "$username:$password" | chpasswd

                # Aplicar expiración si se indicó
                if [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )); then
                    local exp_date
                    exp_date=$(date -d "+${days} days" +%Y-%m-%d)
                    chage -E "$exp_date" "$username"
                    success "Usuario '${username}' creado. Expira: ${exp_date}"
                else
                    success "Usuario '${username}' creado sin fecha de expiración."
                fi

                echo ""
                info "Puerto SSH actual: $(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo '22')"
                info "Conexión: ssh ${username}@$(curl -s --max-time 3 https://ipv4.icanhazip.com 2>/dev/null || echo 'TU_IP')"
                _press_enter
                ;;
            2)
                clear
                echo -e "\n  ${W}${BOLD}── Usuarios SSH del Sistema ─────────────────────────${NC}\n"
                printf "  %-18s %-8s %-20s %s\n" "USUARIO" "UID" "EXPIRA" "SHELL"
                echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
                while IFS=: read -r user _ uid _ _ _ shell; do
                    if [[ "$shell" == */bash || "$shell" == */sh ]] && (( uid >= 1000 )); then
                        local exp
                        exp=$(chage -l "$user" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
                        printf "  ${G}%-18s${NC} %-8s %-20s %s\n" "$user" "$uid" "$exp" "$shell"
                    fi
                done < /etc/passwd
                echo ""
                _press_enter
                ;;
            3)
                clear
                echo -e "\n  ${W}${BOLD}── Eliminar Usuario SSH ─────────────────────────────${NC}\n"
                echo -e "  Usuario a eliminar: \c"; read -r username

                if ! id "$username" &>/dev/null; then
                    error "El usuario '$username' no existe."
                    _press_enter; continue
                fi

                # Seguridad: no eliminar root ni usuarios del sistema
                local uid
                uid=$(id -u "$username" 2>/dev/null)
                if (( uid < 1000 )); then
                    error "No se puede eliminar usuario del sistema (UID < 1000)."
                    _press_enter; continue
                fi

                echo -e "  ${Y}⚠  ¿Eliminar '${username}' y su directorio home? [s/N]: \c"
                read -r confirm
                if [[ "${confirm,,}" == "s" ]]; then
                    # Cerrar sesiones activas del usuario
                    pkill -u "$username" 2>/dev/null || true
                    userdel -r "$username" 2>/dev/null
                    success "Usuario '$username' eliminado correctamente."
                else
                    info "Operación cancelada."
                fi
                _press_enter
                ;;
            4)
                clear
                echo -e "\n  ${W}${BOLD}── Cambiar Contraseña ───────────────────────────────${NC}\n"
                echo -e "  Nombre de usuario: \c"; read -r username

                if ! id "$username" &>/dev/null; then
                    error "El usuario '$username' no existe."
                    _press_enter; continue
                fi

                echo -e "  Nueva contraseña: \c"; read -rs password; echo
                if [[ -z "$password" ]]; then
                    error "La contraseña no puede estar vacía."
                    _press_enter; continue
                fi

                echo "$username:$password" | chpasswd
                success "Contraseña de '$username' actualizada."
                _press_enter
                ;;
            5)
                clear
                echo -e "\n  ${W}${BOLD}── Expiración de Usuario ────────────────────────────${NC}\n"
                echo -e "  Nombre de usuario: \c"; read -r username

                if ! id "$username" &>/dev/null; then
                    error "El usuario '$username' no existe."
                    _press_enter; continue
                fi

                echo ""
                chage -l "$username" | while IFS= read -r line; do
                    echo -e "  ${DIM}$line${NC}"
                done
                _press_enter
                ;;
            0) return ;;
            *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  HANDLERS DE PROTOCOLOS
# ╚══════════════════════════════════════════════════════════╝
handle_ssh() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── OpenSSH ──────────────────────────────────────────${NC}\n"

        if ! _cmd_exists "sshd"; then
            _apt_install "openssh-server"
        fi

        local status_ssh
        if systemctl is-active --quiet ssh 2>/dev/null; then
            status_ssh="${G}● ACTIVO${NC}"
        else
            status_ssh="${R}● INACTIVO${NC}"
        fi
        local puerto_ssh
        puerto_ssh=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo '22')

        echo -e "  Estado : $status_ssh"
        echo -e "  Puerto : ${W}${puerto_ssh}${NC}"
        echo ""
        echo -e "  ${W}[1]${NC} Activar / Desactivar SSH"
        echo -e "  ${W}[2]${NC} Cambiar puerto SSH"
        echo -e "  ${W}[3]${NC} Ver usuarios conectados ahora"
        echo -e "  ${W}[4]${NC} ${G}${BOLD}Gestión de usuarios SSH${NC}"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""
        echo -e "  Selección: \c"; read -r opt

        case "$opt" in
            1) _toggle_service "ssh" "OpenSSH"; _press_enter ;;
            2)
                echo -e "  Nuevo puerto: \c"; read -r port
                if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )); then
                    sed -i "s/^#*Port .*/Port $port/" /etc/ssh/sshd_config
                    systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null
                    success "Puerto SSH cambiado a $port"
                else
                    error "Puerto inválido: $port"
                fi
                _press_enter
                ;;
            3)
                echo ""
                info "Sesiones SSH activas:"
                who 2>/dev/null | grep -v "^$" || echo -e "  ${DIM}(ninguna sesión activa)${NC}"
                echo ""
                info "Últimos accesos:"
                last -n 5 2>/dev/null | head -6 || true
                _press_enter
                ;;
            4) handle_ssh_users ;;
            0) return ;;
            *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

handle_dropbear() {
    clear
    echo -e "\n  ${W}${BOLD}── Dropbear SSH ────────────────────────────────${NC}\n"
    if ! _cmd_exists "dropbear"; then
        echo -e "  Dropbear no está instalado."
        echo -e "  ${W}[1]${NC} Instalar ahora  ${DIM}[0]${NC} Cancelar"
        read -r opt
        [[ "$opt" == "1" ]] || return
        _apt_install "dropbear"
    fi
    echo -e "  ${W}[1]${NC} Activar / Desactivar Dropbear"
    echo -e "  ${W}[2]${NC} Cambiar puerto Dropbear"
    echo -e "  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r opt
    case "$opt" in
        1) _toggle_service "dropbear" "Dropbear" ;;
        2)
            echo -e "  Nuevo puerto: \c"; read -r port
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$port/" /etc/default/dropbear 2>/dev/null || true
                systemctl restart dropbear 2>/dev/null
                success "Dropbear en puerto $port"
            else
                error "Puerto inválido"
            fi
            ;;
        0) return ;;
    esac
    _press_enter
}

handle_openvpn() {
    clear
    echo -e "\n  ${W}${BOLD}── OpenVPN ──────────────────────────────────────${NC}\n"
    if ! _cmd_exists "openvpn"; then
        echo -e "  OpenVPN no está instalado."
        echo -e "  ${W}[1]${NC} Instalar con script automático  ${DIM}[0]${NC} Cancelar"
        read -r opt
        [[ "$opt" == "1" ]] || return
        info "Descargando instalador de OpenVPN..."
        curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh \
            && chmod +x openvpn-install.sh \
            && bash openvpn-install.sh
        return
    fi
    echo -e "  ${W}[1]${NC} Activar / Desactivar OpenVPN"
    echo -e "  ${W}[2]${NC} Gestionar clientes"
    echo -e "  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r opt
    case "$opt" in
        1) _toggle_service "openvpn" "OpenVPN" ;;
        2)
            if [[ -f /root/openvpn-install.sh ]]; then
                bash /root/openvpn-install.sh
            else
                warn "Script de gestión no encontrado en /root/openvpn-install.sh"
            fi
            ;;
        0) return ;;
    esac
    _press_enter
}

handle_xray() {
    clear
    echo -e "\n  ${W}${BOLD}── V2Ray / Xray ─────────────────────────────────${NC}\n"
    if ! _cmd_exists "xray"; then
        echo -e "  Xray no está instalado."
        echo -e "  ${W}[1]${NC} Instalar Xray oficial  ${DIM}[0]${NC} Cancelar"
        read -r opt
        [[ "$opt" == "1" ]] || return
        info "Instalando Xray..."
        bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) \
            || die "Falló la instalación de Xray"
        success "Xray instalado."
        return
    fi
    echo -e "  ${W}[1]${NC} Activar / Desactivar Xray"
    echo -e "  ${W}[2]${NC} Ver configuración actual"
    echo -e "  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r opt
    case "$opt" in
        1) _toggle_service "xray" "Xray" ;;
        2) cat /usr/local/etc/xray/config.json 2>/dev/null || warn "Config no encontrada." ;;
        0) return ;;
    esac
    _press_enter
}

handle_squid() {
    clear
    echo -e "\n  ${W}${BOLD}── Squid Proxy ──────────────────────────────────${NC}\n"
    if ! _cmd_exists "squid"; then
        echo -e "  ${W}[1]${NC} Instalar Squid  ${DIM}[0]${NC} Cancelar"
        read -r opt; [[ "$opt" == "1" ]] || return
        _apt_install "squid"
    fi
    echo -e "  ${W}[1]${NC} Activar / Desactivar Squid"
    echo -e "  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r opt
    case "$opt" in
        1) _toggle_service "squid" "Squid" ;;
        0) return ;;
    esac
    _press_enter
}

handle_trojan() {
    clear
    echo -e "\n  ${W}${BOLD}── Trojan-GO ─────────────────────────────────────${NC}\n"
    echo -e "  ${W}[1]${NC} Activar / Desactivar Trojan-GO"
    echo -e "  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r opt
    case "$opt" in
        1) _toggle_service "trojan-go" "Trojan-GO" ;;
        0) return ;;
    esac
    _press_enter
}

handle_ssr() {
    clear
    echo -e "\n  ${W}${BOLD}── ShadowsocksR ─────────────────────────────────${NC}\n"
    echo -e "  ${W}[1]${NC} Activar / Desactivar SSR"
    echo -e "  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r opt
    case "$opt" in
        1) _toggle_service "shadowsocksr" "ShadowsocksR" ;;
        0) return ;;
    esac
    _press_enter
}

handle_websocket() {
    clear
    echo -e "\n  ${W}${BOLD}── WebSocket + SSL/TLS ──────────────────────────${NC}\n"
    warn "Esta función requiere que Nginx o Xray estén instalados."
    echo -e "  ${W}[1]${NC} Configurar WebSocket TLS  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r opt
    case "$opt" in
        1) info "Módulo WS-TLS — Próximamente." ;;
        0) return ;;
    esac
    _press_enter
}

handle_psiphon() {
    clear
    echo -e "\n  ${W}${BOLD}── Psiphon ───────────────────────────────────────${NC}\n"
    echo -e "  ${W}[1]${NC} Activar / Desactivar Psiphon  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r opt
    case "$opt" in
        1) _toggle_service "psiphon" "Psiphon" ;;
        0) return ;;
    esac
    _press_enter
}

# ── Router principal ─────────────────────────────────────────
PROTOCOL="${1:-}"

case "$PROTOCOL" in
    ssh)       handle_ssh       ;;
    dropbear)  handle_dropbear  ;;
    openvpn)   handle_openvpn   ;;
    squid)     handle_squid     ;;
    xray)      handle_xray      ;;
    trojan)    handle_trojan    ;;
    ssr)       handle_ssr       ;;
    websocket) handle_websocket ;;
    psiphon)   handle_psiphon   ;;
    *)
        error "Protocolo no reconocido: '$PROTOCOL'"
        echo -e "  Válidos: ssh dropbear openvpn squid xray trojan ssr websocket psiphon"
        exit 1
        ;;
esac
