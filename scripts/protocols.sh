#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo de Protocolos COMPLETO
#  Incluye: SSH, Dropbear, OpenVPN, Squid, Xray,
#           Trojan-GO, SSR, WebSocket+TLS, Psiphon
#           HTTP Custom, Payload, Gestión de usuarios
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

            local pub_ip; pub_ip=$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo "TU_IP")
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
        echo -e "  ${W}[6]${NC} Configurar HTTP Custom (para apps como HTTP Injector)"
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
        6) handle_http_custom ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  HTTP CUSTOM / HTTP INJECTOR / PAYLOAD
# ╚══════════════════════════════════════════════════════════╝
handle_http_custom() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── HTTP Custom / Payload / HTTP Injector ────────────${NC}\n"
        echo -e "  ${DIM}Permite conectar mediante apps como HTTP Injector,${NC}"
        echo -e "  ${DIM}HTTP Custom, NapsternetV, usando SSH sobre HTTP/WS.${NC}"
        echo ""

        # Estado del proxy HTTP (BadVPN/Badvpn o script propio)
        local ws_status; _port_in_use "8880" && ws_status="${G}● Activo (8880)${NC}" || ws_status="${R}● Inactivo${NC}"

        echo -e "  Estado proxy HTTP : $ws_status"
        echo ""
        echo -e "  ${W}[1]${NC} Instalar y activar proxy HTTP (puerto 8880)"
        echo -e "  ${W}[2]${NC} Configurar puerto del proxy HTTP"
        echo -e "  ${W}[3]${NC} Ver payload recomendado para HTTP Custom"
        echo -e "  ${W}[4]${NC} Instalar WebSocket (badvpn-udpgw)"
        echo -e "  ${W}[5]${NC} Desactivar proxy HTTP"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""; echo -e "  Selección: \c"; read -r opt

        case "$opt" in
        1)
            clear
            echo -e "\n  ${W}${BOLD}── Instalando Proxy HTTP ────────────────────────────${NC}\n"
            _apt_install "python3"

            local proxy_port=8880
            local ssh_port; ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")

            # Crear script de proxy HTTP simple
            cat > /etc/vps-henyer/http_proxy.py << PYPROXY
#!/usr/bin/env python3
"""
VPS-HENYER — Proxy HTTP para SSH
Compatible con HTTP Injector, HTTP Custom, NapsternetV
"""
import socket, threading, select, sys

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8880
SSH_HOST    = "127.0.0.1"
SSH_PORT    = int(sys.argv[2]) if len(sys.argv) > 2 else $ssh_port
BUFFER      = 4096

def log(msg):
    import datetime
    print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)

def forward(src, dst):
    try:
        while True:
            r, _, _ = select.select([src, dst], [], [], 60)
            if not r: break
            for s in r:
                data = s.recv(BUFFER)
                if not data: return
                (dst if s is src else src).sendall(data)
    except: pass
    finally:
        for s in (src, dst): 
            try: s.close()
            except: pass

def handle_client(client):
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = client.recv(BUFFER)
            if not chunk: return
            req += chunk

        # Responder con 200 Connection Established
        client.sendall(b"HTTP/1.1 200 Connection Established\r\nProxy-agent: VPS-HENYER\r\n\r\n")

        # Conectar al SSH real
        ssh = socket.create_connection((SSH_HOST, SSH_PORT))
        log(f"Nueva conexión → SSH:{SSH_PORT}")
        threading.Thread(target=forward, args=(client, ssh), daemon=True).start()
        forward(ssh, client)
    except Exception as e:
        log(f"Error: {e}")
        try: client.close()
        except: pass

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", LISTEN_PORT))
    srv.listen(200)
    log(f"HTTP Proxy escuchando en :{LISTEN_PORT} → SSH:{SSH_PORT}")
    while True:
        try:
            client, addr = srv.accept()
            threading.Thread(target=handle_client, args=(client,), daemon=True).start()
        except KeyboardInterrupt: break
        except: pass

if __name__ == "__main__":
    main()
PYPROXY
            chmod +x /etc/vps-henyer/http_proxy.py

            # Crear servicio systemd
            cat > /etc/systemd/system/vps-http-proxy.service << SVCFILE
[Unit]
Description=VPS-HENYER HTTP Proxy (HTTP Custom / Injector)
After=network.target ssh.service
Wants=ssh.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vps-henyer/http_proxy.py $proxy_port $ssh_port
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCFILE

            systemctl daemon-reload
            systemctl enable vps-http-proxy
            systemctl restart vps-http-proxy

            if _service_active "vps-http-proxy"; then
                success "Proxy HTTP activo en puerto ${proxy_port}"
                echo ""
                info "Configura tu app así:"
                echo -e "  ${W}Modo     :${NC} HTTP / HTTPS"
                echo -e "  ${W}Servidor :${NC} $(curl -s --max-time 3 https://ipv4.icanhazip.com 2>/dev/null || echo 'TU_IP')"
                echo -e "  ${W}Puerto   :${NC} ${proxy_port}"
                echo -e "  ${W}Payload  :${NC} GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]"
            else
                error "El proxy no pudo iniciarse. Revisa: journalctl -u vps-http-proxy -n 20"
            fi
            _press_enter
            ;;
        2)
            echo -e "  Nuevo puerto para proxy HTTP (actual 8880): \c"; read -r nport
            if [[ "$nport" =~ ^[0-9]+$ ]] && (( nport > 0 && nport < 65536 )); then
                local ssh_port; ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
                sed -i "s|ExecStart=.*http_proxy.py.*|ExecStart=/usr/bin/python3 /etc/vps-henyer/http_proxy.py $nport $ssh_port|" \
                    /etc/systemd/system/vps-http-proxy.service 2>/dev/null || true
                systemctl daemon-reload
                systemctl restart vps-http-proxy 2>/dev/null
                success "Proxy HTTP movido al puerto $nport"
            else
                error "Puerto inválido."
            fi
            _press_enter
            ;;
        3)
            clear
            echo -e "\n  ${W}${BOLD}── Payloads para HTTP Custom / HTTP Injector ─────────${NC}\n"
            local ip; ip=$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo "TU_IP")
            local ssh_port; ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")

            echo -e "  ${Y}${BOLD}── Payload 1: CONNECT directo ──────────────────────${NC}"
            echo -e "  ${DIM}CONNECT $ip:$ssh_port HTTP/1.1[crlf]Host: $ip[crlf][crlf]${NC}"
            echo ""
            echo -e "  ${Y}${BOLD}── Payload 2: GET con Upgrade (WebSocket) ───────────${NC}"
            echo -e "  ${DIM}GET / HTTP/1.1[crlf]Host: $ip[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]${NC}"
            echo ""
            echo -e "  ${Y}${BOLD}── Payload 3: Para HTTP Injector ────────────────────${NC}"
            echo -e "  ${DIM}CONNECT $ip:[port] HTTP/1.0[crlf][crlf]${NC}"
            echo ""
            echo -e "  ${Y}${BOLD}── Configuración recomendada en la app ──────────────${NC}"
            echo -e "  ${W}Servidor SSH   :${NC} $ip"
            echo -e "  ${W}Puerto SSH     :${NC} $ssh_port"
            echo -e "  ${W}Proxy HTTP     :${NC} $ip:8880"
            echo -e "  ${W}Tipo conexión  :${NC} HTTP / CONNECT"
            echo ""
            echo -e "  ${DIM}Nota: [crlf] = salto de línea (\\r\\n). En la app${NC}"
            echo -e "  ${DIM}HTTP Custom normalmente lo pones como texto literal.${NC}"
            _press_enter
            ;;
        4)
            clear
            echo -e "\n  ${W}${BOLD}── Instalar BadVPN-UDPGW (WebSocket UDP) ─────────────${NC}\n"
            info "Instalando dependencias..."
            _apt_install "cmake"
            _apt_install "build-essential"

            if _cmd_exists "badvpn-udpgw"; then
                success "badvpn-udpgw ya está instalado."
            else
                info "Compilando badvpn..."
                cd /tmp || exit 1
                rm -rf badvpn 2>/dev/null || true
                if ! git clone --depth=1 https://github.com/ambrop72/badvpn.git 2>/dev/null; then
                    warn "No se pudo clonar badvpn. Intentando instalación alternativa..."
                    # Intentar desde repositorio alternativo
                    apt-get install -y -qq badvpn 2>/dev/null || \
                        error "No se pudo instalar badvpn. Intenta manualmente."
                else
                    mkdir -p /tmp/badvpn/build && cd /tmp/badvpn/build
                    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null 2>&1
                    make -j"$(nproc)" > /dev/null 2>&1
                    if [[ -f /tmp/badvpn/build/udpgw/badvpn-udpgw ]]; then
                        cp /tmp/badvpn/build/udpgw/badvpn-udpgw /usr/local/bin/
                        success "badvpn-udpgw instalado."
                    else
                        error "Compilación fallida."
                    fi
                fi
            fi

            # Crear servicio para badvpn-udpgw
            if _cmd_exists "badvpn-udpgw"; then
                cat > /etc/systemd/system/badvpn-udpgw.service << 'BADVPNSVC'
