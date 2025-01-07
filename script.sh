#!/bin/bash

# Проверка на выполнение с правами суперпользователя
if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите этот скрипт с правами суперпользователя (sudo)."
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
sed -i "s/^#Port 22/Port $NEW_PORT/" /etc/ssh/sshd_config
sed -i "s/^Port 22/Port $NEW_PORT/" /etc/ssh/sshd_config

# Отключение входа по паролю
echo "Отключение входа по паролю..."
sed -i "s/^#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config

# Перезапуск службы SSH
echo "Перезапуск службы SSH..."
systemctl restart sshd

# Вывод информации
echo "Порт SSH успешно изменен на $NEW_PORT."
echo "Вход по паролю отключен. Убедитесь, что у вас есть доступ через ключи SSH."
