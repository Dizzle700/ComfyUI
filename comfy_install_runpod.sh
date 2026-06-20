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

ensure_python_pip() {
    if "$PYTHON_EXE" -m pip --version >/dev/null 2>&1; then
        success "pip готов к работе: $("$PYTHON_EXE" -m pip --version)"
        return
    fi

    info "pip не найден в Python-окружении RunPod. Устанавливаем через ensurepip..."
    "$PYTHON_EXE" -m ensurepip --upgrade
}

write_preinstalled_torch_constraints() {
    TORCH_CONSTRAINTS="$COMFY_DIR/.runpod-torch-constraints.txt"
    "$PYTHON_EXE" - <<'PY' > "$TORCH_CONSTRAINTS"
from importlib.metadata import PackageNotFoundError, version

for package in ("torch", "torchvision", "torchaudio"):
    try:
        print(f"{package}=={version(package)}")
    except PackageNotFoundError:
        pass
print("transformers>=4.46.2,<5.0.0")
print("gradio>=5.5.0,<6.0.0")
print("huggingface-hub>=0.34.0,<1.0.0")
PY
}

has_cuda_torch() {
    local python_exe=$1
    "$python_exe" - <<'PY' >/dev/null 2>&1
import torch

raise SystemExit(0 if torch.version.cuda else 1)
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
PYTHON_EXE="${PYTHON_EXE:-python3}"
export PIP_BREAK_SYSTEM_PACKAGES="${PIP_BREAK_SYSTEM_PACKAGES:-1}"
ensure_python_pip

# Используем готовое Python-окружение RunPod напрямую. Constraints запрещают pip
# подменять предустановленный Torch другой сборкой.
if has_cuda_torch "$PYTHON_EXE"; then
    success "Используем предустановленный PyTorch: $("$PYTHON_EXE" -c 'import torch; print(torch.__version__, "(CUDA", torch.version.cuda, ")")')"
    if ! "$PYTHON_EXE" -c "import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)" >/dev/null 2>&1; then
        warn "PyTorch собран с CUDA, но GPU сейчас недоступен. Проверьте драйвер и настройки RunPod."
    fi
else
    error "CUDA-enabled PyTorch в RunPod-образе не найден."
    error "Выберите PyTorch template; автоматическая загрузка другой сборки отключена."
    exit 1
fi

write_preinstalled_torch_constraints
PIP_TORCH_ARGS=(--constraint "$TORCH_CONSTRAINTS")
export PIP_CONSTRAINT="$TORCH_CONSTRAINTS"

info "Устанавливаем зависимости ComfyUI..."
"$PYTHON_EXE" -m pip install \
    -r requirements.txt \
    "${PIP_TORCH_ARGS[@]}"

info "Устанавливаем/обновляем ComfyUI-Manager..."
mkdir -p "$COMFY_DIR/custom_nodes"
if [[ ! -d "$MANAGER_DIR" ]]; then
    git clone --depth 1 "$MANAGER_REPO" "$MANAGER_DIR"
else
    git -C "$MANAGER_DIR" pull --ff-only
fi

if [[ -f "$MANAGER_DIR/requirements.txt" ]]; then
    "$PYTHON_EXE" -m pip install \
        -r "$MANAGER_DIR/requirements.txt" \
        "${PIP_TORCH_ARGS[@]}"
fi

info "Устанавливаем зависимости панели и совместимый T5/SentencePiece tokenizer..."
if "$PYTHON_EXE" -m pip show hf-gradio >/dev/null 2>&1; then
    warn "Удаляем несовместимый пакет hf-gradio из RunPod image..."
    "$PYTHON_EXE" -m pip uninstall -y hf-gradio
fi
"$PYTHON_EXE" -m pip install \
    "gradio>=5.5.0,<6.0.0" psutil tiktoken sentencepiece protobuf hf_transfer \
    "transformers[sentencepiece]>=4.46.2,<5.0.0" \
    "huggingface-hub>=0.34.0,<1.0.0"

# Копирование pisa_sr.pkl, если он лежит в папке со скриптом
if [[ -f "$SCRIPT_DIR/pisa_sr.pkl" ]]; then
    info "Обнаружен локальный файл pisa_sr.pkl. Копируем в ComfyUI..."
    mkdir -p "$COMFY_DIR/models/loras"
    cp "$SCRIPT_DIR/pisa_sr.pkl" "$COMFY_DIR/models/loras/pisa_sr.pkl"
fi

success "Автоматическая установка ComfyUI в Python-окружение RunPod завершена!"
if [[ "$START_PANEL" == true ]]; then
    info "Запускаем Графическую Панель Управления..."
    exec "$PYTHON_EXE" "$SCRIPT_DIR/comfy_control_panel.py"
fi
info "Флаг --no-start указан: панель управления не запускаем."
