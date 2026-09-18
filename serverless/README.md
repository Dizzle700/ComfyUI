# RunPod Serverless ComfyUI (Krea-2 Edition)

Данная директория содержит всё необходимое для запуска **ComfyUI** в бессерверном режиме (**RunPod Serverless**) с моделью **Krea-2** (веса Turbo FP8, текстовый энкодер Qwen3-VL, VAE и LoRA).

---

## 💰 Экономический анализ: Обычный Pod против Serverless

> **Главный вывод:** Для периодической генерации изображений (10–500 картинок в день) Serverless **экономнее на 80–98%**.

| Параметр | Обычный GPU Pod | RunPod Serverless (`worker-comfyui`) |
| :--- | :--- | :--- |
| **Тарификация** | Поминутная/почасовая за **всё время включения** | **Помиллисекундная строго за время генерации** |
| **Стоимость простоя** | ~$0.40 – $0.85/час (RTX 4090 / 5090) даже пока спите | **$0.00** (при отсутствии запросов воркеры отключаются) |
| **Стоимость 50 картинок в день** | ~$5 – $10/день (если держать Pod включенным рабочий день) | **~$0.05 – $0.15/день** (50 картинок × 3–5 сек = ~3–4 минуты GPU) |
| **Затраты за месяц** | **$150 – $350+** | **$2 – $8** (+ ~$1.5/мес за Network Volume) |
| **Риск забыть выключить** | 🔴 Высокий (деньги списываются непрерывно) | 🟢 Нулевой (автоматический Scale-to-Zero) |
| **Интерфейс** | Веб-интерфейс ComfyUI (граф нод в браузере) | **Headless API** (отправка JSON-запросов через API / ботов) |
| **Холодный старт** | Нет (модель загружена в VRAM) | 20–35 секунд при первом запросе после простоя |

### Когда использовать Serverless:
- Вы подключаете генерацию к **Telegram-боту**, сайту, мобильному приложению или бэкенду.
- Вы генерируете пачки картинок время от времени и не хотите платить за простой.
- У вас уже есть настроенный и протестированный воркфлоу.

### Когда лучше использовать обычный Pod:
- Вы только разрабатываете и настраиваете пайплайн: двигаете ноды на холсте ComfyUI, подбираете настройки семплеров вживую.
- **Идеальная связка:** Собрать воркфлоу на обычном дешевом поде (или локально), нажать **Save (API Format)** и запустить в продакшн на Serverless.

---

## 📁 Структура папки `serverless/`

```
serverless/
├── prepare_network_volume.sh      # Скрипт подготовки RunPod Network Volume с моделями Krea-2
├── Dockerfile                     # Оптимизированный Dockerfile на базе runpod/worker-comfyui
├── test_client.py                 # Готовый Python-клиент для вызова API и сохранения картинок
├── test_input.json                # Пример тестового JSON-пейлоада для консоли RunPod
├── workflows/
│   ├── krea2_turbo_api.json       # Базовый API-воркфлоу Krea-2 Turbo (8 шагов)
│   └── krea2_turbo_lora_api.json  # API-воркфлоу Krea-2 Turbo с LoRA Softwatercolor
└── README.md                      # Данная инструкция
```

---

## 🚀 Пошаговое развертывание на RunPod

### Шаг 1. Создание RunPod Network Volume

Поскольку связка Krea-2 Turbo FP8 + Qwen3-VL + VAE занимает суммарно **~17 ГБ**, «запекать» их в Docker-образ нерационально (образ будет долго собираться и медленно скачиваться). 

