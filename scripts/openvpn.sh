#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo OpenVPN
#  Gestión completa: instalar, usuarios, arrancar/detener
#  Llamado desde menu.sh: bash openvpn.sh
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
_svc_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }

# ── Rutas ────────────────────────────────────────────────────
OVPN_DIR="/etc/openvpn"
OVPN_CONF="$OVPN_DIR/server.conf"
OVPN_CLIENT_TPL="$OVPN_DIR/client-common.txt"
OVPN_USERS_DIR="$OVPN_DIR/clients"
HENYER_DIR="/etc/vps-henyer"

LN="══════════════════════════════════════════════════════"

# ── Helpers ──────────────────────────────────────────────────
_ovpn_is_installed() { [[ -f "$OVPN_CONF" ]]; }

_ovpn_status() {
    if _svc_active "openvpn" || _svc_active "openvpn@server"; then
        echo -e "${G}● ACTIVO${NC}"
    elif pgrep -x openvpn &>/dev/null; then
        echo -e "${Y}● EN PROCESO${NC}"
    else
        echo -e "${R}● INACTIVO${NC}"
    fi
}

_ovpn_get_port() {
    [[ -f "$OVPN_CONF" ]] && grep "^port " "$OVPN_CONF" | awk '{print $2}' || echo "N/A"
}

_ovpn_get_proto() {
    [[ -f "$OVPN_CONF" ]] && grep "^proto " "$OVPN_CONF" | awk '{print $2}' || echo "N/A"
}

_get_public_ip() {
    curl -s --max-time 5 https://ipv4.icanhazip.com 2>/dev/null \
     || curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
     || ip addr | grep 'inet ' | grep -v '127\.' | awk '{print $2}' | cut -d/ -f1 | head -1
}

_get_nic() {
    ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1
}

