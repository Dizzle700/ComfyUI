#!/usr/bin/env python3
"""RunPod Serverless Client for ComfyUI Krea-2.

This script allows you to easily test and integrate your RunPod Serverless ComfyUI
endpoint. It supports both synchronous (/runsync) and asynchronous (/run + /status)
requests, dynamic prompt injection, seed randomization, and automatic image saving.

Usage example:
    python3 test_client.py \
        --endpoint-id YOUR_ENDPOINT_ID \
        --api-key YOUR_RUNPOD_API_KEY \
        --prompt "A cyberpunk cat walking through rain-slicked Tokyo streets, neon reflections" \
        --sync
"""

import argparse
import base64
import json
import os
import random
import sys
import time
from pathlib import Path
from typing import Any, Dict, Optional
import urllib.request
import urllib.error


def make_request(
    url: str,
    api_key: str,
    payload: Optional[Dict[str, Any]] = None,
    timeout: int = 300,
) -> Dict[str, Any]:
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
        "User-Agent": "RunPod-ComfyUI-Client/1.0",
    }
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data else "GET")

    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            res_body = response.read().decode("utf-8")
            return json.loads(res_body)
    except urllib.error.HTTPError as e:
        err_msg = e.read().decode("utf-8", errors="replace")
        print(f"[ОШИБКА] HTTP {e.code} от RunPod: {err_msg}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"[ОШИБКА] Ошибка запроса к {url}: {e}", file=sys.stderr)
        sys.exit(1)


def save_image_from_base64_or_url(data_str: str, output_path: Path) -> None:
    if data_str.startswith("data:image/"):
        header, base64_data = data_str.split(",", 1)
        image_bytes = base64.b64decode(base64_data)
    elif data_str.startswith("http://") or data_str.startswith("https://"):
        print(f"  [ИНФО] Скачивание изображения по ссылке: {data_str}")
        with urllib.request.urlopen(data_str) as resp:
            image_bytes = resp.read()
    else:
        image_bytes = base64.b64decode(data_str)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "wb") as f:
        f.write(image_bytes)
    print(f"  [УСПЕХ] Изображение сохранено: {output_path} ({len(image_bytes) // 1024} КБ)")


def extract_and_save_outputs(output_data: Any, output_dir: Path) -> int:
    saved_count = 0
    timestamp = time.strftime("%Y%m%d_%H%M%S")

    # Формат worker-comfyui обычно возвращает:
    # {"images": [{"image": "data:image/png;base64,...", "name": "...", "type": "base64"}]}
    # Либо {"message": "...", "images": [...]}
    if isinstance(output_data, dict):
        images = output_data.get("images", [])
        if not images and "message" in output_data:
            print(f"[ОТВЕТ] Сообщение от воркера: {output_data['message']}")

        for idx, img_item in enumerate(images):
            saved_count += 1
            file_name = f"krea2_{timestamp}_{idx + 1}.png"
            if isinstance(img_item, dict):
                content = img_item.get("image") or img_item.get("data")
                custom_name = img_item.get("name")
                if custom_name and custom_name.endswith((".png", ".jpg", ".webp")):
                    file_name = f"{Path(custom_name).stem}_{timestamp}_{idx + 1}.png"
            elif isinstance(img_item, str):
                content = img_item
            else:
                continue

            if content:
                save_image_from_base64_or_url(content, output_dir / file_name)

    elif isinstance(output_data, list):
        for idx, item in enumerate(output_data):
            if isinstance(item, str):
                saved_count += 1
                save_image_from_base64_or_url(item, output_dir / f"krea2_{timestamp}_{idx + 1}.png")

    return saved_count


