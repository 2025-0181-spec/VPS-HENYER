#!/usr/bin/env bash
# ============================================================
#  VPS-HENYER — Módulo WebSocket + SSL/TLS (Nginx)
# ============================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

handle_websocket() {
    while true; do
        clear
        echo -e "\n  ${W}${BOLD}── WebSocket + SSL/TLS ──────────────────────────────${NC}\n"

        local ws_status nginx_status
        _port_in_use "80"  && nginx_status="${G}● Activo (80)${NC}"  || nginx_status="${R}● Inactivo${NC}"
        _port_in_use "443" && ws_status="${G}● SSL Activo (443)${NC}" || ws_status="${R}● SSL Inactivo${NC}"

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
            echo -e "  ${W}ws://$(_get_ip):80/${NC}"
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
            local ip; ip=$(_get_ip)
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

handle_websocket
