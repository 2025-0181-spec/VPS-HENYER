#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo Proxy Python (HTTP Custom / WS)
#  Módulo independiente: scripts/proxy_python.sh
#  Llamado desde menu.sh:  bash proxy_python.sh
#
#  Modos soportados (igual que VPS-MX):
#    [1] Proxy SIMPLE      — response 200
#    [2] Proxy SEGURO      — response 200 + header personalizado
#    [3] Proxy DIRECTO WS  — response 101 (Over WebSocket)
#    [4] Proxy OPENVPN     — apunta al puerto OpenVPN
#    [5] Proxy GETTUNEL    — puerto personalizable
#    [6] Proxy TCP BYPASS  — respuesta personalizable completa
#
#  Cada instancia corre en un screen con nombre único,
#  con un archivo .service de systemd para persistir.
# ============================================================

set -uo pipefail

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'
C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'
BOLD='\033[1m'

info()    { echo -e "  ${C}[INFO]${NC} $*"; }
success() { echo -e "  ${G}[OK]${NC}   $*"; }
warn()    { echo -e "  ${Y}[WARN]${NC}  $*"; }
error()   { echo -e "  ${R}[ERR]${NC}  $*"; }

_press_enter() { echo -e "\n  ${DIM}[Enter] para continuar...${NC}"; read -r; }
_cmd_exists()  { command -v "$1" &>/dev/null; }

# ── Rutas ────────────────────────────────────────────────────
PROXY_DIR="/etc/vps-henyer/proxy"
PROXY_PY="/etc/vps-henyer/http_proxy.py"
PROXY_STATE_FILE="$PROXY_DIR/instances.json"

LN="══════════════════════════════════════════════════════"

# ── Instalar el script Python si no existe ───────────────────
_proxy_install_py() {
    mkdir -p "$PROXY_DIR"
    [[ -f "$PROXY_PY" ]] && return 0

    cat > "$PROXY_PY" << 'PYEOF'
#!/usr/bin/env python3
"""
VPS-HENYER — Proxy HTTP/WebSocket para SSH
Soporta: CONNECT, WebSocket (GET+Upgrade), HTTP generico
Argumentos: python3 http_proxy.py <puerto_proxy> <puerto_local> [response_code] [header_personalizado]
"""
import socket, threading, select, sys, datetime, signal

LISTEN_PORT  = int(sys.argv[1]) if len(sys.argv) > 1 else 8880
SSH_PORT     = int(sys.argv[2]) if len(sys.argv) > 2 else 22
RESPONSE     = int(sys.argv[3]) if len(sys.argv) > 3 else 200
CUSTOM_HDR   = sys.argv[4]      if len(sys.argv) > 4 else ""
SSH_HOST     = "127.0.0.1"
BUFFER       = 65536

def log(msg):
    ts = datetime.datetime.now().strftime('%H:%M:%S')
    print(f"[{ts}] {msg}", flush=True)

def build_response(is_connect, is_websocket):
    if is_websocket or RESPONSE == 101:
        return (
            b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\n"
            b"Connection: Upgrade\r\n"
            + (CUSTOM_HDR.encode() + b"\r\n" if CUSTOM_HDR else b"")
            + b"\r\n"
        )
    elif is_connect:
        return (
            b"HTTP/1.1 200 Connection Established\r\n"
            b"Proxy-agent: VPS-HENYER\r\n"
            + (CUSTOM_HDR.encode() + b"\r\n" if CUSTOM_HDR else b"")
            + b"\r\n"
        )
    else:
        code_map = {
            200: b"HTTP/1.1 200 OK",
            403: b"HTTP/1.1 403 Forbidden",
            500: b"HTTP/1.1 500 Internal Server Error",
        }
        first_line = code_map.get(RESPONSE, b"HTTP/1.1 200 OK")
        return (
            first_line + b"\r\n"
            b"Proxy-agent: VPS-HENYER\r\n"
            + (CUSTOM_HDR.encode() + b"\r\n" if CUSTOM_HDR else b"")
            + b"\r\n"
        )

def bridge(src, dst):
    try:
        while True:
            r, _, _ = select.select([src, dst], [], [], 120)
            if not r: break
            for s in r:
                try:
                    data = s.recv(BUFFER)
                except: return
                if not data: return
                other = dst if s is src else src
                try: other.sendall(data)
                except: return
    except: pass
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
            if not chunk: return
            raw += chunk
            if len(raw) > 65536: return

        header_part  = raw[:raw.find(b"\r\n\r\n")].decode("utf-8", errors="ignore")
        first_line   = header_part.split("\r\n")[0] if header_part else ""
        is_websocket = "upgrade: websocket" in header_part.lower()
        is_connect   = first_line.upper().startswith("CONNECT")

        ssh = socket.create_connection((SSH_HOST, SSH_PORT), timeout=10)
        ssh.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        client.sendall(build_response(is_connect, is_websocket))

        mode = "WS" if (is_websocket or RESPONSE==101) else ("CONNECT" if is_connect else "HTTP")
        log(f"[{mode}] :{LISTEN_PORT} -> :{SSH_PORT} | {first_line[:50]}")

        tail = raw[raw.find(b"\r\n\r\n") + 4:]
        if tail: ssh.sendall(tail)

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
    log(f"VPS-HENYER Proxy  :{LISTEN_PORT} -> SSH:{SSH_PORT}  Response:{RESPONSE}")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        try:
            client, _ = srv.accept()
            threading.Thread(target=handle_client, args=(client,), daemon=True).start()
        except KeyboardInterrupt: break
        except Exception as e: log(f"[ACCEPT ERR] {e}")

if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PROXY_PY"
    success "http_proxy.py instalado en $PROXY_PY"
}

