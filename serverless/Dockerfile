# ==============================================================================
# Dockerfile for RunPod Serverless ComfyUI (Krea-2 Ready)
#
# Базируется на официальном образе RunPod ComfyUI Worker:
# https://github.com/runpod-workers/worker-comfyui
#
# Рекомендуемый способ использования:
#   1. Образ остается легким (без запеченных 15 ГБ моделей) для быстрого билда
#      и мгновенного старта контейнера на RunPod (FlashBoot).
#   2. Модели Krea-2 подключаются через RunPod Network Volume, смонтированный
#      в /runpod-volume (подготовленный скриптом prepare_network_volume.sh).
# ==============================================================================

ARG BASE_TAG=latest-base
FROM runpod/worker-comfyui:${BASE_TAG}

LABEL maintainer="Dizzle700"
LABEL description="ComfyUI Serverless Worker for Krea-2 on RunPod"

# Установка зависимостей для токенизаторов Qwen3-VL / T5 и ускоренной работы
RUN pip install --no-cache-dir \
    "transformers>=4.46.2,<5.0.0" \
    sentencepiece \
    protobuf \
    tiktoken \
    chardet \
    "huggingface-hub[hf_xet]>=0.34.0,<1.0.0"

# Оптимизация запуска ComfyUI
ENV COMFY_ARGS="--highvram --fast"
ENV HF_XET_HIGH_PERFORMANCE=1

# Рабочая директория по умолчанию
WORKDIR /
