#!/usr/bin/env bash

# ============================================================
# Быстрая первичная настройка Ubuntu-сервера
# - смена SSH порта
# - отключение входа по паролю, если есть root SSH key
# - корректный reload/restart для ssh + ssh.socket
# - опциональная установка Docker из official Docker repo
# - опциональное обновление системы
#
# Сценарий: простой сервер, вход под root
# ============================================================

set -Eeuo pipefail

trap 'echo "❌ Ошибка на строке $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_NAME="$(basename "$0")"
SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSH_PORT_FILE="$SSH_DROPIN_DIR/99-custom-port.conf"
SSH_AUTH_FILE="$SSH_DROPIN_DIR/99-root-auth.conf"

log()  { echo -e "$*"; }
die()  { echo -e "❌ $*" >&2; exit 1; }
warn() { echo -e "⚠️  $*"; }

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Запустите как root или через sudo: sudo ./$SCRIPT_NAME"
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Не найден /etc/os-release"
    fi

    . /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Скрипт рассчитан на Ubuntu. Обнаружено: ${PRETTY_NAME:-unknown}"
    fi

    UBUNTU_CODENAME_RESOLVED="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$UBUNTU_CODENAME_RESOLVED" ]] || die "Не удалось определить codename Ubuntu"
}

ensure_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg iproute2 lsb-release >/dev/null
}

has_root_authorized_keys() {
    [[ -s /root/.ssh/authorized_keys ]]
}

backup_file_if_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.bak.$(date +%F-%H%M%S)"
    fi
}

configure_ssh() {
    log "🔧 [1/4] Настройка SSH..."

    local new_port
    read -r -p "Введите новый порт SSH (по умолчанию 2222): " new_port
    new_port="${new_port:-2222}"

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
        die "Неверный порт: '$new_port'"
    fi

    mkdir -p "$SSH_DROPIN_DIR"
    chmod 755 "$SSH_DROPIN_DIR"

    backup_file_if_exists "$SSH_PORT_FILE"
    backup_file_if_exists "$SSH_AUTH_FILE"

    cat > "$SSH_PORT_FILE" <<EOF
Port $new_port
EOF

    if has_root_authorized_keys; then
        cat > "$SSH_AUTH_FILE" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
EOF
        log "🔒 Для root найден SSH key — вход по паролю отключён."
    else
        rm -f "$SSH_AUTH_FILE"
        warn "У root не найден /root/.ssh/authorized_keys — вход по паролю оставлен."
    fi

    mkdir -p /run/sshd
    chmod 755 /run/sshd

    if ! sshd -t; then
        die "Конфиг SSH недействителен. Проверьте вручную: sshd -t"
    fi

    # На новых Ubuntu ssh может работать через socket activation.
    systemctl daemon-reload || true

    if systemctl list-unit-files | grep -q '^ssh.socket'; then
        systemctl restart ssh.socket || true
    fi

    systemctl restart ssh

    if ! systemctl is-active --quiet ssh; then
        die "SSH не запущен. Проверьте: systemctl status ssh --no-pager -l"
    fi

    local actual_port=""
    if actual_port="$(sshd -T 2>/dev/null | sed -n 's/^port //p' | head -n1)" && [[ -n "$actual_port" ]]; then
        if [[ "$actual_port" == "$new_port" ]]; then
            log "✅ sshd подтвердил порт: $actual_port"
        else
            warn "sshd сообщает порт '$actual_port', ожидался '$new_port'"
        fi
    else
        warn "Не удалось получить effective port через 'sshd -T'. Пропускаю эту проверку."
    fi

    if ss -tlnp | grep -qE "LISTEN.+:${new_port}\b"; then
        log "✅ Порт реально слушается: $new_port"
    else
        warn "Не вижу слушающий порт $new_port через ss. Проверьте:"
        warn "systemctl status ssh --no-pager -l"
        warn "systemctl status ssh.socket --no-pager -l"
    fi

    SSH_NEW_PORT="$new_port"
}

ask_install_docker() {
    local choice
    echo
    read -r -p "Установить Docker и Compose plugin? [Y/n]: " choice
    case "${choice:-Y}" in
        [nN]|[nN][oO]) INSTALL_DOCKER=false ;;
        *) INSTALL_DOCKER=true ;;
    esac
}

