#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo V2Ray / Xray
#  Gestión completa: instalar, wizard de protocolos,
#  usuarios UUID, TLS, QR, log, etc.
#  Archivo: scripts/v2ray.sh
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

# ── Rutas ────────────────────────────────────────────────────
XRAY_USERS_FILE="/etc/vps-henyer/xray_users.json"
XRAY_CFG_DIR="/usr/local/etc/xray"
XRAY_CFG="$XRAY_CFG_DIR/config.json"

# ╔══════════════════════════════════════════════════════════╗
#  HELPERS INTERNOS
# ╚══════════════════════════════════════════════════════════╝
_xray_svc() {
    systemctl list-unit-files xray.service  &>/dev/null 2>&1 | grep -q "xray"  && { echo "xray";  return; }
    systemctl list-unit-files v2ray.service &>/dev/null 2>&1 | grep -q "v2ray" && { echo "v2ray"; return; }
    echo "xray"
}

_xray_is_active() {
    _service_active "xray" 2>/dev/null || _service_active "v2ray" 2>/dev/null
}

_xray_get_port() {
    python3 -c "
import json
try:
    d = json.load(open('$XRAY_CFG'))
    print(d['inbounds'][0].get('port','N/A'))
except: print('N/A')
" 2>/dev/null || echo "N/A"
}

_xray_get_proto() {
    python3 -c "
import json
try:
    d   = json.load(open('$XRAY_CFG'))
    ib  = d['inbounds'][0]
    proto = ib.get('protocol','?').upper()
    net   = ib.get('streamSettings',{}).get('network','tcp').upper()
    sec   = ib.get('streamSettings',{}).get('security','none').upper()
    print(f'{proto}+{net}+{sec}')
except: print('N/A')
" 2>/dev/null || echo "N/A"
}

_xray_get_tls() {
    python3 -c "
import json
try:
    d   = json.load(open('$XRAY_CFG'))
    sec = d['inbounds'][0].get('streamSettings',{}).get('security','none')
    print(sec)
except: print('none')
" 2>/dev/null || echo "none"
}

_xray_count_users() {
    [[ -f "$XRAY_USERS_FILE" ]] || { echo "0"; return; }
    python3 -c "
import json
try:
    d=json.load(open('$XRAY_USERS_FILE'))
    print(len(d.get('users',[])))
except: print('0')
" 2>/dev/null || echo "0"
}

_xray_count_locked() {
    [[ -f "$XRAY_USERS_FILE" ]] || { echo "0"; return; }
    python3 -c "
import json
try:
    d=json.load(open('$XRAY_USERS_FILE'))
    print(sum(1 for u in d.get('users',[]) if u.get('locked',False)))
except: print('0')
" 2>/dev/null || echo "0"
}

_xray_count_connected() {
    local log_file="/var/log/xray/access.log"
    [[ -f "$log_file" ]] || { echo "0"; return; }
    grep -c "accepted" "$log_file" 2>/dev/null || echo "0"
}

_xray_users_init() {
    mkdir -p /etc/vps-henyer
    [[ -f "$XRAY_USERS_FILE" ]] || echo '{"users":[]}' > "$XRAY_USERS_FILE"
}

_gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null \
        || uuidgen 2>/dev/null \
        || echo "$(date +%s)-$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 12)"
}

# ── Verificar si un puerto está ocupado ─────────────────────
_port_in_use() {
    ss -tlnp 2>/dev/null | grep -q ":${1} " \
        || lsof -i :"$1" &>/dev/null 2>&1
}

_ask_port() {
    local default="$1" label="${2:-Puerto}" varname="${3:-_PORT_RESULT}"
    local _p
    while true; do
        echo -e "  ${label} [default: ${default}]: \c" >&2; read -r _p
        _p="${_p:-$default}"
        if [[ "$_p" =~ ^[0-9]+$ ]] && (( _p > 0 && _p < 65536 )); then
            # Verificar si el puerto está en uso
            if _port_in_use "$_p"; then
                warn "⚠  El puerto ${_p} ya está en uso por otro proceso." >&2
                echo -e "  ${DIM}Procesos usando ese puerto:${NC}" >&2
                ss -tlnp 2>/dev/null | grep ":${_p} " | head -3 | while IFS= read -r l; do
                    echo -e "    ${R}$l${NC}" >&2
                done
                echo -e "  ${Y}¿Usar de todas formas? [s/N]: \c" >&2; read -r force
                if [[ "${force,,}" == "s" ]]; then
                    printf -v "$varname" '%s' "$_p"
                    return 0
                fi
                echo -e "  Ingresa otro puerto: " >&2
                continue
            fi
            printf -v "$varname" '%s' "$_p"
            return 0
        fi
        warn "Puerto inválido (1-65535)." >&2
    done
}

