#!/usr/bin/env bash

set -Eeuo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMFY_DIR="${COMFY_DIR:-$SCRIPT_DIR/ComfyUI}"
COMFY_REPO="https://github.com/Comfy-Org/ComfyUI.git"
MANAGER_DIR="$COMFY_DIR/custom_nodes/comfyui-manager"
MANAGER_REPO="https://github.com/Comfy-Org/ComfyUI-Manager.git"
MODEL_DOWNLOADER="$SCRIPT_DIR/comfy_model_downloader.sh"

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

confirm_step() {
    local prompt=$1 choice
    printf '\n%b\n' "${YELLOW}==> $prompt${NC}"

    while true; do
        if ! read -r -p "Продолжить? [Y/n]: " choice; then
            printf '\n'
            return 1
        fi
        case "${choice:-y}" in
            [YyДд]) return 0 ;;
            [NnНн]) warn "Шаг пропущен."; return 1 ;;
            *) warn "Введите y (да) или n (нет)." ;;
        esac
    done
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "Не найдена обязательная команда: $1"
        exit 1
    fi
}

ensure_uv() {
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    if command -v uv >/dev/null 2>&1; then
        success "uv готов к работе: $(uv --version)"
        return
    fi

    require_command curl
    warn "uv не найден. Устанавливаем с официального сайта Astral..."
    curl --proto '=https' --tlsv1.2 -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

    if ! command -v uv >/dev/null 2>&1; then
        error "Не удалось запустить uv после установки."
        exit 1
    fi
    success "uv установлен: $(uv --version)"
}

require_comfy_venv() {
    if [[ ! -x "$COMFY_DIR/.venv/bin/python" ]]; then
        error "Не найдено виртуальное окружение: $COMFY_DIR/.venv"
        error "Завершите установку ComfyUI или создайте окружение заново."
        exit 1
    fi
}

launch_comfy() {
    require_comfy_venv
    cd "$COMFY_DIR"
    success "Запускаем ComfyUI. Откройте адрес, который появится ниже."
    exec .venv/bin/python main.py "$@"
}

update_comfy() {
    require_command git
    ensure_uv
    require_comfy_venv

    info "Обновляем ComfyUI..."
    git -C "$COMFY_DIR" pull --ff-only
    uv pip install --python "$COMFY_DIR/.venv/bin/python" \
        -r "$COMFY_DIR/requirements.txt"
    success "ComfyUI и его зависимости обновлены."
}

install_or_update_manager() {
    require_command git
    ensure_uv
    require_comfy_venv
    mkdir -p "$COMFY_DIR/custom_nodes"

    if [[ -d "$MANAGER_DIR/.git" ]]; then
        info "Обновляем ComfyUI-Manager..."
        git -C "$MANAGER_DIR" pull --ff-only
    elif [[ -e "$MANAGER_DIR" ]]; then
        error "Путь Manager уже существует, но не является Git-репозиторием:"
        error "$MANAGER_DIR"
        exit 1
    else
        info "Устанавливаем ComfyUI-Manager..."
        git clone "$MANAGER_REPO" "$MANAGER_DIR"
    fi

    if [[ -f "$MANAGER_DIR/requirements.txt" ]]; then
        uv pip install --python "$COMFY_DIR/.venv/bin/python" \
            -r "$MANAGER_DIR/requirements.txt"
    fi
    success "ComfyUI-Manager установлен и обновлен."
}

run_model_downloader() {
    if [[ ! -x "$MODEL_DOWNLOADER" ]]; then
        error "Загрузчик не найден или не исполняемый: $MODEL_DOWNLOADER"
        return 1
    fi
    COMFY_DIR="$COMFY_DIR" "$MODEL_DOWNLOADER"
}

configure_model_tokens() {
    if [[ ! -x "$MODEL_DOWNLOADER" ]]; then
        error "Загрузчик не найден или не исполняемый: $MODEL_DOWNLOADER"
        return 1
    fi
    COMFY_DIR="$COMFY_DIR" "$MODEL_DOWNLOADER" --tokens
}

install_global_model_downloader() {
    if [[ ! -x "$MODEL_DOWNLOADER" ]]; then
        error "Загрузчик не найден или не исполняемый: $MODEL_DOWNLOADER"
        return 1
    fi
    COMFY_DIR="$COMFY_DIR" "$MODEL_DOWNLOADER" --install-global
}

download_model_list() {
    if [[ ! -x "$MODEL_DOWNLOADER" ]]; then
        error "Загрузчик не найден или не исполняемый: $MODEL_DOWNLOADER"
        return 1
    fi
    COMFY_DIR="$COMFY_DIR" "$MODEL_DOWNLOADER" --batch
}