[Unit]
Description=BadVPN UDPGW
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500 --max-connections-for-client 10
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
BADVPNSVC
                systemctl daemon-reload
                systemctl enable badvpn-udpgw
                systemctl restart badvpn-udpgw
                _service_active "badvpn-udpgw" && success "badvpn-udpgw activo en 127.0.0.1:7300" || warn "Revisa: journalctl -u badvpn-udpgw"
            fi
            _press_enter
            ;;
        5)
            systemctl stop vps-http-proxy 2>/dev/null && systemctl disable vps-http-proxy 2>/dev/null
            success "Proxy HTTP desactivado."
            _press_enter
            ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  BADVPN-UDPGW — MÓDULO COMPLETO (Llamadas VoIP / UDP)
# ╚══════════════════════════════════════════════════════════╝
handle_badvpn() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── BadVPN-UDPGW  (UDP para llamadas VoIP) ───────────${NC}\n"
        echo -e "  ${DIM}BadVPN-UDPGW permite túneles UDP sobre SSH.${NC}"
        echo -e "  ${DIM}Necesario para llamadas WhatsApp/Telegram con HTTP Custom.${NC}"
        echo ""

        # ─ Estado actual ──────────────────────────────────
        local udpgw_bin="" udpgw_status="" udpgw_port="7300"
        _cmd_exists "badvpn-udpgw" && udpgw_bin="/usr/local/bin/badvpn-udpgw"
        [[ -z "$udpgw_bin" && -f /usr/bin/badvpn-udpgw ]] && udpgw_bin="/usr/bin/badvpn-udpgw"

        if [[ -n "$udpgw_bin" ]]; then
            if _service_active "badvpn-udpgw"; then
                udpgw_status="${G}● ACTIVO${NC}"
                udpgw_port=$(grep -oP '\-\-listen-addr 127\.0\.0\.1:\K[0-9]+' \
                    /etc/systemd/system/badvpn-udpgw.service 2>/dev/null || echo "7300")
            else
                udpgw_status="${Y}● INSTALADO / INACTIVO${NC}"
            fi
        else
            udpgw_status="${R}● NO INSTALADO${NC}"
        fi

        echo -e "  Estado      : $udpgw_status"
        echo -e "  Puerto UDPGW: ${W}127.0.0.1:${udpgw_port}${NC}  ${DIM}(local, para clientes SSH)${NC}"
        echo ""
        echo -e "  ${W}[1]${NC} Instalar BadVPN-UDPGW"
        echo -e "  ${W}[2]${NC} Activar / Desactivar servicio"
        echo -e "  ${W}[3]${NC} Cambiar puerto UDPGW"
        echo -e "  ${W}[4]${NC} Ver log en tiempo real"
        echo -e "  ${W}[5]${NC} Mostrar guía de configuración en la app"
        echo -e "  ${W}[6]${NC} Desinstalar BadVPN-UDPGW"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""; echo -e "  Selección: \c"; read -r opt

        case "$opt" in
        1)
            clear
            echo -e "\n  ${W}${BOLD}── Instalando BadVPN-UDPGW ──────────────────────────${NC}\n"

            if [[ -n "$udpgw_bin" ]]; then
                success "badvpn-udpgw ya está instalado en: $udpgw_bin"
                _press_enter; continue
            fi

            # Método 1: apt (Ubuntu/Debian repos)
            info "Intentando instalación desde repositorio..."
            if apt-get install -y -qq badvpn 2>/dev/null; then
                success "badvpn instalado via apt."
            else
                # Método 2: compilar desde fuente
                info "Compilando desde fuente (puede tomar 2-3 min)..."
                _apt_install "cmake"
                _apt_install "build-essential"
                _apt_install "git"

                cd /tmp || exit 1
                rm -rf badvpn-src 2>/dev/null || true

                if git clone --depth=1 https://github.com/ambrop72/badvpn.git badvpn-src 2>/dev/null; then
                    mkdir -p /tmp/badvpn-src/build
                    cd /tmp/badvpn-src/build
                    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null 2>&1
                    make -j"$(nproc)" > /dev/null 2>&1
                    if [[ -f udpgw/badvpn-udpgw ]]; then
                        cp udpgw/badvpn-udpgw /usr/local/bin/
                        chmod +x /usr/local/bin/badvpn-udpgw
                        udpgw_bin="/usr/local/bin/badvpn-udpgw"
                        success "badvpn-udpgw compilado e instalado."
                    else
                        error "Compilación fallida. Verifica gcc/cmake."
                        _press_enter; continue
                    fi
                else
                    # Método 3: binario precompilado
                    warn "git clone fallido. Intentando binario precompilado..."
                    if wget -q -O /usr/local/bin/badvpn-udpgw \
                        "https://github.com/Towerism/badvpn/releases/download/1.999.130/badvpn-udpgw" 2>/dev/null; then
                        chmod +x /usr/local/bin/badvpn-udpgw
                        udpgw_bin="/usr/local/bin/badvpn-udpgw"
                        success "Binario precompilado instalado."
                    else
                        error "No se pudo instalar badvpn-udpgw por ningún método."
                        warn "Intenta: apt-get install badvpn manualmente."
                        _press_enter; continue
                    fi
                fi
            fi

            # Crear servicio systemd
            cat > /etc/systemd/system/badvpn-udpgw.service << 'UDPGWSVC'
