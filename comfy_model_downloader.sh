#!/usr/bin/env bash

set -Eeuo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/comfy-model-downloader"
TOKEN_FILE="$TOKEN_DIR/tokens.env"
COMFY_PATH_FILE="$TOKEN_DIR/comfy_dir"
SAVED_COMFY_DIR=''
if [[ -f "$COMFY_PATH_FILE" ]]; then
    IFS= read -r SAVED_COMFY_DIR < "$COMFY_PATH_FILE" || true
fi
COMFY_DIR="${COMFY_DIR:-${SAVED_COMFY_DIR:-$SCRIPT_DIR/ComfyUI}}"

info() { printf '%b\n' "${BLUE}$*${NC}"; }
success() { printf '%b\n' "${GREEN}$*${NC}"; }
warn() { printf '%b\n' "${YELLOW}$*${NC}"; }
error() { printf '%b\n' "${RED}$*${NC}" >&2; }

confirm_step() {
    local prompt=$1 choice
    while true; do
        read -r -p "$prompt [y/N]: " choice || return 1
        case "$choice" in
            [YyДд]) return 0 ;;
            ''|[NnНн]) return 1 ;;
            *) warn "Введите y (да) или n (нет)." ;;
        esac
    done
}

load_tokens() {
    HF_TOKEN=${HF_TOKEN:-}
    CIVITAI_API_TOKEN=${CIVITAI_API_TOKEN:-}
    if [[ -f "$TOKEN_FILE" ]]; then
        # Файл создается только этой утилитой и доступен лишь владельцу.
        source "$TOKEN_FILE"
    fi
}

save_tokens() {
    mkdir -p "$TOKEN_DIR"
    chmod 700 "$TOKEN_DIR"
    umask 077
    {
        printf 'HF_TOKEN=%q\n' "$HF_TOKEN"
        printf 'CIVITAI_API_TOKEN=%q\n' "$CIVITAI_API_TOKEN"
    } > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
}

configure_tokens() {
    local choice token
    load_tokens

    while true; do
        printf '\n%b\n' "${YELLOW}Глобальные токены загрузчика:${NC}"
        if [[ -n "$HF_TOKEN" ]]; then
            printf '  1) Hugging Face: настроен\n'
        else
            printf '  1) Hugging Face: не настроен\n'
        fi
        if [[ -n "$CIVITAI_API_TOKEN" ]]; then
            printf '  2) Civitai: настроен\n'
        else
            printf '  2) Civitai: не настроен\n'
        fi
        printf '  3) Удалить оба токена\n'
        printf '  0) Назад\n'
        read -r -p "Выберите действие: " choice || return

        case "$choice" in
            1)
                read -r -s -p "Вставьте Hugging Face token: " token
                printf '\n'
                [[ -n "$token" ]] || { warn "Пустой токен не сохранен."; continue; }
                HF_TOKEN=$token
                save_tokens
                success "Hugging Face token сохранен."
                ;;
            2)
                read -r -s -p "Вставьте Civitai API token: " token
                printf '\n'
                [[ -n "$token" ]] || { warn "Пустой токен не сохранен."; continue; }
                CIVITAI_API_TOKEN=$token
                save_tokens
                success "Civitai token сохранен."
                ;;
            3)
                if confirm_step "Удалить сохраненные токены?"; then
                    HF_TOKEN=''
                    CIVITAI_API_TOKEN=''
                    rm -f -- "$TOKEN_FILE"
                    success "Сохраненные токены удалены."
                fi
                ;;
            0) return ;;
            *) warn "Введите 1, 2, 3 или 0." ;;
        esac
    done
}

