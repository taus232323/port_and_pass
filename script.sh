#!/bin/bash

# Проверка на выполнение с правами суперпользователя
if [ "$EUID" -ne 0 ]; then
    echo "❌ Пожалуйста, запустите этот скрипт с правами суперпользователя: sudo $0"
    exit 1
fi

set -e  # Автоматически выходить при ошибках (кроме явно обработанных)

echo "🚀 Начало настройки сервера..."

# === 1. Выбор пользователя для добавления в группу docker ===
TARGET_USER=""
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
elif [ "$USER" != "root" ]; then
    TARGET_USER="$USER"
else
    # Ищем первого обычного пользователя (UID ≥ 1000)
    TARGET_USER=$(getent passwd {1000..65535} | awk -F: '($3 >= 1000) && ($3 != 65534) {print $1; exit}')
fi

if [ -z "$TARGET_USER" ]; then
    echo "ℹ️  Не найден непривилегированный пользователь. Пропуск добавления в группу 'docker'."
fi

# === 2. Обновление системы ===
echo
echo "🔄 Обновление списка пакетов..."
apt update -qq || { echo "❌ Ошибка при apt update"; exit 1; }

UPGRADABLE_COUNT=$(apt list --upgradable 2>/dev/null | grep -c -v "Listing...")
echo "📦 Доступно обновлений: $UPGRADABLE_COUNT"

if [ "$UPGRADABLE_COUNT" -gt 0 ]; then
    echo "Примеры обновлений:"
    apt list --upgradable 2>/dev/null | grep -v "Listing..." | head -n 5
    echo
    read -p "Выполнить обновление системы? [Y/n]: " -r REPLY
    case "${REPLY:-Y}" in
        [yY]|[Yy][eE][sS]|"")
            echo
            read -p "Режим: (a) автоматически (сохранить конфиги) / (i) интерактивно? [a/i]: " -r MODE
            case "${MODE:-a}" in
                [iI]*)
                    echo "🔁 Запуск интерактивного обновления..."
                    apt upgrade
                    ;;
                *)
                    echo "✅ Автообновление (сохранение текущих конфигов)..."
                    DEBIAN_FRONTEND=noninteractive \
                    apt upgrade -y -qq \
                        -o Dpkg::Options::="--force-confdef" \
                        -o Dpkg::Options::="--force-confold" \
                    || { echo "❌ Ошибка при обновлении"; exit 1; }
                    echo "✅ Обновление завершено."
                    ;;
            esac
            ;;
        *)
            echo "⏭️  Обновление пропущено."
            ;;
    esac
else
    echo "✅ Обновлять нечего."
fi

# === 3. Настройка SSH ===
echo
read -p "Введите новый порт SSH (по умолчанию 2222): " -r NEW_PORT
NEW_PORT="${NEW_PORT:-2222}"

# Валидация порта
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo "❌ Неверный порт: '$NEW_PORT'. Допустимо: 1–65535."
    exit 1
fi

echo "🔧 Настройка SSH: Port $NEW_PORT..."
sed -i '/^[[:space:]]*Port[[:space:]]\+/d' /etc/ssh/sshd_config
echo "Port $NEW_PORT" >> /etc/ssh/sshd_config