Лучшая практика RunPod — хранить модели на **Network Volume**:
1. Перейдите в [RunPod Console -> Storage -> Network Volumes](https://www.runpod.io/console/user/storage).
2. Нажмите **New Network Volume**:
   - **Name:** `comfy-models-volume`
   - **Data Center:** Выберите ближайший датацентр (например, `EU-RO-1` или `US-CA-1`).
   - **Size:** 30–50 GB (стоимость: всего ~$2–$3.50 в месяц).
3. Нажмите **Create**.

---

### Шаг 2. Загрузка моделей Krea-2 на Network Volume

Чтобы быстро скачать все модели в правильную структуру каталогов:
1. Запустите временный Pod (достаточно CPU-пода или любого дешевого GPU), подключив к нему созданный **Network Volume** в точку `/workspace` или `/runpod-volume`.
2. Запустите скрипт подготовки:
   ```bash
   bash serverless/prepare_network_volume.sh
   ```
   *Если вы хотите передать токен Hugging Face:*
   ```bash
   bash serverless/prepare_network_volume.sh --hf-token "hf_xxx"
   ```
3. Скрипт создаст правильную структуру и скачает файлы:
   ```
   models/
   ├── diffusion_models/
   │   └── krea2_turbo_fp8_scaled.safetensors
   ├── text_encoders/
   │   └── qwen3vl_4b_fp8_scaled.safetensors
   ├── vae/
   │   └── qwen_image_vae.safetensors
   └── loras/
       └── softwatercolor.safetensors
   ```
4. После завершения загрузки выключите и удалите временный Pod. Модели навсегда останутся на Network Volume.

---

### Шаг 3. Создание Serverless Endpoint

1. Перейдите в [RunPod Console -> Serverless -> Endpoints](https://www.runpod.io/console/serverless/user/endpoints).
2. Нажмите **+ New Endpoint**.
3. Заполните параметры:
   - **Endpoint Name:** `krea2-serverless`
   - **Container Image:** `runpod/worker-comfyui:latest-base`
   - **Select GPU:** Выберите **RTX 4090** (24 GB) или **RTX 5090** (32 GB) или **L40S** (48 GB).
   - **Active Workers:** `0` *(для максимальной экономии: при отсутствии нагрузки плата не идет)*.
   - **Max Workers:** `2` или `3` *(сколько параллельных видеокарт можно поднимать при наплыве запросов)*.
   - **Idle Timeout:** `5` – `15` секунд *(сколько воркер ждет новых запросов перед отключением)*.
   - **FlashBoot:** `Enabled` (ускоряет холодный старт).
   - **Network Volume:** Выберите созданный на Шаге 1 том `comfy-models-volume`.
4. Нажмите **Deploy**.
5. Скопируйте ваш **Endpoint ID** (например, `v2-xxxxxxxxx`).

---

## 🧪 Тестирование и запуск генерации

### Способ 1. Через скрипт `test_client.py` (Рекомендуется)

Мы подготовили скрипт [test_client.py](file:///home/dizzle/Documents/Code_Runpod/ComfyUI/serverless/test_client.py), который сам форматирует запрос, подставляет промпт, отправляет его в RunPod, декодирует изображение и сохраняет его на диск.

1. Установите переменные окружения или передайте их аргументами:
   ```bash
   export RUNPOD_API_KEY="ваш_runpod_api_ключ"
   export RUNPOD_ENDPOINT_ID="ваш_endpoint_id"
   ```

2. Запустите синхронную генерацию:
   ```bash
   python3 serverless/test_client.py \
       --prompt "A stunning crystal dragon perched on a mountain at sunrise, cinematic lighting, 8k" \
       --sync
   ```

3. Запустите генерацию с LoRA Softwatercolor:
   ```bash
   python3 serverless/test_client.py \
       --workflow-file serverless/workflows/krea2_turbo_lora_api.json \
       --prompt "art deco watercolor style, a majestic tiger in the bamboo forest, pastel wash" \
       --sync
   ```
Готовое изображение сохранится в папку `serverless/output/`.

---

### Способ 2. Через cURL (HTTP API)

#### Синхронный запрос (`/runsync`):
```bash
curl -X POST "https://api.runpod.ai/v2/ВАШ_ENDPOINT_ID/runsync" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer ВАШ_RUNPOD_API_KEY" \
     -d @serverless/test_input.json
```

#### Асинхронный запрос (`/run` + `/status`):
1. Отправка задачи:
   ```bash
   curl -X POST "https://api.runpod.ai/v2/ВАШ_ENDPOINT_ID/run" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ВАШ_RUNPOD_API_KEY" \
        -d @serverless/test_input.json
   ```
   В ответ вернется `{"id": "JOB_ID", "status": "IN_QUEUE"}`.

2. Проверка статуса:
   ```bash
   curl -X GET "https://api.runpod.ai/v2/ВАШ_ENDPOINT_ID/status/JOB_ID" \
        -H "Authorization: Bearer ВАШ_RUNPOD_API_KEY"
   ```
   Когда статус станет `"COMPLETED"`, в поле `output.images` будет массив сгенерированных Base64-изображений.

---

## 🛠️ Как экспортировать свой собственный воркфлоу в API JSON

Если вы изменили воркфлоу в обычном ComfyUI:
1. В веб-интерфейсе ComfyUI откройте меню настроек ⚙️ (в правом верхнем углу).
2. Включите переключатель **"Enable Dev mode Options"**.
3. В правом меню появится кнопка **"Save (API Format)"**.
4. Сохраните JSON-файл в `serverless/workflows/my_workflow_api.json`.
5. Теперь его можно использовать в `test_client.py`:
   ```bash
   python3 serverless/test_client.py --workflow-file serverless/workflows/my_workflow_api.json --sync
   ```

---

## ❓ Частые вопросы и диагностика (Troubleshooting)

### 1. Ошибка `CLIPLoader: Value not in list`
Для текстового энкодера `qwen3vl_4b_fp8_scaled.safetensors` в ноде `CLIPLoader` параметр `type` **обязательно** должен быть равен `"krea2"`. Если используется старая версия ComfyUI, обновите ComfyUI.

### 2. Ошибка `Model not found`
Убедитесь, что модели на Network Volume расположены именно в подпапках:
- `models/diffusion_models/` (для диффузионной модели Krea-2, **не** в checkpoints!);
- `models/text_encoders/` (для Qwen3-VL);
- `models/vae/` (для VAE);
- `models/loras/` (для LoRA).

### 3. Холодный старт (Cold Start) занимает много времени
- Убедитесь, что для Endpoint включен **FlashBoot**.
- Network Volume должен быть создан **в том же регионе/датацентре**, что и Endpoint.
- После холодного старта все последующие генерации выполняются за 2–4 секунды.