[Unit]
Description=BadVPN UDPGW — UDP Gateway para VoIP/llamadas SSH
After=network.target
Documentation=https://github.com/ambrop72/badvpn

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw \
    --listen-addr 127.0.0.1:7300 \
    --max-clients 500 \
    --max-connections-for-client 10
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UDPGWSVC

            systemctl daemon-reload
            systemctl enable badvpn-udpgw
            systemctl start badvpn-udpgw
            sleep 1
            if _service_active "badvpn-udpgw"; then
                success "badvpn-udpgw activo en 127.0.0.1:7300"
                echo ""
                echo -e "  ${Y}${BOLD}⟶  SIGUIENTE PASO:${NC}"
                echo -e "  ${DIM}En tu app (HTTP Custom / HTTP Injector / NapsternetV)${NC}"
                echo -e "  ${DIM}activa la opción UDP/VoIP y pon el puerto: 7300${NC}"
            else
                warn "Servicio no inició. Revisa: journalctl -u badvpn-udpgw -n 20"
            fi
            _press_enter
            ;;
        2)
            if [[ -z "$udpgw_bin" ]]; then
                error "BadVPN no está instalado. Usa la opción [1]."
                _press_enter; continue
            fi
            if _service_active "badvpn-udpgw"; then
                systemctl stop badvpn-udpgw && systemctl disable badvpn-udpgw 2>/dev/null
                success "badvpn-udpgw → DETENIDO"
            else
                systemctl enable badvpn-udpgw && systemctl start badvpn-udpgw 2>/dev/null
                sleep 1
                _service_active "badvpn-udpgw" && success "badvpn-udpgw → ACTIVO (127.0.0.1:7300)" \
                    || error "No pudo iniciar. Revisa: journalctl -u badvpn-udpgw"
            fi
            _press_enter
            ;;
        3)
            echo -e "  Nuevo puerto UDPGW (actual: ${udpgw_port}): \c"; read -r nport
            if [[ "$nport" =~ ^[0-9]+$ ]] && (( nport > 1024 && nport < 65535 )); then
                sed -i "s/127\.0\.0\.1:[0-9]*/127.0.0.1:$nport/" \
                    /etc/systemd/system/badvpn-udpgw.service 2>/dev/null || true
                systemctl daemon-reload
                systemctl restart badvpn-udpgw 2>/dev/null
                success "Puerto UDPGW cambiado a $nport"
            else
                error "Puerto inválido (usa 1025-65534)."
            fi
            _press_enter
            ;;
        4)
            echo -e "\n  ${DIM}Log en tiempo real (Ctrl+C para salir)...${NC}\n"
            journalctl -u badvpn-udpgw -f --no-pager 2>/dev/null || \
                warn "journalctl no disponible."
            ;;
        5)
            clear
            echo -e "\n  ${W}${BOLD}── Guía: Activar llamadas VoIP en tu app ─────────────${NC}\n"
            local ip; ip=$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo "TU_IP")
            local ssh_port; ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
            local cur_port; cur_port=$(grep -oP '\-\-listen-addr 127\.0\.0\.1:\K[0-9]+' \
                /etc/systemd/system/badvpn-udpgw.service 2>/dev/null || echo "7300")

            echo -e "  ${Y}${BOLD}╔═ CONFIGURACIÓN PARA HTTP CUSTOM ══════════════════╗${NC}"
            echo -e "  ${Y}│${NC}"
            echo -e "  ${Y}│${NC}  1. Abre HTTP Custom → pestaña SSH"
            echo -e "  ${Y}│${NC}  2. Servidor: ${W}${ip}:8880${NC}  (o tu dominio)"
            echo -e "  ${Y}│${NC}  3. Usuario SSH y contraseña"
            echo -e "  ${Y}│${NC}  4. Activa: ${W}\"Use Payload\"${NC}"
            echo -e "  ${Y}│${NC}  5. Para llamadas: activa ${W}\"UDP Custom\"${NC}"
            echo -e "  ${Y}│${NC}     Puerto UDP: ${W}${cur_port}${NC}"
            echo -e "  ${Y}│${NC}  6. Payload sugerido:"
            echo -e "  ${Y}│${NC}     ${DIM}GET / HTTP/1.1[crlf]Host: ${ip}[crlf]"
            echo -e "  ${Y}│${NC}     ${DIM}Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]${NC}"
            echo -e "  ${Y}│${NC}"
            echo -e "  ${Y}${BOLD}╠═ CONFIGURACIÓN PARA HTTP INJECTOR ════════════════╣${NC}"
            echo -e "  ${Y}│${NC}"
            echo -e "  ${Y}│${NC}  SSH Server  : ${W}${ip}${NC}"
            echo -e "  ${Y}│${NC}  SSH Port    : ${W}${ssh_port}${NC}"
            echo -e "  ${Y}│${NC}  Proxy Host  : ${W}${ip}${NC}"
            echo -e "  ${Y}│${NC}  Proxy Port  : ${W}8880${NC}"
            echo -e "  ${Y}│${NC}  Payload Type: ${W}Default / CONNECT${NC}"
            echo -e "  ${Y}│${NC}  UDPGW Port  : ${W}${cur_port}${NC}  ← para VoIP"
            echo -e "  ${Y}│${NC}"
            echo -e "  ${Y}${BOLD}╠═ NAPSTERNETV ══════════════════════════════════════╣${NC}"
            echo -e "  ${Y}│${NC}"
            echo -e "  ${Y}│${NC}  Modo        : ${W}SSH${NC}"
            echo -e "  ${Y}│${NC}  Host        : ${W}${ip}${NC}"
            echo -e "  ${Y}│${NC}  Puerto      : ${W}${ssh_port}${NC}"
            echo -e "  ${Y}│${NC}  SNI/Host    : tu dominio (si tienes)"
            echo -e "  ${Y}│${NC}  BadVPN Port : ${W}${cur_port}${NC}  ← para llamadas"
            echo -e "  ${Y}${BOLD}╚═══════════════════════════════════════════════════╝${NC}"
            echo ""
            warn "BadVPN debe estar ACTIVO en el servidor para que funcionen las llamadas."
            _press_enter
            ;;
        6)
            echo -e "  ${R}⚠  ¿Desinstalar badvpn-udpgw? [s/N]: \c"; read -r confirm
            if [[ "${confirm,,}" == "s" ]]; then
                systemctl stop badvpn-udpgw 2>/dev/null || true
                systemctl disable badvpn-udpgw 2>/dev/null || true
                rm -f /etc/systemd/system/badvpn-udpgw.service
                rm -f /usr/local/bin/badvpn-udpgw /usr/bin/badvpn-udpgw 2>/dev/null || true
                systemctl daemon-reload
                success "badvpn-udpgw desinstalado."
            else
                info "Cancelado."
            fi
            _press_enter
            ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  XRAY / V2RAY — WIZARD COMPLETO PASO A PASO