# ── Estado de instancias ─────────────────────────────────────
_proxy_load_state() {
    mkdir -p "$PROXY_DIR"
    [[ -f "$PROXY_STATE_FILE" ]] || echo '{"instances":[]}' > "$PROXY_STATE_FILE"
}

_proxy_save_instance() {
    local name="$1" port_proxy="$2" port_local="$3" response="$4" header="$5" mode="$6"
    _proxy_load_state
    python3 << PYSAVE
import json, datetime
path = '$PROXY_STATE_FILE'
d = json.load(open(path))
# Eliminar si ya existe con ese nombre
d['instances'] = [i for i in d['instances'] if i.get('name') != '$name']
d['instances'].append({
    'name':       '$name',
    'port_proxy': $port_proxy,
    'port_local': $port_local,
    'response':   $response,
    'header':     '$header',
    'mode':       '$mode',
    'created':    datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
})
json.dump(d, open(path,'w'), indent=2)
PYSAVE
}

_proxy_remove_instance() {
    local name="$1"
    _proxy_load_state
    python3 << PYREM
import json
path = '$PROXY_STATE_FILE'
d = json.load(open(path))
d['instances'] = [i for i in d['instances'] if i.get('name') != '$name']
json.dump(d, open(path,'w'), indent=2)
PYREM
}

_proxy_get_instances() {
    _proxy_load_state
    python3 << 'PYGET'
import json, subprocess
d = json.load(open('/etc/vps-henyer/proxy/instances.json'))
for inst in d.get('instances', []):
    name  = inst['name']
    pp    = inst['port_proxy']
    pl    = inst['port_local']
    resp  = inst['response']
    mode  = inst['mode']
    # Verificar si el screen está corriendo
    result = subprocess.run(['screen', '-ls'], capture_output=True, text=True)
    running = name in result.stdout
    status = 'ON' if running else 'OFF'
    print(f"{name}|{pp}|{pl}|{resp}|{mode}|{status}")
PYGET
}

_proxy_is_running() {
    local name="$1"
    screen -ls 2>/dev/null | grep -q "$name"
}

