#!/usr/bin/env bash

set -Eeuo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# На RunPod используем /workspace/ComfyUI для сохранения данных после перезапуска пода
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "/workspace" ]]; then
    COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
else
    COMFY_DIR="${COMFY_DIR:-$SCRIPT_DIR/ComfyUI}"
fi

COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
MANAGER_DIR="$COMFY_DIR/custom_nodes/comfyui-manager"
MANAGER_REPO="https://github.com/Comfy-Org/ComfyUI-Manager.git"

info() { printf '%b\n' "${BLUE}$*${NC}"; }
success() { printf '%b\n' "${GREEN}$*${NC}"; }
warn() { printf '%b\n' "${YELLOW}$*${NC}"; }
error() { printf '%b\n' "${RED}$*${NC}" >&2; }

on_error() {
    local exit_code=$?
    error "Ошибка на строке $1 (код: $exit_code). Установка остановлена."
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

# Проверка окружения RunPod
if [[ -d "/workspace" ]]; then
    info "Обнаружено окружение RunPod. Установка будет выполнена в $COMFY_DIR (persistent storage)."
else
    warn "Каталог /workspace не найден. Данные могут быть потеряны при остановке пода."
fi

ensure_uv() {
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    if command -v uv >/dev/null 2>&1; then
        success "uv готов к работе: $(uv --version)"
        return
    fi

    info "uv не найден. Устанавливаем..."
    curl --proto '=https' --tlsv1.2 -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
}

# Клонируем или обновляем ComfyUI
if [[ ! -d "$COMFY_DIR/.git" ]]; then
    info "Клонируем репозиторий ComfyUI..."
    git clone --depth 1 "$COMFY_REPO" "$COMFY_DIR"
else
    info "Репозиторий ComfyUI уже существует. Обновляем..."
    git -C "$COMFY_DIR" pull --ff-only
fi

cd "$COMFY_DIR"
ensure_uv

# На RunPod обычно уже предустановлен PyTorch с нужной версией CUDA
if python3 -c "import torch" >/dev/null 2>&1; then
    success "Обнаружен предустановленный PyTorch: $(python3 -c 'import torch; print(torch.__version__, "(CUDA:", torch.cuda.is_available(), ")")')"
    
    info "Устанавливаем зависимости ComfyUI в системное окружение..."
    uv pip install --system -r requirements.txt
    
    info "Устанавливаем/обновляем ComfyUI-Manager..."
    mkdir -p "$COMFY_DIR/custom_nodes"
    if [[ ! -d "$MANAGER_DIR" ]]; then
        git clone "$MANAGER_REPO" "$MANAGER_DIR"
    else
        git -C "$MANAGER_DIR" pull --ff-only
    fi
    
    if [[ -f "$MANAGER_DIR/requirements.txt" ]]; then
        uv pip install --system -r "$MANAGER_DIR/requirements.txt"
    fi
    
    info "Устанавливаем зависимости для Панели Управления (Gradio, psutil)..."
    uv pip install --system gradio psutil
    
    # Копирование pisa_sr.pkl, если он лежит в папке со скриптом
    if [[ -f "$SCRIPT_DIR/pisa_sr.pkl" ]]; then
        info "Обнаружен локальный файл pisa_sr.pkl. Копируем в ComfyUI..."
        mkdir -p "$COMFY_DIR/models/loras"
        cp "$SCRIPT_DIR/pisa_sr.pkl" "$COMFY_DIR/models/loras/pisa_sr.pkl"
    fi

    success "Автоматическая установка ComfyUI завершена!"
    info "Запускаем Графическую Панель Управления (comfy_control_panel.py)..."
    exec python3 "$SCRIPT_DIR/comfy_control_panel.py"
else
    # Альтернативный вариант с виртуальным окружением, если PyTorch нет в системе
    info "PyTorch не найден. Создаем виртуальное окружение .venv..."
    uv venv --python 3.10 .venv
    
    info "Устанавливаем PyTorch..."
    uv pip install --python .venv/bin/python torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
    
    info "Устанавливаем зависимости ComfyUI..."
    uv pip install --python .venv/bin/python -r requirements.txt
    
    info "Устанавливаем/обновляем ComfyUI-Manager..."
    mkdir -p "$COMFY_DIR/custom_nodes"
    if [[ ! -d "$MANAGER_DIR" ]]; then
        git clone "$MANAGER_REPO" "$MANAGER_DIR"
    else
        git -C "$MANAGER_DIR" pull --ff-only
    fi
    
    if [[ -f "$MANAGER_DIR/requirements.txt" ]]; then
        uv pip install --python .venv/bin/python -r "$MANAGER_DIR/requirements.txt"
    fi
    
    info "Устанавливаем Gradio и psutil в виртуальное окружение..."
    uv pip install --python .venv/bin/python gradio psutil
    
    # Копирование pisa_sr.pkl, если он лежит в папке со скриптом
    if [[ -f "$SCRIPT_DIR/pisa_sr.pkl" ]]; then
        info "Обнаружен локальный файл pisa_sr.pkl. Копируем в ComfyUI..."
        mkdir -p "$COMFY_DIR/models/loras"
        cp "$SCRIPT_DIR/pisa_sr.pkl" "$COMFY_DIR/models/loras/pisa_sr.pkl"
    fi

    success "Автоматическая установка ComfyUI в .venv завершена!"
    info "Запускаем Графическую Панель Управления..."
    exec .venv/bin/python "$SCRIPT_DIR/comfy_control_panel.py"
fi