def main():
    parser = argparse.ArgumentParser(description="RunPod Serverless ComfyUI Client")
    parser.add_argument(
        "--endpoint-id",
        default=os.environ.get("RUNPOD_ENDPOINT_ID", ""),
        help="RunPod Endpoint ID (или переменная RUNPOD_ENDPOINT_ID)",
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("RUNPOD_API_KEY", ""),
        help="RunPod API Key (или переменная RUNPOD_API_KEY)",
    )
    parser.add_argument(
        "--workflow-file",
        default=str(Path(__file__).parent / "workflows" / "krea2_turbo_api.json"),
        help="Путь к ComfyUI API workflow JSON (по умолчанию: workflows/krea2_turbo_api.json)",
    )
    parser.add_argument(
        "--prompt",
        default=None,
        help="Положительный текстовый промпт (заменяет текст в ноде Positive Prompt)",
    )
    parser.add_argument(
        "--negative",
        default=None,
        help="Отрицательный текстовый промпт (заменяет текст в ноде Negative Prompt)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Сид генерации (по умолчанию: случайный)",
    )
    parser.add_argument(
        "--sync",
        action="store_true",
        help="Использовать синхронный вызов /runsync (ждет завершения)",
    )
    parser.add_argument(
        "--output-dir",
        default=str(Path(__file__).parent / "output"),
        help="Каталог для сохранения сгенерированных изображений",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=2.0,
        help="Интервал опроса статуса задачи в секундах (для асинхронного режима)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Максимальное время ожидания задачи в секундах",
    )

    args = parser.parse_args()

    if not args.endpoint_id:
        print("[ОШИБКА] Укажите --endpoint-id или установите RUNPOD_ENDPOINT_ID", file=sys.stderr)
        sys.exit(1)
    if not args.api_key:
        print("[ОШИБКА] Укажите --api-key или установите RUNPOD_API_KEY", file=sys.stderr)
        sys.exit(1)

    workflow_path = Path(args.workflow_file)
    if not workflow_path.is_file():
        print(f"[ОШИБКА] Файл воркфлоу не найден: {workflow_path}", file=sys.stderr)
        sys.exit(1)

    with open(workflow_path, "r", encoding="utf-8") as f:
        workflow = json.load(f)

    # Если в файле уже обертка {"input": {"workflow": ...}}, извлекаем сам workflow
    if "input" in workflow and "workflow" in workflow["input"]:
        workflow = workflow["input"]["workflow"]

    # Динамическая подстановка промпта и сида
    seed = args.seed if args.seed is not None else random.randint(1, 10**14)

    # Поиск подходящих нод для замены параметров
    for node_id, node_data in workflow.items():
        if not isinstance(node_data, dict):
            continue
        class_type = node_data.get("class_type", "")
        inputs = node_data.get("inputs", {})
        title = node_data.get("_meta", {}).get("title", "").lower()

        # Положительный промпт (CLIPTextEncode без 'negative' в названии)
        if args.prompt and class_type == "CLIPTextEncode":
            if "negative" not in title and node_id in ("4", "6"):
                inputs["text"] = args.prompt
                print(f"[ПАРАМЕТР] Positive Prompt (нода {node_id}): {args.prompt}")

        # Отрицательный промпт
        if args.negative and class_type == "CLIPTextEncode":
            if "negative" in title or node_id in ("5",):
                inputs["text"] = args.negative
                print(f"[ПАРАМЕТР] Negative Prompt (нода {node_id}): {args.negative}")

        # Сид в KSampler
        if class_type in ("KSampler", "KSamplerAdvanced"):
            if "seed" in inputs:
                inputs["seed"] = seed
                print(f"[ПАРАМЕТР] Seed (нода {node_id}): {seed}")

    payload = {
        "input": {
            "workflow": workflow
        }
    }

    base_url = f"https://api.runpod.ai/v2/{args.endpoint_id}"
    output_dir = Path(args.output_dir)

    print("=" * 65)
    print(f" Отправка запроса на RunPod Serverless: {args.endpoint_id}")
    print("=" * 65)
    start_time = time.time()

    if args.sync:
        url = f"{base_url}/runsync"
        print(f"[ЗАПРОС] Синхронный вызов POST {url} ...")
        response = make_request(url, args.api_key, payload, timeout=args.timeout)
        status = response.get("status")
        print(f"[ОТВЕТ] Статус выполнения: {status}")

        if status == "COMPLETED":
            duration = time.time() - start_time
            print(f"[ИНФО] Задача завершена успешно за {duration:.2f} сек!")
            output = response.get("output", {})
            saved = extract_and_save_outputs(output, output_dir)
            if saved == 0:
                print(f"[ВНИМАНИЕ] Не найдено изображений в ответе воркера: {response}")
        else:
            print(f"[ОШИБКА] Ответ воркера: {json.dumps(response, indent=2, ensure_ascii=False)}")
            sys.exit(1)
    else:
        # Асинхронный вызов
        url = f"{base_url}/run"
        print(f"[ЗАПРОС] Асинхронный запуск POST {url} ...")
        response = make_request(url, args.api_key, payload, timeout=30)
        job_id = response.get("id")
        if not job_id:
            print(f"[ОШИБКА] Не получен ID задачи: {response}", file=sys.stderr)
            sys.exit(1)

        print(f"[ИНФО] ID задачи: {job_id}. Ожидание выполнения...")
        status_url = f"{base_url}/status/{job_id}"

        while True:
            elapsed = time.time() - start_time
            if elapsed > args.timeout:
                print(f"[ОШИБКА] Превышено время ожидания ({args.timeout} сек).", file=sys.stderr)
                sys.exit(1)

            time.sleep(args.poll_interval)
            status_resp = make_request(status_url, args.api_key)
            status = status_resp.get("status")
            print(f"  -> Статус задачи ({elapsed:.1f} сек): {status}")

            if status == "COMPLETED":
                total_time = time.time() - start_time
                print(f"[ИНФО] Задача успешно выполнена за {total_time:.2f} сек!")
                output = status_resp.get("output", {})
                saved = extract_and_save_outputs(output, output_dir)
                if saved == 0:
                    print(f"[ВНИМАНИЕ] Не найдено изображений в ответе: {status_resp}")
                break
            elif status in ("FAILED", "CANCELLED", "TIMED_OUT"):
                print(f"[ОШИБКА] Задача завершилась со статусом: {status}", file=sys.stderr)
                print(json.dumps(status_resp, indent=2, ensure_ascii=False), file=sys.stderr)
                sys.exit(1)

    print("=" * 65)


if __name__ == "__main__":
    main()
