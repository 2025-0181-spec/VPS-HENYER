#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo HTTP Custom / HTTP Injector / Payload
#  (proxy Python para SSH sobre HTTP)
# ============================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

handle_http_custom() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── HTTP Custom / Payload / HTTP Injector ────────────${NC}\n"
        echo -e "  ${DIM}Permite conectar mediante apps como HTTP Injector,${NC}"
        echo -e "  ${DIM}HTTP Custom, NapsternetV, usando SSH sobre HTTP/WS.${NC}"
        echo ""

        # Estado y puerto actuales del proxy HTTP
        local proxy_port="8880" ws_status
        if [[ -f /etc/systemd/system/vps-http-proxy.service ]]; then
            proxy_port=$(grep -oP 'http_proxy\.py \K[0-9]+' /etc/systemd/system/vps-http-proxy.service 2>/dev/null || echo "8880")
        fi
        _service_active "vps-http-proxy" && ws_status="${G}● Activo (${proxy_port})${NC}" || ws_status="${R}● Inactivo${NC}"

        echo -e "  Estado proxy HTTP : $ws_status"
        echo ""
        echo -e "  ${W}[1]${NC} Instalar y activar proxy HTTP"
        echo -e "  ${W}[2]${NC} Configurar puerto del proxy HTTP (actual: ${proxy_port})"
        echo -e "  ${W}[3]${NC} Ver payload recomendado para HTTP Custom"
        echo -e "  ${W}[4]${NC} Activar / Desactivar proxy HTTP"
        echo -e "  ${DIM}[0]${NC} Volver"
        echo ""; echo -e "  Selección: \c"; read -r opt

        case "$opt" in
        1)
            clear
            echo -e "\n  ${W}${BOLD}── Instalando Proxy HTTP ────────────────────────────${NC}\n"
            _apt_install "python3"

            local set_port=8880
            local ssh_port; ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")

            mkdir -p /etc/vps-henyer

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
        while b"\\r\\n\\r\\n" not in req:
            chunk = client.recv(BUFFER)
            if not chunk: return
            req += chunk

        client.sendall(b"HTTP/1.1 200 Connection Established\\r\\nProxy-agent: VPS-HENYER\\r\\n\\r\\n")

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
            threading.Thread(target=handle_client, args=(client, addr), daemon=True).start()
        except KeyboardInterrupt: break
        except: pass

if __name__ == "__main__":
    main()
PYPROXY
            chmod +x /etc/vps-henyer/http_proxy.py

            cat > /etc/systemd/system/vps-http-proxy.service << SVCFILE
[Unit]
Description=VPS-HENYER HTTP Proxy (HTTP Custom / Injector)
After=network.target ssh.service
Wants=ssh.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vps-henyer/http_proxy.py $set_port $ssh_port
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
                success "Proxy HTTP activo en puerto ${set_port}"
                echo ""
                info "Configura tu app así:"
                echo -e "  ${W}Modo     :${NC} HTTP / HTTPS"
                echo -e "  ${W}Servidor :${NC} $(_get_ip)"
                echo -e "  ${W}Puerto   :${NC} ${set_port}"
                echo -e "  ${W}Payload  :${NC} GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]"
            else
                error "El proxy no pudo iniciarse. Revisa: journalctl -u vps-http-proxy -n 20"
            fi
            _press_enter
            ;;
        2)
            echo -e "  Nuevo puerto para proxy HTTP (actual ${proxy_port}): \c"; read -r nport
            if [[ "$nport" =~ ^[0-9]+$ ]] && (( nport > 0 && nport < 65536 )); then
                local ssh_port; ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
                if [[ -f /etc/systemd/system/vps-http-proxy.service ]]; then
                    sed -i "s|ExecStart=.*http_proxy.py.*|ExecStart=/usr/bin/python3 /etc/vps-henyer/http_proxy.py $nport $ssh_port|" \
                        /etc/systemd/system/vps-http-proxy.service
                    systemctl daemon-reload
                    systemctl restart vps-http-proxy 2>/dev/null
                    success "Proxy HTTP movido al puerto $nport"
                else
                    warn "Primero instala el proxy con la opción [1]."
                fi
            else
                error "Puerto inválido."
            fi
            _press_enter
            ;;
        3)
            clear
            echo -e "\n  ${W}${BOLD}── Payloads para HTTP Custom / HTTP Injector ─────────${NC}\n"
            local ip; ip=$(_get_ip)
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
            echo -e "  ${W}Proxy HTTP     :${NC} $ip:${proxy_port}"
            echo -e "  ${W}Tipo conexión  :${NC} HTTP / CONNECT"
            echo ""
            echo -e "  ${DIM}Nota: [crlf] = salto de línea (\\r\\n). En la app${NC}"
            echo -e "  ${DIM}HTTP Custom normalmente lo pones como texto literal.${NC}"
            _press_enter
            ;;
        4)
            if ! [[ -f /etc/systemd/system/vps-http-proxy.service ]]; then
                error "Proxy HTTP no instalado. Usa la opción [1]."
                _press_enter; continue
            fi
            _toggle_service "vps-http-proxy" "Proxy HTTP"
            _press_enter
            ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

handle_http_custom