# Отключаем пароли, только если есть ключи
if [ -s /root/.ssh/authorized_keys ] || ls /home/*/\.ssh/authorized_keys 2>/dev/null | grep -q .; then
    sed -i 's/^[[:space:]]*#*[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    echo "🔒 Вход по паролю отключён."
else
    echo "⚠️  Вход по паролю оставлен включённым — не найдено SSH-ключей."
    echo "   Добавьте ключ в ~/.ssh/authorized_keys и перезапустите скрипт."
fi

# Проверка конфига перед перезапуском
if ! sshd -t; then
    echo "❌ Ошибка в /etc/ssh/sshd_config. Исправьте вручную и перезапустите скрипт."
    exit 1
fi

echo "🔁 Перезапуск SSH..."
systemctl restart ssh

if ! systemctl is-active --quiet ssh; then
    echo "❌ SSH не запущен. Проверьте: systemctl status ssh"
    exit 1
fi
echo "✅ SSH настроен на порт $NEW_PORT."

# === 4. Установка Docker ===
echo
echo "🐳 Установка Docker и Docker Compose..."

# Зависимости
echo "📦 Установка зависимостей..."
apt install -y -qq ca-certificates curl gnupg lsb-release

# GPG-ключ
echo "🔑 Добавление GPG-ключа Docker..."
install -m 0755 -d /etc/apt/keyrings
if ! curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" -o /tmp/docker.gpg.key; then
    echo "❌ Не удалось загрузить GPG-ключ Docker."
    exit 1
fi
gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg.key
chmod a+r /etc/apt/keyrings/docker.gpg
rm -f /tmp/docker.gpg.key

# Репозиторий
CODENAME=$(lsb_release -cs 2>/dev/null || { . /etc/os-release; echo "$UBUNTU_CODENAME"; } || echo "jammy")
ARCH=$(dpkg --print-architecture)
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
  | tee /etc/apt/sources.list.d/docker.list >/dev/null

apt update -qq

# Установка
echo "📥 Установка Docker..."
apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Проверка
if ! docker --version >/dev/null 2>&1; then
    echo "❌ Docker не установлен."
    exit 1
fi
echo "✅ Docker: $(docker --version)"

if ! docker compose version >/dev/null 2>&1; then
    echo "❌ docker compose недоступен."
    exit 1
fi
echo "✅ docker compose: $(docker compose version)"

# === 5. Совместимость: docker-compose (через симлинк) ===
echo "🔗 Настройка совместимости 'docker-compose' → 'docker compose'..."

COMPOSE_BIN=""
for path in \
    "/usr/lib/docker/cli-plugins/docker-compose" \
    "/usr/local/lib/docker/cli-plugins/docker-compose" \
    "/usr/libexec/docker/cli-plugins/docker-compose"; do
    if [ -x "$path" ]; then
        COMPOSE_BIN="$path"
        break
    fi
done

if [ -n "$COMPOSE_BIN" ]; then
    mkdir -p /usr/local/bin
    ln -sf "$COMPOSE_BIN" /usr/local/bin/docker-compose
    echo "✅ Симлинк создан: /usr/local/bin/docker-compose → $COMPOSE_BIN"
else
    echo "⚠️ compose-плагин не найден. Устанавливаю standalone-версию..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | cut -d'"' -f4 2>/dev/null)
    [ -z "$LATEST_VERSION" ] && LATEST_VERSION="v2.29.7"
    URL="https://github.com/docker/compose/releases/download/${LATEST_VERSION}/docker-compose-$(uname -s)-$(uname -m)"
    if curl -fSL "$URL" -o /usr/local/bin/docker-compose; then
        chmod +x /usr/local/bin/docker-compose
        echo "✅ Установлен standalone docker-compose $LATEST_VERSION"
    else
        echo "❌ Не удалось загрузить docker-compose. Проверьте интернет."
        exit 1
    fi
fi

# Финальная проверка
if docker-compose --version >/dev/null 2>&1; then
    echo "✅ docker-compose: $(docker-compose --version)"
else
    echo "❌ docker-compose недоступен."
    exit 1
fi

# === 6. Добавление пользователя в группу docker ===
if [ -n "$TARGET_USER" ] && id "$TARGET_USER" >/dev/null 2>&1; then
    if ! groups "$TARGET_USER" | grep -q '\bdocker\b'; then
        usermod -aG docker "$TARGET_USER"
        echo "✅ Пользователь '$TARGET_USER' добавлен в группу 'docker'."
        echo "ℹ️  Чтобы изменения вступили в силу:"
        echo "      su - $TARGET_USER"
        echo "   или перелогиньтесь."
    else
        echo "ℹ️  Пользователь '$TARGET_USER' уже в группе 'docker'."
    fi
fi

# === 7. Итог ===
echo
echo "============================================"
echo "✅ Настройка завершена!"
echo
echo "🔹 SSH: порт $NEW_PORT"
echo "🔹 Docker и docker-compose: установлены"
[ -n "$TARGET_USER" ] && echo "🔹 Пользователь '$TARGET_USER' в группе docker"
echo
echo "⚠️  Важно:"
if command -v ufw >/dev/null 2>&1 && ! ufw status | grep -q "Status: active"; then
    echo "   - Брандмауэр (ufw) не включён. Разрешите порт:"
    echo "       ufw allow $NEW_PORT/tcp && ufw enable"
elif command -v ufw >/dev/null 2>&1; then
    echo "   - Убедитесь, что порт $NEW_PORT разрешён в ufw."
fi
echo "   - Переподключитесь по SSH: ssh -p $NEW_PORT user@host"
echo "============================================"
