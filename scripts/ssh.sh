#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo SSH (OpenSSH + Gestión de usuarios)
# ============================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

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
        echo -e "  ${W}[4]${NC} Cambiar contraseña"
        echo -e "  ${W}[5]${NC} Ver expiración"
        echo -e "  ${W}[6]${NC} Extender expiración"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""; echo -e "  Selección: \c"; read -r opt

        case "$opt" in
        1)
            clear
            echo -e "\n  ${W}${BOLD}── Crear Usuario SSH ────────────────────────────────${NC}\n"
            echo -e "  Nombre de usuario: \c"; read -r username
            if [[ -z "$username" || ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                error "Nombre inválido. Solo letras minúsculas, números, - y _"; _press_enter; continue
            fi
            if id "$username" &>/dev/null; then
                error "El usuario '$username' ya existe."; _press_enter; continue
            fi
            echo -e "  Contraseña: \c"; read -rs password; echo
            [[ -z "$password" ]] && { error "Contraseña vacía."; _press_enter; continue; }
            echo -e "  Días hasta expiración (0 = sin límite): \c"; read -r days

            useradd -m -s /bin/bash "$username" || die "Error al crear usuario"
            echo "$username:$password" | chpasswd

            if [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )); then
                local exp_date; exp_date=$(date -d "+${days} days" +%Y-%m-%d)
                chage -E "$exp_date" "$username"
                success "Usuario '${username}' creado. Expira: ${exp_date}"
            else
                success "Usuario '${username}' creado sin expiración."
            fi

            local pub_ip; pub_ip=$(_get_ip)
            local ssh_port; ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
            echo ""
            info "Datos de conexión:"
            echo -e "  ${W}IP     :${NC} $pub_ip"
            echo -e "  ${W}Puerto :${NC} $ssh_port"
            echo -e "  ${W}Usuario:${NC} $username"
            echo -e "  ${W}Clave  :${NC} $password"
            _press_enter
            ;;
        2)
            clear
            echo -e "\n  ${W}${BOLD}── Usuarios SSH del Sistema ─────────────────────────${NC}\n"
            printf "  ${Y}%-20s %-8s %-22s %s${NC}\n" "USUARIO" "UID" "EXPIRA" "SHELL"
            echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
            while IFS=: read -r user _ uid _ _ _ shell; do
                if [[ "$shell" == */bash || "$shell" == */sh ]] && (( uid >= 1000 )); then
                    local exp; exp=$(chage -l "$user" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
                    printf "  ${G}%-20s${NC} %-8s %-22s %s\n" "$user" "$uid" "$exp" "$shell"
                fi
            done < /etc/passwd
            echo ""; _press_enter
            ;;
        3)
            clear
            echo -e "\n  ${W}${BOLD}── Eliminar Usuario SSH ─────────────────────────────${NC}\n"
            echo -e "  Usuario a eliminar: \c"; read -r username
            if ! id "$username" &>/dev/null; then
                error "Usuario '$username' no existe."; _press_enter; continue
            fi
            local uid; uid=$(id -u "$username" 2>/dev/null)
            if (( uid < 1000 )); then
                error "No se puede eliminar usuario del sistema."; _press_enter; continue
            fi
            echo -e "  ${Y}⚠  ¿Eliminar '${username}' y su home? [s/N]: \c"; read -r confirm
            if [[ "${confirm,,}" == "s" ]]; then
                pkill -u "$username" 2>/dev/null || true
                userdel -r "$username" 2>/dev/null
                success "Usuario '$username' eliminado."
            else
                info "Cancelado."
            fi
            _press_enter
            ;;
        4)
            clear
            echo -e "\n  ${W}${BOLD}── Cambiar Contraseña ───────────────────────────────${NC}\n"
            echo -e "  Usuario: \c"; read -r username
            if ! id "$username" &>/dev/null; then
                error "Usuario no existe."; _press_enter; continue
            fi
            echo -e "  Nueva contraseña: \c"; read -rs password; echo
            [[ -z "$password" ]] && { error "Vacía."; _press_enter; continue; }
            echo "$username:$password" | chpasswd
            success "Contraseña de '$username' actualizada."
            _press_enter
            ;;
        5)
            clear
            echo -e "\n  ${W}${BOLD}── Expiración de Usuario ────────────────────────────${NC}\n"
            echo -e "  Usuario: \c"; read -r username
            if ! id "$username" &>/dev/null; then
                error "Usuario no existe."; _press_enter; continue
            fi
            echo ""
            chage -l "$username" 2>/dev/null | while IFS= read -r line; do
                echo -e "  ${DIM}$line${NC}"
            done
            _press_enter
            ;;
        6)
            clear
            echo -e "\n  ${W}${BOLD}── Extender Expiración ──────────────────────────────${NC}\n"
            echo -e "  Usuario: \c"; read -r username
            if ! id "$username" &>/dev/null; then
                error "Usuario no existe."; _press_enter; continue
            fi
            echo -e "  Días adicionales: \c"; read -r days
            if [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )); then
                local current_exp; current_exp=$(chage -l "$username" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
                if [[ "$current_exp" == "never" || -z "$current_exp" ]]; then
                    warn "El usuario no tiene fecha de expiración. Se asignará desde hoy."
                    local new_exp; new_exp=$(date -d "+${days} days" +%Y-%m-%d)
                else
                    local new_exp; new_exp=$(date -d "$current_exp +${days} days" +%Y-%m-%d 2>/dev/null || date -d "+${days} days" +%Y-%m-%d)
                fi
                chage -E "$new_exp" "$username"
                success "Expiración de '$username' extendida hasta: $new_exp"
            else
                error "Número de días inválido."
            fi
            _press_enter
            ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  SSH PRINCIPAL
# ╚══════════════════════════════════════════════════════════╝
handle_ssh() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── OpenSSH / SSH ────────────────────────────────────${NC}\n"

        _cmd_exists "sshd" || _apt_install "openssh-server"

        local ssh_port; ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
        local status_txt
        _service_active "ssh" && status_txt="${G}● ACTIVO${NC}" || status_txt="${R}● INACTIVO${NC}"

        echo -e "  Estado  : $status_txt"
        echo -e "  Puerto  : ${W}${ssh_port}${NC}"
        echo ""
        echo -e "  ${W}[1]${NC} Activar / Desactivar SSH"
        echo -e "  ${W}[2]${NC} Cambiar puerto SSH"
        echo -e "  ${W}[3]${NC} ${G}${BOLD}Gestión de usuarios (crear/listar/eliminar)${NC}"
        echo -e "  ${W}[4]${NC} Ver sesiones activas"
        echo -e "  ${W}[5]${NC} Configurar acceso por contraseña"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""; echo -e "  Selección: \c"; read -r opt

        case "$opt" in
        1) _toggle_service "ssh" "OpenSSH"; _press_enter ;;
        2)
            echo -e "  Nuevo puerto (actual: $ssh_port): \c"; read -r port
            if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )); then
                if grep -qiE "^Port " /etc/ssh/sshd_config; then
                    sed -i "s/^Port .*/Port $port/" /etc/ssh/sshd_config
                else
                    sed -i "s/^#Port .*/Port $port/" /etc/ssh/sshd_config
                    grep -qiE "^Port " /etc/ssh/sshd_config || echo "Port $port" >> /etc/ssh/sshd_config
                fi
                systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null
                success "Puerto SSH cambiado a $port"
            else
                error "Puerto inválido."
            fi
            _press_enter
            ;;
        3) handle_ssh_users ;;
        4)
            clear
            echo -e "\n  ${W}${BOLD}── Sesiones SSH Activas ─────────────────────────────${NC}\n"
            echo -e "  ${Y}Usuarios conectados:${NC}"
            who 2>/dev/null | while read -r line; do echo -e "  ${G}●${NC} $line"; done || echo -e "  ${DIM}(ninguna)${NC}"
            echo ""
            echo -e "  ${Y}Últimos accesos:${NC}"
            last -n 8 2>/dev/null | head -9 | while read -r line; do echo -e "  ${DIM}$line${NC}"; done
            _press_enter
            ;;
        5)
            clear
            echo -e "\n  ${W}${BOLD}── Acceso por Contraseña ────────────────────────────${NC}\n"
            local current_val; current_val=$(grep -iE "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "yes")
            info "Estado actual: ${W}PasswordAuthentication ${current_val}${NC}"
            echo ""
            echo -e "  ${W}[1]${NC} Habilitar (yes)  ${W}[2]${NC} Deshabilitar (no)  ${DIM}[0]${NC} Volver"
            echo -e "  Selección: \c"; read -r o
            case "$o" in
                1) sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
                   systemctl reload ssh 2>/dev/null; success "PasswordAuthentication → yes" ;;
                2) sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
                   systemctl reload ssh 2>/dev/null; success "PasswordAuthentication → no" ;;
                0) continue ;;
            esac
            _press_enter
            ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

handle_ssh