# ── Crear servicio systemd para una instancia ────────────────
_proxy_create_service() {
    local name="$1" port_proxy="$2" port_local="$3" response="$4" header="$5"
    local svc_file="/etc/systemd/system/vps-proxy-${name}.service"

    cat > "$svc_file" << SVCEOF
[Unit]
Description=VPS-HENYER Proxy Python — ${name} (${port_proxy}->${port_local})
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 ${PROXY_PY} ${port_proxy} ${port_local} ${response} "${header}"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable "vps-proxy-${name}" 2>/dev/null
}

# ── Arrancar instancia por screen ────────────────────────────
_proxy_start_screen() {
    local name="$1" port_proxy="$2" port_local="$3" response="$4" header="$5"
    # Matar screen previo con ese nombre si existe
    screen -ls 2>/dev/null | grep "$name" | cut -d. -f1 | xargs -r kill 2>/dev/null || true
    sleep 0.3
    screen -dmS "$name" python3 "$PROXY_PY" "$port_proxy" "$port_local" "$response" "$header" 2>/dev/null
    sleep 0.5
    _proxy_is_running "$name"
}

_proxy_stop() {
    local name="$1"
    # Detener screen
    screen -ls 2>/dev/null | grep "$name" | cut -d. -f1 | awk '{print $1}' | xargs -r kill 2>/dev/null || true
    # Detener systemd
    systemctl stop "vps-proxy-${name}" 2>/dev/null || true
}

