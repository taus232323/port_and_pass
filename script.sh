#!/bin/bash

# Проверка на выполнение с правами суперпользователя
if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите этот скрипт с правами суперпользователя (sudo)."
    exit 1
fi

# Обновление системы
echo "Обновление списка пакетов и обновление системы..."
apt update && apt upgrade -y -qq
if [ $? -ne 0 ]; then
    echo "Ошибка при обновлении системы."
    exit 1
fi

# Запрос порта у пользователя
read -p "Введите новый порт SSH (например, 2222): " NEW_PORT

# Проверка, что порт является числом и в диапазоне 1-65535
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo "Неверный номер порта. Пожалуйста, введите число от 1 до 65535."
    exit 1
fi

# Изменение конфигурации SSH
echo "Изменение порта SSH на $NEW_PORT..."
# Удаляем все строки с Port и добавляем новую, чтобы избежать дублей
sed -i '/^Port/d' /etc/ssh/sshd_config
echo "Port $NEW_PORT" >> /etc/ssh/sshd_config

# Отключение входа по паролю (только если есть хотя бы один ключ в authorized_keys)
if [ -s /root/.ssh/authorized_keys ] || [ -s /home/*/\.ssh/authorized_keys 2>/dev/null ]; then
    echo "Отключение входа по паролю..."
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
else
    echo "⚠️  Вход по паролю не отключён: не найдено ни одного SSH-ключа в authorized_keys."
    echo "Рекомендуется добавить ключ и повторно запустить скрипт или вручную отключить PasswordAuthentication."
fi

# Перезапуск службы SSH
echo "Перезапуск службы SSH..."
systemctl restart ssh

if ! systemctl is-active --quiet ssh; then
    echo "❌ Служба SSH не запущена. Возможна ошибка конфигурации (например, дублирование Port)."
    echo "Проверьте конфиг: sudo sshd -t"
    exit 1
fi

# Установка зависимостей Docker
echo "Установка зависимостей для Docker..."
apt install -y -qq ca-certificates curl gnupg lsb-release

# Добавление официального GPG-ключа Docker
if ! command -v docker &> /dev/null; then
    echo "Добавление GPG-ключа Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Добавление репозитория Docker
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    echo "Обновление пакетов после добавления репозитория..."
    apt update -qq
fi

# Установка Docker и docker-compose-plugin (предпочтительно — официальный compose v2 как подкоманда)
echo "Установка Docker и Docker Compose..."
apt install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Проверка установки
if command -v docker &> /dev/null && command -v docker compose &> /dev/null; then
    echo "✅ Docker и Docker Compose установлены успешно."
    echo "Проверка: $(docker --version)"
    echo "Проверка Compose: $(docker compose version)"
else
    echo "❌ Ошибка установки Docker или Docker Compose."
    exit 1
fi

# Добавление текущего пользователя (если вызван через sudo) в группу docker
# Определяем исходного пользователя (не root), если скрипт запущен через sudo
SUDO_USER="${SUDO_USER:-$USER}"
if id "$SUDO_USER" &>/dev/null && ! groups "$SUDO_USER" | grep -q '\bdocker\b'; then
    echo "Добавление пользователя $SUDO_USER в группу docker..."
    usermod -aG docker "$SUDO_USER"
    echo "⚠️  Для применения изменений групп требуется перелогиниться (или выполнить: newgrp docker)."
fi

# Вывод информации
echo ""
echo "============================================"
echo "✅ Настройка завершена:"
echo "- Порт SSH изменён на $NEW_PORT"
echo "- Вход по паролю отключён (если были ключи)"
echo "- Docker и Docker Compose установлены"
echo "- Пользователь $SUDO_USER добавлен в группу docker"
echo ""
echo "⚠️  Важно:"
echo "- Убедитесь, что брандмауэр разрешает подключения на порт $NEW_PORT:"
echo "    sudo ufw allow $NEW_PORT/tcp"
echo "    sudo ufw reload"
echo "- Переподключитесь по SSH на новый порт:"
echo "    ssh -p $NEW_PORT user@host"
echo "============================================"