_ask_ws_path() {
    local default="${1:-/ws}" varname="${2:-_WS_PATH}"
    echo -e "  Path WebSocket [default: ${default}]: \c" >&2
    read -r _p
    _p="${_p:-$default}"
    [[ "$_p" != /* ]] && _p="/$_p"
    printf -v "$varname" '%s' "$_p"
}

_ask_server_addr() {
    local varname="${1:-_ADDR_RESULT}"
    local detected; detected=$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo "")
    echo -e "  IP o dominio del servidor [${detected:-TU_IP}]: \c" >&2
    read -r _addr
    _addr="${_addr:-$detected}"
    [[ -z "$_addr" ]] && _addr="TU_IP"
    printf -v "$varname" '%s' "$_addr"
}

_ask_tls_cert() {
    local domain="$1"
    local cert_var="${2:-_CERT_PATH}" key_var="${3:-_KEY_PATH}"
    local cp="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local kp="/etc/letsencrypt/live/${domain}/privkey.pem"

    if [[ -f "$cp" && -f "$kp" ]]; then
        success "Certificado Let's Encrypt encontrado para $domain."
        printf -v "$cert_var" '%s' "$cp"
        printf -v "$key_var"  '%s' "$kp"
        return 0
    fi

    warn "No se encontró certificado para: $domain"
    echo -e "  ${W}[1]${NC} Obtener con certbot  ${W}[2]${NC} Rutas manuales  ${DIM}[0]${NC} Cancelar"
    echo -e "  Selección: \c"; read -r tls_opt
    case "$tls_opt" in
        1)
            if ! _cmd_exists certbot; then
                apt-get install -y -qq certbot 2>/dev/null || die "No se pudo instalar certbot."
            fi
            certbot certonly --standalone -d "$domain" --non-interactive \
                --agree-tos --email "admin@${domain}" 2>/dev/null \
                || certbot certonly --standalone -d "$domain"
            if [[ -f "$cp" ]]; then
                success "Certificado obtenido para $domain."
                printf -v "$cert_var" '%s' "$cp"
                printf -v "$key_var"  '%s' "$kp"
                return 0
            else
                error "No se pudo obtener certificado."
                return 1
            fi
            ;;
        2)
            echo -e "  Ruta al certificado (.crt/.pem): \c"; read -r cp
            echo -e "  Ruta a la clave privada (.key/.pem): \c"; read -r kp
            if [[ -f "$cp" && -f "$kp" ]]; then
                printf -v "$cert_var" '%s' "$cp"
                printf -v "$key_var"  '%s' "$kp"
                return 0
            else
                error "Archivos no encontrados."
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

_xray_fix_letsencrypt_perms() {
    local le_dir="/etc/letsencrypt"
    [[ -d "$le_dir" ]] || return 0
    chmod 755 "$le_dir/live/"    2>/dev/null || true
    chmod 755 "$le_dir/archive/" 2>/dev/null || true
    find "$le_dir/archive/" -name "*.pem" -exec chmod 644 {} \; 2>/dev/null || true
    find "$le_dir/live/"    -name "*.pem" -exec chmod 644 {} \; 2>/dev/null || true

    local hook_dir="$le_dir/renewal-hooks/deploy"
    mkdir -p "$hook_dir"
    cat > "$hook_dir/fix-xray-perms.sh" << 'HOOK'
#!/bin/bash
chmod 755 /etc/letsencrypt/live/    2>/dev/null || true
chmod 755 /etc/letsencrypt/archive/ 2>/dev/null || true
find /etc/letsencrypt/archive/ -name "*.pem" -exec chmod 644 {} \; 2>/dev/null || true
find /etc/letsencrypt/live/    -name "*.pem" -exec chmod 644 {} \; 2>/dev/null || true
systemctl restart xray 2>/dev/null || true
HOOK
    chmod +x "$hook_dir/fix-xray-perms.sh" 2>/dev/null || true
}

# ╔══════════════════════════════════════════════════════════╗
#  APLICAR CONFIG — guardar, validar y reiniciar Xray
# ╚══════════════════════════════════════════════════════════╝
_xray_apply_config() {
    local config_json="$1"
    mkdir -p "$XRAY_CFG_DIR" /var/log/xray

    # Validar JSON antes de escribir
    if ! echo "$config_json" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        error "JSON inválido — no se aplicará la configuración."
        echo "$config_json" | head -30
        _press_enter; return 1
    fi

    echo "$config_json" > "$XRAY_CFG"

    # Verificar puerto antes de arrancar
    local port
    port=$(python3 -c "
import json
try:
    d = json.load(open('$XRAY_CFG'))
    print(d['inbounds'][0].get('port',''))
except: print('')
" 2>/dev/null || echo "")

    if [[ -n "$port" ]] && _port_in_use "$port"; then
        warn "⚠  El puerto ${port} está en uso. Xray podría no iniciar."
        warn "Verifica con: ss -tlnp | grep :${port}"
        echo -e "  ${DIM}Considera matar el proceso o usar otro puerto ([3] Cambiar puerto).${NC}"
    fi

    # Test con xray si disponible
    if _cmd_exists "xray"; then
        if ! xray run -test -config "$XRAY_CFG" &>/dev/null; then
            warn "xray detectó un error en la config:"
            xray run -test -config "$XRAY_CFG" 2>&1 | head -10 | while IFS= read -r l; do
                echo -e "  ${R}${l}${NC}"
            done
        else
            success "Config JSON validada correctamente."
        fi
    fi

    _xray_fix_letsencrypt_perms

    systemctl daemon-reload 2>/dev/null
    systemctl enable xray 2>/dev/null || true
    systemctl restart xray 2>/dev/null || true
    sleep 2

    if _service_active "xray"; then
        success "Xray activo con nueva configuración."
    else
        error "Xray no pudo iniciar. Diagnóstico:"
        journalctl -u xray -n 15 --no-pager 2>/dev/null | while IFS= read -r l; do
            echo -e "  ${DIM}${l}${NC}"
        done || true
        echo ""
        warn "Puerto en uso — libera el puerto o cambia con opción [3]."
        info "Ver proceso en puerto: ${W}ss -tlnp | grep :${port}${NC}"
        info "Matar proceso:         ${W}fuser -k ${port}/tcp${NC}"
        info "Depurar manualmente:   ${W}xray run -config $XRAY_CFG${NC}"
    fi
}

# ╔══════════════════════════════════════════════════════════╗
#  SYNC — Sincroniza usuarios activos al config.json
# ╚══════════════════════════════════════════════════════════╝
_xray_sync_config() {
    [[ -f "$XRAY_CFG" ]] || return
    python3 - << PYSYNC "$XRAY_CFG" "$XRAY_USERS_FILE"
import json, sys

cfg_path   = sys.argv[1]
users_path = sys.argv[2]

try:
    cfg = json.load(open(cfg_path))
    ud  = json.load(open(users_path))
except Exception as e:
    print(f"Error leyendo archivos: {e}")
    sys.exit(1)

active_clients = []
proto = cfg["inbounds"][0].get("protocol","vmess")

for u in ud.get("users",[]):
    if u.get("locked", False):
        continue
    if proto == "vmess":
        active_clients.append({"id": u["uuid"], "alterId": 0, "level": 8, "security": "auto"})
    elif proto == "vless":
        active_clients.append({"id": u["uuid"], "flow": "", "level": 0, "email": u.get("name","user") + "@vless"})
    elif proto == "trojan":
        active_clients.append({"password": u.get("password", u["uuid"])})

cfg["inbounds"][0]["settings"]["clients"] = active_clients
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)

print(f"Sincronizados {len(active_clients)} usuarios activos.")
PYSYNC
}

# ╔══════════════════════════════════════════════════════════╗
#  PANEL PRINCIPAL XRAY / V2RAY
# ╚══════════════════════════════════════════════════════════╝
handle_v2ray() {
    while true; do
        clear
        _xray_users_init

        local xray_bin=""
        _cmd_exists "xray"  && xray_bin="xray"
        _cmd_exists "v2ray" && [[ -z "$xray_bin" ]] && xray_bin="v2ray"

        local xray_status
        if _service_active "xray"; then
            xray_status="${G}● ACTIVO${NC}"
        elif _service_active "v2ray"; then
            xray_status="${G}● ACTIVO (v2ray)${NC}"
        elif [[ -n "$xray_bin" ]]; then
            xray_status="${Y}● INSTALADO / INACTIVO${NC}"
        else
            xray_status="${R}● NO INSTALADO${NC}"
        fi

        local puerto proto tls_st n_users n_locked n_conn
        puerto=$(_xray_get_port)
        proto=$(_xray_get_proto)
        tls_st=$(_xray_get_tls)
        n_users=$(_xray_count_users)
        n_locked=$(_xray_count_locked)
        n_conn=$(_xray_count_connected)

        local tls_label tls_plain
        if   [[ "$tls_st" == "tls"     ]]; then tls_label="${G}[ TLS ]${NC}";      tls_plain="TLS"
        elif [[ "$tls_st" == "reality" ]]; then tls_label="${C}[ Reality ]${NC}";  tls_plain="Reality"
        else                                    tls_label="${R}[ NONE ]${NC}";     tls_plain="NONE"
        fi

        local LN="══════════════════════════════════════════════════════"
        echo -e ""
        echo -e "  ${C}${BOLD}╔${LN}╗${NC}"
        echo -e "  ${C}${BOLD}║${NC}  ${W}${BOLD}   V2RAY / XRAY — Panel de Control             ${NC}${C}${BOLD}║${NC}"
        echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
        echo -e "  ${C}║${NC}  Estado    : $xray_status"
        echo -e "  ${C}║${NC}  Protocolo : ${W}${proto}${NC}"
        echo -e "  ${C}║${NC}  Puerto    : ${W}${puerto}${NC}   TLS: ${tls_label}"
        echo -e "  ${C}║${NC}  Usuarios  : ${G}${n_users} registrados${NC}  ${R}${n_locked} bloqueados${NC}  ${Y}${n_conn} online${NC}"
        echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
        echo -e "  ${C}║${NC}  ${W}[1]${NC}   Instalar / Actualizar Xray"
        echo -e "  ${C}║${NC}  ${W}[2]${NC}   Cambiar protocolo           ${DIM}(Wizard)${NC}"
        echo -e "  ${C}║${NC}  ${W}[3]${NC}   Cambiar puerto V2Ray        ${DIM}[ ${puerto} ]${NC}"
        echo -e "  ${C}║${NC}  ${W}[4]${NC}   TLS Estado →                ${DIM}[ ${tls_plain} ]${NC}"
        echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
        echo -e "  ${C}║${NC}  ${Y}${BOLD}── Usuarios UUID ──────────────────────────────${NC}"
        echo -e "  ${C}║${NC}  ${W}[5]${NC}   Agregar usuario"
        echo -e "  ${C}║${NC}  ${W}[6]${NC}   Eliminar usuario"
        echo -e "  ${C}║${NC}  ${W}[b]${NC}   LOCK / UNLOCK usuarios"
        echo -e "  ${C}║${NC}  ${W}[9]${NC}   Listar usuarios registrados  ${DIM}( ${n_users} )${NC}"
        echo -e "  ${C}║${NC}  ${W}[10]${NC}  Limpiador de expirados"
        echo -e "  ${C}${BOLD}╠${LN}╣${NC}"
        echo -e "  ${C}║${NC}  ${Y}${BOLD}── Estado / Diagnóstico ───────────────────────${NC}"
        echo -e "  ${C}║${NC}  ${W}[7]${NC}   Usuarios conectados"
        echo -e "  ${C}║${NC}  ${W}[8]${NC}   Información de conexión / QR"
        echo -e "  ${C}║${NC}  ${W}[a]${NC}   Activar / Desactivar Xray"
        echo -e "  ${C}║${NC}  ${W}[r]${NC}   Reiniciar Xray"
        echo -e "  ${C}║${NC}  ${W}[l]${NC}   Ver log en tiempo real"
        echo -e "  ${C}║${NC}  ${W}[c]${NC}   Ver configuración actual"
        echo -e "  ${C}║${NC}  ${W}[p]${NC}   ${Y}Diagnosticar puerto${NC}       ${DIM}(ver qué usa el puerto)${NC}"
        echo -e "  ${C}║${NC}  ${W}[11]${NC}  Desinstalar Xray / V2Ray"
        echo -e "  ${C}║${NC}  ${DIM}[0]   Volver${NC}"
        echo -e "  ${C}${BOLD}╚${LN}╝${NC}"
        echo ""
        echo -e "  Opción : \c"; read -r opt

        case "${opt,,}" in
        1)  _xray_install ;;
        2)  _xray_wizard  ;;
        3)  _xray_change_port ;;
        4)  _xray_toggle_tls ;;
        5)  _xray_add_user ;;
        6)  _xray_del_user ;;
        7)  _xray_show_connected ;;
        8)  _xray_show_client ;;
        b)  _xray_lock_unlock ;;
        9)  _xray_list_users ;;
        10) _xray_clean_expired ;;
        11) _xray_uninstall ;;
        p)
            echo ""
            local cur_port; cur_port=$(_xray_get_port)
            info "Puerto configurado: ${W}${cur_port}${NC}"
            if [[ "$cur_port" != "N/A" ]]; then
                echo -e "\n  ${Y}Procesos usando el puerto ${cur_port}:${NC}"
                ss -tlnp 2>/dev/null | grep ":${cur_port} " \
                    && true || echo -e "  ${G}(libre)${NC}"
                echo -e "\n  ${Y}Para liberar: ${W}fuser -k ${cur_port}/tcp${NC}"
            fi
            _press_enter
            ;;
        a)
            local svc; svc=$(_xray_svc)
            if _xray_is_active; then
                systemctl stop "$svc" 2>/dev/null
                systemctl disable "$svc" 2>/dev/null || true
                success "Xray → DETENIDO"
            else
                if ! _cmd_exists "xray"; then
                    error "Xray no está instalado. Usa [1] para instalar primero."
                    _press_enter; continue
                fi
                if ! [[ -f "$XRAY_CFG" ]]; then
                    error "No hay configuración. Usa [2] para configurar un protocolo."
                    _press_enter; continue
                fi
                # Verificar puerto antes de intentar iniciar
                local cfg_port
                cfg_port=$(python3 -c "
import json
try:
    d = json.load(open('$XRAY_CFG'))
    print(d['inbounds'][0].get('port',''))
except: print('')
" 2>/dev/null || echo "")
                if [[ -n "$cfg_port" ]] && _port_in_use "$cfg_port"; then
                    error "El puerto ${cfg_port} ya está en uso. Xray no puede iniciar."
                    warn "Proceso usando el puerto:"
                    ss -tlnp 2>/dev/null | grep ":${cfg_port} " | head -3 | while IFS= read -r l; do
                        echo -e "  ${R}$l${NC}"
                    done
                    echo ""
                    info "Opciones:"
                    info "  ${W}[3]${NC} Cambiar puerto de Xray a uno libre"
                    info "  Liberar puerto: ${W}fuser -k ${cfg_port}/tcp${NC}"
                    _press_enter; continue
                fi
                # Validar config antes de intentar iniciar
                if xray run -test -config "$XRAY_CFG" &>/dev/null; then
                    systemctl enable "$svc" 2>/dev/null || true
                    systemctl start "$svc" 2>/dev/null
                    sleep 2
                    _xray_is_active && success "Xray → ACTIVO" || {
                        error "No pudo iniciar. Diagnóstico:"
                        journalctl -u "$svc" -n 15 --no-pager 2>/dev/null | while IFS= read -r l; do
                            echo -e "  ${DIM}${l}${NC}"
                        done || true
                    }
                else
                    error "Config inválida. Ejecuta [2] Wizard para reconfigurar."
                    warn "Detalle del error:"
                    xray run -test -config "$XRAY_CFG" 2>&1 | head -10 | while IFS= read -r l; do
                        echo -e "  ${R}${l}${NC}"
                    done
                fi
            fi
            _press_enter
            ;;
        r)
            local svc; svc=$(_xray_svc)
            systemctl restart "$svc" 2>/dev/null
            sleep 1
            _xray_is_active && success "$svc reiniciado." || error "No pudo reiniciar."
            _press_enter
            ;;
        l)
            echo -e "\n  ${DIM}Log en tiempo real (Ctrl+C para salir)...${NC}\n"
            local svc; svc=$(_xray_svc)
            journalctl -u "$svc" -f --no-pager 2>/dev/null || warn "journalctl no disponible."
            ;;
        c)
            echo ""
            if [[ -f "$XRAY_CFG" ]]; then
                cat "$XRAY_CFG" | while read -r line; do echo -e "  ${DIM}$line${NC}"; done
            else
                warn "No hay config instalada. Usa [2] para configurar."
            fi
            _press_enter
            ;;
        0) return ;;
        *)  warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ╔══════════════════════════════════════════════════════════╗
#  INSTALAR XRAY
# ╚══════════════════════════════════════════════════════════╝
_xray_install() {
    clear
    echo -e "\n  ${W}${BOLD}── Instalar Xray (XTLS oficial) ──────────────────────${NC}\n"

    if _cmd_exists "xray"; then
        local ver; ver=$(xray version 2>/dev/null | head -1 || echo "desconocida")
        success "Xray ya instalado: $ver"
        echo -e "  ${W}[1]${NC} Reinstalar/Actualizar  ${DIM}[0]${NC} Cancelar"
        echo -e "  Selección: \c"; read -r o
        [[ "$o" == "1" ]] || { _press_enter; return; }
    fi

    info "Descargando instalador oficial Xray (XTLS)..."
    if bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) 2>/dev/null; then
        success "Xray instalado correctamente."
        local ver; ver=$(xray version 2>/dev/null | head -1 || echo "instalado")
        info "Versión: $ver"
        _xray_fix_letsencrypt_perms
        echo ""
        echo -e "  ${Y}⟶  Ve al menú [2] para configurar el protocolo.${NC}"
    else
        error "Falló la instalación automática."
        warn "Intenta manualmente:"
        echo -e "  ${DIM}bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)${NC}"
    fi
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  WIZARD — Elegir protocolo y configurar
# ╚══════════════════════════════════════════════════════════╝
_xray_wizard() {
    clear
    echo -e "\n  ${W}${BOLD}── Wizard V2Ray/Xray: Protocolo ──────────────────────${NC}\n"
    echo -e "  ${DIM}Elige el protocolo y tipo de transporte.${NC}"
    echo ""
    echo -e "  ${Y}${BOLD}── Sin TLS  (sin dominio — para HTTP Injector, NapsternetV, etc.) ──${NC}"
    echo -e "  ${W}[1]${NC} ${G}VMess + WebSocket${NC}          ${DIM}(sin TLS — host header + path)${NC}"
    echo -e "  ${W}[2]${NC} ${G}VMess + TCP${NC}                ${DIM}(sin TLS — conexión directa)${NC}"
    echo -e "  ${W}[3]${NC} ${G}VLESS + WebSocket${NC}          ${DIM}(sin TLS — más ligero que VMess)${NC}"
    echo -e "  ${W}[4]${NC} ${G}VLESS + TCP${NC}                ${DIM}(sin TLS — ultra ligero)${NC}"
    echo ""
    echo -e "  ${Y}${BOLD}── Con TLS  (requiere dominio o certificado) ──────────${NC}"
    echo -e "  ${W}[5]${NC} ${G}VMess + WebSocket + TLS${NC}    ${DIM}(recomendado, muy compatible)${NC}"
    echo -e "  ${W}[6]${NC} ${G}VLESS + WebSocket + TLS${NC}    ${DIM}(más ligero que VMess)${NC}"
    echo -e "  ${W}[7]${NC} ${G}Trojan + WebSocket + TLS${NC}   ${DIM}(parece HTTPS legítimo)${NC}"
    echo -e "  ${W}[8]${NC} ${G}VLESS + Reality${NC}            ${DIM}(máxima evasión, sin dominio propio)${NC}"
    echo ""
    echo -e "  ${DIM}[0]${NC} Volver"
    echo ""; echo -e "  Selección: \c"; read -r proto_opt

    case "$proto_opt" in
        1) _xray_config_vmess_ws      ;;
        2) _xray_config_vmess_tcp     ;;
        3) _xray_config_vless_ws      ;;
        4) _xray_config_vless_tcp     ;;
        5) _xray_config_vmess_ws_tls  ;;
        6) _xray_config_vless_ws_tls  ;;
        7) _xray_config_trojan_ws_tls ;;
        8) _xray_config_vless_reality ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
    esac
}

# ╔══════════════════════════════════════════════════════════╗
#  MODO 1: VMess + WebSocket — SIN TLS
#  Formato compatible con HTTP Injector / NapsternetV
# ╚══════════════════════════════════════════════════════════╝
_xray_config_vmess_ws() {
    clear
    echo -e "\n  ${W}${BOLD}── VMess + WebSocket (sin TLS) ───────────────────────${NC}\n"
    echo -e "  ${DIM}Ideal para HTTP Injector, NapsternetV, KPN Tunnel.${NC}\n"

    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID generado : ${G}${uuid}${NC}"
    echo -e "  ¿Personalizar UUID? [s/N]: \c"; read -r ans
    [[ "${ans,,}" == "s" ]] && { echo -e "  UUID: \c"; read -r uuid; }

    # Advertir sobre puerto 80/8080 si están en uso
    echo -e "\n  ${DIM}Puertos comunes sin TLS: 80, 8080, 8880, 2052, 2086, 2095${NC}"
    local port; _ask_port "8080" "Puerto de escucha" port
    local ws_path; _ask_ws_path "/ws" ws_path

    echo -e "  Host header (ej: cdn.operador.com — vacío para ninguno): \c"
    read -r ws_host

    local addr; _ask_server_addr addr

    local config_json
    config_json=$(python3 - << PYEOF
import json
ws_s = {"path": "$ws_path"}
if "$ws_host":
    ws_s["headers"] = {"Host": "$ws_host"}
cfg = {
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log"},
  "inbounds": [{
    "port": $port,
    "listen": "0.0.0.0",
    "protocol": "vmess",
    "settings": {
      "clients": [{"id": "$uuid", "alterId": 0, "level": 8, "security": "auto"}]
    },
    "streamSettings": {
      "network": "ws",
      "security": "none",
      "wsSettings": ws_s
    },
    "sniffing": {"enabled": True, "destOverride": ["http","tls"]}
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}],
  "policy": {"levels": {"8": {"connIdle": 300, "downlinkOnly": 1, "handshake": 4, "uplinkOnly": 1}}}
}
print(json.dumps(cfg, indent=2))
PYEOF
)

    info "Aplicando VMess + WebSocket sin TLS..."
    _xray_apply_config "$config_json"

    cat > /etc/vps-henyer/xray_client.txt << CD
PROTOCOLO=VMess+WebSocket
DIRECCION=$addr
PUERTO=$port
UUID=$uuid
ALTERID=0
RED=ws
SEGURIDAD=none
PATH_WS=$ws_path
HOST_HEADER=$ws_host
CD
    _xray_show_client
}

# ╔══════════════════════════════════════════════════════════╗
#  MODO 2: VMess + TCP — SIN TLS
# ╚══════════════════════════════════════════════════════════╝
_xray_config_vmess_tcp() {
    clear
    echo -e "\n  ${W}${BOLD}── VMess + TCP (sin TLS) ─────────────────────────────${NC}\n"
    echo -e "  ${DIM}Sin dominio ni TLS. Rápido, conexión directa.${NC}\n"

    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID generado : ${G}${uuid}${NC}"
    echo -e "  ¿Personalizar UUID? [s/N]: \c"; read -r ans
    [[ "${ans,,}" == "s" ]] && { echo -e "  UUID: \c"; read -r uuid; }

    echo -e "\n  ${DIM}Puertos comunes sin TLS: 80, 8080, 8880, 2052, 2086, 2095${NC}"
    local port; _ask_port "8080" "Puerto de escucha" port
    local addr; _ask_server_addr addr

    local config_json
    config_json=$(python3 - << PYEOF
import json
cfg = {
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log"},
  "inbounds": [{
    "port": $port,
    "listen": "0.0.0.0",
    "protocol": "vmess",
    "settings": {
      "clients": [{"id": "$uuid", "alterId": 0, "level": 8, "security": "auto"}]
    },
    "streamSettings": {"network": "tcp", "security": "none"},
    "sniffing": {"enabled": True, "destOverride": ["http","tls"]}
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}],
  "policy": {"levels": {"8": {"connIdle": 300, "downlinkOnly": 1, "handshake": 4, "uplinkOnly": 1}}}
}
print(json.dumps(cfg, indent=2))
PYEOF
)

    info "Aplicando VMess + TCP sin TLS..."
    _xray_apply_config "$config_json"

    cat > /etc/vps-henyer/xray_client.txt << CD
PROTOCOLO=VMess+TCP
DIRECCION=$addr
PUERTO=$port
UUID=$uuid
ALTERID=0
RED=tcp
SEGURIDAD=none
CD
    _xray_show_client
}

# ╔══════════════════════════════════════════════════════════╗
#  MODO 3: VLESS + WebSocket — SIN TLS
# ╚══════════════════════════════════════════════════════════╝
_xray_config_vless_ws() {
    clear
    echo -e "\n  ${W}${BOLD}── VLESS + WebSocket (sin TLS) ───────────────────────${NC}\n"
    echo -e "  ${DIM}Más eficiente que VMess. Sin certificado necesario.${NC}\n"

    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID generado : ${G}${uuid}${NC}"
    echo -e "  ¿Personalizar UUID? [s/N]: \c"; read -r ans
    [[ "${ans,,}" == "s" ]] && { echo -e "  UUID: \c"; read -r uuid; }

    echo -e "\n  ${DIM}Puertos comunes sin TLS: 80, 8080, 8880, 2052, 2086, 2095${NC}"
    local port; _ask_port "8080" "Puerto de escucha" port
    local ws_path; _ask_ws_path "/vless" ws_path
    echo -e "  Host header (vacío para ninguno): \c"; read -r ws_host
    local addr; _ask_server_addr addr

    local config_json
    config_json=$(python3 - << PYEOF
import json
ws_s = {"path": "$ws_path"}
if "$ws_host":
    ws_s["headers"] = {"Host": "$ws_host"}
cfg = {
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log"},
  "inbounds": [{
    "port": $port,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$uuid", "level": 0, "email": "user@vless"}],
      "decryption": "none"
    },
    "streamSettings": {"network": "ws", "security": "none", "wsSettings": ws_s},
    "sniffing": {"enabled": True, "destOverride": ["http","tls"]}
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
print(json.dumps(cfg, indent=2))
PYEOF
)

    info "Aplicando VLESS + WebSocket sin TLS..."
    _xray_apply_config "$config_json"

    cat > /etc/vps-henyer/xray_client.txt << CD
PROTOCOLO=VLESS+WebSocket
DIRECCION=$addr
PUERTO=$port
UUID=$uuid
RED=ws
SEGURIDAD=none
PATH_WS=$ws_path
HOST_HEADER=$ws_host
CD
    _xray_show_client
}

# ╔══════════════════════════════════════════════════════════╗
#  MODO 4: VLESS + TCP — SIN TLS
# ╚══════════════════════════════════════════════════════════╝
_xray_config_vless_tcp() {
    clear
    echo -e "\n  ${W}${BOLD}── VLESS + TCP (sin TLS) ─────────────────────────────${NC}\n"
    echo -e "  ${DIM}Ultra ligero. Sin overhead de VMess ni TLS.${NC}\n"

    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID generado : ${G}${uuid}${NC}"
    echo -e "  ¿Personalizar UUID? [s/N]: \c"; read -r ans
    [[ "${ans,,}" == "s" ]] && { echo -e "  UUID: \c"; read -r uuid; }

    echo -e "\n  ${DIM}Puertos comunes sin TLS: 80, 8080, 8880, 2052, 2086, 2095${NC}"
    local port; _ask_port "8080" "Puerto de escucha" port
    local addr; _ask_server_addr addr

    local config_json
    config_json=$(python3 - << PYEOF
import json
cfg = {
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log"},
  "inbounds": [{
    "port": $port,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$uuid", "level": 0, "email": "user@vless"}],
      "decryption": "none"
    },
    "streamSettings": {"network": "tcp", "security": "none"},
    "sniffing": {"enabled": True, "destOverride": ["http","tls"]}
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
print(json.dumps(cfg, indent=2))
PYEOF
)

    info "Aplicando VLESS + TCP sin TLS..."
    _xray_apply_config "$config_json"

    cat > /etc/vps-henyer/xray_client.txt << CD
PROTOCOLO=VLESS+TCP
DIRECCION=$addr
PUERTO=$port
UUID=$uuid
RED=tcp
SEGURIDAD=none
CD
    _xray_show_client
}

# ╔══════════════════════════════════════════════════════════╗
#  MODO 5: VMess + WebSocket + TLS
# ╚══════════════════════════════════════════════════════════╝
_xray_config_vmess_ws_tls() {
    clear
    echo -e "\n  ${W}${BOLD}── VMess + WebSocket + TLS ───────────────────────────${NC}\n"

    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID generado : ${G}${uuid}${NC}"
    echo -e "  ¿Personalizar UUID? [s/N]: \c"; read -r ans
    [[ "${ans,,}" == "s" ]] && { echo -e "  UUID: \c"; read -r uuid; }

    local port; _ask_port "443" "Puerto de escucha" port
    echo -e "  Dominio del servidor: \c"; read -r domain
    domain="${domain:-$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo 'TU_DOMINIO')}"
    local ws_path; _ask_ws_path "/ws" ws_path

    local _CERT_PATH _KEY_PATH
    _ask_tls_cert "$domain" _CERT_PATH _KEY_PATH || { _press_enter; return; }

    local config_json
    config_json=$(python3 - << PYEOF
import json
cfg = {
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log"},
  "inbounds": [{
    "port": $port,
    "listen": "0.0.0.0",
    "protocol": "vmess",
    "settings": {
      "clients": [{"id": "$uuid", "alterId": 0, "level": 8, "security": "auto"}]
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{"certificateFile": "$_CERT_PATH", "keyFile": "$_KEY_PATH"}],
        "alpn": ["h2","http/1.1"]
      },
      "wsSettings": {"path": "$ws_path"}
    },
    "sniffing": {"enabled": True, "destOverride": ["http","tls"]}
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}],
  "policy": {"levels": {"8": {"connIdle": 300, "downlinkOnly": 1, "handshake": 4, "uplinkOnly": 1}}}
}
print(json.dumps(cfg, indent=2))
PYEOF
)

    info "Aplicando VMess + WS + TLS..."
    _xray_apply_config "$config_json"

    cat > /etc/vps-henyer/xray_client.txt << CD
PROTOCOLO=VMess+WebSocket+TLS
DIRECCION=$domain
PUERTO=$port
UUID=$uuid
ALTERID=0
RED=ws
SEGURIDAD=tls
PATH_WS=$ws_path
CD
    _xray_show_client
}

# ╔══════════════════════════════════════════════════════════╗
#  MODO 6: VLESS + WebSocket + TLS
# ╚══════════════════════════════════════════════════════════╝
_xray_config_vless_ws_tls() {
    clear
    echo -e "\n  ${W}${BOLD}── VLESS + WebSocket + TLS ───────────────────────────${NC}\n"

    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID generado : ${G}${uuid}${NC}"
    echo -e "  ¿Personalizar UUID? [s/N]: \c"; read -r ans
    [[ "${ans,,}" == "s" ]] && { echo -e "  UUID: \c"; read -r uuid; }

    local port; _ask_port "443" "Puerto de escucha" port
    echo -e "  Dominio: \c"; read -r domain
    domain="${domain:-$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo 'TU_DOMINIO')}"
    local ws_path; _ask_ws_path "/vless" ws_path

    local _CERT_PATH _KEY_PATH
    _ask_tls_cert "$domain" _CERT_PATH _KEY_PATH || { _press_enter; return; }

    local config_json
    config_json=$(python3 - << PYEOF
import json
cfg = {
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log"},
  "inbounds": [{
    "port": $port,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$uuid", "level": 0, "email": "user@vless"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{"certificateFile": "$_CERT_PATH", "keyFile": "$_KEY_PATH"}],
        "alpn": ["h2","http/1.1"]
      },
      "wsSettings": {"path": "$ws_path"}
    },
    "sniffing": {"enabled": True, "destOverride": ["http","tls"]}
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
print(json.dumps(cfg, indent=2))
PYEOF
)

    info "Aplicando VLESS + WS + TLS..."
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
#  MODO 7: Trojan + WebSocket + TLS
# ╚══════════════════════════════════════════════════════════╝
_xray_config_trojan_ws_tls() {
    clear
    echo -e "\n  ${W}${BOLD}── Trojan + WebSocket + TLS ──────────────────────────${NC}\n"

    echo -e "  Contraseña Trojan (vacío = auto): \c"; read -rs trojan_pass; echo
    [[ -z "$trojan_pass" ]] && trojan_pass="$(_gen_uuid | cut -c1-16)"
    echo -e "  Contraseña: ${G}${trojan_pass}${NC}"

    local port; _ask_port "443" "Puerto de escucha" port
    echo -e "  Dominio: \c"; read -r domain
    domain="${domain:-$(curl -s --max-time 4 https://ipv4.icanhazip.com 2>/dev/null || echo 'TU_DOMINIO')}"
    local ws_path; _ask_ws_path "/trojan" ws_path

    local _CERT_PATH _KEY_PATH
    _ask_tls_cert "$domain" _CERT_PATH _KEY_PATH || { _press_enter; return; }

    local config_json
    config_json=$(python3 - << PYEOF
import json
cfg = {
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log"},
  "inbounds": [{
    "port": $port,
    "listen": "0.0.0.0",
    "protocol": "trojan",
    "settings": {"clients": [{"password": "$trojan_pass"}]},
    "streamSettings": {
      "network": "ws",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{"certificateFile": "$_CERT_PATH", "keyFile": "$_KEY_PATH"}]
      },
      "wsSettings": {"path": "$ws_path"}
    }
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
print(json.dumps(cfg, indent=2))
PYEOF
)

    info "Aplicando Trojan + WS + TLS..."
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

# ╔══════════════════════════════════════════════════════════╗
#  MODO 8: VLESS + Reality
# ╚══════════════════════════════════════════════════════════╝
_xray_config_vless_reality() {
    clear
    echo -e "\n  ${W}${BOLD}── VLESS + Reality ───────────────────────────────────${NC}\n"
    echo -e "  ${DIM}Máxima evasión. Usa TLS de otro sitio. Sin dominio propio.${NC}\n"

    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID generado : ${G}${uuid}${NC}"
    echo -e "  ¿Personalizar UUID? [s/N]: \c"; read -r ans
    [[ "${ans,,}" == "s" ]] && { echo -e "  UUID: \c"; read -r uuid; }

    local port; _ask_port "443" "Puerto de escucha" port
    echo -e "  Destino SNI (ej: www.microsoft.com) [default: www.microsoft.com]: \c"; read -r sni
    sni="${sni:-www.microsoft.com}"

    local priv_key pub_key short_id
    short_id=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 8)

    if _cmd_exists "xray"; then
        local keys; keys=$(xray x25519 2>/dev/null || echo "")
        priv_key=$(echo "$keys" | grep "Private" | awk '{print $3}')
        pub_key=$(echo  "$keys" | grep "Public"  | awk '{print $3}')
    fi

    if [[ -z "$priv_key" || -z "$pub_key" ]]; then
        warn "No se pudo generar par de claves con xray x25519."
        warn "Instala Xray primero con la opción [1]."
        _press_enter; return
    fi

    local config_json
    config_json=$(python3 - << PYEOF
import json
cfg = {
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log"},
  "inbounds": [{
    "port": $port,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$uuid", "flow": "xtls-rprx-vision", "level": 0}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": False,
        "dest": "${sni}:443",
        "xver": 0,
        "serverNames": ["$sni"],
        "privateKey": "$priv_key",
        "shortIds": ["$short_id"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}}]
}
print(json.dumps(cfg, indent=2))
PYEOF
)

    local addr; _ask_server_addr addr
    info "Aplicando VLESS + Reality..."
    _xray_apply_config "$config_json"

    cat > /etc/vps-henyer/xray_client.txt << CD
PROTOCOLO=VLESS+Reality
DIRECCION=$addr
PUERTO=$port
UUID=$uuid
RED=tcp
SEGURIDAD=reality
SNI=$sni
PUBLIC_KEY=$pub_key
SHORT_ID=$short_id
FLOW=xtls-rprx-vision
FINGERPRINT=chrome
CD
    _xray_show_client
}

# ╔══════════════════════════════════════════════════════════╗
#  CAMBIAR PUERTO
# ╚══════════════════════════════════════════════════════════╝
_xray_change_port() {
    clear
    echo -e "\n  ${W}${BOLD}── Cambiar Puerto V2Ray ──────────────────────────────${NC}\n"
    local current; current=$(_xray_get_port)
    info "Puerto actual: ${W}${current}${NC}"
    echo -e "  Nuevo puerto [1-65535]: \c"; read -r nport

    if [[ "$nport" =~ ^[0-9]+$ ]] && (( nport > 0 && nport < 65536 )); then
        if _port_in_use "$nport"; then
            warn "El puerto $nport ya está en uso:"
            ss -tlnp 2>/dev/null | grep ":${nport} " | head -3
            echo -e "  ${Y}¿Continuar de todas formas? [s/N]: \c"; read -r force
            [[ "${force,,}" != "s" ]] && { info "Cancelado."; _press_enter; return; }
        fi
        python3 - "$XRAY_CFG" "$nport" << 'PYPORT'
import json, sys
cfg_path = sys.argv[1]; port = int(sys.argv[2])
try:
    d = json.load(open(cfg_path))
    d["inbounds"][0]["port"] = port
    json.dump(d, open(cfg_path,"w"), indent=2)
    print(f"Puerto actualizado a {port}")
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
PYPORT
        local svc; svc=$(_xray_svc)
        systemctl restart "$svc" 2>/dev/null
        sleep 1
        _xray_is_active && success "Xray reiniciado en puerto $nport" || error "No pudo reiniciar."
        command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active" \
            && ufw allow "$nport/tcp" > /dev/null 2>&1 && info "UFW: puerto $nport abierto."
    else
        error "Puerto inválido."
    fi
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  TOGGLE TLS — Info y acceso al wizard
# ╚══════════════════════════════════════════════════════════╝
_xray_toggle_tls() {
    clear
    echo -e "\n  ${W}${BOLD}── TLS Estado ────────────────────────────────────────${NC}\n"
    local tls; tls=$(_xray_get_tls)
    local proto; proto=$(_xray_get_proto)
    info "TLS actual    : ${W}${tls}${NC}"
    info "Protocolo     : ${W}${proto}${NC}"
    echo ""
    echo -e "  ${W}[1]${NC} Cambiar protocolo completo (Wizard)"
    echo -e "  ${W}[2]${NC} Ver certificados Let's Encrypt instalados"
    echo -e "  ${DIM}[0]${NC} Volver"
    echo -e "  Selección: \c"; read -r o
    case "$o" in
        1) _xray_wizard ;;
        2)
            echo ""
            if [[ -d /etc/letsencrypt/live ]]; then
                ls /etc/letsencrypt/live/ 2>/dev/null | while read -r d; do
                    echo -e "  ${G}●${NC} $d"
                done || echo -e "  ${DIM}(ninguno)${NC}"
            else
                warn "Let's Encrypt no instalado o sin certificados."
            fi
            _press_enter
            ;;
        0) return ;;
    esac
}

# ╔══════════════════════════════════════════════════════════╗
#  AGREGAR USUARIO UUID
# ╚══════════════════════════════════════════════════════════╝
_xray_add_user() {
    clear
    echo -e "\n  ${W}${BOLD}── Agregar Usuario UUID ──────────────────────────────${NC}\n"
    _xray_users_init

    echo -e "  Nombre del usuario: \c"; read -r uname
    [[ -z "$uname" ]] && { error "Nombre vacío."; _press_enter; return; }

    if ! python3 -c "
import json,sys
d=json.load(open('$XRAY_USERS_FILE'))
names=[u['name'] for u in d.get('users',[])]
sys.exit(0 if '$uname' not in names else 1)
" 2>/dev/null; then
        error "El usuario '$uname' ya existe."; _press_enter; return
    fi

    local uuid; uuid=$(_gen_uuid)
    echo -e "  UUID generado : ${G}${uuid}${NC}"
    echo -e "  ¿Usar este UUID? [S/n]: \c"; read -r ans
    [[ "${ans,,}" == "n" ]] && { echo -e "  UUID manual: \c"; read -r uuid; }

    echo -e "  Días hasta expiración (0 = sin límite): \c"; read -r dias
    [[ "$dias" =~ ^[0-9]+$ ]] || dias=0

    local exp_date="never"
    (( dias > 0 )) && exp_date=$(date -d "+${dias} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')

    python3 - "$XRAY_USERS_FILE" "$uname" "$uuid" "$exp_date" << 'PYADD'
import json, sys
path, name, uuid, expiry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open(path))
d["users"].append({
    "name": name, "uuid": uuid,
    "expiry": expiry, "locked": False,
    "created": __import__('datetime').date.today().isoformat()
})
json.dump(d, open(path,"w"), indent=2)
PYADD

    _xray_sync_config
    local svc; svc=$(_xray_svc)
    systemctl restart "$svc" 2>/dev/null
    sleep 1

    success "Usuario '${uname}' agregado."
    echo -e "  ${W}UUID    :${NC} ${G}${uuid}${NC}"
    echo -e "  ${W}Expira  :${NC} $exp_date"
    echo -e "  ${W}Puerto  :${NC} $(_xray_get_port)"
    echo -e "  ${W}Protocolo:${NC} $(_xray_get_proto)"
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  ELIMINAR USUARIO UUID
# ╚══════════════════════════════════════════════════════════╝
_xray_del_user() {
    clear
    echo -e "\n  ${W}${BOLD}── Eliminar Usuario UUID ─────────────────────────────${NC}\n"
    _xray_users_init
    _xray_list_users_inline

    echo -e "  Nombre del usuario a eliminar: \c"; read -r uname
    [[ -z "$uname" ]] && { _press_enter; return; }

    echo -e "  ${Y}⚠  ¿Eliminar '${uname}'? [s/N]: \c"; read -r conf
    [[ "${conf,,}" != "s" ]] && { info "Cancelado."; _press_enter; return; }

    python3 - "$XRAY_USERS_FILE" "$uname" << 'PYDEL'
import json, sys
path, name = sys.argv[1], sys.argv[2]
d = json.load(open(path))
before = len(d["users"])
d["users"] = [u for u in d["users"] if u["name"] != name]
json.dump(d, open(path,"w"), indent=2)
sys.exit(0 if (before - len(d["users"])) else 1)
PYDEL

    if [[ $? -eq 0 ]]; then
        _xray_sync_config
        local svc; svc=$(_xray_svc)
        systemctl restart "$svc" 2>/dev/null
        success "Usuario '$uname' eliminado."
    else
        error "Usuario '$uname' no encontrado."
    fi
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  LOCK / UNLOCK USUARIOS
# ╚══════════════════════════════════════════════════════════╝
_xray_lock_unlock() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── LOCK / UNLOCK Usuarios ────────────────────────────${NC}\n"
        _xray_users_init
        _xray_list_users_inline
        echo ""
        echo -e "  ${W}[1]${NC} Bloquear usuario   ${W}[2]${NC} Desbloquear usuario   ${DIM}[0]${NC} Volver"
        echo -e "  Selección: \c"; read -r o

        case "$o" in
        1|2)
            local action; [[ "$o" == "1" ]] && action="lock" || action="unlock"
            echo -e "  Nombre del usuario: \c"; read -r uname
            [[ -z "$uname" ]] && continue

            python3 - "$XRAY_USERS_FILE" "$uname" "$action" << 'PYLOCK'
import json, sys
path, name, action = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
found = False
for u in d["users"]:
    if u["name"] == name:
        u["locked"] = (action == "lock")
        found = True
        break
json.dump(d, open(path,"w"), indent=2)
sys.exit(0 if found else 1)
PYLOCK

            if [[ $? -eq 0 ]]; then
                _xray_sync_config
                local svc; svc=$(_xray_svc)
                systemctl restart "$svc" 2>/dev/null
                [[ "$action" == "lock" ]] \
                    && success "Usuario '$uname' BLOQUEADO." \
                    || success "Usuario '$uname' DESBLOQUEADO."
            else
                error "Usuario '$uname' no encontrado."
            fi
            _press_enter
            ;;
        0) return ;;
        *) warn "Opción inválida."; sleep 1 ;;
        esac
    done
}

# ── Listar usuarios (inline) ─────────────────────────────────
_xray_list_users_inline() {
    [[ -f "$XRAY_USERS_FILE" ]] || { echo -e "  ${DIM}(sin usuarios registrados)${NC}"; return; }
    python3 - "$XRAY_USERS_FILE" << 'PYLIST'
import json, sys
from datetime import date

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'
W='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'

d = json.load(open(sys.argv[1]))
users = d.get("users", [])
if not users:
    print(f"  {DIM}(sin usuarios registrados){NC}")
    sys.exit()

print(f"  {Y}{'USUARIO':<18} {'UUID':<38} {'EXPIRA':<12} {'ESTADO'}{NC}")
print(f"  {DIM}{'─'*80}{NC}")
for u in users:
    name   = u.get("name","?")[:17]
    uuid   = u.get("uuid","?")[:36]
    expiry = u.get("expiry","never")
    locked = u.get("locked", False)

    status = f"{R}BLOQUEADO{NC}" if locked else f"{G}ACTIVO{NC}"
    if not locked and expiry != "never":
        try:
            diff = (date.fromisoformat(expiry) - date.today()).days
            if diff < 0:
                status = f"{R}EXPIRADO{NC}"
            elif diff <= 3:
                status = f"{Y}VENCE {diff}d{NC}"
        except: pass

    print(f"  {G}{name:<18}{NC} {DIM}{uuid:<38}{NC} {W}{expiry:<12}{NC} {status}")
PYLIST
}

# ── Listar usuarios (pantalla completa) ──────────────────────
_xray_list_users() {
    clear
    echo -e "\n  ${W}${BOLD}── Usuarios Registrados ──────────────────────────────${NC}\n"
    _xray_users_init
    _xray_list_users_inline
    echo ""
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  USUARIOS CONECTADOS
# ╚══════════════════════════════════════════════════════════╝
_xray_show_connected() {
    clear
    echo -e "\n  ${W}${BOLD}── Usuarios Conectados ───────────────────────────────${NC}\n"

    local log_file="/var/log/xray/access.log"
    if [[ ! -f "$log_file" ]]; then
        warn "Log de acceso no encontrado en $log_file"
        info "Verifica que Xray tenga logging habilitado."
        _press_enter; return
    fi

    echo -e "  ${Y}${BOLD}Conexiones recientes:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    grep "accepted" "$log_file" 2>/dev/null | tail -20 | while read -r line; do
        echo -e "  ${G}●${NC} ${DIM}${line}${NC}"
    done || echo -e "  ${DIM}(sin conexiones recientes)${NC}"

    echo ""
    echo -e "  ${Y}${BOLD}Conexiones TCP activas:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────${NC}"
    local port; port=$(_xray_get_port)
    if [[ "$port" != "N/A" ]]; then
        ss -tnp 2>/dev/null | grep ":$port " | while read -r line; do
            echo -e "  ${C}$line${NC}"
        done || echo -e "  ${DIM}(ninguna)${NC}"
    fi
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  LIMPIADOR DE EXPIRADOS
# ╚══════════════════════════════════════════════════════════╝
_xray_clean_expired() {
    clear
    echo -e "\n  ${W}${BOLD}── Limpiador de Expirados ────────────────────────────${NC}\n"
    _xray_users_init

    local result
    result=$(python3 - "$XRAY_USERS_FILE" << 'PYCLEAN'
import json, sys
from datetime import date

path = sys.argv[1]
d    = json.load(open(path))
today = date.today()

expired = []
active  = []
for u in d.get("users", []):
    exp = u.get("expiry", "never")
    if exp != "never":
        try:
            if date.fromisoformat(exp) < today:
                expired.append(u["name"])
                continue
        except: pass
    active.append(u)

d["users"] = active
json.dump(d, open(path,"w"), indent=2)
if expired:
    print("ELIMINADOS: " + ", ".join(expired))
else:
    print("NINGUNO: No hay usuarios expirados.")
PYCLEAN
)

    echo -e "  $result"
    echo ""

    if echo "$result" | grep -q "^ELIMINADOS"; then
        _xray_sync_config
        local svc; svc=$(_xray_svc)
        systemctl restart "$svc" 2>/dev/null
        success "Xray sincronizado. Expirados eliminados."
    else
        info "No se realizaron cambios."
    fi
    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  VER DATOS / QR DE CONEXIÓN
# ╚══════════════════════════════════════════════════════════╝
_xray_show_client() {
    clear
    echo -e "\n  ${W}${BOLD}── Datos de Conexión ─────────────────────────────────${NC}\n"

    local client_file="/etc/vps-henyer/xray_client.txt"
    if [[ ! -f "$client_file" ]]; then
        warn "No hay configuración guardada. Usa el Wizard [2] primero."
        _press_enter; return
    fi

    # shellcheck disable=SC1090
    source <(grep -E '^[A-Z_]+=' "$client_file" 2>/dev/null || true)

    echo -e "  ${Y}${BOLD}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "  ${Y}║          DATOS DE CONEXIÓN — VPS-HENYER          ║${NC}"
    echo -e "  ${Y}╠═══════════════════════════════════════════════════╣${NC}"
    echo -e "  ${Y}║${NC}"
    echo -e "  ${Y}║${NC}  Protocolo  : ${W}${PROTOCOLO:-N/A}${NC}"
    echo -e "  ${Y}║${NC}  Servidor   : ${W}${DIRECCION:-N/A}${NC}"
    echo -e "  ${Y}║${NC}  Puerto     : ${W}${PUERTO:-N/A}${NC}"
    [[ -n "${UUID:-}"        ]] && echo -e "  ${Y}║${NC}  UUID       : ${G}${UUID}${NC}"
    [[ -n "${PASSWORD:-}"    ]] && echo -e "  ${Y}║${NC}  Password   : ${G}${PASSWORD}${NC}"
    [[ -n "${ALTERID:-}"     ]] && echo -e "  ${Y}║${NC}  Alter ID   : ${W}${ALTERID}${NC}"
    echo -e "  ${Y}║${NC}  Red        : ${W}${RED:-N/A}${NC}"
    echo -e "  ${Y}║${NC}  Seguridad  : ${W}${SEGURIDAD:-none}${NC}"
    [[ -n "${PATH_WS:-}"     ]] && echo -e "  ${Y}║${NC}  WS Path    : ${W}${PATH_WS}${NC}"
    [[ -n "${HOST_HEADER:-}" && "${HOST_HEADER:-}" != "" ]] \
        && echo -e "  ${Y}║${NC}  Host Hdr   : ${W}${HOST_HEADER}${NC}"
    [[ -n "${SNI:-}"         ]] && echo -e "  ${Y}║${NC}  SNI        : ${W}${SNI}${NC}"
    [[ -n "${PUBLIC_KEY:-}"  ]] && echo -e "  ${Y}║${NC}  Public Key : ${G}${PUBLIC_KEY}${NC}"
    [[ -n "${SHORT_ID:-}"    ]] && echo -e "  ${Y}║${NC}  Short ID   : ${W}${SHORT_ID}${NC}"
    [[ -n "${FLOW:-}"        ]] && echo -e "  ${Y}║${NC}  Flow       : ${W}${FLOW}${NC}"
    [[ -n "${FINGERPRINT:-}" ]] && echo -e "  ${Y}║${NC}  Fingerprint: ${W}${FINGERPRINT}${NC}"
    echo -e "  ${Y}║${NC}"
    echo -e "  ${Y}╠═══════════════════════════════════════════════════╣${NC}"
    echo -e "  ${Y}║${NC}  ${DIM}Apps: v2rayNG, v2rayN, NekoBox, Hiddify,${NC}"
    echo -e "  ${Y}║${NC}  ${DIM}      Shadowrocket, V2Box, HTTP Injector, NapsternetV${NC}"
    echo -e "  ${Y}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    # Generar link vmess://
    if [[ "${PROTOCOLO:-}" == VMess* ]]; then
        local vmess_json
        vmess_json=$(python3 -c "
import json, base64
d = {
    'v':'2', 'ps':'VPS-HENYER', 'add':'${DIRECCION:-}',
    'port':'${PUERTO:-0}', 'id':'${UUID:-}', 'aid':'${ALTERID:-0}',
    'net':'${RED:-tcp}', 'type':'none',
    'host':'${HOST_HEADER:-${DIRECCION:-}}',
    'path':'${PATH_WS:-/}', 'tls':'${SEGURIDAD:-none}'
}
print('vmess://' + base64.b64encode(json.dumps(d).encode()).decode())
" 2>/dev/null || echo "")
        [[ -n "$vmess_json" ]] && {
            echo -e "  ${C}${BOLD}Link VMess:${NC}"
            echo -e "  ${G}${vmess_json}${NC}"
            echo ""
        }
    fi

    # Generar link vless://
    if [[ "${PROTOCOLO:-}" == VLESS* && "${SEGURIDAD:-}" != "reality" ]]; then
        local vless_link="vless://${UUID:-}@${DIRECCION:-}:${PUERTO:-443}?encryption=none&security=${SEGURIDAD:-none}&type=${RED:-tcp}&path=${PATH_WS:-/}&host=${HOST_HEADER:-}#VPS-HENYER"
        echo -e "  ${C}${BOLD}Link VLESS:${NC}"
        echo -e "  ${G}${vless_link}${NC}"
        echo ""
    fi

    # Generar link vless+Reality
    if [[ "${SEGURIDAD:-}" == "reality" ]]; then
        local reality_link="vless://${UUID:-}@${DIRECCION:-}:${PUERTO:-443}?encryption=none&flow=${FLOW:-}&security=reality&sni=${SNI:-}&fp=${FINGERPRINT:-chrome}&pbk=${PUBLIC_KEY:-}&sid=${SHORT_ID:-}&type=tcp#VPS-HENYER"
        echo -e "  ${C}${BOLD}Link VLESS+Reality:${NC}"
        echo -e "  ${G}${reality_link}${NC}"
        echo ""
    fi

    # Generar link trojan://
    if [[ "${PROTOCOLO:-}" == Trojan* ]]; then
        local trojan_link="trojan://${PASSWORD:-}@${DIRECCION:-}:${PUERTO:-443}?security=${SEGURIDAD:-tls}&type=${RED:-ws}&path=${PATH_WS:-/}#VPS-HENYER"
        echo -e "  ${C}${BOLD}Link Trojan:${NC}"
        echo -e "  ${G}${trojan_link}${NC}"
        echo ""
    fi

    _press_enter
}

# ╔══════════════════════════════════════════════════════════╗
#  DESINSTALAR XRAY
# ╚══════════════════════════════════════════════════════════╝
_xray_uninstall() {
    clear
    echo -e "\n  ${R}${BOLD}── Desinstalar Xray / V2Ray ──────────────────────────${NC}\n"
    echo -e "  ${Y}⚠  Esto eliminará Xray, su configuración y usuarios.${NC}"
    echo ""
    echo -e "  ${W}[1]${NC} Confirmar desinstalación  ${DIM}[0]${NC} Cancelar"
    echo -e "  Selección: \c"; read -r o
    [[ "$o" != "1" ]] && return

    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) --remove 2>/dev/null \
        || rm -f /usr/local/bin/xray /usr/local/bin/v2ray 2>/dev/null || true

    rm -rf "$XRAY_CFG_DIR" "$XRAY_USERS_FILE" /var/log/xray 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    success "Xray desinstalado correctamente."
    _press_enter
}

# ── Punto de entrada ─────────────────────────────────────────
handle_v2ray