# ── Detectar puertos SSH/Dropbear/OpenVPN disponibles ────────
_proxy_get_local_ports() {
    echo ""
    echo -e "  ${Y}${BOLD}Puertos locales disponibles:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    local i=1
    declare -gA __port_map
    # SSH
    local ssh_port; ssh_port=$(grep -iE "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    [[ -n "$ssh_port" ]] && { echo -e "  ${W}[$i]${NC} ${G}SSH${NC}       : ${W}${ssh_port}${NC}"; __port_map[$i]="$ssh_port"; (( i++ )); }
    # Dropbear
    local db_port; db_port=$(ss -tlnp 2>/dev/null | grep dropbear | grep -oP ':\K[0-9]+' | head -1)
    [[ -n "$db_port" ]] && { echo -e "  ${W}[$i]${NC} ${G}Dropbear${NC}  : ${W}${db_port}${NC}"; __port_map[$i]="$db_port"; (( i++ )); }
    # OpenVPN
    local ov_port; ov_port=$(grep "^port " /etc/openvpn/server.conf 2>/dev/null | awk '{print $2}')
    [[ -n "$ov_port" ]] && { echo -e "  ${W}[$i]${NC} ${G}OpenVPN${NC}   : ${W}${ov_port}${NC}"; __port_map[$i]="$ov_port"; (( i++ )); }
    # Manual
    echo -e "  ${W}[$i]${NC} ${DIM}Ingresar manualmente${NC}"
    __port_map[$i]="manual"
    echo ""
    echo -n "  Selección: "; read -r sel
    local chosen="${__port_map[$sel]:-}"
    if [[ "$chosen" == "manual" || -z "$chosen" ]]; then
        echo -n "  Puerto local: "; read -r chosen
    fi
    [[ "$chosen" =~ ^[0-9]+$ ]] || { error "Puerto inválido."; return 1; }
    echo "$chosen"
}

# ╔══════════════════════════════════════════════════════════╗
#  INSTALADORES POR MODO
# ╔══════════════════════════════════════════════════════════╝

# ── Modo 1: SIMPLE (response 200) ───────────────────────────
_proxy_add_simple() {
    clear
    echo -e "\n  ${C}${BOLD}╔${LN}╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}Proxy SIMPLE — Response 200                    ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╚${LN}╝${NC}\n"
    info "Puerto proxy externo (ej: 8080 o 8880):"
    echo -n "  Puerto proxy: "; read -r port_proxy
    [[ "$port_proxy" =~ ^[0-9]+$ ]] || { error "Puerto inválido."; _press_enter; return; }

    local port_local; port_local=$(_proxy_get_local_ports) || { _press_enter; return; }

    local name="proxy_simple_${port_proxy}"
    _proxy_install_py
    _proxy_create_service "$name" "$port_proxy" "$port_local" "200" ""
    if _proxy_start_screen "$name" "$port_proxy" "$port_local" "200" ""; then
        _proxy_save_instance "$name" "$port_proxy" "$port_local" "200" "" "SIMPLE"
        success "Proxy SIMPLE activo  :${port_proxy} → :${port_local}"
    else
        error "No pudo iniciar. Verifica que el puerto no esté en uso."
    fi
    _press_enter
}

# ── Modo 2: SEGURO (response 200 + header personalizado) ────
_proxy_add_seguro() {
    clear
    echo -e "\n  ${C}${BOLD}╔${LN}╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}Proxy SEGURO — Con Header Personalizado        ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╚${LN}╝${NC}\n"

    echo -n "  Puerto proxy externo: "; read -r port_proxy
    [[ "$port_proxy" =~ ^[0-9]+$ ]] || { error "Puerto inválido."; _press_enter; return; }

    local port_local; port_local=$(_proxy_get_local_ports) || { _press_enter; return; }

    echo ""
    echo -e "  ${Y}${BOLD}Encabezado HTTP personalizado${NC}"
    echo -e "  ${DIM}Ejemplo: X-Online-Host: default_host${NC}"
    echo -e "  ${DIM}Para Over WebSocket, pon vacío o usa Modo 3${NC}"
    echo -n "  Header (Enter = ninguno): "; read -r header

    local name="proxy_seguro_${port_proxy}"
    _proxy_install_py
    _proxy_create_service "$name" "$port_proxy" "$port_local" "200" "$header"
    if _proxy_start_screen "$name" "$port_proxy" "$port_local" "200" "$header"; then
        _proxy_save_instance "$name" "$port_proxy" "$port_local" "200" "$header" "SEGURO"
        success "Proxy SEGURO activo  :${port_proxy} → :${port_local}"
    else
        error "No pudo iniciar."
    fi
    _press_enter
}

# ── Modo 3: DIRECTO WS (response 101) ───────────────────────
_proxy_add_ws() {
    clear
    echo -e "\n  ${C}${BOLD}╔${LN}╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}Proxy DIRECTO WS — Over WebSocket (101)        ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╚${LN}╝${NC}\n"
    info "Este modo responde 101 Switching Protocols"
    info "Compatible con HTTP Injector y NapsternetV"
    echo ""
    echo -n "  Puerto proxy externo: "; read -r port_proxy
    [[ "$port_proxy" =~ ^[0-9]+$ ]] || { error "Puerto inválido."; _press_enter; return; }

    local port_local; port_local=$(_proxy_get_local_ports) || { _press_enter; return; }

    local name="proxy_ws_${port_proxy}"
    _proxy_install_py
    _proxy_create_service "$name" "$port_proxy" "$port_local" "101" ""
    if _proxy_start_screen "$name" "$port_proxy" "$port_local" "101" ""; then
        _proxy_save_instance "$name" "$port_proxy" "$port_local" "101" "" "WS-DIRECTO"
        success "Proxy WS DIRECTO activo  :${port_proxy} → :${port_local}  Response: 101"
    else
        error "No pudo iniciar."
    fi
    _press_enter
}

# ── Modo 4: OPENVPN ─────────────────────────────────────────
_proxy_add_openvpn() {
    clear
    echo -e "\n  ${C}${BOLD}╔${LN}╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}Proxy OPENVPN — Apunta al puerto OpenVPN       ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╚${LN}╝${NC}\n"

    local ov_port; ov_port=$(grep "^port " /etc/openvpn/server.conf 2>/dev/null | awk '{print $2}')
    if [[ -n "$ov_port" ]]; then
        info "Puerto OpenVPN detectado: ${W}${ov_port}${NC}"
    else
        warn "OpenVPN no instalado o no detectado."
        echo -n "  Puerto OpenVPN manual: "; read -r ov_port
    fi

    echo -n "  Puerto proxy externo (ej: 8880): "; read -r port_proxy
    [[ "$port_proxy" =~ ^[0-9]+$ ]] || { error "Puerto inválido."; _press_enter; return; }

    local name="proxy_openvpn_${port_proxy}"
    _proxy_install_py
    _proxy_create_service "$name" "$port_proxy" "$ov_port" "200" ""
    if _proxy_start_screen "$name" "$port_proxy" "$ov_port" "200" ""; then
        _proxy_save_instance "$name" "$port_proxy" "$ov_port" "200" "" "OPENVPN"
        success "Proxy OPENVPN activo  :${port_proxy} → :${ov_port}"
    else
        error "No pudo iniciar."
    fi
    _press_enter
}

# ── Modo 5: GETTUNEL ────────────────────────────────────────
_proxy_add_gettunel() {
    clear
    echo -e "\n  ${C}${BOLD}╔${LN}╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}Proxy GETTUNEL — Puerto libre                  ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╚${LN}╝${NC}\n"
    info "Para usar con aplicaciones tipo GetTunel/HTTP Custom"
    echo ""
    echo -n "  Puerto proxy externo: "; read -r port_proxy
    [[ "$port_proxy" =~ ^[0-9]+$ ]] || { error "Puerto inválido."; _press_enter; return; }

    local port_local; port_local=$(_proxy_get_local_ports) || { _press_enter; return; }

    echo ""
    echo -e "  ${Y}Response code:${NC}  ${W}[1]${NC} 200  ${W}[2]${NC} 101  ${W}[3]${NC} 403"
    echo -n "  Selección [1]: "; read -r rsel
    local resp=200
    case "${rsel:-1}" in 2) resp=101 ;; 3) resp=403 ;; *) resp=200 ;; esac

    local name="proxy_gettunel_${port_proxy}"
    _proxy_install_py
    _proxy_create_service "$name" "$port_proxy" "$port_local" "$resp" ""
    if _proxy_start_screen "$name" "$port_proxy" "$port_local" "$resp" ""; then
        _proxy_save_instance "$name" "$port_proxy" "$port_local" "$resp" "" "GETTUNEL"
        success "Proxy GETTUNEL activo  :${port_proxy} → :${port_local}  Resp:${resp}"
    else
        error "No pudo iniciar."
    fi
    _press_enter
}

