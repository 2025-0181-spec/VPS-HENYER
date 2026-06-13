#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo BadVPN-UDPGW (UDP para llamadas VoIP)
# ============================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

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
                udpgw_port=$(grep -oP '\-\-listen-addr 127\.0\.0\.1:\K[0-9]+' \
                    /etc/systemd/system/badvpn-udpgw.service 2>/dev/null || echo "7300")
                udpgw_status="${G}● ACTIVO (${udpgw_port})${NC}"
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
                udpgw_bin=$(command -v badvpn-udpgw)
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
                _service_active "badvpn-udpgw" && success "badvpn-udpgw → ACTIVO (127.0.0.1:${udpgw_port})" \
                    || error "No pudo iniciar. Revisa: journalctl -u badvpn-udpgw"
            fi
            _press_enter
            ;;
        3)
            echo -e "  Nuevo puerto UDPGW (actual: ${udpgw_port}): \c"; read -r nport
            if [[ "$nport" =~ ^[0-9]+$ ]] && (( nport > 1024 && nport < 65535 )); then
                if [[ -f /etc/systemd/system/badvpn-udpgw.service ]]; then
                    sed -i "s/127\.0\.0\.1:[0-9]*/127.0.0.1:$nport/" \
                        /etc/systemd/system/badvpn-udpgw.service
                    systemctl daemon-reload
                    systemctl restart badvpn-udpgw 2>/dev/null
                    success "Puerto UDPGW cambiado a $nport"
                else
                    error "BadVPN no está instalado. Usa la opción [1]."
                fi
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
            local ip; ip=$(_get_ip)
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

handle_badvpn