# ╚══════════════════════════════════════════════════════════╝
handle_xray() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── V2Ray / Xray ──────────────────────────────────────${NC}\n"

        local xray_bin=""
        _cmd_exists "xray"   && xray_bin="xray"
        _cmd_exists "v2ray"  && [[ -z "$xray_bin" ]] && xray_bin="v2ray"

        local xray_status
        if _service_active "xray"; then
            xray_status="${G}● ACTIVO (xray)${NC}"
        elif _service_active "v2ray"; then
            xray_status="${G}● ACTIVO (v2ray)${NC}"
        elif [[ -n "$xray_bin" ]]; then
            xray_status="${Y}● INSTALADO / INACTIVO${NC}"
        else
            xray_status="${R}● NO INSTALADO${NC}"
        fi

        echo -e "  Estado: $xray_status"
        echo ""
        echo -e "  ${W}[1]${NC} ${G}${BOLD}Instalar Xray${NC} (oficial XTLS)"
        echo -e "  ${W}[2]${NC} ${G}${BOLD}Configurar protocolo${NC} (Wizard paso a paso)"
        echo -e "  ${W}[3]${NC} Activar / Desactivar Xray"
        echo -e "  ${W}[4]${NC} Ver configuración actual"
        echo -e "  ${W}[5]${NC} Ver QR / datos de conexión para cliente"
        echo -e "  ${W}[6]${NC} Ver log en tiempo real"
        echo -e "  ${W}[7]${NC} Reiniciar Xray"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""; echo -e "  Selección: \c"; read -r opt

        case "$opt" in
        1) _xray_install ;;
        2) _xray_wizard  ;;
        3)
            local svc="xray"
            _service_active "v2ray" && svc="v2ray"
            if _service_active "$svc"; then
                systemctl stop "$svc" && systemctl disable "$svc" 2>/dev/null
                success "Xray → DETENIDO"
            else
                systemctl enable "$svc" && systemctl start "$svc" 2>/dev/null
                sleep 1
                _service_active "$svc" && success "Xray → ACTIVO" || error "No pudo iniciar. Usa [6] para ver el log."
            fi
            _press_enter
            ;;
        4)
            echo ""
            local cfg="/usr/local/etc/xray/config.json"
            [[ -f "$cfg" ]] || cfg="/etc/xray/config.json"
            if [[ -f "$cfg" ]]; then
                cat "$cfg" | while read -r line; do echo -e "  ${DIM}$line${NC}"; done
            else
                warn "No hay config instalada. Usa [2] para configurar."
            fi
            _press_enter
            ;;
        5) _xray_show_client ;;
        6)
            echo -e "\n  ${DIM}Log en tiempo real (Ctrl+C para salir)...${NC}\n"
            local svc="xray"; _service_active "v2ray" && svc="v2ray"
            journalctl -u "$svc" -f --no-pager 2>/dev/null || warn "journalctl no disponible."
            ;;
        7)
            local svc="xray"; _service_active "v2ray" && svc="v2ray"
            systemctl restart "$svc" 2>/dev/null
            sleep 1
            _service_active "$svc" && success "$svc reiniciado." || error "No pudo reiniciar."
            _press_enter
            ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ── Instalar Xray ────────────────────────────────────────────
_xray_install() {
    clear
    echo -e "\n  ${W}${BOLD}── Instalar Xray (XTLS oficial) ──────────────────────${NC}\n"

    if _cmd_exists "xray"; then
        local ver; ver=$(xray version 2>/dev/null | head -1 || echo "desconocida")
        success "Xray ya está instalado. ($ver)"
        echo -e "  ${W}[1]${NC} Reinstalar/Actualizar  ${DIM}[0]${NC} Cancelar"
        echo -e "  Selección: \c"; read -r o
        [[ "$o" == "1" ]] || { _press_enter; return; }
    fi

    info "Descargando instalador oficial de Xray (XTLS)..."
    if bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) 2>/dev/null; then
        success "Xray instalado correctamente."
        local ver; ver=$(xray version 2>/dev/null | head -1 || echo "instalado")
        info "Versión: $ver"
        echo ""
        echo -e "  ${Y}⟶  Ahora ve al menú [2] para configurar el protocolo.${NC}"
    else
        error "Falló la instalación automática."
        warn "Intenta manualmente:"
        echo -e "  ${DIM}bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)${NC}"
    fi
    _press_enter
}

# ── Wizard de configuración V2Ray/Xray ───────────────────────
_xray_wizard() {
    clear
    echo -e "\n  ${W}${BOLD}── Wizard V2Ray/Xray: Elige protocolo ────────────────${NC}\n"
    echo -e "  ${DIM}Cada protocolo tiene su caso de uso. Elige el que${NC}"
    echo -e "  ${DIM}mejor se adapte a tu situación.${NC}"
    echo ""
    echo -e "  ${W}[1]${NC} ${G}VMess + WebSocket + TLS${NC}  ${DIM}(recomendado, muy compatible)${NC}"
    echo -e "  ${W}[2]${NC} ${G}VMess + TCP${NC}               ${DIM}(rápido, sin dominio necesario)${NC}"
    echo -e "  ${W}[3]${NC} ${G}VLESS + WebSocket + TLS${NC}   ${DIM}(más ligero que VMess)${NC}"
    echo -e "  ${W}[4]${NC} ${G}VLESS + Reality${NC}           ${DIM}(máxima evasión, avanzado)${NC}"
    echo -e "  ${W}[5]${NC} ${G}Trojan + WebSocket + TLS${NC}  ${DIM}(parece HTTPS legítimo)${NC}"
    echo -e "  ${DIM}[0]${NC} Volver"
    echo ""; echo -e "  Selección: \c"; read -r proto_opt

    case "$proto_opt" in
        1) _xray_config_vmess_ws_tls ;;
        2) _xray_config_vmess_tcp    ;;
        3) _xray_config_vless_ws_tls ;;
        4) _xray_config_vless_reality ;;
        5) _xray_config_trojan_ws_tls ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
    esac
}

# ── Generar UUID ────────────────────────────────────────────
_gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null \
        || uuidgen 2>/dev/null \
        || echo "$(date +%s)-$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 12)"
}

# ── Paso común: preguntar puerto ────────────────────────────
_ask_port() {
    local default="$1" label="${2:-Puerto}"
    local port
    while true; do
        echo -e "  ${label} [default: ${default}]: \c"; read -r port
        port="${port:-$default}"
        if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port < 65536 )); then
            echo "$port"; return 0
        fi
        warn "Puerto inválido. Usa un número entre 1 y 65535."
    done
}

# ── Guardar y aplicar config ────────────────────────────────
_xray_apply_config() {
    local config_json="$1"
    local cfg_dir="/usr/local/etc/xray"
    mkdir -p "$cfg_dir"
    echo "$config_json" > "$cfg_dir/config.json"

    # Validar JSON con xray si disponible
    if _cmd_exists "xray"; then
        if xray run -test -config "$cfg_dir/config.json" &>/dev/null; then
            success "Configuración JSON válida."
        else
            warn "Posible error en el JSON. Revisa con: xray run -test -config $cfg_dir/config.json"
        fi
    fi

    systemctl daemon-reload
    systemctl enable xray 2>/dev/null || true
    systemctl restart xray 2>/dev/null || true
    sleep 2

    if _service_active "xray"; then
        success "Xray reiniciado con nueva configuración."
    else
        error "Xray no pudo iniciar. Revisa el log:"
        echo -e "  ${DIM}journalctl -u xray -n 30${NC}"
    fi
}