# ── Modo 6: TCP BYPASS (configuración completa) ──────────────
_proxy_add_tcp_bypass() {
    clear
    echo -e "\n  ${C}${BOLD}╔${LN}╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}Proxy TCP BYPASS — Configuración completa      ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╚${LN}╝${NC}\n"

    echo -n "  Puerto proxy externo: "; read -r port_proxy
    [[ "$port_proxy" =~ ^[0-9]+$ ]] || { error "Puerto inválido."; _press_enter; return; }

    local port_local; port_local=$(_proxy_get_local_ports) || { _press_enter; return; }

    echo ""
    echo -e "  ${Y}${BOLD}RESPONDE DE CABECERA (101, 200, 403, 500, etc.)${NC}"
    echo -e "  ${DIM}Response personalizado (Enter por defecto 200)${NC}"
    echo -e "  ${DIM}NOTA: Para OVER WEBSOCKET escribe [ 101 ]${NC}"
    echo -n "  RESPONSE: "; read -r resp_raw
    local resp=${resp_raw:-200}
    [[ "$resp" =~ ^[0-9]+$ ]] || resp=200
    info "RESPONSE : ${W}${resp}${NC} VALIDA"

    echo ""
    echo -e "  ${Y}${BOLD}ENCABEZADO PERSONALIZADO${NC}"
    echo -e "  ${DIM}* EJEMPLO *${NC}"
    echo -e "  ${DIM}\\r\\nContent-length: 0\\r\\n\\r\\nHTTP/1.1 200 Connection Established\\r\\n\\r\\n${NC}"
    echo -e "  ${DIM}SI DESCONOCES ESTA OPCION SOLO PRESIONA ENTER${NC}"
    echo -e "  CABECERA: ${DIM}DEFAULT_HOST${NC}"
    echo ""
    echo -e "  Introduzca su Mini-Banner"
    echo -e "  Introduzca un texto [NORMAL] o en [HTML]"
    echo -n "  --> : "; read -r header

    echo ""
    echo -e "  ${Y}${BOLD}Opciones de inicio:${NC}"
    echo -e "  ${W}[1]${NC}  Proxy (WS/Direct) (SCREEN)"
    echo -e "  ${W}[2]${NC}  Proxy (WS/Direct) (SYSTEM)  ${G}[REC]${NC}"
    echo -n "  Opcion: "; read -r start_opt

    local name="proxy_bypass_${port_proxy}"
    _proxy_install_py

    if [[ "${start_opt:-2}" == "2" ]]; then
        _proxy_create_service "$name" "$port_proxy" "$port_local" "$resp" "$header"
        systemctl start "vps-proxy-${name}" 2>/dev/null
        sleep 1
        if systemctl is-active --quiet "vps-proxy-${name}" 2>/dev/null; then
            _proxy_save_instance "$name" "$port_proxy" "$port_local" "$resp" "$header" "TCP-BYPASS"
            success "Proxy TCP BYPASS activo (SYSTEM) :${port_proxy} → :${port_local}"
        else
            error "No pudo iniciar como servicio. Intentando screen..."
            _proxy_start_screen "$name" "$port_proxy" "$port_local" "$resp" "$header" \
                && _proxy_save_instance "$name" "$port_proxy" "$port_local" "$resp" "$header" "TCP-BYPASS" \
                && success "Proxy TCP BYPASS activo (SCREEN) :${port_proxy} → :${port_local}" \
                || error "No pudo iniciar."
        fi
    else
        if _proxy_start_screen "$name" "$port_proxy" "$port_local" "$resp" "$header"; then
            _proxy_save_instance "$name" "$port_proxy" "$port_local" "$resp" "$header" "TCP-BYPASS"
            success "Proxy TCP BYPASS activo (SCREEN) :${port_proxy} → :${port_local}"
        else
            error "No pudo iniciar."
        fi
    fi
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  ELIMINAR INSTANCIAS
# ╚══════════════════════════════════════════════════════════╝
_proxy_eliminar_todos() {
    echo -e "\n  ${Y}⚠  Esto detendrá y eliminará TODAS las instancias.${NC}"
    echo -n "  ¿Confirmar? [s/N]: "; read -r conf
    [[ "${conf,,}" != "s" ]] && return

    _proxy_load_state
    local names
    names=$(python3 << 'PYLIST'
import json
d = json.load(open('/etc/vps-henyer/proxy/instances.json'))
for inst in d.get('instances', []):
    print(inst['name'])
PYLIST
)
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        _proxy_stop "$name"
        rm -f "/etc/systemd/system/vps-proxy-${name}.service" 2>/dev/null
        success "Instancia '${name}' eliminada."
    done <<< "$names"

    echo '{"instances":[]}' > "$PROXY_STATE_FILE"
    systemctl daemon-reload 2>/dev/null
    success "Todas las instancias eliminadas."
    _press_enter
}

_proxy_eliminar_uno() {
    local instances
    instances=$(_proxy_get_instances)
    if [[ -z "$instances" ]]; then
        warn "No hay instancias activas."; _press_enter; return
    fi
    echo -e "\n  ${Y}${BOLD}Instancias activas:${NC}"
    local i=1
    declare -A __inst_map
    while IFS='|' read -r name pp pl resp mode status; do
        echo -e "  ${W}[$i]${NC} ${name} :${pp} → :${pl}  ${DIM}[${status}]${NC}"
        __inst_map[$i]="$name"
        (( i++ ))
    done <<< "$instances"
    echo ""
    echo -n "  Número a eliminar (0=cancelar): "; read -r sel
    [[ "$sel" == "0" || -z "${__inst_map[$sel]:-}" ]] && return
    local target="${__inst_map[$sel]}"
    _proxy_stop "$target"
    _proxy_remove_instance "$target"
    rm -f "/etc/systemd/system/vps-proxy-${target}.service" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    success "Instancia '${target}' eliminada."
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  PANEL PRINCIPAL
# ╚══════════════════════════════════════════════════════════╝

# Asegurar que screen y python3 están instalados
_proxy_check_deps() {
    local missing=()
    _cmd_exists python3 || missing+=("python3")
    _cmd_exists screen  || missing+=("screen")
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Instalando dependencias: ${missing[*]}"
        apt-get install -y -qq "${missing[@]}" 2>/dev/null
    fi
}

while true; do
    clear
    _proxy_load_state

    # Leer instancias
    local_instances=$(_proxy_get_instances 2>/dev/null || echo "")

    # Contar activas
    local active_count=0
    while IFS='|' read -r _ _ _ _ _ status; do
        [[ "$status" == "ON" ]] && (( active_count++ )) || true
    done <<< "$local_instances"

    # Detectar si python3 en algún puerto está escuchando
    local py3_info
    py3_info=$(ss -tlnp 2>/dev/null | grep python | grep -oP ':\K[0-9]+' | head -1 || echo "")
    local py3_status
    [[ -n "$py3_info" ]] \
        && py3_status="${G}● python3 : ${py3_info}  [ WORKING ]${NC}" \
        || py3_status="${R}● python3 : sin instancias activas${NC}"

    echo -e ""
    echo -e "  ${C}${BOLD}╔${LN}╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}   PROXY PYTHON — VPS-HENYER               ${NC}   ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${py3_status}"
    echo -e "  ${C}${BOLD}╠${LN}╣${NC}"

    # Mostrar instancias activas
    if [[ -n "$local_instances" ]]; then
        echo -e "  ${C}${BOLD}║${NC}  ${Y}Instancias configuradas:${NC}"
        while IFS='|' read -r name pp pl resp mode status; do
            local dot; [[ "$status" == "ON" ]] && dot="${G}●${NC}" || dot="${R}●${NC}"
            printf "  ${C}${BOLD}║${NC}  %b ${W}%-12s${NC} :%-5s → :%-5s  ${DIM}%s${NC}  [%s]\n" \
                   "$dot" "$mode" "$pp" "$pl" "Resp:${resp}" "$status"
        done <<< "$local_instances"
    else
        echo -e "  ${C}${BOLD}║${NC}  ${DIM}  (sin instancias configuradas)${NC}"
    fi

    echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[1]${NC}  Proxy Python SIMPLE"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[2]${NC}  Proxy Python SEGURO         ${DIM}(header custom)${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[3]${NC}  Proxy Python DIRETO (WS)    ${DIM}(response 101)${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[4]${NC}  Proxy Python OPENVPN"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[5]${NC}  Proxy Python GETTUNEL"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[6]${NC}  Proxy Python TCP BYPASS     ${DIM}(configuración completa)${NC}"
    echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[7]${NC}  Eliminar instancia"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[8]${NC}  Eliminar todas las instancias"
    echo -e "  ${C}${BOLD}║${NC}  ${DIM}[0]  Volver al menú principal${NC}"
    echo -e "  ${C}${BOLD}╚${LN}╝${NC}"
    echo ""
    echo -e "  Opción : \c"; read -r opt

    case "$opt" in
        1) _proxy_check_deps; _proxy_add_simple    ;;
        2) _proxy_check_deps; _proxy_add_seguro    ;;
        3) _proxy_check_deps; _proxy_add_ws        ;;
        4) _proxy_check_deps; _proxy_add_openvpn   ;;
        5) _proxy_check_deps; _proxy_add_gettunel  ;;
        6) _proxy_check_deps; _proxy_add_tcp_bypass;;
        7) _proxy_eliminar_uno   ;;
        8) _proxy_eliminar_todos ;;
        0) exit 0 ;;
        *) warn "Opción inválida."; sleep 1 ;;
    esac
done
