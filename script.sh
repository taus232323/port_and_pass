#!/bin/bash

# ───────────────────────────────────────────────────────────────
# 🚀 Быстрая настройка сервера: SSH → Docker → Обновление (в конце)
# ───────────────────────────────────────────────────────────────

set -e  # Выход при любой ошибке (кроме явно разрешённых)

if [ "$EUID" -ne 0 ]; then
    echo "❌ Запустите как root или через sudo: sudo $0"
    exit 1
fi

echo "🚀 Начало настройки (быстрые операции в первую очередь)..."

# ───────────────────────────────────────────────────────────────
# 1. Определение пользователя для добавления в группу docker
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
# 2. Настройка SSH (самое важное — делаем СРАЗУ)
# ───────────────────────────────────────────────────────────────
echo "🔧 [1/6] Настройка SSH..."

read -p "Введите новый порт SSH (по умолчанию 2222): " -r NEW_PORT
NEW_PORT="${NEW_PORT:-2222}"

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo "❌ Неверный порт: '$NEW_PORT'"
    exit 1
fi

# Удаляем все Port-строки и добавляем новую
sed -i '/^[[:space:]]*Port[[:space:]]\+/d' /etc/ssh/sshd_config
echo "Port $NEW_PORT" >> /etc/ssh/sshd_config

# Отключаем пароли, только если есть ключи
if [ -s /root/.ssh/authorized_keys ] || ls /home/*/\.ssh/authorized_keys 2>/dev/null | grep -q .; then
    sed -i 's/^[[:space:]]*#*[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    echo "🔒 Вход по паролю отключён."
else
    echo "⚠️  Вход по паролю оставлен — нет SSH-ключей."
fi

# КРИТИЧЕСКАЯ ПРОВЕРКА перед перезапуском
if ! sshd -t; then
    echo "❌ Конфиг SSH недействителен. Исправьте вручную:"
    echo "   sudo nano /etc/ssh/sshd_config"
    echo "   sudo sshd -t"
    exit 1
fi

systemctl restart ssh
if ! systemctl is-active --quiet ssh; then
    echo "❌ SSH не запущен. Проверьте systemctl status ssh"
    exit 1
fi
echo "✅ SSH настроен на порт $NEW_PORT."

# ───────────────────────────────────────────────────────────────
# 3. Установка зависимостей и Docker (без upgrade!)
# ───────────────────────────────────────────────────────────────
echo "🐳 [2/6] Установка Docker..."

apt install -y -qq ca-certificates curl gnupg lsb-release >/dev/null

# GPG-ключ (из актуального URL — см. knowledge base: /gpg существует)
echo "🔑 Добавление GPG-ключа Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Репозиторий
CODENAME=$(lsb_release -cs 2>/dev/null || { . /etc/os-release; echo "${VERSION_CODENAME:-jammy}"; })
ARCH=$(dpkg --print-architecture)
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
  | tee /etc/apt/sources.list.d/docker.list >/dev/null

apt update -qq >/dev/null

# Установка (только нужные пакеты)
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

# ───────────────────────────────────────────────────────────────
# 4. Совместимость: docker-compose → docker compose
# ───────────────────────────────────────────────────────────────
echo "🔗 [3/6] Настройка 'docker-compose' совместимости..."

COMPOSE_BIN=""
for p in /usr/lib/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose; do
    [ -x "$p" ] && COMPOSE_BIN="$p" && break
done

if [ -n "$COMPOSE_BIN" ]; then
    ln -sf "$COMPOSE_BIN" /usr/local/bin/docker-compose 2>/dev/null || true
else
    # Fallback: standalone (редко нужно)
    VER=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
    [ -z "$VER" ] && VER="v2.29.7"
    curl -SL "https://github.com/docker/compose/releases/download/$VER/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

docker-compose --version >/dev/null || { echo "❌ docker-compose не работает."; exit 1; }
echo "✅ docker-compose доступен."

# ───────────────────────────────────────────────────────────────
# 5. Добавление пользователя в группу docker
# ───────────────────────────────────────────────────────────────
echo "👥 [4/6] Настройка прав доступа..."

if [ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1; then
    if ! groups "$TARGET_USER" | grep -q '\bdocker\b'; then
        usermod -aG docker "$TARGET_USER"
        echo "✅ $TARGET_USER добавлен в группу 'docker'."
        echo "ℹ️  Примените изменения: выполните 'newgrp docker' или перелогиньтесь."
    fi
else
    echo "ℹ️  Пользователь не определён — пропуск добавления в 'docker'."
fi

# ───────────────────────────────────────────────────────────────
# 6. Обновление системы — В САМОМ КОНЦЕ
# ───────────────────────────────────────────────────────────────
echo
echo "📦 [5/6] Проверка обновлений..."
apt update -qq >/dev/null 2>&1
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v "Listing..." | wc -l)
echo "Доступно обновлений: $UPGRADABLE"

if [ "$UPGRADABLE" -gt 0 ]; then
    echo
    read -p "Выполнить 'apt upgrade' (самая долгая операция)? [Y/n]: " -r REPLY
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
                    echo "⏳ Автообновление (ожидайте, может занять несколько минут)..."
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
echo "🔹 Docker: $(docker --version | cut -d' ' -f3)"
echo "🔹 docker-compose: $(docker-compose --version | cut -d',' -f1)"
[ -n "$TARGET_USER" ] && echo "🔹 Пользователь: $TARGET_USER (в группе docker)"
echo
echo "⚠️  Действия после скрипта:"
echo "   1. Разрешите порт в фаерволе:"
echo "        sudo ufw allow $NEW_PORT/tcp && sudo ufw reload"
echo "   2. Переподключитесь: ssh -p $NEW_PORT user@host"
echo "============================================"