install_docker() {
    log "🐳 [2/4] Установка Docker из official repo..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg >/dev/null

    # Удаляем конфликтующие/старые пакеты
    apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc >/dev/null 2>&1 || true

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $UBUNTU_CODENAME_RESOLVED
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update -qq

    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin >/dev/null

    docker --version >/dev/null || die "Docker не установлен"
    docker compose version >/dev/null || die "Docker Compose plugin недоступен"

    # Совместимость для старых скриптов: docker-compose -> docker compose
    cat > /usr/local/bin/docker-compose <<'EOF'
#!/bin/sh
exec docker compose "$@"
EOF
    chmod +x /usr/local/bin/docker-compose

    log "✅ Docker установлен: $(docker --version)"
    log "✅ Compose plugin установлен: $(docker compose version)"
    log "ℹ️  /usr/local/bin/docker-compose создан как shim на 'docker compose'"
}

maybe_configure_ufw() {
    if ! command -v ufw >/dev/null 2>&1; then
        return
    fi

    if ! ufw status 2>/dev/null | grep -q "^Status: active"; then
        return
    fi

    echo
    read -r -p "UFW активен. Разрешить новый SSH порт ${SSH_NEW_PORT}/tcp сейчас? [Y/n]: " reply
    case "${reply:-Y}" in
        [nN]|[nN][oO])
            warn "Порт в UFW не открыт автоматически."
            ;;
        *)
            ufw allow "${SSH_NEW_PORT}/tcp"
            log "✅ UFW: разрешён порт ${SSH_NEW_PORT}/tcp"
            ;;
    esac
}

maybe_upgrade_system() {
    log
    log "📦 [3/4] Проверка обновлений..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1

    local upgradable
    upgradable="$(apt list --upgradable 2>/dev/null | grep -vc '^Listing\.\.\.$' || true)"
    upgradable="${upgradable:-0}"

    log "Доступно обновлений: $upgradable"

    if [[ "$upgradable" -le 0 ]]; then
        log "✅ Обновлять нечего."
        return
    fi

    echo
    read -r -p "Выполнить apt upgrade? [Y/n]: " reply
    case "${reply:-Y}" in
        [nN]|[nN][oO])
            log "⏭️  Обновление пропущено."
            return
            ;;
    esac

    echo
    read -r -p "Режим: (a) авто / (i) интерактивно? [a/i]: " mode
    case "${mode:-a}" in
        [iI]*)
            log "🔁 Интерактивное обновление..."
            apt-get upgrade
            ;;
        *)
            log "⏳ Автообновление..."
            apt-get upgrade -y -qq \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold"
            ;;
    esac

    log "✅ Обновление завершено."
}

print_summary() {
    log
    log "============================================"
    log "✅ Сервер настроен"
    log
    log "🔹 SSH порт: $SSH_NEW_PORT"

    if has_root_authorized_keys; then
        log "🔹 Root login: только по SSH ключу"
    else
        log "🔹 Root login: пароль оставлен включённым"
    fi

    if [[ "$INSTALL_DOCKER" == true ]]; then
        log "🔹 Docker: $(docker --version | sed 's/,//g')"
        log "🔹 Compose: $(docker compose version | head -n1)"
    else
        log "🔹 Docker: пропущен"
    fi

    log
    log "⚠️  Что сделать дальше:"
    log "   1. Переподключитесь:"
    log "      ssh -p $SSH_NEW_PORT root@YOUR_SERVER_IP"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        log "   2. После успешного входа можно убрать старый 22/tcp из UFW, если он больше не нужен"
    fi

    if [[ "$INSTALL_DOCKER" == true ]]; then
        log "   3. Проверка Docker:"
        log "      docker run hello-world"
    fi

    log "============================================"
}

main() {
    require_root
    check_os
    ensure_packages

    log "🚀 Начало настройки сервера..."
    log "ℹ️  Сценарий рассчитан на простой сервер с логином под root"

    configure_ssh
    maybe_configure_ufw
    ask_install_docker

    if [[ "$INSTALL_DOCKER" == true ]]; then
        install_docker
    else
        log "⏭️  Установка Docker пропущена."
    fi

    maybe_upgrade_system
    print_summary
}

main "$@"
