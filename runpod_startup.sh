#!/usr/bin/env bash

set -Eeuo pipefail

# Логируем весь вывод скрипта запуска
LOG_FILE="/workspace/runpod_startup.log"
exec > >(tee -i "$LOG_FILE") 2>&1

echo "=== ЗАПУСК КОНТЕЙНЕРА RUNPOD: $(date) ==="

# Определяем директорию, в которой находится этот скрипт
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Проверяем наличие основного установщика
if [[ -f "$SCRIPT_DIR/comfy_install_runpod.sh" ]]; then
    echo "Обнаружен comfy_install_runpod.sh. Запуск автоматической установки и панели управления..."
    bash "$SCRIPT_DIR/comfy_install_runpod.sh"
else
    echo "Ошибка: comfy_install_runpod.sh не найден в директории $SCRIPT_DIR!"
    exit 1
fi