_count_users() {
    [[ -d "$OVPN_USERS_DIR" ]] && ls "$OVPN_USERS_DIR"/*.ovpn 2>/dev/null | wc -l || echo 0
}

# ── Instalar OpenVPN ─────────────────────────────────────────
_ovpn_instalar() {
    clear
    echo -e "\n  ${W}${BOLD}── Instalar OpenVPN ──────────────────────────────────${NC}\n"

    # Verificar TUN
    if [[ ! -e /dev/net/tun ]]; then
        error "El dispositivo TUN no está disponible."
        warn  "Habilita TUN en el panel de tu proveedor VPS."
        _press_enter; return
    fi

    # Verificar OS
    if [[ ! -f /etc/debian_version ]]; then
        error "Solo compatible con Debian/Ubuntu."
        _press_enter; return
    fi

    # Detectar IP
    local PUBLIC_IP; PUBLIC_IP=$(_get_public_ip)
    echo -e "  ${Y}IP detectada:${NC} ${W}${PUBLIC_IP}${NC}"
    echo -e "  ¿Usar esta IP? [S/n]: \c"; read -r ans
    if [[ "${ans,,}" == "n" ]]; then
        echo -e "  IP pública del servidor: \c"; read -r PUBLIC_IP
        [[ -z "$PUBLIC_IP" ]] && { error "IP vacía."; _press_enter; return; }
    fi

    # Puerto
    echo ""
    echo -e "  Puerto OpenVPN ${DIM}[1194]${NC}: \c"; read -r PORT
    PORT="${PORT:-1194}"
    [[ "$PORT" =~ ^[0-9]+$ ]] || { error "Puerto inválido."; _press_enter; return; }

    # Protocolo
    echo ""
    echo -e "  ${W}[1]${NC} UDP ${DIM}(recomendado)${NC}"
    echo -e "  ${W}[2]${NC} TCP"
    echo -e "  Protocolo [1]: \c"; read -r proto_sel
    case "${proto_sel:-1}" in
        2) PROTOCOL="tcp" ;;
        *) PROTOCOL="udp" ;;
    esac

    # DNS
    echo ""
    echo -e "  ${Y}DNS para los clientes:${NC}"
    echo -e "  ${W}[1]${NC} Google     (8.8.8.8 / 8.8.4.4)"
    echo -e "  ${W}[2]${NC} Cloudflare (1.1.1.1 / 1.0.0.1)"
    echo -e "  ${W}[3]${NC} OpenDNS    (208.67.222.222 / 208.67.220.220)"
    echo -e "  ${W}[4]${NC} DNS del sistema"
    echo -e "  DNS [1]: \c"; read -r dns_sel
    local DNS1 DNS2
    case "${dns_sel:-1}" in
        2) DNS1="1.1.1.1";        DNS2="1.0.0.1" ;;
        3) DNS1="208.67.222.222"; DNS2="208.67.220.220" ;;
        4)
            DNS1=$(grep -v '#' /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}')
            DNS2=$(grep -v '#' /etc/resolv.conf | grep nameserver | sed -n '2p' | awk '{print $2}')
            DNS1="${DNS1:-8.8.8.8}"; DNS2="${DNS2:-8.8.4.4}"
            ;;
        *) DNS1="8.8.8.8"; DNS2="8.8.4.4" ;;
    esac

    # Cipher
    echo ""
    echo -e "  ${Y}Cifrado:${NC}"
    echo -e "  ${W}[1]${NC} AES-128-CBC"
    echo -e "  ${W}[2]${NC} AES-192-CBC"
    echo -e "  ${W}[3]${NC} AES-256-CBC ${DIM}(más seguro)${NC}"
    echo -e "  Cipher [3]: \c"; read -r cipher_sel
    case "${cipher_sel:-3}" in
        1) CIPHER="AES-128-CBC" ;;
        2) CIPHER="AES-192-CBC" ;;
        *) CIPHER="AES-256-CBC" ;;
    esac

    echo ""
    echo -e "  ${Y}Resumen:${NC}"
    echo -e "  IP: ${W}${PUBLIC_IP}${NC}  Puerto: ${W}${PORT}/${PROTOCOL}${NC}"
    echo -e "  DNS: ${W}${DNS1} / ${DNS2}${NC}   Cipher: ${W}${CIPHER}${NC}"
    echo ""
    echo -e "  ¿Confirmar instalación? [s/N]: \c"; read -r confirm
    [[ "${confirm,,}" != "s" ]] && return

    # ── Instalar paquetes ────────────────────────────────────
    echo ""
    info "Instalando paquetes..."
    apt-get update -qq && apt-get install -y -qq openvpn openssl ca-certificates curl \
        || { error "Fallo al instalar paquetes."; _press_enter; return; }

    mkdir -p "$OVPN_DIR" "$OVPN_USERS_DIR"

    # ── Generar PKI con openssl (sin easy-rsa) ───────────────
    info "Generando CA y certificados del servidor..."

    # CA key + cert
    openssl genrsa -out "$OVPN_DIR/ca-key.pem" 2048 &>/dev/null
    openssl req -new -x509 -days 3650 -nodes \
        -key "$OVPN_DIR/ca-key.pem" \
        -out "$OVPN_DIR/ca.pem" \
        -subj "/CN=VPS-HENYER-CA/" &>/dev/null
    chmod 600 "$OVPN_DIR/ca-key.pem"

    # DH params
    info "Generando parámetros DH (puede tardar ~1 min)..."
    openssl dhparam -out "$OVPN_DIR/dh.pem" 2048 &>/dev/null

    # Server key + cert
    openssl genrsa -out "$OVPN_DIR/server-key.pem" 2048 &>/dev/null
    openssl req -new -key "$OVPN_DIR/server-key.pem" \
        -out "$OVPN_DIR/server-csr.pem" \
        -subj "/CN=VPS-HENYER-Server/" &>/dev/null
    openssl x509 -req -in "$OVPN_DIR/server-csr.pem" \
        -CA "$OVPN_DIR/ca.pem" -CAkey "$OVPN_DIR/ca-key.pem" \
        -CAcreateserial -out "$OVPN_DIR/server-cert.pem" \
        -days 3650 &>/dev/null
    chmod 600 "$OVPN_DIR/server-key.pem"

    # Client key + cert (compartido, auth por usuario/pass)
    openssl genrsa -out "$OVPN_DIR/client-key.pem" 2048 &>/dev/null
    openssl req -new -key "$OVPN_DIR/client-key.pem" \
        -out "$OVPN_DIR/client-csr.pem" \
        -subj "/CN=VPS-HENYER-Client/" &>/dev/null
    openssl x509 -req -in "$OVPN_DIR/client-csr.pem" \
        -CA "$OVPN_DIR/ca.pem" -CAkey "$OVPN_DIR/ca-key.pem" \
        -CAcreateserial -out "$OVPN_DIR/client-cert.pem" \
        -days 3650 &>/dev/null
    chmod 600 "$OVPN_DIR/client-key.pem"

    # Buscar plugin PAM
    local PLUGIN=""
    PLUGIN=$(find /usr/lib -name "openvpn-plugin-auth-pam.so" 2>/dev/null | head -1)

    # ── server.conf ──────────────────────────────────────────
    info "Escribiendo server.conf..."
    cat > "$OVPN_CONF" << CONF
port $PORT
proto $PROTOCOL
dev tun

ca      $OVPN_DIR/ca.pem
cert    $OVPN_DIR/server-cert.pem
key     $OVPN_DIR/server-key.pem
dh      $OVPN_DIR/dh.pem

server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /etc/openvpn/ipp.txt
duplicate-cn

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS ${DNS1}"
push "dhcp-option DNS ${DNS2}"

keepalive 10 120
cipher ${CIPHER}
comp-lzo
user nobody
group nogroup
persist-key
persist-tun
status /var/log/openvpn-status.log
log    /var/log/openvpn.log
verb 3
CONF

    # Autenticación usuario/contraseña vía PAM
    if [[ -n "$PLUGIN" ]]; then
        cat >> "$OVPN_CONF" << CONF

client-cert-not-required
username-as-common-name
plugin $PLUGIN login
CONF
        info "Plugin PAM encontrado: auth por usuario/contraseña habilitada."
    else
        warn "Plugin PAM no encontrado: los clientes usarán solo certificado."
    fi

    # ── client-common.txt ────────────────────────────────────
    cat > "$OVPN_CLIENT_TPL" << TPL
client
dev tun
proto $PROTOCOL
remote $PUBLIC_IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher $CIPHER
comp-lzo
auth-user-pass
verb 3
TPL

    # ── Habilitar ip_forward ─────────────────────────────────
    sed -i 's|#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf 2>/dev/null || true
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # ── iptables masquerade ──────────────────────────────────
    local NIC; NIC=$(_get_nic)
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$NIC" -j MASQUERADE 2>/dev/null || true
    iptables -I INPUT -p "$PROTOCOL" --dport "$PORT" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    # Persistir iptables
    iptables-save > /etc/iptables.conf 2>/dev/null || true
    cat > /etc/network/if-up.d/iptables << 'EOF'
#!/bin/sh
iptables-restore < /etc/iptables.conf
EOF
    chmod +x /etc/network/if-up.d/iptables 2>/dev/null || true

    # UFW: abrir puerto si está activo
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q active; then
        ufw allow "${PORT}/${PROTOCOL}" > /dev/null 2>&1
        info "UFW: puerto ${PORT}/${PROTOCOL} abierto."
    fi

    # ── Iniciar servicio ─────────────────────────────────────
    info "Iniciando OpenVPN..."
    systemctl enable openvpn 2>/dev/null || true
    systemctl restart openvpn 2>/dev/null || true
    sleep 2

    if _svc_active "openvpn" || pgrep -x openvpn &>/dev/null; then
        success "OpenVPN instalado y activo."
        info "Puerto: ${W}${PORT}/${PROTOCOL}${NC}  IP: ${W}${PUBLIC_IP}${NC}"
    else
        # Intentar lanzar directamente con screen como fallback
        screen -dmS ovpn openvpn --config "$OVPN_CONF" 2>/dev/null && \
            success "OpenVPN iniciado vía screen." || \
            error   "OpenVPN no pudo iniciar. Revisa: journalctl -u openvpn"
    fi

    # Guardar IP pública para uso posterior
    mkdir -p "$HENYER_DIR"
    echo "$PUBLIC_IP" > "$HENYER_DIR/ovpn_ip"

    _press_enter
}

# ── Crear usuario / generar .ovpn ────────────────────────────
_ovpn_add_user() {
    clear
    echo -e "\n  ${W}${BOLD}── Crear Usuario OpenVPN ─────────────────────────────${NC}\n"

    if ! _ovpn_is_installed; then
        error "OpenVPN no está instalado. Usa [1] primero."; _press_enter; return
    fi

    echo -e "  Nombre del usuario: \c"; read -r USERNAME
    USERNAME=$(echo "$USERNAME" | tr -dc '[:alnum:]_-')
    [[ -z "$USERNAME" ]] && { error "Nombre inválido."; _press_enter; return; }

    local OUTFILE="$OVPN_USERS_DIR/${USERNAME}.ovpn"

    if [[ -f "$OUTFILE" ]]; then
        warn "El usuario '$USERNAME' ya existe."
        echo -e "  ¿Sobreescribir? [s/N]: \c"; read -r ow
        [[ "${ow,,}" != "s" ]] && return
    fi

    # Generar .ovpn inline (embeds CA + cert + key)
    {
        cat "$OVPN_CLIENT_TPL"
        echo ""
        echo "<ca>"
        cat "$OVPN_DIR/ca.pem"
        echo "</ca>"
        echo "<cert>"
        cat "$OVPN_DIR/client-cert.pem"
        echo "</cert>"
        echo "<key>"
        cat "$OVPN_DIR/client-key.pem"
        echo "</key>"
    } > "$OUTFILE"

    success "Perfil generado: ${W}${OUTFILE}${NC}"
    echo ""
    info "Transfiere el archivo .ovpn al cliente con scp/sftp:"
    echo -e "  ${DIM}scp root@<IP>:${OUTFILE} ./${USERNAME}.ovpn${NC}"
    _press_enter
}

# ── Listar usuarios ──────────────────────────────────────────
_ovpn_list_users() {
    clear
    echo -e "\n  ${W}${BOLD}── Usuarios OpenVPN ──────────────────────────────────${NC}\n"

    if [[ ! -d "$OVPN_USERS_DIR" ]] || [[ -z "$(ls -A "$OVPN_USERS_DIR" 2>/dev/null)" ]]; then
        warn "No hay perfiles de usuario creados."; _press_enter; return
    fi

    local i=1
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    for f in "$OVPN_USERS_DIR"/*.ovpn; do
        local name; name=$(basename "$f" .ovpn)
        echo -e "  ${W}[$i]${NC}  ${G}${name}${NC}"
        ((i++))
    done
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    _press_enter
}

# ── Eliminar usuario ─────────────────────────────────────────
_ovpn_del_user() {
    clear
    echo -e "\n  ${W}${BOLD}── Eliminar Usuario OpenVPN ──────────────────────────${NC}\n"

    if [[ ! -d "$OVPN_USERS_DIR" ]] || [[ -z "$(ls -A "$OVPN_USERS_DIR" 2>/dev/null)" ]]; then
        warn "No hay usuarios."; _press_enter; return
    fi

    local i=1
    declare -A usr_map
    for f in "$OVPN_USERS_DIR"/*.ovpn; do
        local name; name=$(basename "$f" .ovpn)
        echo -e "  ${W}[$i]${NC}  $name"
        usr_map[$i]="$name"
        ((i++))
    done
    echo ""
    echo -e "  Número a eliminar: \c"; read -r sel
    local target="${usr_map[$sel]:-}"
    [[ -z "$target" ]] && { error "Selección inválida."; _press_enter; return; }

    echo -e "  ¿Eliminar usuario '${W}${target}${NC}'? [s/N]: \c"; read -r conf
    [[ "${conf,,}" != "s" ]] && return

    rm -f "$OVPN_USERS_DIR/${target}.ovpn"
    success "Usuario '$target' eliminado."
    _press_enter
}

# ── Ver configuración del servidor ───────────────────────────
_ovpn_ver_config() {
    clear
    echo -e "\n  ${W}${BOLD}── Configuración del Servidor ────────────────────────${NC}\n"
    if [[ -f "$OVPN_CONF" ]]; then
        while IFS= read -r line; do
            echo -e "  ${DIM}${line}${NC}"
        done < "$OVPN_CONF"
    else
        warn "No hay configuración instalada."
    fi
    _press_enter
}

# ── Ver log de conexiones ────────────────────────────────────
_ovpn_ver_log() {
    clear
    echo -e "\n  ${W}${BOLD}── Log OpenVPN (últimas 30 líneas) ───────────────────${NC}\n"
    if [[ -f /var/log/openvpn.log ]]; then
        tail -30 /var/log/openvpn.log | while IFS= read -r line; do
            echo -e "  ${DIM}${line}${NC}"
        done
    else
        warn "Log no disponible."
    fi
    _press_enter
}

# ── Clientes conectados ──────────────────────────────────────
_ovpn_clientes() {
    clear
    echo -e "\n  ${W}${BOLD}── Clientes Conectados ───────────────────────────────${NC}\n"
    local STATUS_FILE="/var/log/openvpn-status.log"
    if [[ -f "$STATUS_FILE" ]]; then
        echo -e "  ${Y}${BOLD}Clientes activos:${NC}"
        echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
        grep "^CLIENT_LIST" "$STATUS_FILE" 2>/dev/null | while IFS=, read -r _ name ip vip _ bytes_rx bytes_tx _ connected; do
            echo -e "  ${G}●${NC} ${W}${name}${NC}  IP: ${C}${ip}${NC}  VIP: ${ip}  TX: ${bytes_tx}B  RX: ${bytes_rx}B"
            echo -e "    Conectado: ${DIM}${connected}${NC}"
        done || echo -e "  ${DIM}(sin clientes)${NC}"
    else
        warn "Archivo de estado no disponible. OpenVPN puede no estar activo."
    fi
    _press_enter
}

# ── Iniciar / Detener ────────────────────────────────────────
_ovpn_toggle() {
    if _svc_active "openvpn" || pgrep -x openvpn &>/dev/null; then
        info "Deteniendo OpenVPN..."
        systemctl stop openvpn 2>/dev/null || true
        pkill -x openvpn 2>/dev/null || true
        sleep 1
        success "OpenVPN → DETENIDO"
    else
        info "Iniciando OpenVPN..."
        systemctl start openvpn 2>/dev/null || \
            screen -dmS ovpn openvpn --config "$OVPN_CONF" 2>/dev/null
        sleep 2
        if _svc_active "openvpn" || pgrep -x openvpn &>/dev/null; then
            success "OpenVPN → ACTIVO"
        else
            error "No pudo iniciar. Revisa: journalctl -u openvpn"
        fi
    fi
    _press_enter
}

# ── Desinstalar ──────────────────────────────────────────────
_ovpn_desinstalar() {
    clear
    echo -e "\n  ${R}${BOLD}── Desinstalar OpenVPN ───────────────────────────────${NC}\n"
    echo -e "  ${Y}⚠  Esto eliminará OpenVPN, sus certificados y perfiles.${NC}"
    echo -e "  ¿Confirmar? [s/N]: \c"; read -r conf
    [[ "${conf,,}" != "s" ]] && return

    # Leer puerto/protocolo para limpiar iptables
    local PORT PROTOCOL NIC
    PORT=$(_ovpn_get_port); PORT="${PORT:-1194}"
    PROTOCOL=$(_ovpn_get_proto); PROTOCOL="${PROTOCOL:-udp}"
    NIC=$(_get_nic)

    # Detener
    systemctl stop openvpn 2>/dev/null || true
    systemctl disable openvpn 2>/dev/null || true
    pkill -x openvpn 2>/dev/null || true

    # Limpiar iptables
    iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o "$NIC" -j MASQUERADE 2>/dev/null || true
    iptables -D INPUT -p "$PROTOCOL" --dport "$PORT" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -s 10.8.0.0/24 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables-save > /etc/iptables.conf 2>/dev/null || true

    # Purgar paquete y archivos
    apt-get purge -y -qq openvpn 2>/dev/null || true
    rm -rf "$OVPN_DIR"
    rm -f "$HENYER_DIR/ovpn_ip"

    success "OpenVPN desinstalado."
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  PANEL PRINCIPAL
# ╚══════════════════════════════════════════════════════════╝
while true; do
    clear

    ovpn_status=$(_ovpn_status)
    ovpn_port=$(_ovpn_get_port)
    ovpn_proto=$(_ovpn_get_proto)
    ovpn_users=$(_count_users)
    ovpn_installed="NO"; _ovpn_is_installed && ovpn_installed="SÍ"

    echo -e ""
    echo -e "  ${C}${BOLD}╔${LN}╗${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}OpenVPN — Panel de Control${NC}              ${C}${BOLD}║${NC}"
    echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  Estado      : $ovpn_status"
    echo -e "  ${C}${BOLD}║${NC}  Instalado   : ${W}${ovpn_installed}${NC}"
    echo -e "  ${C}${BOLD}║${NC}  Puerto      : ${W}${ovpn_port}/${ovpn_proto}${NC}"
    echo -e "  ${C}${BOLD}║${NC}  Perfiles    : ${G}${ovpn_users}${NC} usuario(s)"
    echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[1]${NC}  Instalar / Reconfigurar OpenVPN"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[2]${NC}  Crear usuario (.ovpn)"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[3]${NC}  Listar usuarios"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[4]${NC}  Eliminar usuario"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[5]${NC}  Ver clientes conectados"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[6]${NC}  Ver configuración del servidor"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[7]${NC}  Ver log de conexiones"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[8]${NC}  Iniciar / Detener OpenVPN"
    echo -e "  ${C}${BOLD}║${NC}  ${W}[9]${NC}  Desinstalar OpenVPN"
    echo -e "  ${C}${BOLD}║${NC}  ${DIM}[0]  Volver al menú principal${NC}"
    echo -e "  ${C}${BOLD}╚${LN}╝${NC}"
    echo ""
    echo -e "  Opción : \c"; read -r opt

    case "$opt" in
        1) _ovpn_instalar    ;;
        2) _ovpn_add_user    ;;
        3) _ovpn_list_users  ;;
        4) _ovpn_del_user    ;;
        5) _ovpn_clientes    ;;
        6) _ovpn_ver_config  ;;
        7) _ovpn_ver_log     ;;
        8) _ovpn_toggle      ;;
        9) _ovpn_desinstalar ;;
        0) exit 0            ;;
        *) warn "Opción inválida."; sleep 1 ;;
    esac
done
