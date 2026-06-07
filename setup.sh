#!/usr/bin/env bash
# ============================================================
#   VPS-HENYER — Instalador Remoto Corregido
#   Uso: curl -sL https://raw.githubusercontent.com/2025-01-0181-spec/vps-henyer/main/setup.sh | bash
# ============================================================

set -euo pipefail

# ── Constantes ──────────────────────────────────────────────
readonly REPO_RAW="https://raw.githubusercontent.com/2025-01-0181-spec/vps-henyer/main"
readonly INSTALL_DIR="/etc/vps-henyer"
readonly BIN_PATH="/usr/local/bin/vps"
readonly LOG_DIR="/var/log/vps-henyer"
# Corregido: Sin barras diagonales y solo con tus archivos existentes
readonly SCRIPTS=("menu.sh" "protocols.sh")

# ── Colores ──────────────────────────────────────────────────
RED='\033;31m'; GREEN='\033;32m'; YELLOW='\033;33m'
CYAN='\033;36m'; BOLD='\033;1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Verificaciones previas ───────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || die "Ejecuta este script como root: sudo bash setup.sh"
}

check_arch() {
    local arch; arch=$(uname -m)
    [[ "$arch" == "x86_64" ]] || die "Arquitectura no soportada: $arch (requiere x86_64)"
    success "Arquitectura: $arch"
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "$ID" in
            ubuntu|debian) success "Sistema operativo: $PRETTY_NAME" ;;
            *) warn "Sistema no probado: $PRETTY_NAME — continuando de todas formas." ;;
         Palaesac
    else
        warn "No se pudo detectar el SO. Continuando..."
    fi
}

check_internet() {
    info "Verificando conexión a internet..."
    if ! curl -s --max-time 5 https://github.com > /dev/null 2>&1; then
        die "Sin acceso a internet o GitHub no responde."
    fi
    success "Conexión a internet OK"
}

install_dependencies() {
    info "Instalando dependencias base..."
    local deps=("curl" "wget" "git" "jq" "bc" "net-tools" "lsof")
    local to_install=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            to_install+=("$dep")
        fi
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        apt-get update -qq
        apt-get install -y -qq "${to_install[@]}" || die "Falló la instalación de dependencias."
        success "Dependencias installed: ${to_install[*]}"
    else
        success "Todas las dependencias ya están instaladas."
    fi
}

# ── Estructura de directorios ────────────────────────────────
create_dirs() {
    info "Creando estructura de directorios..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$LOG_DIR"
    chmod 755 "$INSTALL_DIR"
    chmod 755 "$LOG_DIR"
    success "Directorios creados en $INSTALL_DIR"
}

# ── Descarga de scripts ──────────────────────────────────────
download_scripts() {
    info "Descargando componentes desde GitHub..."
    local failed=0

    for script in "${SCRIPTS[@]}"; do
        local url="$REPO_RAW/$script"
        local dest="$INSTALL_DIR/$script"

        if curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"; then
            chmod +x "$dest"
            success "Descargado: $script"
        else
            warn "Falló: $script"
            ((failed++)) || true
        fi
    done

    [[ $failed -eq 0 ]] || die "$failed script(s) no se pudieron descargar."
}

# ── Versión ──────────────────────────────────────────────────
save_version() {
    local remote_version
    remote_version=$(curl -fsSL "$REPO_RAW/version.txt" 2>/dev/null || echo "1.0.0")
    echo "$remote_version" > "$INSTALL_DIR/version.txt"
    success "Versión instalada: $remote_version"
}

# ── Acceso global: comandos 'vps' y 'menu' ───────────────────
create_global_command() {
    cat > "$BIN_PATH" << 'GLOBALCMD'
#!/usr/bin/env bash
exec bash /etc/vps-henyer/menu.sh "$@"
GLOBALCMD
    chmod +x "$BIN_PATH"
    # Crear también el comando directo 'menu'
    ln -sf "$BIN_PATH" /usr/local/bin/menu
    success "Comandos globales creados: 'vps' y 'menu'"
}

# ── Banner de bienvenida ─────────────────────────────────────
print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔═══════════════════════════════════════╗"
    echo "  ║     VPS-HENYER — INSTALADOR           ║"
    echo "  ╚═══════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_success() {
    echo ""
    echo -e "${GREEN}${BOLD}  ✔  Instalación completada exitosamente${RESET}"
    echo ""
    echo -e "  ${BOLD}Uso:${RESET} escribe ${CYAN}vps${RESET} o ${CYAN}menu${RESET} en tu terminal"
    echo -e "  ${BOLD}Directorio:${RESET} $INSTALL_DIR"
    echo -e "  ${BOLD}Logs:${RESET} $LOG_DIR"
    echo ""
    echo -e "  Para iniciar ahora: ${YELLOW}menu${RESET}"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────
main() {
    print_banner
    check_root
    check_arch
    check_os
    check_internet
    install_dependencies
    create_dirs
    download_scripts
    save_version
    create_global_command
    print_success
}

main "$@"
