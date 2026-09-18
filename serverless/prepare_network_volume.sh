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
# Загружает модели Krea-2 с использованием:
#   1. Токена Hugging Face (из .env.secrets, HF_TOKEN или флага --hf-token)
#   2. Ускоренного многопоточного транспорта hf-xet (через huggingface_hub),
#      с надежным fallback на curl при отсутствии hf-xet.
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

TARGET_DIR="${TARGET_DIR:-}"
DOWNLOAD_ERNIE=false
HF_TOKEN="${HF_TOKEN:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# ------------------------------------------------------------------------------
# 1. Автоматический поиск и загрузка HF_TOKEN из .env.secrets
# ------------------------------------------------------------------------------
load_secret_token() {
    [[ -z "$HF_TOKEN" ]] || return 0

    local secret_candidates=(
        "$PARENT_DIR/.env.secrets"
        "$SCRIPT_DIR/.env.secrets"
        "/workspace/.env.secrets"
        "./.env.secrets"
    )

    for s_file in "${secret_candidates[@]}"; do
        if [[ -f "$s_file" && -r "$s_file" ]]; then
            local token_from_file
            token_from_file=$(grep -E '^[[:space:]]*HF_TOKEN=' "$s_file" | head -n 1 | cut -d'=' -f2- | tr -d ' "' | tr -d "'")
            if [[ -n "$token_from_file" ]]; then
                HF_TOKEN="$token_from_file"
                export HF_TOKEN
                info "Загружен HF_TOKEN из $s_file"
                return 0
            fi
        fi
    done
}

load_secret_token

# ------------------------------------------------------------------------------
# 2. Обработка аргументов командной строки
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Использование:
  $0 [ОПЦИИ]

Опции:
  --target <ПУТЬ>       Путь к корню Network Volume (по умолчанию: автоопределение:
                        /runpod-volume, /workspace или ./runpod-volume)
  --hf-token <ТОКЕН>    Hugging Face API токен (или переменная HF_TOKEN,
                        также читается автоматически из .env.secrets)
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

export HF_TOKEN

# Включение многопоточного высокоскоростного транспорта Hugging Face (hf-xet)
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"

# Автоопределение целевой папки
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
UNET_DIR="$MODELS_DIR/unet"
TEXT_ENC_DIR="$MODELS_DIR/text_encoders"
CLIP_DIR="$MODELS_DIR/clip"
VAE_DIR="$MODELS_DIR/vae"
LORAS_DIR="$MODELS_DIR/loras"

mkdir -p "$DIFFUSION_DIR" "$UNET_DIR" "$TEXT_ENC_DIR" "$CLIP_DIR" "$VAE_DIR" "$LORAS_DIR"

# Проверка и вывод статуса токена HF
if [[ -n "$HF_TOKEN" ]]; then
    masked_token="${HF_TOKEN:0:4}...${HF_TOKEN: -4}"
    success "Авторизация Hugging Face: активна (токен: $masked_token)"
else
    warn "HF_TOKEN не указан. Публичные модели скачаются без токена, но возможны ограничения скорости со стороны HF."
fi

# Проверка доступности hf-xet через python
has_huggingface_hub() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -c "import huggingface_hub" >/dev/null 2>&1 || return 1
}

format_duration() {
    local seconds=$1
    printf "%02d:%02d" $((seconds / 60)) $((seconds % 60))
}