# ╔══════════════════════════════════════════════════════════╗
#  WIZARD 1: VMess + WebSocket + TLS
# ╚══════════════════════════════════════════════════════════╝
_xray_config_vmess_ws_tls() {
    clear
    echo -e "\n  ${W}${BOLD}── Configurar VMess + WebSocket + TLS ────────────────${NC}\n"
    echo -e "  ${DIM}PASO 1/4: Datos básicos${NC}\n"

    # Paso 1: UUID
    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID generado: ${G}${uuid}${NC}"
    echo -e "  ¿Usar este UUID? [S/n]: \c"; read -r ans
    if [[ "${ans,,}" == "n" ]]; then
        echo -e "  Escribe tu UUID: \c"; read -r uuid
    fi

    # Paso 2: Puerto de escucha
    echo ""
    echo -e "  ${DIM}PASO 2/4: Puerto${NC}\n"
    local port; port=$(_ask_port "443" "Puerto de escucha (443 recomendado con TLS)")

    # Paso 3: Dominio y TLS
    echo ""
    echo -e "  ${DIM}PASO 3/4: Dominio y certificado TLS${NC}\n"
    echo -e "  Dominio (ej: midominio.com) o IP del servidor: \c"; read -r domain
    domain="${domain:-$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo 'TU_DOMINIO')}"

    local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local key_path="/etc/letsencrypt/live/${domain}/privkey.pem"
    local use_tls="true"

    if [[ ! -f "$cert_path" ]]; then
        warn "No se encontró certificado Let's Encrypt para: $domain"
        echo -e "  ${W}[1]${NC} Obtener certificado ahora (certbot)  ${W}[2]${NC} Usar rutas manuales  ${W}[3]${NC} Sin TLS (inseguro)"
        echo -e "  Selección: \c"; read -r tls_opt
        case "$tls_opt" in
            1)
                _apt_install "certbot"
                certbot certonly --standalone -d "$domain" --non-interactive --agree-tos --email "admin@${domain}" 2>/dev/null \
                    || certbot certonly --standalone -d "$domain"
                if [[ -f "$cert_path" ]]; then
                    success "Certificado obtenido para $domain"
                else
                    warn "No se pudo obtener el certificado. Continuando sin TLS."
                    use_tls="false"
                fi
                ;;
            2)
                echo -e "  Ruta al certificado (.crt/.pem): \c"; read -r cert_path
                echo -e "  Ruta a la clave privada (.key/.pem): \c"; read -r key_path
                [[ -f "$cert_path" && -f "$key_path" ]] || { warn "Archivos no encontrados. Continuando sin TLS."; use_tls="false"; }
                ;;
            3) use_tls="false" ;;
        esac
    else
        success "Certificado Let's Encrypt encontrado para $domain."
    fi

    # Paso 4: Path WebSocket
    echo ""
    echo -e "  ${DIM}PASO 4/4: Path WebSocket${NC}\n"
    echo -e "  Path WebSocket [default: /ws]: \c"; read -r ws_path
    ws_path="${ws_path:-/ws}"
    [[ "$ws_path" != /* ]] && ws_path="/$ws_path"

    # Construir JSON
    local tls_block=""
    if [[ "$use_tls" == "true" ]]; then
        tls_block=$(cat << TLSJ
    "security": "tls",
    "tlsSettings": {
      "certificates": [
        {
          "certificateFile": "$cert_path",
          "keyFile": "$key_path"
        }
      ]
    },
TLSJ
)
    fi

    local config_json
    config_json=$(cat << VJSON
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        $tls_block
        "wsSettings": {
          "path": "$ws_path"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
VJSON
)

    echo ""
    info "Aplicando configuración VMess + WS + TLS..."
    mkdir -p /var/log/xray
    _xray_apply_config "$config_json"

    # Guardar datos del cliente
    cat > /etc/vps-henyer/xray_client.txt << CLIENTDATA
PROTOCOLO=VMess+WebSocket+TLS
DIRECCION=$domain
PUERTO=$port
UUID=$uuid
ALTERID=0
RED=ws
SEGURIDAD=$([ "$use_tls" == "true" ] && echo "tls" || echo "none")
PATH_WS=$ws_path
CLIENTDATA

    _xray_show_client
}

# ╔══════════════════════════════════════════════════════════╗
#  WIZARD 2: VMess + TCP
# ╚══════════════════════════════════════════════════════════╝
_xray_config_vmess_tcp() {
    clear
    echo -e "\n  ${W}${BOLD}── Configurar VMess + TCP ────────────────────────────${NC}\n"
    echo -e "  ${DIM}Sin dominio ni TLS. Más simple, menos ofuscado.${NC}\n"

    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID: ${G}${uuid}${NC}"
    echo -e "  ¿Personalizar UUID? [s/N]: \c"; read -r ans
    [[ "${ans,,}" == "s" ]] && { echo -e "  UUID: \c"; read -r uuid; }

    local port; port=$(_ask_port "10086" "Puerto de escucha")

    local config_json
    config_json=$(cat << VTCPJSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $port,
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "$uuid", "alterId": 0}]
      },
      "streamSettings": {"network": "tcp"}
    }
  ],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
VTCPJSON
)
    info "Aplicando configuración VMess + TCP..."
    _xray_apply_config "$config_json"

    cat > /etc/vps-henyer/xray_client.txt << CD
PROTOCOLO=VMess+TCP
DIRECCION=$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo 'TU_IP')
PUERTO=$port
UUID=$uuid
ALTERID=0
RED=tcp
SEGURIDAD=none
CD
    _xray_show_client
}

# ╔══════════════════════════════════════════════════════════╗
#  WIZARD 3: VLESS + WebSocket + TLS
# ╚══════════════════════════════════════════════════════════╝
_xray_config_vless_ws_tls() {
    clear
    echo -e "\n  ${W}${BOLD}── Configurar VLESS + WebSocket + TLS ───────────────${NC}\n"
    echo -e "  ${DIM}Más eficiente que VMess. Requiere dominio con TLS.${NC}\n"

    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID: ${G}${uuid}${NC}"
    echo -e "  ¿Personalizar UUID? [s/N]: \c"; read -r ans
    [[ "${ans,,}" == "s" ]] && { echo -e "  UUID: \c"; read -r uuid; }

    local port; port=$(_ask_port "443" "Puerto de escucha")
    echo -e "  Dominio: \c"; read -r domain
    domain="${domain:-$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo 'TU_DOMINIO')}"
    echo -e "  Path WebSocket [/vless]: \c"; read -r ws_path
    ws_path="${ws_path:-/vless}"
    [[ "$ws_path" != /* ]] && ws_path="/$ws_path"

    local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local key_path="/etc/letsencrypt/live/${domain}/privkey.pem"

    if [[ ! -f "$cert_path" ]]; then
        warn "Certificado TLS no encontrado para $domain."
        echo -e "  Ruta cert (.pem): \c"; read -r cert_path
        echo -e "  Ruta key  (.pem): \c"; read -r key_path
    fi

    local config_json
    config_json=$(cat << VLESSJSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$uuid", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {"certificateFile": "$cert_path", "keyFile": "$key_path"}
          ]
        },
        "wsSettings": {"path": "$ws_path"}
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
VLESSJSON
)
    info "Aplicando configuración VLESS + WS + TLS..."
    _xray_apply_config "$config_json"

    cat > /etc/vps-henyer/xray_client.txt << CD
PROTOCOLO=VLESS+WebSocket+TLS
DIRECCION=$domain
PUERTO=$port
UUID=$uuid
RED=ws
SEGURIDAD=tls
PATH_WS=$ws_path
CD
    _xray_show_client
}

# ╔══════════════════════════════════════════════════════════╗
#  WIZARD 4: VLESS + Reality
# ╚══════════════════════════════════════════════════════════╝
_xray_config_vless_reality() {
    clear
    echo -e "\n  ${W}${BOLD}── Configurar VLESS + Reality ────────────────────────${NC}\n"
    echo -e "  ${DIM}El protocolo más difícil de detectar. Sin necesidad de dominio propio.${NC}"
    echo -e "  ${DIM}Usa el certificado TLS de otro sitio legítimo como pantalla.${NC}\n"

    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID: ${G}${uuid}${NC}"
    echo -e "  ¿Personalizar UUID? [s/N]: \c"; read -r ans
    [[ "${ans,,}" == "s" ]] && { echo -e "  UUID: \c"; read -r uuid; }

    local port; port=$(_ask_port "443" "Puerto de escucha")
    echo -e "  Destino Reality (SNI, ej: www.microsoft.com): \c"; read -r sni
    sni="${sni:-www.microsoft.com}"

    # Generar par de claves para Reality
    local keys_output=""
    if _cmd_exists "xray"; then
        keys_output=$(xray x25519 2>/dev/null || echo "")
    fi

    local priv_key pub_key short_id
    priv_key=$(echo "$keys_output" | grep -i "private" | awk '{print $NF}' || echo "")
    pub_key=$(echo  "$keys_output" | grep -i "public"  | awk '{print $NF}' || echo "")
    short_id=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 8)

    if [[ -z "$priv_key" ]]; then
        warn "No se pudieron generar claves automáticamente."
        echo -e "  Clave privada (private key): \c"; read -r priv_key
        echo -e "  Clave pública (public key) : \c"; read -r pub_key
        [[ -z "$short_id" ]] && short_id="$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 8)"
    else
        success "Par de claves X25519 generado."
        echo -e "  ${W}Private Key:${NC} ${DIM}$priv_key${NC}"
        echo -e "  ${W}Public Key :${NC} ${G}$pub_key${NC}  ${DIM}← para el cliente${NC}"
    fi

    local config_json
    config_json=$(cat << REALITYJSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$sni:443",
          "xver": 0,
          "serverNames": ["$sni"],
          "privateKey": "$priv_key",
          "shortIds": ["$short_id"]
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
REALITYJSON
)
    info "Aplicando configuración VLESS + Reality..."
    _xray_apply_config "$config_json"

    cat > /etc/vps-henyer/xray_client.txt << CD
PROTOCOLO=VLESS+Reality
DIRECCION=$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo 'TU_IP')
PUERTO=$port
UUID=$uuid
FLOW=xtls-rprx-vision
RED=tcp
SEGURIDAD=reality
PUBLIC_KEY=$pub_key
SHORT_ID=$short_id
SNI=$sni
FINGERPRINT=chrome
CD
    _xray_show_client
}

# ╔══════════════════════════════════════════════════════════╗
#  WIZARD 5: Trojan + WebSocket + TLS
# ╚══════════════════════════════════════════════════════════╝
_xray_config_trojan_ws_tls() {
    clear
    echo -e "\n  ${W}${BOLD}── Configurar Trojan + WebSocket + TLS ──────────────${NC}\n"
    echo -e "  ${DIM}Trojan se disfraza de tráfico HTTPS real. Muy evasivo.${NC}\n"

    echo -e "  Contraseña Trojan: \c"; read -rs trojan_pass; echo
    [[ -z "$trojan_pass" ]] && trojan_pass="$(_gen_uuid | cut -c1-16)"
    echo -e "  Contraseña configurada: ${G}${trojan_pass}${NC}"

    local port; port=$(_ask_port "443" "Puerto de escucha")
    echo -e "  Dominio (requerido para TLS): \c"; read -r domain
    domain="${domain:-$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo 'TU_DOMINIO')}"
    echo -e "  Path WebSocket [/trojan]: \c"; read -r ws_path
    ws_path="${ws_path:-/trojan}"
    [[ "$ws_path" != /* ]] && ws_path="/$ws_path"

    local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local key_path="/etc/letsencrypt/live/${domain}/privkey.pem"
    if [[ ! -f "$cert_path" ]]; then
        warn "Certificado no encontrado para $domain."
        echo -e "  Ruta cert: \c"; read -r cert_path
        echo -e "  Ruta key : \c"; read -r key_path
    fi

    local config_json
    config_json=$(cat << TROJANJSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $port,
      "protocol": "trojan",
      "settings": {
        "clients": [{"password": "$trojan_pass"}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {"certificateFile": "$cert_path", "keyFile": "$key_path"}
          ]
        },
        "wsSettings": {"path": "$ws_path"}
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
TROJANJSON
)
    info "Aplicando configuración Trojan + WS + TLS..."
    _xray_apply_config "$config_json"

    cat > /etc/vps-henyer/xray_client.txt << CD
PROTOCOLO=Trojan+WebSocket+TLS
DIRECCION=$domain
PUERTO=$port
PASSWORD=$trojan_pass
RED=ws
SEGURIDAD=tls
PATH_WS=$ws_path
CD
    _xray_show_client
}

# ── Mostrar datos del cliente ─────────────────────────────────
_xray_show_client() {
    clear
    echo -e "\n  ${W}${BOLD}── Datos de conexión para el cliente ─────────────────${NC}\n"

    local client_file="/etc/vps-henyer/xray_client.txt"
    if [[ ! -f "$client_file" ]]; then
        warn "No hay configuración guardada. Usa el Wizard primero."; _press_enter; return
    fi

    # Leer variables del archivo
    # shellcheck disable=SC1090
    source <(grep -E '^[A-Z_]+=.' "$client_file" 2>/dev/null || true)

    echo -e "  ${Y}${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "  ${Y}║          DATOS DE CONEXIÓN — VPS-HENYER          ║${NC}"
    echo -e "  ${Y}╠═══════════════════════════════════════════════════╣${NC}"
    echo -e "  ${Y}║${NC}"
    echo -e "  ${Y}║${NC}  Protocolo  : ${W}${PROTOCOLO:-N/A}${NC}"
    echo -e "  ${Y}║${NC}  Servidor   : ${W}${DIRECCION:-N/A}${NC}"
    echo -e "  ${Y}║${NC}  Puerto     : ${W}${PUERTO:-N/A}${NC}"
    [[ -n "${UUID:-}" ]]        && echo -e "  ${Y}║${NC}  UUID       : ${G}${UUID}${NC}"
    [[ -n "${PASSWORD:-}" ]]    && echo -e "  ${Y}║${NC}  Password   : ${G}${PASSWORD}${NC}"
    [[ -n "${ALTERID:-}" ]]     && echo -e "  ${Y}║${NC}  Alter ID   : ${W}${ALTERID}${NC}"
    echo -e "  ${Y}║${NC}  Red        : ${W}${RED:-N/A}${NC}"
    echo -e "  ${Y}║${NC}  Seguridad  : ${W}${SEGURIDAD:-none}${NC}"
    [[ -n "${PATH_WS:-}" ]]     && echo -e "  ${Y}║${NC}  WS Path    : ${W}${PATH_WS}${NC}"
    [[ -n "${SNI:-}" ]]         && echo -e "  ${Y}║${NC}  SNI        : ${W}${SNI}${NC}"
    [[ -n "${PUBLIC_KEY:-}" ]]  && echo -e "  ${Y}║${NC}  Public Key : ${G}${PUBLIC_KEY}${NC}"
    [[ -n "${SHORT_ID:-}" ]]    && echo -e "  ${Y}║${NC}  Short ID   : ${W}${SHORT_ID}${NC}"
    [[ -n "${FLOW:-}" ]]        && echo -e "  ${Y}║${NC}  Flow       : ${W}${FLOW}${NC}"
    [[ -n "${FINGERPRINT:-}" ]] && echo -e "  ${Y}║${NC}  Fingerprint: ${W}${FINGERPRINT}${NC}"
    echo -e "  ${Y}║${NC}"
    echo -e "  ${Y}╠═══════════════════════════════════════════════════╣${NC}"
    echo -e "  ${Y}║${NC}  ${DIM}Apps compatibles: v2rayNG, v2rayN, NekoBox,${NC}"
    echo -e "  ${Y}║${NC}  ${DIM}Hiddify, Shadowrocket, V2Box, Streisand${NC}"
    echo -e "  ${Y}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    # Generar link VMess si aplica
    if [[ "${PROTOCOLO:-}" == VMess* ]]; then
        local vmess_json
        vmess_json=$(python3 -c "
import json, base64
d = {
    'v': '2', 'ps': 'VPS-HENYER', 'add': '${DIRECCION:-}',
    'port': '${PUERTO:-0}', 'id': '${UUID:-}', 'aid': '${ALTERID:-0}',
    'net': '${RED:-tcp}', 'type': 'none', 'host': '${DIRECCION:-}',
    'path': '${PATH_WS:-/}', 'tls': '${SEGURIDAD:-none}'
}
print('vmess://' + base64.b64encode(json.dumps(d).encode()).decode())
" 2>/dev/null || echo "")
        if [[ -n "$vmess_json" ]]; then
            echo -e "  ${C}${BOLD}Link VMess (copia en tu app):${NC}"
            echo -e "  ${G}$vmess_json${NC}"
            echo ""
        fi
    fi

    # Link VLESS
    if [[ "${PROTOCOLO:-}" == VLESS* && "${SEGURIDAD:-}" != "reality" ]]; then
        local vless_link="vless://${UUID:-}@${DIRECCION:-}:${PUERTO:-443}?encryption=none&security=${SEGURIDAD:-none}&type=${RED:-tcp}&path=${PATH_WS:-/}#VPS-HENYER"
        echo -e "  ${C}${BOLD}Link VLESS:${NC}"
        echo -e "  ${G}${vless_link}${NC}"
        echo ""
    fi

    # Link VLESS Reality
    if [[ "${SEGURIDAD:-}" == "reality" ]]; then
        local reality_link="vless://${UUID:-}@${DIRECCION:-}:${PUERTO:-443}?encryption=none&flow=${FLOW:-}&security=reality&sni=${SNI:-}&fp=${FINGERPRINT:-chrome}&pbk=${PUBLIC_KEY:-}&sid=${SHORT_ID:-}&type=tcp#VPS-HENYER"
        echo -e "  ${C}${BOLD}Link VLESS+Reality:${NC}"
        echo -e "  ${G}${reality_link}${NC}"
        echo ""
    fi

    # Link Trojan
    if [[ "${PROTOCOLO:-}" == Trojan* ]]; then
        local trojan_link="trojan://${PASSWORD:-}@${DIRECCION:-}:${PUERTO:-443}?security=${SEGURIDAD:-tls}&type=${RED:-ws}&path=${PATH_WS:-/}#VPS-HENYER"
        echo -e "  ${C}${BOLD}Link Trojan:${NC}"
        echo -e "  ${G}${trojan_link}${NC}"
        echo ""
    fi

    _press_enter
}
# ╚══════════════════════════════════════════════════════════╝
handle_websocket() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── WebSocket + SSL/TLS ──────────────────────────────${NC}\n"

        local ws_status nginx_status
        _port_in_use "80"  && nginx_status="${G}● Activo${NC}" || nginx_status="${R}● Inactivo${NC}"
        _port_in_use "443" && ws_status="${G}● SSL Activo${NC}" || ws_status="${R}● SSL Inactivo${NC}"

        echo -e "  Nginx/HTTP  : $nginx_status"
        echo -e "  SSL/HTTPS   : $ws_status"
        echo ""
        echo -e "  ${W}[1]${NC} Instalar Nginx + WebSocket proxy"
        echo -e "  ${W}[2]${NC} Configurar SSL/TLS con Let's Encrypt"
        echo -e "  ${W}[3]${NC} Ver configuración WebSocket actual"
        echo -e "  ${W}[4]${NC} Activar / Desactivar Nginx"
        echo -e "  ${W}[5]${NC} Mostrar datos de conexión WS"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""; echo -e "  Selección: \c"; read -r opt

        case "$opt" in
        1)
            clear
            echo -e "\n  ${W}${BOLD}── Instalando Nginx + WebSocket ─────────────────────${NC}\n"
            _apt_install "nginx"

            local ssh_port; ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")

            # Configurar Nginx como proxy WebSocket para SSH
            cat > /etc/nginx/conf.d/vps-websocket.conf << NGINXCONF
# VPS-HENYER — WebSocket proxy para SSH
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${ssh_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 10s;
    }

    # Puerto 8880 como alternativa
    location /ssh {
        proxy_pass http://127.0.0.1:${ssh_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
}
NGINXCONF

            nginx -t 2>/dev/null && systemctl restart nginx && systemctl enable nginx
            _service_active "nginx" && success "Nginx + WebSocket activo en puerto 80" || error "Nginx no pudo iniciar."
            echo ""
            info "Conexión WS desde tu app:"
            echo -e "  ${W}ws://$(curl -s --max-time 3 https://ipv4.icanhazip.com 2>/dev/null || echo 'TU_IP'):80/${NC}"
            _press_enter
            ;;
        2)
            clear
            echo -e "\n  ${W}${BOLD}── SSL/TLS con Let's Encrypt ────────────────────────${NC}\n"
            _apt_install "certbot"
            _apt_install "python3-certbot-nginx"
            echo -e "  Dominio (ej: midominio.com): \c"; read -r domain
            if [[ -n "$domain" ]]; then
                certbot --nginx -d "$domain" --non-interactive --agree-tos --email "admin@${domain}" 2>/dev/null || \
                certbot --nginx -d "$domain"
                success "SSL configurado para $domain"
                echo -e "  ${W}WSS URL: wss://${domain}/${NC}"
            else
                error "Debes ingresar un dominio válido."
            fi
            _press_enter
            ;;
        3)
            echo ""
            if [[ -f /etc/nginx/conf.d/vps-websocket.conf ]]; then
                cat /etc/nginx/conf.d/vps-websocket.conf | while read -r line; do
                    echo -e "  ${DIM}$line${NC}"
                done
            else
                warn "No hay configuración WebSocket instalada. Usa opción [1]."
            fi
            _press_enter
            ;;
        4)
            _cmd_exists "nginx" || { error "Nginx no instalado. Usa opción [1]."; _press_enter; continue; }
            _toggle_service "nginx" "Nginx"
            _press_enter
            ;;
        5)
            clear
            echo -e "\n  ${W}${BOLD}── Datos de Conexión WebSocket ──────────────────────${NC}\n"
            local ip; ip=$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo "TU_IP")
            local ssh_port; ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
            echo -e "  ${Y}${BOLD}Para HTTP Custom / HTTP Injector / NapsternetV:${NC}"
            echo ""
            echo -e "  ${W}Tipo conexión :${NC} WebSocket"
            echo -e "  ${W}Servidor      :${NC} $ip"
            echo -e "  ${W}Puerto WS     :${NC} 80"
            echo -e "  ${W}Puerto WSS    :${NC} 443 (si tienes dominio+SSL)"
            echo -e "  ${W}Puerto SSH    :${NC} $ssh_port"
            echo -e "  ${W}Path WS       :${NC} /"
            echo ""
            echo -e "  ${Y}${BOLD}Payload sugerido:${NC}"
            echo -e "  ${DIM}GET / HTTP/1.1[crlf]"
            echo -e "  Host: $ip[crlf]"
            echo -e "  Upgrade: websocket[crlf]"
            echo -e "  Connection: Upgrade[crlf][crlf]${NC}"
            _press_enter
            ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  DROPBEAR
# ╚══════════════════════════════════════════════════════════╝
handle_dropbear() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── Dropbear SSH ─────────────────────────────────────${NC}\n"

        if ! _cmd_exists "dropbear"; then
            echo -e "  Dropbear no instalado.  ${W}[1]${NC} Instalar  ${DIM}[0]${NC} Volver"
            echo -e "  Selección: \c"; read -r o
            [[ "$o" == "1" ]] && _apt_install "dropbear" || return
            _press_enter; continue
        fi

        local db_port; db_port=$(grep "^DROPBEAR_PORT" /etc/default/dropbear 2>/dev/null | cut -d= -f2 || echo "2222")
        _service_active "dropbear" && local st="${G}● ACTIVO${NC}" || local st="${R}● INACTIVO${NC}"
        echo -e "  Estado: $st  Puerto: ${W}${db_port}${NC}\n"
        echo -e "  ${W}[1]${NC} Activar / Desactivar  ${W}[2]${NC} Cambiar puerto  ${DIM}[0]${NC} Volver"
        echo -e "  Selección: \c"; read -r o

        case "$o" in
            1) _toggle_service "dropbear" "Dropbear"; _press_enter ;;
            2)
                echo -e "  Nuevo puerto: \c"; read -r port
                [[ "$port" =~ ^[0-9]+$ ]] && {
                    sed -i "s/^DROPBEAR_PORT=.*/DROPBEAR_PORT=$port/" /etc/default/dropbear 2>/dev/null || true
                    systemctl restart dropbear 2>/dev/null; success "Dropbear en puerto $port"
                } || error "Puerto inválido."
                _press_enter
                ;;
            0) return ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  OPENVPN