normalize_model_url() {
    local url=$1

    if [[ "$url" == https://huggingface.co/*/blob/* ]]; then
        url=${url/\/blob\//\/resolve\/}
        [[ "$url" == *\?* ]] || url="${url}?download=true"
        info "Ссылка Hugging Face преобразована в прямую загрузку." >&2
    fi

    if [[ "$url" =~ ^https://(www\.)?civitai\.com/models/ ]]; then
        error "Это страница модели Civitai, а не прямая ссылка на файл."
        error "На Civitai нажмите Download и вставьте адрес ссылки загрузки."
        return 1
    fi

    printf '%s\n' "$url"
}

validate_download() {
    local file=$1 headers=$2 content_type detected_type file_size

    [[ -s "$file" ]] || { error "Сервер вернул пустой файл."; return 1; }
    file_size=$(stat -c '%s' "$file")

    content_type=$(
        awk 'tolower($0) ~ /^content-type:/ { value=$0 } END {
            sub(/^[^:]+:[[:space:]]*/, "", value)
            sub(/\r$/, "", value)
            print tolower(value)
        }' "$headers"
    )

    case "$content_type" in
        text/html*|application/xhtml+xml*|application/json*)
            error "Сервер вернул не модель, а ответ типа: ${content_type:-неизвестно}"
            return 1
            ;;
    esac

    if head -c 4096 "$file" | LC_ALL=C grep -aEiq \
        '<!doctype html|<html|<head|^[[:space:]]*\{"(error|message|detail|status)"'; then
        error "Вместо модели получена HTML-страница или сообщение об ошибке."
        return 1
    fi

    if head -c 256 "$file" | LC_ALL=C grep -aFq \
        'version https://git-lfs.github.com/spec/v1'; then
        error "Получен указатель Git LFS, а не содержимое модели."
        error "Используйте ссылку Hugging Face /resolve/, а не Raw из Git-репозитория."
        return 1
    fi

    detected_type=$(file --brief --mime-type "$file" 2>/dev/null || true)
    if [[ "$content_type" == text/plain* && "$detected_type" == text/plain &&
        "$file_size" -lt 1048576 ]]; then
        error "Сервер вернул небольшой текстовый ответ ($(format_bytes "$file_size")), а не модель."
        return 1
    fi

    if [[ "$content_type" == text/plain* && "$detected_type" != text/plain ]]; then
        warn "Сервер указал text/plain, но файл бинарный ($detected_type). Продолжаем проверку."
    fi
}

format_bytes() {
    awk -v bytes="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB", units, " ")
        value = bytes + 0
        unit = 1
        while (value >= 1024 && unit < 5) {
            value /= 1024
            unit++
        }
        if (unit == 1) printf "%.0f %s", value, units[unit]
        else printf "%.2f %s", value, units[unit]
    }'
}

format_duration() {
    awk -v seconds="${1:-0}" 'BEGIN {
        total = int(seconds + 0.5)
        hours = int(total / 3600)
        minutes = int((total % 3600) / 60)
        secs = total % 60
        if (hours > 0) printf "%dh %02dm %02ds", hours, minutes, secs
        else if (minutes > 0) printf "%dm %02ds", minutes, secs
        else printf "%ds", secs
    }'
}