# ------------------------------------------------------------------------------
# 3. Функция загрузки через hf-xet (huggingface_hub)
# ------------------------------------------------------------------------------
try_hf_xet_download() {
    local url=$1 dest_file=$2
    has_huggingface_hub || return 1

    info "Попытка загрузки через hf-xet (высокоскоростной транспорт)..."
    local python_pid started elapsed next_report=10

    python3 -u - "$url" "$dest_file" <<'PY' &
import os
import shutil
import sys
from urllib.parse import unquote, urlparse

try:
    from huggingface_hub import hf_hub_download
except ImportError:
    sys.exit(3)

url, target = sys.argv[1:]
parsed = urlparse(url)
if parsed.hostname not in {"huggingface.co", "www.huggingface.co"}:
    sys.exit(4)

parts = [unquote(part) for part in parsed.path.split("/") if part]
if len(parts) < 5 or parts[2] not in {"resolve", "blob"}:
    sys.exit(5)

repo_id = "/".join(parts[:2])
revision = parts[3]
filename = "/".join(parts[4:])

token = os.environ.get("HF_TOKEN") or None
cached_path = os.path.realpath(hf_hub_download(
    repo_id=repo_id,
    filename=filename,
    revision=revision,
    token=token,
))

if not os.path.isfile(cached_path):
    raise RuntimeError(f"HF blob не найден: {cached_path}")

os.makedirs(os.path.dirname(target), exist_ok=True)
try:
    os.unlink(target)
except FileNotFoundError:
    pass

try:
    os.link(cached_path, target)
except OSError:
    shutil.copy2(cached_path, target)

sys.exit(0)
PY
    python_pid=$!
    started=$SECONDS

    while kill -0 "$python_pid" 2>/dev/null; do
        sleep 2
        elapsed=$(( SECONDS - started ))
        if (( elapsed >= next_report )); then
            info "  -> hf-xet: скачивание продолжается, прошло $(format_duration "$elapsed")..."
            next_report=$(( next_report + 15 ))
        fi
    done

    if wait "$python_pid"; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 4. Основная функция загрузки с fallback на curl
# ------------------------------------------------------------------------------
download_file() {
    local url="$1"
    local dest_dir="$2"
    local filename="$3"
    local dest_file="$dest_dir/$filename"

    if [[ -f "$dest_file" && -s "$dest_file" ]]; then
        success "Файл уже существует, пропускаем: $filename ($(du -h "$dest_file" | cut -f1))"
        return 0
    fi

    info "Подготовка к загрузке: ${CYAN}$filename${NC} -> $dest_dir"

    # Шаг 1: Пробуем загрузить через hf-xet (если ссылка на Hugging Face)
    if [[ "$url" == *"huggingface.co"* ]] && try_hf_xet_download "$url" "$dest_file"; then
        success "Загружен через hf-xet: $filename ($(du -h "$dest_file" | cut -f1))"
        return 0
    fi

    # Шаг 2: Fallback на curl с докачкой (-C -) и Bearer-токеном
    info "Используется fallback через curl (многопоточный hf-xet недоступен)..."
    local auth_header=()
    if [[ -n "$HF_TOKEN" && "$url" == *"huggingface.co"* ]]; then
        auth_header=(-H "Authorization: Bearer $HF_TOKEN")
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -C - -L "${auth_header[@]}" \
            --progress-bar \
            --fail \
            --retry 5 \
            --retry-delay 3 \
            "$url" -o "$dest_file.tmp"
        mv "$dest_file.tmp" "$dest_file"
        success "Загружен через curl: $filename ($(du -h "$dest_file" | cut -f1))"
    elif command -v wget >/dev/null 2>&1; then
        local wget_header=()
        if [[ -n "$HF_TOKEN" && "$url" == *"huggingface.co"* ]]; then
            wget_header=(--header="Authorization: Bearer $HF_TOKEN")
        fi
        wget -c "${wget_header[@]}" -O "$dest_file.tmp" "$url"
        mv "$dest_file.tmp" "$dest_file"
        success "Загружен через wget: $filename ($(du -h "$dest_file" | cut -f1))"
    else
        error "Ни python3 huggingface_hub, ни curl, ни wget не смогли скачать файл."
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

# Создание симлинков для полной совместимости с runpod/worker-comfyui (unet и clip)
info "Создание симлинков (unet <-> diffusion_models, clip <-> text_encoders)..."
for f in "$DIFFUSION_DIR"/*; do
    [[ -f "$f" ]] && ln -sf "$f" "$UNET_DIR/$(basename "$f")" 2>/dev/null || true
done
for f in "$TEXT_ENC_DIR"/*; do
    [[ -f "$f" ]] && ln -sf "$f" "$CLIP_DIR/$(basename "$f")" 2>/dev/null || true
done

echo "================================================================="
success "Подготовка Network Volume завершена!"
info "Итоговая структура файлов:"
ls -lh "$DIFFUSION_DIR" "$UNET_DIR" "$TEXT_ENC_DIR" "$CLIP_DIR" "$VAE_DIR" "$LORAS_DIR" 2>/dev/null || true
echo "================================================================="
