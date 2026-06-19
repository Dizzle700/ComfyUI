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
    export PIP_CACHE_DIR="${PIP_CACHE_DIR:-/workspace/.cache/pip}"
    export TORCH_HOME="${TORCH_HOME:-/workspace/.cache/torch}"
    export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
    export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-/workspace/.cache/huggingface/hub}"
    export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/workspace/.cache/huggingface/transformers}"
    export DIFFUSERS_CACHE="${DIFFUSERS_CACHE:-/workspace/.cache/huggingface/diffusers}"
    mkdir -p "$PIP_CACHE_DIR" "$TORCH_HOME" \
        "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$TRANSFORMERS_CACHE" "$DIFFUSERS_CACHE"
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
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
TORCH_VERSION="${TORCH_VERSION:-2.8.0}"
TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.23.0}"
TORCHAUDIO_VERSION="${TORCHAUDIO_VERSION:-2.8.0}"
TORCH_CUDA_VERSION="${TORCH_CUDA_VERSION:-12.8}"

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

ensure_venv_pip() {
    if "$VENV_PYTHON" -m pip --version >/dev/null 2>&1; then
        success "pip готов к работе: $("$VENV_PYTHON" -m pip --version)"
        return
    fi

    info "pip не найден в .venv. Устанавливаем через ensurepip..."
    "$VENV_PYTHON" -m ensurepip --upgrade
}

write_torch_constraints() {
    TORCH_CONSTRAINTS="$COMFY_DIR/.runpod-torch-constraints.txt"
    cat > "$TORCH_CONSTRAINTS" <<EOF
torch==$TORCH_VERSION
torchvision==$TORCHVISION_VERSION
torchaudio==$TORCHAUDIO_VERSION
EOF
}

install_compatible_torch() {
    warn "Устанавливаем PyTorch $TORCH_VERSION для CUDA $TORCH_CUDA_VERSION ($TORCH_INDEX_URL)..."
    "$VENV_PYTHON" -m pip install \
        torch=="$TORCH_VERSION" torchvision=="$TORCHVISION_VERSION" torchaudio=="$TORCHAUDIO_VERSION" \
        --index-url "$TORCH_INDEX_URL"
}

torch_matches_target() {
    local python_exe=$1
    "$python_exe" - "$TORCH_VERSION" "$TORCH_CUDA_VERSION" <<'PY' >/dev/null 2>&1
import sys
import torch

expected_torch = sys.argv[1]
expected_cuda = sys.argv[2]
installed_torch = torch.__version__.split("+", 1)[0]
installed_cuda = str(torch.version.cuda or "")

ok = (
    torch.cuda.is_available()
    and installed_torch == expected_torch
    and installed_cuda == expected_cuda
)
raise SystemExit(0 if ok else 1)
PY
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

# В современных RunPod/PyTorch images системный Python часто externally managed,
# поэтому зависимости ComfyUI ставим в venv. Если PyTorch уже есть в template,
# создаем venv с system-site-packages и не скачиваем torch повторно.
SYSTEM_TORCH_READY=false
if torch_matches_target python3; then
    SYSTEM_TORCH_READY=true
    success "Контейнерный PyTorch подходит: $(python3 -c 'import torch; print(torch.__version__, "(CUDA", torch.version.cuda, ")")')"
elif python3 -c "import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)" >/dev/null 2>&1; then
    warn "Предустановленный PyTorch не совпадает с целевым стеком $TORCH_VERSION + CUDA $TORCH_CUDA_VERSION."
fi

if [[ ! -x .venv/bin/python ]]; then
    if [[ "$SYSTEM_TORCH_READY" == true ]]; then
        info "Создаем .venv с доступом к контейнерному PyTorch..."
        python3 -m venv --system-site-packages .venv
    else
        info "Создаем изолированное виртуальное окружение .venv..."
        python3 -m venv .venv
    fi
else
    success "Используем существующее окружение: $COMFY_DIR/.venv"
fi
VENV_PYTHON="$COMFY_DIR/.venv/bin/python"
ensure_venv_pip
write_torch_constraints

if torch_matches_target "$VENV_PYTHON"; then
    success "PyTorch в .venv готов: $("$VENV_PYTHON" -c 'import torch; print(torch.__version__, "(CUDA", torch.version.cuda, ")")')"
else
    install_compatible_torch
fi

info "Устанавливаем зависимости ComfyUI..."
"$VENV_PYTHON" -m pip install \
    -r requirements.txt \
    --constraint "$TORCH_CONSTRAINTS" \
    --extra-index-url "$TORCH_INDEX_URL"

info "Устанавливаем/обновляем ComfyUI-Manager..."
mkdir -p "$COMFY_DIR/custom_nodes"
if [[ ! -d "$MANAGER_DIR" ]]; then
    git clone --depth 1 "$MANAGER_REPO" "$MANAGER_DIR"
else
    git -C "$MANAGER_DIR" pull --ff-only
fi

if [[ -f "$MANAGER_DIR/requirements.txt" ]]; then
    "$VENV_PYTHON" -m pip install \
        -r "$MANAGER_DIR/requirements.txt" \
        --constraint "$TORCH_CONSTRAINTS" \
        --extra-index-url "$TORCH_INDEX_URL"
fi

info "Устанавливаем зависимости для Панели Управления (Gradio, psutil)..."
"$VENV_PYTHON" -m pip install gradio psutil

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