get_response_filename() {
    local headers=$1 disposition filename=''
    disposition=$(
        awk 'tolower($0) ~ /^content-disposition:/ { value=$0 } END {
            sub(/\r$/, "", value)
            print value
        }' "$headers"
    )
    if [[ "$disposition" =~ filename\*=UTF-8\'\'([^\;]+) ]]; then
        filename=${BASH_REMATCH[1]}
        if command -v python3 >/dev/null 2>&1; then
            filename=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]))' "$filename")
        fi
    elif [[ "$disposition" =~ filename=\"([^\"]+)\" ]]; then
        filename=${BASH_REMATCH[1]}
    elif [[ "$disposition" =~ filename=([^\;[:space:]]+) ]]; then
        filename=${BASH_REMATCH[1]}
    fi

    filename=${filename##*/}
    filename=${filename##*\\}
    [[ -n "$filename" && "$filename" != "." && "$filename" != ".." ]] || return 1
    printf '%s\n' "$filename"
}

get_clipboard_url() {
    local content=''

    if command -v wl-paste >/dev/null 2>&1; then
        content=$(wl-paste --no-newline 2>/dev/null || true)
    fi
    if [[ -z "$content" ]] && command -v xclip >/dev/null 2>&1; then
        content=$(xclip -selection clipboard -o 2>/dev/null || true)
    fi
    if [[ -z "$content" ]] && command -v xsel >/dev/null 2>&1; then
        content=$(xsel --clipboard --output 2>/dev/null || true)
    fi
    if [[ -z "$content" ]] && command -v powershell.exe >/dev/null 2>&1; then
        content=$(powershell.exe -NoProfile -Command Get-Clipboard 2>/dev/null || true)
    fi
    if [[ -z "$content" ]] && command -v termux-clipboard-get >/dev/null 2>&1; then
        content=$(termux-clipboard-get 2>/dev/null || true)
    fi

    content=${content//$'\r'/}
    while [[ "$content" == [[:space:]]* ]]; do content=${content:1}; done
    while [[ "$content" == *[[:space:]] ]]; do content=${content::-1}; done
    [[ "$content" != *$'\n'* && "$content" =~ ^https?://[^[:space:]]+$ ]] || return 1
    printf '%s\n' "$content"
}

read_model_url() {
    local clipboard_url='' entered='' display_url

    clipboard_url=$(get_clipboard_url || true)
    if [[ -n "$clipboard_url" ]]; then
        display_url=${clipboard_url%%\?*}
        printf '\n%b\n' "${GREEN}В буфере обмена найдена ссылка:${NC}"
        printf '%s\n' "$display_url"
        read -r -p "Enter — использовать её, либо вставьте другую ссылку: " entered || return 1
        MODEL_URL=${entered:-$clipboard_url}
    else
        printf '\n%b\n' "${YELLOW}Ссылка в буфере не найдена. Вставьте её вручную.${NC}"
        read -r -p "URL: " MODEL_URL || return 1
    fi
}

infer_folder_from_name() {
    local value=${1,,}

    case "$value" in
        *diffusion_models/*|*/unet/*|*diffusion-model*|*diffusion_model*)
            printf 'diffusion_models|имя или URL содержит diffusion model / UNet\n' ;;
        *text_encoders/*|*text-encoder*|*text_encoder*|*umt5*|*t5xxl*|*clip_l*|*clip_g*)
            printf 'text_encoders|имя или URL указывает на текстовый энкодер\n' ;;
        *clip_vision/*|*clip-vision*|*clip_vision*|*vision_encoder*)
            printf 'clip_vision|имя или URL указывает на vision encoder\n' ;;
        *vae/*|*-vae*|*_vae*|*vae-ft*|*ae.safetensors*)
            printf 'vae|имя или URL содержит VAE / autoencoder\n' ;;
        *lora*|*lycoris*|*locon*)
            printf 'loras|имя или URL указывает на LoRA\n' ;;
        *controlnet*|*control_net*|*control-lora*|*t2iadapter*|*t2i-adapter*)
            printf 'controlnet|имя или URL указывает на ControlNet / adapter\n' ;;
        *upscale*|*upscaler*|*esrgan*|*realesrgan*|*swinir*|*scunet*)
            printf 'upscale_models|имя или URL указывает на апскейлер\n' ;;
        *embedding*|*textual_inversion*|*textual-inversion*)
            printf 'embeddings|имя или URL указывает на embedding\n' ;;
        *checkpoints/*|*checkpoint*|*.ckpt*)
            printf 'checkpoints|имя или URL указывает на checkpoint\n' ;;
        *.gguf*)
            printf 'diffusion_models|GGUF обычно используется как diffusion model\n' ;;
    esac
}

infer_folder_from_safetensors() {
    local file=$1
    command -v python3 >/dev/null 2>&1 || return 0

    python3 - "$file" <<'PY'
import json
import struct
import sys

path = sys.argv[1]
try:
    with open(path, "rb") as stream:
        raw = stream.read(8)
        if len(raw) != 8:
            raise ValueError
        header_size = struct.unpack("<Q", raw)[0]
        if header_size < 2 or header_size > 100 * 1024 * 1024:
            raise ValueError
        header = json.loads(stream.read(header_size))
except (OSError, ValueError, json.JSONDecodeError, struct.error):
    sys.exit(0)

keys = [key.lower() for key in header if key != "__metadata__"]
metadata = header.get("__metadata__", {})
metadata_text = " ".join(f"{k}={v}" for k, v in metadata.items()).lower()

def has(*parts):
    return any(any(part in key for part in parts) for key in keys)

if (has("lora_up.weight", "lora_down.weight", ".lora_a.", ".lora_b.", "lora_unet_")
        or "ss_network_module" in metadata_text or "lycoris" in metadata_text):
    print("loras|заголовок Safetensors содержит слои LoRA")
elif has("controlnet_cond_embedding", "control_model.", "zero_convs.", "input_hint_block."):
    print("controlnet|заголовок Safetensors содержит слои ControlNet")
elif (has("model.diffusion_model.") and has("first_stage_model.")
      and has("cond_stage_model.")):
    print("checkpoints|файл содержит diffusion model, VAE и text encoder")
elif (has("encoder.down_blocks.", "decoder.up_blocks.", "quant_conv.", "post_quant_conv.")
      and not has("model.diffusion_model.")):
    print("vae|заголовок Safetensors содержит encoder/decoder VAE")
elif has("vision_model.", "visual.transformer.", "image_encoder."):
    print("clip_vision|заголовок Safetensors содержит vision encoder")
elif has("text_model.", "encoder.block.", "shared.weight", "conditioner.embedders."):
    print("text_encoders|заголовок Safetensors содержит text encoder")
elif has("model.diffusion_model.", "diffusion_model.", "transformer_blocks.",
         "double_blocks.", "single_blocks.", "down_blocks.", "input_blocks."):
    print("diffusion_models|заголовок Safetensors содержит diffusion/transformer layers")
elif has("string_to_param", "emb_params") or (len(keys) <= 8 and has("embedding")):
    print("embeddings|заголовок Safetensors похож на textual inversion embedding")
PY
}

select_model_folder() {
    local models_dir=$1 choice dir priority found
    local -a priority_dirs=(
        diffusion_models text_encoders vae checkpoints loras controlnet
        clip clip_vision upscale_models embeddings
    )
    local -a all_model_dirs=() model_dirs=()

    mapfile -t all_model_dirs < <(
        find "$models_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort
    )
    (( ${#all_model_dirs[@]} > 0 )) || { error "В $models_dir нет папок."; return 1; }

    for priority in "${priority_dirs[@]}"; do
        for dir in "${all_model_dirs[@]}"; do
            [[ "$dir" == "$priority" ]] && { model_dirs+=("$dir"); break; }
        done
    done
    for dir in "${all_model_dirs[@]}"; do
        found=false
        for priority in "${priority_dirs[@]}"; do
            [[ "$dir" == "$priority" ]] && { found=true; break; }
        done
        [[ "$found" == false ]] && model_dirs+=("$dir")
    done

    printf '\n%b\n' "${YELLOW}Куда сохранить модель?${NC}" >&2
    for choice in "${!model_dirs[@]}"; do
        printf '  %2d) %s\n' "$((choice + 1))" "${model_dirs[$choice]}" >&2
    done
    while true; do
        read -r -p "Номер папки: " choice || return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
            (( choice >= 1 && choice <= ${#model_dirs[@]} )); then
            SELECTED_MODEL_DIR=${model_dirs[$((choice - 1))]}
            return
        fi
        warn "Введите номер от 1 до ${#model_dirs[@]}." >&2
    done
}

validate_model_folder() {
    local folder=$1 models_dir="$COMFY_DIR/models"
    if [[ "$folder" == "." || "$folder" == ".." ||
        "$folder" == */* || "$folder" == *\\* || ! -d "$models_dir/$folder" ]]; then
        error "Папка models/$folder не существует."
        return 1
    fi
}

download_model() {
    local supplied_url=${1:-}
    local forced_folder=${2:-}
    local batch_mode=${3:-false}
    local supplied_filename=${4:-}
    local assume_yes=${5:-false}
    local models_dir="$COMFY_DIR/models"
    local download_dir="$COMFY_DIR/.model-downloads"
    local url url_path suggested_name filename destination header_file temp_file
    local source_host metrics http_code transferred average_speed total_time redirects
    local final_size free_space partial_size
    local inference inferred_dir inference_reason metadata_inference answer server_filename url_key
    local dir selection_mode=auto
    local -a curl_args=()

    command -v curl >/dev/null 2>&1 || { error "Не найдена команда curl."; return 1; }
    [[ -d "$models_dir" ]] || { error "Каталог моделей не найден: $models_dir"; return 1; }
    load_tokens

    if [[ -n "$supplied_url" ]]; then
        url=$supplied_url
    else
        read_model_url || return
        url=$MODEL_URL
    fi
    [[ "$url" =~ ^https?:// ]] || { error "Нужна ссылка http:// или https://"; return 1; }
    url=$(normalize_model_url "$url") || return 1

    url_path=${url%%\?*}
    url_path=${url_path%%\#*}
    suggested_name=${url_path##*/}
    [[ -n "$suggested_name" && "$suggested_name" != "download" ]] || \
        suggested_name="model.safetensors"
    if [[ -n "$supplied_filename" ]]; then
        filename=$supplied_filename
    elif [[ "$batch_mode" == true || "$assume_yes" == true ]]; then
        filename=$suggested_name
    else
        read -r -p "Имя файла [$suggested_name]: " filename || return
        filename=${filename:-$suggested_name}
    fi
    if [[ "$filename" == "." || "$filename" == ".." ||
        "$filename" == */* || "$filename" == *\\* ]]; then
        error "Недопустимое имя файла."
        return 1
    fi

    if [[ -n "$forced_folder" ]]; then
        validate_model_folder "$forced_folder" || return 1
        dir=$forced_folder
        selection_mode=manual
        info "Принудительная папка: models/$dir"
    else
        inference=$(infer_folder_from_name "$url $filename" || true)
    fi
    if [[ -z "$forced_folder" && -n "$inference" ]]; then
        inferred_dir=${inference%%|*}
        inference_reason=${inference#*|}
        info "Автоопределение: $inferred_dir ($inference_reason)"
        if [[ "$batch_mode" == true || "$assume_yes" == true ]]; then
            dir=$inferred_dir
        else
            read -r -p "Enter — принять, m — выбрать папку вручную: " answer || return
        fi
        if [[ "$batch_mode" != true &&
            ( "${answer,,}" == "m" || "${answer,,}" == "м" ) ]]; then
            select_model_folder "$models_dir" || return 1
            dir=$SELECTED_MODEL_DIR
            selection_mode=manual
        elif [[ "$batch_mode" != true ]]; then
            dir=$inferred_dir
        fi
    elif [[ -z "$forced_folder" ]]; then
        info "По имени тип неясен. Определим его после загрузки по содержимому файла."
        dir=''
    fi

    mkdir -p "$download_dir"
    url_key=$(printf '%s' "$url" | cksum | awk '{print $1}')
    temp_file="$download_dir/$filename.$url_key.part"
    source_host=${url#*://}
    source_host=${source_host%%/*}
    free_space=$(df -Pk "$models_dir" | awk 'NR == 2 { print $4 * 1024 }')

    printf '\n%b\n' "${BLUE}Параметры загрузки:${NC}"
    printf '  Источник:       %s\n' "$source_host"
    printf '  Имя файла:      %s\n' "$filename"
    if [[ -n "$dir" ]]; then
        printf '  Папка:          models/%s\n' "$dir"
    else
        printf '  Папка:          будет определена после загрузки\n'
    fi
    printf '  Свободно:       %s\n' "$(format_bytes "$free_space")"
    if [[ -s "$temp_file" ]]; then
        partial_size=$(stat -c '%s' "$temp_file")
        printf '  Продолжение с:  %s\n' "$(format_bytes "$partial_size")"
    fi

    curl_args=(
        --fail --location --show-error --progress-meter
        --retry 3 --retry-delay 2 --continue-at -
        --user-agent "comfy-model-downloader/1.0"
    )
    if [[ "$url" == *huggingface.co* && -n "$HF_TOKEN" ]]; then
        curl_args+=(--header "Authorization: Bearer $HF_TOKEN")
    elif [[ "$url" == *civitai.com* && -n "$CIVITAI_API_TOKEN" ]]; then
        curl_args+=(--header "Authorization: Bearer $CIVITAI_API_TOKEN")
    fi

    printf '\n%b\n' "${GREEN}Загрузка началась.${NC}"
    printf '%s\n' "Прогресс curl: %% получено | размер | средняя скорость | время | осталось | текущая скорость"
    header_file=$(mktemp)
    if ! metrics=$(curl "${curl_args[@]}" --dump-header "$header_file" \
        --write-out $'%{http_code}\t%{size_download}\t%{speed_download}\t%{time_total}\t%{num_redirects}' \
        --output "$temp_file" "$url"); then
        rm -f -- "$header_file"
        error "Загрузка не удалась. Проверьте ссылку и токен сайта."
        return 1
    fi

    IFS=$'\t' read -r http_code transferred average_speed total_time redirects <<< "$metrics"
    final_size=$(stat -c '%s' "$temp_file")
    server_filename=$(get_response_filename "$header_file" || true)
    if [[ "$batch_mode" == true && -n "$server_filename" &&
        ( "$filename" == "model.safetensors" || "$filename" =~ ^[0-9]+$ ||
          ! "$filename" =~ \.(safetensors|ckpt|pt|pth|bin|gguf)$ ) ]]; then
        info "Имя файла от сервера: $server_filename"
        filename=$server_filename
    fi
    printf '\n%b\n' "${BLUE}Результат передачи:${NC}"
    printf '  HTTP-код:       %s\n' "$http_code"
    printf '  Получено:       %s\n' "$(format_bytes "$transferred")"
    printf '  Размер файла:   %s\n' "$(format_bytes "$final_size")"
    printf '  Средняя скорость: %s/s\n' "$(format_bytes "$average_speed")"
    printf '  Время:          %s\n' "$(format_duration "$total_time")"
    printf '  Редиректы:      %s\n' "$redirects"

    if ! validate_download "$temp_file" "$header_file"; then
        rm -f -- "$header_file" "$temp_file"
        error "Файл удален. Используйте прямую ссылку Download, а не адрес страницы модели."
        return 1
    fi
    rm -f -- "$header_file"

    metadata_inference=$(infer_folder_from_safetensors "$temp_file" || true)
    if [[ -n "$metadata_inference" ]]; then
        inferred_dir=${metadata_inference%%|*}
        inference_reason=${metadata_inference#*|}
        info "Проверка файла: $inferred_dir ($inference_reason)"
        if [[ "$selection_mode" == auto ]]; then
            dir=$inferred_dir
        elif [[ "$dir" != "$inferred_dir" ]]; then
            warn "Ручной выбор '$dir' отличается от определенного типа '$inferred_dir'."
        fi
    fi

    if [[ -z "$dir" ]]; then
        if [[ "$batch_mode" == true || "$assume_yes" == true ]]; then
            error "Автоматически определить папку не удалось. Используйте --folder ИМЯ."
            warn "Загруженный файл оставлен для продолжения: $temp_file"
            return 1
        else
            warn "Автоматически определить тип не удалось. Выберите папку вручную."
            select_model_folder "$models_dir" || return 1
            dir=$SELECTED_MODEL_DIR
        fi
    fi

    mkdir -p "$models_dir/$dir"
    destination="$models_dir/$dir/$filename"
    if [[ -e "$destination" ]]; then
        if [[ "$batch_mode" == true || "$assume_yes" == true ]]; then
            warn "Файл уже существует, пропускаем: $destination"
            rm -f -- "$temp_file"
            return 10
        elif ! confirm_step "Файл существует. Перезаписать?"; then
            warn "Загруженный файл оставлен для продолжения: $temp_file"
            return
        fi
    fi
    mv -f -- "$temp_file" "$destination"
    printf '\n%b\n' "${GREEN}Модель успешно установлена.${NC}"
    printf '  Тип/папка:      %s\n' "$dir"
    printf '  Размер:         %s\n' "$(format_bytes "$final_size")"
    printf '  Путь:           %s\n' "$destination"
}

download_batch() {
    local list_file=${1:-} forced_folder=${2:-}
    local line url line_number=0 total=0 success_count=0 skipped_count=0 failed_count=0 status

    if [[ -z "$list_file" ]]; then
        read -r -e -p "Путь к TXT-файлу: " list_file || return 1
    fi
    list_file=${list_file/#\~/$HOME}
    [[ -f "$list_file" ]] || { error "TXT-файл не найден: $list_file"; return 1; }
    [[ -r "$list_file" ]] || { error "Нет доступа на чтение: $list_file"; return 1; }
    [[ -z "$forced_folder" ]] || validate_model_folder "$forced_folder" || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line=${line//$'\r'/}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -z "$line" || "$line" == \#* ]] && continue
        total=$((total + 1))
    done < "$list_file"
    (( total > 0 )) || { error "В файле нет ссылок для загрузки."; return 1; }

    printf '\n%b\n' "${BLUE}Пакетная загрузка: $total моделей${NC}"
    [[ -n "$forced_folder" ]] && printf 'Принудительная папка: models/%s\n' "$forced_folder"

    line_number=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line=${line//$'\r'/}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -z "$line" || "$line" == \#* ]] && continue
        url=$line

        printf '\n%b\n' "${YELLOW}========== Модель $((success_count + skipped_count + failed_count + 1))/$total, строка $line_number ==========${NC}"
        if download_model "$url" "$forced_folder" true; then
            success_count=$((success_count + 1))
        else
            status=$?
            if [[ "$status" -eq 10 ]]; then
                skipped_count=$((skipped_count + 1))
            else
                failed_count=$((failed_count + 1))
                error "Ошибка строки $line_number. Переходим к следующей модели."
            fi
        fi
    done < "$list_file"

    printf '\n%b\n' "${BLUE}Итог пакетной загрузки:${NC}"
    printf '  Успешно:   %d\n' "$success_count"
    printf '  Пропущено: %d\n' "$skipped_count"
    printf '  Ошибок:    %d\n' "$failed_count"
    (( failed_count == 0 ))
}

install_global_command() {
    local bin_dir="$HOME/.local/bin"
    local target="$bin_dir/comfy-model-downloader"
    local source_file

    if [[ "$(uname -s)" != "Linux" ]]; then
        error "Глобальная команда сейчас поддерживается только в Linux."
        return 1
    fi
    source_file=$(readlink -f "${BASH_SOURCE[0]}")

    mkdir -p "$bin_dir" "$TOKEN_DIR"
    chmod 700 "$TOKEN_DIR"
    if [[ "$source_file" != "$(readlink -f "$target" 2>/dev/null || true)" ]]; then
        install -m 0755 -- "$source_file" "$target"
    else
        chmod 0755 "$target"
    fi
    printf '%s\n' "$COMFY_DIR" > "$COMFY_PATH_FILE"
    chmod 600 "$COMFY_PATH_FILE"

    success "Глобальная команда установлена: $target"
    success "Путь ComfyUI сохранен: $COMFY_DIR"
    printf '\nЗапуск из любого каталога:\n  %b\n' "${YELLOW}comfy-model-downloader${NC}"

    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *)
            warn "$bin_dir пока отсутствует в PATH."
            printf 'Добавьте в ~/.bashrc или ~/.zshrc:\n  %b\n' \
                "${YELLOW}export PATH=\"\$HOME/.local/bin:\$PATH\"${NC}"
            ;;
    esac
}

main() {
    local choice
    while true; do
        printf '\n%b\n' "${BLUE}Загрузчик моделей ComfyUI${NC}"
        printf 'ComfyUI: %s\n' "$COMFY_DIR"
        printf '  1) Скачать модель\n'
        printf '  2) Скачать список моделей из TXT\n'
        printf '  3) Настроить Hugging Face / Civitai токены\n'
        printf '  4) Установить глобальную Linux-команду\n'
        printf '  0) Выход\n'
        read -r -p "Выберите действие [1]: " choice || return
        case "${choice:-1}" in
            1) download_model || warn "Модель не была загружена." ;;
            2) download_batch || warn "Пакетная загрузка завершена с ошибками." ;;
            3) configure_tokens ;;
            4) install_global_command ;;
            0) return ;;
            *) warn "Введите число от 0 до 4." ;;
        esac
    done
}

print_usage() {
    cat <<'EOF'
Использование:
  comfy-model-downloader
  comfy-model-downloader --download [URL] [--folder ПАПКА] [--filename ИМЯ] [--yes]
  comfy-model-downloader --batch models.txt [--folder ПАПКА]
  comfy-model-downloader --batch models.txt --vae
  comfy-model-downloader --tokens
  comfy-model-downloader --install-global

Папку можно задать двумя способами:
  --folder diffusion_models
  --diffusion_models

TXT: одна прямая ссылка на строку. Пустые строки и строки с # пропускаются.
EOF
}

run_cli() {
    local action='' list_file='' forced_folder='' download_url='' download_filename='' assume_yes=false option

    while (( $# > 0 )); do
        option=$1
        case "$option" in
            --download)
                action=download
                if (( $# > 1 )) && [[ "$2" != --* ]]; then
                    download_url=$2
                    shift
                fi
                ;;
            --batch)
                action=batch
                if (( $# > 1 )) && [[ "$2" != --* ]]; then
                    list_file=$2
                    shift
                fi
                ;;
            --folder)
                (( $# > 1 )) || { error "После --folder укажите имя папки."; return 2; }
                forced_folder=$2
                shift
                ;;
            --folder=*) forced_folder=${option#--folder=} ;;
            --filename)
                (( $# > 1 )) || { error "После --filename укажите имя файла."; return 2; }
                download_filename=$2
                shift
                ;;
            --filename=*) download_filename=${option#--filename=} ;;
            --yes|-y) assume_yes=true ;;
            --tokens) action=tokens ;;
            --install-global) action=install ;;
            --help|-h) print_usage; return ;;
            --*)
                forced_folder=${option#--}
                [[ -n "$action" ]] || action=download
                ;;
            *)
                if [[ "$action" == batch && -z "$list_file" ]]; then
                    list_file=$option
                elif [[ "$action" == download && -z "$download_url" ]]; then
                    download_url=$option
                else
                    error "Неизвестный аргумент: $option"
                    print_usage
                    return 2
                fi
                ;;
        esac
        shift
    done

    case "${action:-menu}" in
        menu) main ;;
        download) download_model "$download_url" "$forced_folder" false "$download_filename" "$assume_yes" ;;
        batch) download_batch "$list_file" "$forced_folder" ;;
        tokens) configure_tokens ;;
        install) install_global_command ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_cli "$@"
fi
