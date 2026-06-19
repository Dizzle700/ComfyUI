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
export COMFY_DIR

if [[ -d "/workspace" ]]; then
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/workspace/.cache}"
    export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
    export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-/workspace/.cache/huggingface/hub}"
    export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/workspace/.cache/huggingface/transformers}"
    export DIFFUSERS_CACHE="${DIFFUSERS_CACHE:-/workspace/.cache/huggingface/diffusers}"
    mkdir -p "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$TRANSFORMERS_CACHE" "$DIFFUSERS_CACHE"
fi

START_PANEL=true
for arg in "$@"; do
    case "$arg" in
        --no-start) START_PANEL=false ;;
        --help|-h)
            cat <<'EOF'
Использование:
  comfy_install_runpod.sh [--no-start]

Опции:
  --no-start    Установить/обновить ComfyUI без запуска панели управления.
EOF
            exit 0
            ;;
    esac
done

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

# В современных RunPod/PyTorch images системный Python часто externally managed,
# поэтому все Python-пакеты ставим в venv внутри /workspace/ComfyUI.
if [[ ! -x .venv/bin/python ]]; then
    info "Создаем виртуальное окружение .venv..."
    uv venv --python python3 .venv
else
    success "Используем существующее окружение: $COMFY_DIR/.venv"
fi
VENV_PYTHON="$COMFY_DIR/.venv/bin/python"

if "$VENV_PYTHON" -c "import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)" >/dev/null 2>&1; then
    success "PyTorch в .venv готов: $("$VENV_PYTHON" -c 'import torch; print(torch.__version__, "(CUDA:", torch.cuda.is_available(), ")")')"
else
    info "Устанавливаем PyTorch 2.8.0 для CUDA 12.8..."
    uv pip install --python "$VENV_PYTHON" \
        torch==2.8.0 torchvision==0.23.0 torchaudio==2.8.0 \
        --index-url https://download.pytorch.org/whl/cu128
fi

info "Устанавливаем зависимости ComfyUI..."
uv pip install --python "$VENV_PYTHON" -r requirements.txt

info "Устанавливаем/обновляем ComfyUI-Manager..."
mkdir -p "$COMFY_DIR/custom_nodes"
if [[ ! -d "$MANAGER_DIR" ]]; then
    git clone "$MANAGER_REPO" "$MANAGER_DIR"
else
    git -C "$MANAGER_DIR" pull --ff-only
fi

if [[ -f "$MANAGER_DIR/requirements.txt" ]]; then
    uv pip install --python "$VENV_PYTHON" -r "$MANAGER_DIR/requirements.txt"
fi

info "Устанавливаем зависимости для Панели Управления (Gradio, psutil)..."
uv pip install --python "$VENV_PYTHON" gradio psutil

# Копирование pisa_sr.pkl, если он лежит в папке со скриптом
if [[ -f "$SCRIPT_DIR/pisa_sr.pkl" ]]; then
    info "Обнаружен локальный файл pisa_sr.pkl. Копируем в ComfyUI..."
    mkdir -p "$COMFY_DIR/models/loras"
    cp "$SCRIPT_DIR/pisa_sr.pkl" "$COMFY_DIR/models/loras/pisa_sr.pkl"
fi

success "Автоматическая установка ComfyUI в .venv завершена!"
if [[ "$START_PANEL" == true ]]; then
    info "Запускаем Графическую Панель Управления..."
    exec "$VENV_PYTHON" "$SCRIPT_DIR/comfy_control_panel.py"
fi
info "Флаг --no-start указан: панель управления не запускаем."
