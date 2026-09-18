#!/usr/bin/env bash
# ==============================================================================
# prepare_network_volume.sh
# Скрипт для подготовки RunPod Network Volume под ComfyUI Serverless.
#
# Создает правильную структуру каталогов для RunPod worker-comfyui:
#   <VOLUME_ROOT>/models/diffusion_models/
#   <VOLUME_ROOT>/models/text_encoders/
#   <VOLUME_ROOT>/models/vae/
#   <VOLUME_ROOT>/models/loras/
#
# И скачивает модели Krea-2 (Turbo FP8 + Qwen3-VL + VAE + LoRA).
# ==============================================================================

set -Eeuo pipefail

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { printf "${BLUE}[ИНФО]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[УСПЕХ]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[ВНИМАНИЕ]${NC} %s\n" "$*"; }
error()   { printf "${RED}[ОШИБКА]${NC} %s\n" "$*" >&2; }

# Определение корня тома:
# 1. Аргумент командной строки: --target /path
# 2. Переменная окружения: TARGET_DIR
# 3. /runpod-volume (стандартная точка монтирования в Serverless)
# 4. /workspace (если запускается во временном RunPod Pod, подключенном к Network Volume)
# 5. Локальная папка ./runpod-volume
TARGET_DIR="${TARGET_DIR:-}"
DOWNLOAD_ERNIE=false
HF_TOKEN="${HF_TOKEN:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat <<EOF
Использование:
  $0 [ОПЦИИ]

Опции:
  --target <ПУТЬ>       Путь к корню Network Volume (по умолчанию: автоопределение:
                        /runpod-volume, /workspace или ./runpod-volume)
  --hf-token <ТОКЕН>    Hugging Face API токен (или переменная окружения HF_TOKEN)
  --with-ernie          Также скачать модели ERNIE-Image
  --help, -h            Показать справку
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET_DIR="$2"
            shift 2
            ;;
        --target=*)
            TARGET_DIR="${1#*=}"
            shift
            ;;
        --hf-token)
            HF_TOKEN="$2"
            shift 2
            ;;
        --hf-token=*)
            HF_TOKEN="${1#*=}"
            shift
            ;;
        --with-ernie)
            DOWNLOAD_ERNIE=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "Неизвестный параметр: $1"
            usage
            exit 1
            ;;
    esac
done

# Автоопределение целевой папки, если не указана вручную
if [[ -z "$TARGET_DIR" ]]; then
    if [[ -d "/runpod-volume" ]]; then
        TARGET_DIR="/runpod-volume"
    elif [[ -d "/workspace" ]]; then
        TARGET_DIR="/workspace"
    else
        TARGET_DIR="$SCRIPT_DIR/runpod-volume"
    fi
fi

info "Целевая директория Network Volume: ${CYAN}$TARGET_DIR${NC}"
mkdir -p "$TARGET_DIR"

MODELS_DIR="$TARGET_DIR/models"
DIFFUSION_DIR="$MODELS_DIR/diffusion_models"
TEXT_ENC_DIR="$MODELS_DIR/text_encoders"
VAE_DIR="$MODELS_DIR/vae"
LORAS_DIR="$MODELS_DIR/loras"

mkdir -p "$DIFFUSION_DIR" "$TEXT_ENC_DIR" "$VAE_DIR" "$LORAS_DIR"

download_file() {
    local url="$1"
    local dest_dir="$2"
    local filename="$3"
    local dest_file="$dest_dir/$filename"

    if [[ -f "$dest_file" && -s "$dest_file" ]]; then
        success "Файл уже существует, пропускаем: $filename ($(du -h "$dest_file" | cut -f1))"
        return 0
    fi

    info "Скачивание $filename в $dest_dir ..."
    local auth_header=()
    if [[ -n "$HF_TOKEN" && "$url" == *"huggingface.co"* ]]; then
        auth_header=(-H "Authorization: Bearer $HF_TOKEN")
    fi

    # Используем curl с докачкой (-C -) и следованием редиректам (-L)
    if command -v curl >/dev/null 2>&1; then
        curl -C - -L "${auth_header[@]}" \
            --progress-bar \
            --fail \
            --retry 5 \
            --retry-delay 3 \
            "$url" -o "$dest_file.tmp"
        mv "$dest_file.tmp" "$dest_file"
        success "Загружен: $filename"
    elif command -v wget >/dev/null 2>&1; then
        local wget_header=()
        if [[ -n "$HF_TOKEN" && "$url" == *"huggingface.co"* ]]; then
            wget_header=(--header="Authorization: Bearer $HF_TOKEN")
        fi
        wget -c "${wget_header[@]}" -O "$dest_file.tmp" "$url"
        mv "$dest_file.tmp" "$dest_file"
        success "Загружен: $filename"
    else
        error "Ни curl, ни wget не найдены в системе."
        return 1
    fi
}

echo "================================================================="
echo "   Подготовка моделей Krea-2 для RunPod Serverless ComfyUI"
echo "================================================================="

# 1. Krea-2 Turbo FP8 diffusion model (~13 GB)
download_file \
    "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/diffusion_models/krea2_turbo_fp8_scaled.safetensors" \
    "$DIFFUSION_DIR" \
    "krea2_turbo_fp8_scaled.safetensors"

# 2. Qwen3-VL 4B FP8 text encoder (~4.4 GB)
download_file \
    "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/text_encoders/qwen3vl_4b_fp8_scaled.safetensors" \
    "$TEXT_ENC_DIR" \
    "qwen3vl_4b_fp8_scaled.safetensors"

# 3. Qwen image VAE (~335 MB)
download_file \
    "https://huggingface.co/Comfy-Org/Krea-2/resolve/main/vae/qwen_image_vae.safetensors" \
    "$VAE_DIR" \
    "qwen_image_vae.safetensors"

# 4. Krea-2 LoRA Softwatercolor
download_file \
    "https://huggingface.co/krea/Krea-2-LoRA-softwatercolor/resolve/main/softwatercolor.safetensors" \
    "$LORAS_DIR" \
    "softwatercolor.safetensors"

# 5. Опционально: ERNIE-Image
if [[ "$DOWNLOAD_ERNIE" == true ]]; then
    info "Скачивание пакета моделей ERNIE-Image..."
    download_file \
        "https://huggingface.co/Comfy-Org/ERNIE-Image/resolve/main/diffusion_models/ernie-image.safetensors" \
        "$DIFFUSION_DIR" \
        "ernie-image.safetensors"
    download_file \
        "https://huggingface.co/Comfy-Org/ERNIE-Image/resolve/main/text_encoders/ministral-3-3b.safetensors" \
        "$TEXT_ENC_DIR" \
        "ministral-3-3b.safetensors"
    download_file \
        "https://huggingface.co/Comfy-Org/ERNIE-Image/resolve/main/text_encoders/ernie-image-prompt-enhancer.safetensors" \
        "$TEXT_ENC_DIR" \
        "ernie-image-prompt-enhancer.safetensors"
fi

echo "================================================================="
success "Подготовка Network Volume завершена!"
info "Итоговая структура файлов:"
ls -lh "$DIFFUSION_DIR" "$TEXT_ENC_DIR" "$VAE_DIR" "$LORAS_DIR" 2>/dev/null || true
echo "================================================================="
