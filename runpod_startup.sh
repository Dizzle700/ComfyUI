#!/usr/bin/env bash

set -Eeuo pipefail

# Логируем весь вывод скрипта запуска
LOG_FILE="/workspace/runpod_startup.log"
exec > >(tee -i "$LOG_FILE") 2>&1

echo "=== ЗАПУСК КОНТЕЙНЕРА RUNPOD: $(date) ==="

# Определяем директорию, в которой находится этот скрипт
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Держим тяжелые кэши моделей на persistent storage, а не на container disk.
if [[ -d "/workspace" ]]; then
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/workspace/.cache}"
    export UV_CACHE_DIR="${UV_CACHE_DIR:-/workspace/.cache/uv}"
    export PIP_CACHE_DIR="${PIP_CACHE_DIR:-/workspace/.cache/pip}"
    export TORCH_HOME="${TORCH_HOME:-/workspace/.cache/torch}"
    export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
    export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-/workspace/.cache/huggingface/hub}"
    export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/workspace/.cache/huggingface/transformers}"
    export DIFFUSERS_CACHE="${DIFFUSERS_CACHE:-/workspace/.cache/huggingface/diffusers}"
    mkdir -p "$UV_CACHE_DIR" "$PIP_CACHE_DIR" "$TORCH_HOME" \
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
