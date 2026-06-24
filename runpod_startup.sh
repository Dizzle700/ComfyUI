#!/usr/bin/env bash

set -Eeuo pipefail

# Определяем директорию, в которой находится этот скрипт.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SECRET_ENV_FILE="${COMFY_SECRET_FILE:-$SCRIPT_DIR/.env.secrets}"

load_secret_file() {
    local key value
    [[ -f "$SECRET_ENV_FILE" ]] || return 0
    chmod 600 "$SECRET_ENV_FILE"

    # Безопасно разбираем только известные KEY=VALUE, не исполняя содержимое файла.
    while IFS= read -r -d '' key && IFS= read -r -d '' value; do
        if [[ -z "${!key:-}" ]]; then
            printf -v "$key" '%s' "$value"
            export "$key"
        fi
    done < <(python3 - "$SECRET_ENV_FILE" <<'PY'
import shlex
import sys

allowed = {
    "PANEL_USER", "PANEL_PASS", "HF_TOKEN", "CIVITAI_API_TOKEN",
    "NANO_BANANA_API_KEY", "FAL_KEY",
}
with open(sys.argv[1], encoding="utf-8") as stream:
    for number, raw_line in enumerate(stream, start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, raw_value = line.partition("=")
        key = key.strip()
        if not separator or key not in allowed:
            raise SystemExit(f"Некорректная строка {number} в файле секретов")
        values = shlex.split(raw_value, comments=True, posix=True)
        if len(values) > 1:
            raise SystemExit(f"Значение в строке {number} нужно заключить в кавычки")
        value = values[0] if values else ""
        sys.stdout.buffer.write(key.encode() + b"\0" + value.encode() + b"\0")
PY
    )
}

load_secret_file

# Логируем весь вывод скрипта запуска
if [[ -d "/workspace" ]]; then
    LOG_FILE="${RUNPOD_LOG_FILE:-/workspace/runpod_startup.log}"
else
    LOG_FILE="${RUNPOD_LOG_FILE:-$SCRIPT_DIR/runpod_startup.log}"
fi
exec > >(tee -i "$LOG_FILE") 2>&1

echo "=== ЗАПУСК КОНТЕЙНЕРА RUNPOD: $(date) ==="

if [[ -z "${PANEL_USER:-}" || -z "${PANEL_PASS:-}" ]]; then
    echo "Ошибка: задайте PANEL_USER и PANEL_PASS через RunPod Secrets или .env.secrets." >&2
    echo "Панель с Terminal не будет запущена без аутентификации." >&2
    exit 2
fi

# Панель запустит ComfyUI как дочерний процесс после установки/обновления.
export AUTO_START_COMFY="${AUTO_START_COMFY:-1}"
export COMFY_ARGS="${COMFY_ARGS:---listen 0.0.0.0 --port 8188 --highvram}"

# Современный многопоточный транспорт Hugging Face. hf_transfer устарел;
# huggingface_hub автоматически использует hf-xet.
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"

# Держим тяжелые кэши моделей на persistent storage, а не на container disk.
if [[ -d "/workspace" ]]; then
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/workspace/.cache}"
    export PIP_CACHE_DIR="${PIP_CACHE_DIR:-/workspace/.cache/pip}"
    export TORCH_HOME="${TORCH_HOME:-/workspace/.cache/torch}"
    export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
    export HF_HUB_CACHE="${HF_HUB_CACHE:-${HUGGINGFACE_HUB_CACHE:-/workspace/.cache/huggingface/hub}}"
    export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HUB_CACHE}"
    export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/workspace/.cache/huggingface/transformers}"
    export DIFFUSERS_CACHE="${DIFFUSERS_CACHE:-/workspace/.cache/huggingface/diffusers}"
    export HF_XET_CACHE="${HF_XET_CACHE:-/workspace/.cache/huggingface/xet}"
    mkdir -p "$PIP_CACHE_DIR" "$TORCH_HOME" \
        "$HF_HOME" "$HF_HUB_CACHE" "$TRANSFORMERS_CACHE" "$DIFFUSERS_CACHE" \
        "$HF_XET_CACHE"
fi

# Проверяем наличие основного установщика
if [[ -f "$SCRIPT_DIR/comfy_install_runpod.sh" ]]; then
    echo "Обнаружен comfy_install_runpod.sh. Запуск автоматической установки и панели управления..."
    bash "$SCRIPT_DIR/comfy_install_runpod.sh"
else
    echo "Ошибка: comfy_install_runpod.sh не найден в директории $SCRIPT_DIR!"
    exit 1
fi