existing_install_menu() {
    local choice

    while true; do
        printf '\n%b\n' "${GREEN}Найдена установленная ComfyUI: $COMFY_DIR${NC}"
        printf '  1) Просто запустить ComfyUI\n'
        printf '  2) Обновить ComfyUI и зависимости\n'
        printf '  3) Установить или обновить ComfyUI-Manager\n'
        printf '  4) Загрузчик моделей и настройка токенов\n'
        printf '  5) Установить загрузчик как глобальную Linux-команду\n'
        printf '  6) Настроить Hugging Face / Civitai токены\n'
        printf '  7) Скачать список моделей из TXT\n'
        printf '  0) Выход\n'
        read -r -p "Выберите действие [1]: " choice || exit 0

        case "${choice:-1}" in
            1) launch_comfy "$@" ;;
            2)
                update_comfy
                if confirm_step "Запустить ComfyUI сейчас?"; then
                    launch_comfy "$@"
                fi
                return
                ;;
            3)
                install_or_update_manager
                if confirm_step "Запустить ComfyUI сейчас?"; then
                    launch_comfy "$@"
                fi
                return
                ;;
            4) run_model_downloader || warn "Загрузчик завершился с ошибкой." ;;
            5) install_global_model_downloader || warn "Глобальная команда не установлена." ;;
            6) configure_model_tokens || warn "Токены не были изменены." ;;
            7) download_model_list || warn "Пакетная загрузка завершена с ошибками." ;;
            0) success "Выход."; return ;;
            *) warn "Введите число от 0 до 7." ;;
        esac
    done
}

choose_torch_backend() {
    local default_choice=4 choice
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        default_choice=1
    elif [[ -e /dev/kfd ]]; then
        default_choice=3
    fi

    printf '\n%b\n' "${YELLOW}Выберите сборку PyTorch:${NC}"
    printf '  1) NVIDIA CUDA 13.0 (рекомендуется документацией ComfyUI)\n'
    printf '  2) NVIDIA CUDA 12.8 (для более старых драйверов)\n'
    printf '  3) AMD ROCm 7.2 (Linux)\n'
    printf '  4) CPU (Linux / Windows)\n'
    printf '  5) Apple Silicon (стандартный PyPI)\n'

    while true; do
        read -r -p "Вариант [$default_choice]: " choice || return 1
        choice=${choice:-$default_choice}
        case "$choice" in
            1) TORCH_INDEX="https://download.pytorch.org/whl/cu130"; return ;;
            2) TORCH_INDEX="https://download.pytorch.org/whl/cu128"; return ;;
            3) TORCH_INDEX="https://download.pytorch.org/whl/rocm7.2"; return ;;
            4) TORCH_INDEX="https://download.pytorch.org/whl/cpu"; return ;;
            5) TORCH_INDEX=""; return ;;
            *) warn "Введите число от 1 до 5." ;;
        esac
    done
}

printf '%b\n' "${BLUE}===================================================${NC}"
printf '%b\n' "${BLUE}       Интерактивный установщик ComfyUI + uv       ${NC}"
printf '%b\n' "${BLUE}===================================================${NC}"

if [[ -d "$COMFY_DIR/.git" ]]; then
    existing_install_menu "$@"
    exit 0
elif [[ -e "$COMFY_DIR" ]]; then
    error "Путь уже существует, но не является Git-репозиторием: $COMFY_DIR"
    error "Переименуйте или удалите его вручную, затем запустите установщик снова."
    exit 1
elif confirm_step "Клонировать официальный репозиторий ComfyUI?"; then
    require_command git
    git clone --depth 1 "$COMFY_REPO" "$COMFY_DIR"
else
    error "Без каталога ComfyUI продолжить установку невозможно."
    exit 1
fi

cd "$COMFY_DIR"
ensure_uv

if [[ ! -x .venv/bin/python ]]; then
    if confirm_step "Создать виртуальное окружение .venv (Python 3.12)?"; then
        uv venv --python 3.12 .venv
    else
        error "Для безопасной установки требуется виртуальное окружение .venv."
        exit 1
    fi
else
    success "Используем существующее окружение: $COMFY_DIR/.venv"
fi

if confirm_step "Установить или обновить PyTorch?"; then
    choose_torch_backend
    if [[ -n "$TORCH_INDEX" ]]; then
        info "Устанавливаем PyTorch из $TORCH_INDEX"
        uv pip install --python .venv/bin/python torch torchvision torchaudio \
            --index-url "$TORCH_INDEX"
    else
        info "Устанавливаем PyTorch из стандартного индекса PyPI"
        uv pip install --python .venv/bin/python torch torchvision torchaudio
    fi
fi

if confirm_step "Установить или обновить зависимости ComfyUI?"; then
    uv pip install --python .venv/bin/python -r requirements.txt
fi

printf '\n%b\n' "${GREEN}===================================================${NC}"
printf '%b\n' "${GREEN}             Установка завершена                  ${NC}"
printf '%b\n' "${GREEN}===================================================${NC}"

if confirm_step "Запустить ComfyUI сейчас?"; then
    launch_comfy "$@"
fi

printf '\n%b\n' "${BLUE}Для запуска позже:${NC}"
printf '%b\n' "${YELLOW}cd $(printf '%q' "$COMFY_DIR")${NC}"
printf '%b\n' "${YELLOW}.venv/bin/python main.py${NC}"