# ╚══════════════════════════════════════════════════════════╝
handle_openvpn() {
    clear
    echo -e "\n  ${W}${BOLD}── OpenVPN ───────────────────────────────────────────${NC}\n"
    if ! _cmd_exists "openvpn"; then
        echo -e "  OpenVPN no instalado.  ${W}[1]${NC} Instalar  ${DIM}[0]${NC} Cancelar"
        echo -e "  Selección: \c"; read -r o
        [[ "$o" == "1" ]] || return
        curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh \
            && chmod +x openvpn-install.sh && bash openvpn-install.sh; return
    fi
    echo -e "  ${W}[1]${NC} Activar/Desactivar  ${W}[2]${NC} Gestionar clientes  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r o
    case "$o" in
        1) _toggle_service "openvpn" "OpenVPN" ;;
        2) [[ -f /root/openvpn-install.sh ]] && bash /root/openvpn-install.sh || warn "Script no encontrado." ;;
        0) return ;;
    esac
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  SQUID PROXY
# ╚══════════════════════════════════════════════════════════╝
handle_squid() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── Squid Proxy ──────────────────────────────────────${NC}\n"
        _cmd_exists "squid" || { echo -e "  ${W}[1]${NC} Instalar Squid  ${DIM}[0]${NC} Volver"; read -r o; [[ "$o" == "1" ]] && _apt_install "squid" || return; }
        _service_active "squid" && local st="${G}● ACTIVO${NC}" || local st="${R}● INACTIVO${NC}"
        local sq_port; sq_port=$(grep -E "^http_port" /etc/squid/squid.conf 2>/dev/null | awk '{print $2}' | head -1 || echo "3128")
        echo -e "  Estado: $st  Puerto: ${W}${sq_port}${NC}\n"
        echo -e "  ${W}[1]${NC} Activar/Desactivar  ${W}[2]${NC} Cambiar puerto  ${DIM}[0]${NC} Volver"
        echo -e "  Selección: \c"; read -r o
        case "$o" in
            1) _toggle_service "squid" "Squid"; _press_enter ;;
            2)
                echo -e "  Nuevo puerto: \c"; read -r port
                [[ "$port" =~ ^[0-9]+$ ]] && {
                    sed -i "s/^http_port.*/http_port $port/" /etc/squid/squid.conf 2>/dev/null
                    systemctl restart squid 2>/dev/null; success "Squid en puerto $port"
                } || error "Puerto inválido."
                _press_enter
                ;;
            0) return ;;
        esac
    done
}

# ── Router principal ─────────────────────────────────────────
PROTOCOL="${1:-}"
case "$PROTOCOL" in
    ssh)         handle_ssh         ;;
    dropbear)    handle_dropbear    ;;
    openvpn)     handle_openvpn     ;;
    squid)       handle_squid       ;;
    xray)        handle_xray        ;;
    trojan)      handle_trojan      ;;
    ssr)         handle_ssr         ;;
    websocket)   handle_websocket   ;;
    psiphon)     handle_psiphon     ;;
    http-custom) handle_http_custom ;;
    badvpn)      handle_badvpn      ;;
    *)
        error "Protocolo no reconocido: '$PROTOCOL'"
        echo -e "  Válidos: ssh dropbear openvpn squid xray trojan ssr websocket psiphon http-custom badvpn"
        exit 1
        ;;
esac
