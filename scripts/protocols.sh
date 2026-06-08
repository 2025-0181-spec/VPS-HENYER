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
#  WEBSOCKET + SSL/TLS
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

# ╔══════════════════════════════════════════════════════════╗
#  XRAY / V2RAY
# ╚══════════════════════════════════════════════════════════╝
handle_xray() {
    clear
    echo -e "\n  ${W}${BOLD}── V2Ray / Xray ──────────────────────────────────────${NC}\n"
    if ! _cmd_exists "xray"; then
        echo -e "  Xray no instalado.  ${W}[1]${NC} Instalar  ${DIM}[0]${NC} Cancelar"
        echo -e "  Selección: \c"; read -r o
        [[ "$o" == "1" ]] || return
        bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) || die "Falló instalación de Xray"
        return
    fi
    echo -e "  ${W}[1]${NC} Activar/Desactivar  ${W}[2]${NC} Ver config  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r o
    case "$o" in
        1) _toggle_service "xray" "Xray" ;;
        2) cat /usr/local/etc/xray/config.json 2>/dev/null || warn "Config no encontrada." ;;
        0) return ;;
    esac
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  TROJAN-GO
# ╚══════════════════════════════════════════════════════════╝
handle_trojan() {
    clear
    echo -e "\n  ${W}${BOLD}── Trojan-GO ─────────────────────────────────────────${NC}\n"
    echo -e "  ${W}[1]${NC} Activar/Desactivar  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r o
    [[ "$o" == "1" ]] && _toggle_service "trojan-go" "Trojan-GO"
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  SHADOWSOCKSR
# ╚══════════════════════════════════════════════════════════╝
handle_ssr() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── ShadowsocksR ─────────────────────────────────────${NC}\n"

        if ! _cmd_exists "ssserver" && ! _service_active "shadowsocksr"; then
            echo -e "  ShadowsocksR no está instalado."
            echo -e "  ${W}[1]${NC} Instalar ShadowsocksR  ${DIM}[0]${NC} Volver"
            echo -e "  Selección: \c"; read -r o
            case "$o" in
                1)
                    info "Instalando ShadowsocksR..."
                    _apt_install "python3-pip"
                    pip3 install shadowsocks 2>/dev/null || true
                    # Intentar script de teddysun
                    if wget -q --spider https://raw.githubusercontent.com/teddysun/shadowsocks_install/master/shadowsocksR.sh 2>/dev/null; then
                        wget -qN https://raw.githubusercontent.com/teddysun/shadowsocks_install/master/shadowsocksR.sh
                        chmod +x shadowsocksR.sh && bash shadowsocksR.sh
                    else
                        warn "Script de instalación no disponible."
                        info "Instalando shadowsocks-libev como alternativa..."
                        _apt_install "shadowsocks-libev"
                    fi
                    ;;
                0) return ;;
            esac
            _press_enter; continue
        fi

        _service_active "shadowsocksr" && local st="${G}● ACTIVO${NC}" || local st="${R}● INACTIVO${NC}"
        echo -e "  Estado: $st\n"
        echo -e "  ${W}[1]${NC} Activar/Desactivar  ${DIM}[0]${NC} Volver"
        echo -e "  Selección: \c"; read -r o
        case "$o" in
            1) _toggle_service "shadowsocksr" "ShadowsocksR"; _press_enter ;;
            0) return ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  PSIPHON
# ╚══════════════════════════════════════════════════════════╝
handle_psiphon() {
    clear
    echo -e "\n  ${W}${BOLD}── Psiphon ───────────────────────────────────────────${NC}\n"
    echo -e "  ${W}[1]${NC} Activar/Desactivar  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r o
    [[ "$o" == "1" ]] && _toggle_service "psiphon" "Psiphon"
    _press_enter
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
    *)
        error "Protocolo no reconocido: '$PROTOCOL'"
        echo -e "  Válidos: ssh dropbear openvpn squid xray trojan ssr websocket psiphon http-custom"
        exit 1
        ;;
esac
