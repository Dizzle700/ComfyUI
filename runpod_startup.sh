#!/usr/bin/env bash

set -Eeuo pipefail

# Определяем директорию, в которой находится этот скрипт.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Логируем весь вывод скрипта запуска
if [[ -d "/workspace" ]]; then
    LOG_FILE="${RUNPOD_LOG_FILE:-/workspace/runpod_startup.log}"
else
    LOG_FILE="${RUNPOD_LOG_FILE:-$SCRIPT_DIR/runpod_startup.log}"
fi
exec > >(tee -i "$LOG_FILE") 2>&1

echo "=== ЗАПУСК КОНТЕЙНЕРА RUNPOD: $(date) ==="

# Панель запустит ComfyUI как дочерний процесс после установки/обновления.
export AUTO_START_COMFY="${AUTO_START_COMFY:-1}"
export COMFY_ARGS="${COMFY_ARGS:---listen 0.0.0.0 --port 8188 --highvram}"

# Держим тяжелые кэши моделей на persistent storage, а не на container disk.
if [[ -d "/workspace" ]]; then
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/workspace/.cache}"
    export PIP_CACHE_DIR="${PIP_CACHE_DIR:-/workspace/.cache/pip}"
    export TORCH_HOME="${TORCH_HOME:-/workspace/.cache/torch}"
    export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
    export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-/workspace/.cache/huggingface/hub}"
    export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/workspace/.cache/huggingface/transformers}"
    export DIFFUSERS_CACHE="${DIFFUSERS_CACHE:-/workspace/.cache/huggingface/diffusers}"
    mkdir -p "$PIP_CACHE_DIR" "$TORCH_HOME" \
        "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$TRANSFORMERS_CACHE" "$DIFFUSERS_CACHE"
fi

# Проверяем наличие основного установщика
if [[ -f "$SCRIPT_DIR/comfy_install_runpod.sh" ]]; then
    echo "Обнаружен comfy_install_runpod.sh. Запуск автоматической установки и панели управления..."
    bash "$SCRIPT_DIR/comfy_install_runpod.sh"
else
    echo "Ошибка: comfy_install_runpod.sh не найден в директории $SCRIPT_DIR!"
    exit 1
fi
