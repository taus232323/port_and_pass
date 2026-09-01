#!/usr/bin/env bash
set -Eeuo pipefail

# 1. Проверка прав root
if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ Запустите скрипт как root или через sudo" >&2
    exit 1
fi

# 2. Запрос нового порта
read -r -p "Введите новый порт SSH (по умолчанию 2222): " NEW_PORT
NEW_PORT="${NEW_PORT:-2222}"

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || (( NEW_PORT < 1 || NEW_PORT > 65535 )); then
    echo "❌ Неверный порт: '$NEW_PORT'" >&2
    exit 1
fi

# 3. Применение настроек через drop-in конфигурацию (безопаснее, чем править sshd_config)
CONFIG_DIR="/etc/ssh/sshd_config.d"
CONFIG_FILE="$CONFIG_DIR/99-ssh-hardening.conf"

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
Port $NEW_PORT
PasswordAuthentication no
PermitRootLogin prohibit-password
EOF

# 4. Проверка синтаксиса перед перезапуском (защита от блокировки)
if ! sshd -t; then
    echo "❌ Ошибка в конфигурации SSH. Изменения отменены." >&2
    rm -f "$CONFIG_FILE"
    exit 1
fi

# 5. Перезапуск службы
systemctl daemon-reload
systemctl restart ssh || systemctl restart sshd

# 6. Итоговое сообщение
echo ""
echo "✅ Настройка завершена успешно!"
echo "🔹 Новый порт SSH: $NEW_PORT"
echo "🔹 Вход по паролю: отключён (только по ключу)"
echo ""
echo "⚠️  ВАЖНО: Не закрывайте текущее окно терминала!"
echo "   Сначала проверьте подключение в новом окне:"
echo "   ssh -p $NEW_PORT root@ВАШ_IP_АДРЕС"
