#!/bin/bash

# ───────────────────────────────────────────────────────────────
# 🚀 Быстрая настройка сервера: SSH → (опц. Docker) → Обновление
# ───────────────────────────────────────────────────────────────

set -e  # Exit on any unhandled error

if [ "$EUID" -ne 0 ]; then
    echo "❌ Запустите как root или через sudo: sudo $0"
    exit 1
fi

echo "🚀 Начало настройки (быстрые операции в первую очередь)..."

# ───────────────────────────────────────────────────────────────
# 1. Определение целевого пользователя (для docker-группы)
# ───────────────────────────────────────────────────────────────
TARGET_USER=""
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
elif [ "$USER" != "root" ]; then
    TARGET_USER="$USER"
else
    TARGET_USER=$(getent passwd {1000..65535} | awk -F: '($3 >= 1000) && ($3 != 65534) {print $1; exit}')
fi

# ───────────────────────────────────────────────────────────────
# 2. Настройка SSH (делаем сразу и критически!)
# ───────────────────────────────────────────────────────────────
echo "🔧 [1/5] Настройка SSH..."

read -p "Введите новый порт SSH (по умолчанию 2222): " -r NEW_PORT
NEW_PORT="${NEW_PORT:-2222}"

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo "❌ Неверный порт: '$NEW_PORT'"
    exit 1
fi

# Удаляем старые Port и добавляем новый
sed -i '/^[[:space:]]*Port[[:space:]]\+/d' /etc/ssh/sshd_config
echo "Port $NEW_PORT" >> /etc/ssh/sshd_config

# Отключаем пароли, если есть ключи
if [ -s /root/.ssh/authorized_keys ] || ls /home/*/\.ssh/authorized_keys 2>/dev/null | grep -q .; then
    sed -i 's/^[[:space:]]*#*[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    echo "🔒 Вход по паролю отключён."
else
    echo "⚠️  Вход по паролю оставлен — нет SSH-ключей."
fi

# Проверка конфига перед перезапуском
if ! sshd -t; then
    echo "❌ Конфиг SSH недействителен. Исправьте вручную:"
    echo "   sudo nano /etc/ssh/sshd_config"
    echo "   sudo sshd -t"
    exit 1
fi

systemctl restart ssh
if ! systemctl is-active --quiet ssh; then
    echo "❌ SSH не запущен. Проверьте: systemctl status ssh"
    exit 1
fi
echo "✅ SSH настроен на порт $NEW_PORT."

# ───────────────────────────────────────────────────────────────
# 3. Установка Docker? — выбор пользователя
# ───────────────────────────────────────────────────────────────
echo
read -p "Установить Docker и docker compose? [Y/n]: " -r DOCKER_CHOICE
case "${DOCKER_CHOICE:-Y}" in
    [yY]|[Yy][eE][sS]|"")
        INSTALL_DOCKER=true
        ;;
    *)
        INSTALL_DOCKER=false
        ;;
esac

# ───────────────────────────────────────────────────────────────
# Функция: установка Docker
# ───────────────────────────────────────────────────────────────
install_docker() {
    echo "🐳 [2/5] Установка Docker..."

    apt install -y -qq ca-certificates curl gnupg lsb-release >/dev/null

    # GPG-ключ (из knowledge base: /gpg существует)
    echo "🔑 Добавление GPG-ключа Docker..."
    install -m 0755 -d /etc/apt/keyrings
    # Убираем лишний пробел из URL (была ошибка в оригинале!)
    curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Репозиторий
    CODENAME=$(lsb_release -cs 2>/dev/null || { . /etc/os-release; echo "${VERSION_CODENAME:-jammy}"; })
    ARCH=$(dpkg --print-architecture)
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
        | tee /etc/apt/sources.list.d/docker.list >/dev/null

    apt update -qq >/dev/null

    apt install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
        >/dev/null

    # Проверка
    docker --version >/dev/null || { echo "❌ Docker не установлен."; exit 1; }
    docker compose version >/dev/null || { echo "❌ docker compose недоступен."; exit 1; }
    echo "✅ Docker и docker compose установлены."
}

# ───────────────────────────────────────────────────────────────
# Функция: совместимость `docker-compose` CLI
# ───────────────────────────────────────────────────────────────
setup_docker_compose_compat() {
    echo "🔗 [3/5] Настройка 'docker-compose' совместимости..."

    COMPOSE_BIN=""
    for p in /usr/lib/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose; do
        [ -x "$p" ] && COMPOSE_BIN="$p" && break
    done

    if [ -n "$COMPOSE_BIN" ]; then
        ln -sf "$COMPOSE_BIN" /usr/local/bin/docker-compose 2>/dev/null || true
    else
        # Fallback: standalone (редко)
        VER=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
        [ -z "$VER" ] && VER="v2.29.7"
        # Убираем лишний пробел в URL (было: `.../download/  $VER/...`)
        DOWNLOAD_URL="https://github.com/docker/compose/releases/download/$VER/docker-compose-$(uname -s)-$(uname -m)"
        echo "📥 Загрузка standalone docker-compose: $DOWNLOAD_URL"
        curl -SL "$DOWNLOAD_URL" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi

    docker-compose --version >/dev/null || { echo "❌ docker-compose не работает."; exit 1; }
    echo "✅ docker-compose доступен."
}

# ───────────────────────────────────────────────────────────────
# Выполнение установки Docker (если выбрано)
# ───────────────────────────────────────────────────────────────
if [ "$INSTALL_DOCKER" = true ]; then
    install_docker
    setup_docker_compose_compat

    # ───── Добавление пользователя в группу docker ─────
    echo "👥 [4/5] Настройка прав доступа..."
    if [ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1; then
        if ! groups "$TARGET_USER" | grep -q '\bdocker\b'; then
            usermod -aG docker "$TARGET_USER"
            echo "✅ $TARGET_USER добавлен в группу 'docker'."
            echo "ℹ️  Примените изменения: 'newgrp docker' или перелогиньтесь."
        else
            echo "ℹ️  $TARGET_USER уже состоит в группе 'docker'."
        fi
    else
        echo "⚠️  Не удалось определить пользователя для добавления в группу 'docker'."
    fi
else
    echo "⏭️  Установка Docker пропущена."
fi

# ───────────────────────────────────────────────────────────────
# 4. Обновление системы — В САМОМ КОНЦЕ
# ───────────────────────────────────────────────────────────────
echo
echo "📦 [$(($INSTALL_DOCKER ? 5 : 4))/$(($INSTALL_DOCKER ? 6 : 5))] Проверка обновлений..."
apt update -qq >/dev/null 2>&1
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | wc -l)
echo "Доступно обновлений: $UPGRADABLE"

if [ "$UPGRADABLE" -gt 0 ]; then
    echo
    read -p "Выполнить 'apt upgrade' (может занять время)? [Y/n]: " -r REPLY
    case "${REPLY:-Y}" in
        [yY]|[Yy][eE][sS]|"")
            echo
            read -p "Режим: (a) авто (сохранить конфиги) / (i) интерактивно? [a/i]: " -r MODE
            case "${MODE:-a}" in
                [iI]*)
                    echo "🔁 Интерактивное обновление:"
                    apt upgrade
                    ;;
                *)
                    echo "⏳ Автообновление..."
                    DEBIAN_FRONTEND=noninteractive \
                    apt upgrade -y -qq \
                        -o Dpkg::Options::="--force-confdef" \
                        -o Dpkg::Options::="--force-confold"
                    ;;
            esac
            echo "✅ Обновление завершено."
            ;;
        *)
            echo "⏭️  Обновление отложено. Выполните позже: sudo apt upgrade"
            ;;
    esac
else
    echo "✅ Обновлять нечего."
fi

# ───────────────────────────────────────────────────────────────
# Финал
# ───────────────────────────────────────────────────────────────
echo
echo "============================================"
echo "✅ Сервер настроен!"
echo
echo "🔹 SSH: порт $NEW_PORT"
if [ "$INSTALL_DOCKER" = true ]; then
    echo "🔹 Docker: $(docker --version | cut -d' ' -f3)"
    echo "🔹 docker-compose: $(docker-compose --version | cut -d',' -f1)"
    [ -n "$TARGET_USER" ] && echo "🔹 Пользователь: $TARGET_USER (в группе docker)"
fi
echo
echo "⚠️  Действия после скрипта:"
echo "   1. Разрешите порт в фаерволе:"
echo "        sudo ufw allow $NEW_PORT/tcp && sudo ufw reload"
echo "   2. Переподключитесь: ssh -p $NEW_PORT user@host"
[ "$INSTALL_DOCKER" = true ] && echo "   3. Проверьте Docker: docker run hello-world"
echo "============================================"
