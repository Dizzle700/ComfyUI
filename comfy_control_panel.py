#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import subprocess
import signal
import time
import shutil
import threading
import tempfile
import zipfile
import queue
import shlex
import sys
from collections import deque
import gradio as gr
import psutil

# Определение путей
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
COMFY_DIR = os.environ.get("COMFY_DIR", "/workspace/ComfyUI" if os.path.exists("/workspace") else os.path.join(BASE_DIR, "ComfyUI"))
LOG_FILE = os.path.join(COMFY_DIR, "comfyui.log")
DOWNLOADER_SCRIPT = os.path.join(BASE_DIR, "comfy_model_downloader.sh")
TOKENS_ENV_FILE = os.path.expanduser("~/.config/comfy-model-downloader/tokens.env")
FILE_MANAGER_ROOT = "/workspace" if os.path.exists("/workspace") else BASE_DIR
FILE_DOWNLOAD_DIR = os.path.join(tempfile.gettempdir(), "comfy-control-downloads")
os.makedirs(FILE_DOWNLOAD_DIR, exist_ok=True)
DEFAULT_COMFY_ARGS = os.environ.get(
    "COMFY_ARGS",
    "--listen 0.0.0.0 --port 8188 --highvram",
)

# Состояние процесса ComfyUI
comfy_process = None
process_lock = threading.Lock()

# Состояние установки
is_installing = False
install_lock = threading.Lock()

# Лог скачивания моделей
download_logs = deque(maxlen=1000)
download_lock = threading.Lock()

def add_download_log(text):
    with download_lock:
        download_logs.append(text)

def get_download_logs():
    with download_lock:
        return "\n".join(download_logs)

# Устанавливаем пакеты тем же Python, которым запущена панель.
def build_pip_cmd(*args):
    return [sys.executable, "-m", "pip", "install", *args]

def get_system_stats():
    # Загрузка CPU и RAM
    cpu_percent = psutil.cpu_percent()
    ram = psutil.virtual_memory()
    ram_percent = ram.percent
    
    # Свободное место на диске /workspace или корневом разделе
    disk_path = "/workspace" if os.path.exists("/workspace") else "/"
    disk = shutil.disk_usage(disk_path)
    disk_free_gb = disk.free / (1024**3)
    disk_total_gb = disk.total / (1024**3)
    disk_percent = (disk.total - disk.free) / disk.total * 100

    # Попытка получить статус GPU через nvidia-smi
    gpu_info = "Нет GPU или nvidia-smi недоступен"
    try:
        gpu_out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total", "--format=csv,noheader,nounits"],
            encoding="utf-8"
        ).strip()
        parts = gpu_out.split(", ")
        if len(parts) >= 5:
            gpu_info = f"🔥 {parts[0]} | Темп: {parts[1]}°C | Загрузка: {parts[2]}% | Память: {parts[3]}MB / {parts[4]}MB"
    except Exception:
        pass

    # Форматированный HTML
    stats_html = f"""
    <div style="padding: 10px; border-radius: 8px; background-color: var(--background-fill-secondary); border: 1px solid var(--border-color-primary);">
        <p>📊 <b>Процессор (CPU):</b> {cpu_percent}%</p>
        <p>💾 <b>ОЗУ (RAM):</b> {ram_percent}% ({ram.used / (1024**3):.1f} GB / {ram.total / (1024**3):.1f} GB)</p>
        <p>💽 <b>Диск ({disk_path}):</b> {disk_percent:.1f}% (Свободно {disk_free_gb:.1f} GB из {disk_total_gb:.1f} GB)</p>
        <p>🎮 <b>Видеокарта (GPU):</b> {gpu_info}</p>
    </div>
    """
    return stats_html

def get_comfy_status():
    global comfy_process, is_installing
    
    with install_lock:
        if is_installing:
            return "⏳ Установка (Installing...)", "Выполняется сборка окружения"
            
    # Проверяем, существует ли папка ComfyUI
    if not os.path.exists(COMFY_DIR):
        return "🔴 Не установлено (Not Installed)", f"Папка {COMFY_DIR} отсутствует"
        
    with process_lock:
        # Проверяем наш внутренний дескриптор процесса
        if comfy_process is not None:
            poll = comfy_process.poll()
            if poll is None:
                return "🟢 Запущен (Running)", f"PID: {comfy_process.pid}"
            else:
                comfy_process = None
        
        # Проверяем, запущен ли main.py в системе глобально
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                cmd = proc.info['cmdline']
                if cmd and any('main.py' in part for part in cmd) and any('python' in part for part in cmd):
                    return "🟢 Запущен извне (Running externally)", f"PID: {proc.info['pid']}"
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
                
        return "🔴 Остановлен (Stopped)", "Нет активного процесса"

def start_comfy(args):
    global comfy_process
    status, _ = get_comfy_status()
    if "Запущен" in status:
        return "ComfyUI уже запущен!"

    if not os.path.exists(COMFY_DIR):
        return f"Папка ComfyUI не найдена по пути: {COMFY_DIR}. Сначала выполните установку."

    # Создаем файл логов, если его нет
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    
    # shlex корректно сохраняет аргументы с пробелами и кавычками.
    try:
        arg_list = shlex.split(args or "")
    except ValueError as exc:
        return f"Ошибка в аргументах запуска: {exc}"
    
    # ComfyUI использует то же готовое Python-окружение RunPod, что и панель.
    python_exe = sys.executable

    try:
        # Запускаем в фоновом режиме, перенаправляя логи в файл
        log_file_obj = open(LOG_FILE, "a")
        log_file_obj.write(f"\n--- ЗАПУСК CONTROL PANEL: {time.strftime('%Y-%m-%d %H:%M:%S')} ---\n")
        log_file_obj.flush()
        
        with process_lock:
            comfy_process = subprocess.Popen(
                [python_exe, "main.py"] + arg_list,
                cwd=COMFY_DIR,
                stdout=log_file_obj,
                stderr=log_file_obj,
                preexec_fn=os.setsid # Создаем группу процессов для надежного завершения
            )
        
        # Popen дублирует fd; родительский дескриптор больше не нужен
        log_file_obj.close()
        
        time.sleep(2) # Даем процессу инициализироваться
        if comfy_process.poll() is not None:
            with process_lock:
                return_code = comfy_process.returncode
                comfy_process = None
            return f"ComfyUI завершился сразу после запуска (код {return_code}). Проверьте {LOG_FILE}"
        return f"Запущено! Логи пишутся в {LOG_FILE}"
    except Exception as e:
        return f"Ошибка при запуске: {str(e)}"

def stop_comfy():
    global comfy_process
    status, pid_info = get_comfy_status()
    if "Остановлен" in status:
        return "ComfyUI уже остановлен."

    try:
        # Пытаемся остановить наш процесс через группу процессов
        with process_lock:
            if comfy_process is not None:
                os.killpg(os.getpgid(comfy_process.pid), signal.SIGTERM)
                comfy_process.wait(timeout=5)
                comfy_process = None
                return "Процесс остановлен."
        
        # Если запущен извне, ищем и убиваем все процессы main.py
        killed = 0
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                cmd = proc.info['cmdline']
                if cmd and any('main.py' in part for part in cmd) and any('python' in part for part in cmd):
                    os.kill(proc.info['pid'], signal.SIGTERM)
                    killed += 1
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
        if killed > 0:
            return f"Завершено {killed} внешних процессов ComfyUI."
            
        return "Не удалось найти активный процесс для остановки."
    except Exception as e:
        # Force kill
        try:
            with process_lock:
                if comfy_process is not None:
                    os.killpg(os.getpgid(comfy_process.pid), signal.SIGKILL)
                    comfy_process = None
                    return "Процесс принудительно убит (SIGKILL)."
        except Exception:
            pass
        return f"Ошибка при остановке: {str(e)}"

def restart_comfy(args):
    stop_result = stop_comfy()
    time.sleep(3)
    start_result = start_comfy(args)
    return f"{stop_result}\n{start_result}"

# is_installing и install_lock определены выше, в блоке глобальных переменных

def run_installation():
    global is_installing
    with install_lock:
        if is_installing:
            return "Установка уже запущена и выполняется в фоновом режиме!"
        is_installing = True
        
    install_script = os.path.join(BASE_DIR, "comfy_install_runpod.sh")
    if not os.path.exists(install_script):
        with install_lock:
            is_installing = False
        return f"Скрипт установки не найден: {install_script}"
        
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    
    def worker():
        global is_installing
        try:
            with open(LOG_FILE, "w", encoding="utf-8") as f:
                f.write(f"=== СТАРТ УСТАНОВКИ: {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")
                f.flush()
                
                # Запускаем скрипт установки с флагом --no-start
                proc = subprocess.Popen(
                    ["/usr/bin/env", "bash", install_script, "--no-start"],
                    stdout=f,
                    stderr=f,
                    text=True
                )
                proc.wait()
                
                f.write(f"\n=== УСТАНОВКА ЗАВЕРШЕНА С КОДОМ: {proc.returncode} ===\n")
        except Exception as e:
            try:
                with open(LOG_FILE, "a", encoding="utf-8") as f:
                    f.write(f"\nОшибка при установке: {str(e)}\n")
            except Exception:
                pass
        finally:
            with install_lock:
                is_installing = False
                
    threading.Thread(target=worker, daemon=True).start()
    return "Установка запущена! Следите за логами в окне справа (нажмите '🔄 Обновить лог')."

def read_logs(num_lines=50):
    if not os.path.exists(LOG_FILE):
        return "Файл логов пуст или ещё не создан."
    
    n = max(1, int(num_lines))
    try:
        # Читаем только последние N строк через deque вместо загрузки всего файла
        with open(LOG_FILE, "r", encoding="utf-8", errors="ignore") as f:
            tail = deque(f, maxlen=n)
            return "".join(tail)
    except Exception as e:
        return f"Не удалось прочитать логи: {str(e)}"

# Установка кастомных нод
node_logs = deque(maxlen=1000)
node_lock = threading.Lock()

def add_node_log(text):
    with node_lock:
        node_logs.append(text)

def get_node_logs():
    with node_lock:
        return "\n".join(node_logs)

def run_node_command(cmd, cwd=None):
    """Run an installer command and mirror combined output to the node log."""
    add_node_log(f"$ {shlex.join(cmd)}")
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    if proc.stdout is not None:
        for line in proc.stdout:
            clean_line = line.rstrip()
            if clean_line:
                add_node_log(clean_line)
    proc.wait()
    return proc.returncode

def install_custom_node(repo_url):
    if not repo_url.strip():
        return "Пожалуйста, введите URL git-репозитория ноды."
    
    custom_nodes_dir = os.path.join(COMFY_DIR, "custom_nodes")
    if not os.path.exists(custom_nodes_dir):
        return f"Папка custom_nodes не найдена. Убедитесь, что ComfyUI установлен."
        
    folder_name = repo_url.split("/")[-1]
    if folder_name.endswith(".git"):
        folder_name = folder_name[:-4]
    
    target_node_dir = os.path.join(custom_nodes_dir, folder_name)
    
    def worker():
        add_node_log(f"--- Старт установки кастомной ноды: {time.strftime('%H:%M:%S')} ---")
        add_node_log(f"Репозиторий: {repo_url}")
        
        if os.path.exists(target_node_dir):
            add_node_log(f"Нода {folder_name} уже существует. Пробуем обновить (git pull)...")
            proc = subprocess.Popen(
                ["git", "-C", target_node_dir, "pull", "--ff-only"],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True
            )
        else:
            add_node_log(f"Клонируем в {target_node_dir}...")
            proc = subprocess.Popen(
                ["git", "clone", "--depth", "1", repo_url, target_node_dir],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True
            )
            
        while True:
            line = proc.stdout.readline()
            if not line:
                break
            add_node_log(line.strip())
        proc.wait()
        
        if proc.returncode != 0:
            add_node_log(f"⚠️ Ошибка при работе с Git (код {proc.returncode})")
            return
            
        req_file = os.path.join(target_node_dir, "requirements.txt")
        if os.path.exists(req_file):
            add_node_log(f"Обнаружен requirements.txt. Устанавливаем зависимости...")
            cmd = build_pip_cmd("-r", req_file)
                
            proc_req = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True
            )
            while True:
                line = proc_req.stdout.readline()
                if not line:
                    break
                add_node_log(line.strip())
            proc_req.wait()
            add_node_log(f"Установка зависимостей завершена с кодом {proc_req.returncode}")
            
        add_node_log(f"--- Установка ноды {folder_name} завершена! Перезапустите ComfyUI. ---")
        
    threading.Thread(target=worker, daemon=True).start()
    return "Процесс клонирования и установки запущен. Следите за логами в окне ниже."

def install_sparkvsr():
    custom_nodes_dir = os.path.join(COMFY_DIR, "custom_nodes")
    if not os.path.exists(custom_nodes_dir):
        return "Папка custom_nodes не найдена. Сначала установите ComfyUI."

    def copy_sparkvsr_workflow(source_workflow):
        if not os.path.exists(source_workflow):
            add_node_log(f"⚠️ Workflow не найден: {source_workflow}")
            return

        destinations = [
            os.path.join(COMFY_DIR, "input", "sparkvsr_all_modes_preview.json"),
            os.path.join(COMFY_DIR, "user", "default", "workflows", "sparkvsr_all_modes_preview.json"),
        ]
        for destination in destinations:
            try:
                os.makedirs(os.path.dirname(destination), exist_ok=True)
                shutil.copy2(source_workflow, destination)
                add_node_log(f"Workflow скопирован: {destination}")
            except Exception as e:
                add_node_log(f"⚠️ Не удалось скопировать workflow в {destination}: {str(e)}")

    def worker():
        add_node_log("=== НАЧАЛО УСТАНОВКИ SparkVSR ===")
        
        # 1. Клонируем SparkVSR с sparse checkout
        spark_repo_dir = os.path.join(custom_nodes_dir, "SparkVSR")
        spark_plugin_symlink = os.path.join(custom_nodes_dir, "ComfyUI-Spark")
        
        if not os.path.exists(spark_repo_dir):
            add_node_log("Клонируем репозиторий SparkVSR с sparse checkout...")
            try:
                subprocess.run(
                    ["git", "clone", "--depth", "1", "--filter=blob:none", "--sparse", "https://github.com/taco-group/SparkVSR.git", "SparkVSR"],
                    cwd=custom_nodes_dir, check=True
                )
                subprocess.run(
                    ["git", "sparse-checkout", "set", "ComfyUI-Spark"],
                    cwd=spark_repo_dir, check=True
                )
            except Exception as e:
                add_node_log(f"⚠️ Ошибка клонирования SparkVSR: {str(e)}")
                return
        else:
            add_node_log("Репозиторий SparkVSR уже склонирован.")

        # На повторной установке подтягиваем свежие файлы workflow/custom node.
        try:
            subprocess.run(["git", "pull", "--ff-only"], cwd=spark_repo_dir, check=True)
        except Exception as e:
            add_node_log(f"⚠️ Не удалось обновить SparkVSR через git pull: {str(e)}")
            
        # Создаем симлинк
        if not os.path.exists(spark_plugin_symlink):
            add_node_log("Создаем символическую ссылку для ComfyUI-Spark...")
            try:
                os.symlink("SparkVSR/ComfyUI-Spark", spark_plugin_symlink)
            except Exception as e:
                add_node_log(f"⚠️ Не удалось создать симлинк: {str(e)}")
                
        # 2. Клонируем VideoHelperSuite
        vhs_dir = os.path.join(custom_nodes_dir, "ComfyUI-VideoHelperSuite")
        if not os.path.exists(vhs_dir):
            add_node_log("Клонируем VideoHelperSuite...")
            try:
                subprocess.run(
                    ["git", "clone", "--depth", "1", "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"],
                    cwd=custom_nodes_dir, check=True
                )
            except Exception as e:
                add_node_log(f"⚠️ Ошибка клонирования VideoHelperSuite: {str(e)}")
                return
        else:
            add_node_log("VideoHelperSuite уже установлен.")

        source_workflow = os.path.join(
            spark_plugin_symlink,
            "example_workflows",
            "sparkvsr_all_modes_preview.json",
        )
        copy_sparkvsr_workflow(source_workflow)

        # 3. Установка Python зависимостей
        
        # Зависимости для ComfyUI-Spark
        spark_req = os.path.join(spark_plugin_symlink, "requirements.txt")
        if os.path.exists(spark_req):
            add_node_log("Устанавливаем зависимости для ComfyUI-Spark...")
            cmd = build_pip_cmd("-r", spark_req)
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            while True:
                line = proc.stdout.readline()
                if not line: break
                add_node_log(line.strip())
            proc.wait()
            
        # Зависимости для VideoHelperSuite
        vhs_req = os.path.join(vhs_dir, "requirements.txt")
        if os.path.exists(vhs_req):
            add_node_log("Устанавливаем зависимости для VideoHelperSuite...")
            cmd = build_pip_cmd("-r", vhs_req)
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            while True:
                line = proc.stdout.readline()
                if not line: break
                add_node_log(line.strip())
            proc.wait()
            
        # Дополнительные зависимости
        add_node_log("Устанавливаем дополнительные пакеты (peft, einops, fal-client)...")
        cmd_extra = build_pip_cmd("peft>=0.9.0", "einops>=0.6.0", "fal-client", "requests")
        proc_extra = subprocess.Popen(cmd_extra, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        while True:
            line = proc_extra.stdout.readline()
            if not line: break
            add_node_log(line.strip())
        proc_extra.wait()
        add_node_log(f"Установка дополнительных пакетов завершена с кодом {proc_extra.returncode}")
        
        # 4. Скачивание весов
        loras_dir = os.path.join(COMFY_DIR, "models", "loras")
        os.makedirs(loras_dir, exist_ok=True)
        
        # Сначала проверяем, есть ли pisa_sr.pkl в папке со скриптом
        local_pisa = os.path.join(BASE_DIR, "pisa_sr.pkl")
        if os.path.exists(local_pisa):
            add_node_log("Обнаружен локальный файл pisa_sr.pkl. Копируем в ComfyUI...")
            try:
                shutil.copy(local_pisa, os.path.join(loras_dir, "pisa_sr.pkl"))
                add_node_log("pisa_sr.pkl успешно скопирован!")
            except Exception as e:
                add_node_log(f"⚠️ Ошибка копирования pisa_sr.pkl: {str(e)}")
        else:
            hf_token, _ = load_tokens()
            if hf_token:
                add_node_log("Попытка скачать pisa_sr.pkl с Hugging Face...")
                try:
                    env = os.environ.copy()
                    env["HF_TOKEN"] = hf_token
                    subprocess.run(
                        ["huggingface-cli", "download", "jiangyzy/PiSA-SR", "pisa_sr.pkl", "--local-dir", loras_dir],
                        env=env, check=True
                    )
                    add_node_log("pisa_sr.pkl успешно скачан!")
                except Exception as e:
                    add_node_log(f"⚠️ Не удалось скачать pisa_sr.pkl автоматически: {str(e)}")
                    add_node_log(f"Скачайте его вручную и положите в {loras_dir}/pisa_sr.pkl")
            else:
                add_node_log(f"Локальный pisa_sr.pkl не найден. Для автоматического скачивания настройте Hugging Face Token во вкладке '📥 Загрузчик моделей', либо скачайте его вручную и положите в {loras_dir}/pisa_sr.pkl")
            
        add_node_log("=== УСТАНОВКА SparkVSR ЗАВЕРШЕНА! ===")
        add_node_log("Перезапустите ComfyUI через вкладку Управление. Авто-загрузка workflow работает только после restart и на пустом canvas.")
        add_node_log("Если workflow не появился автоматически, откройте файл sparkvsr_all_modes_preview.json вручную из /workspace/ComfyUI/input или /workspace/ComfyUI/user/default/workflows.")

    threading.Thread(target=worker, daemon=True).start()
    return "Процесс установки SparkVSR и VideoHelperSuite запущен в фоновом режиме. Логи смотрите ниже."

def install_seedvr2():
    custom_nodes_dir = os.path.join(COMFY_DIR, "custom_nodes")
    if not os.path.isdir(custom_nodes_dir):
        return "Папка custom_nodes не найдена. Сначала установите ComfyUI."

    repo_url = "https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git"
    candidate_dirs = [
        os.path.join(custom_nodes_dir, "seedvr2_videoupscaler"),
        os.path.join(custom_nodes_dir, "ComfyUI-SeedVR2_VideoUpscaler"),
    ]

    def copy_example_workflows(node_dir):
        source_dir = os.path.join(node_dir, "example_workflows")
        if not os.path.isdir(source_dir):
            add_node_log("Примеры workflow в репозитории не найдены.")
            return

        destination_dir = os.path.join(COMFY_DIR, "user", "default", "workflows", "SeedVR2")
        os.makedirs(destination_dir, exist_ok=True)
        copied = 0
        for file_name in os.listdir(source_dir):
            source_path = os.path.join(source_dir, file_name)
            if os.path.isfile(source_path) and file_name.lower().endswith(".json"):
                shutil.copy2(source_path, os.path.join(destination_dir, file_name))
                copied += 1
        add_node_log(f"Workflow SeedVR2 скопировано: {copied} -> {destination_dir}")

    def worker():
        add_node_log(f"=== УСТАНОВКА SEEDVR2: {time.strftime('%Y-%m-%d %H:%M:%S')} ===")
        try:
            existing_dir = next((path for path in candidate_dirs if os.path.exists(path)), None)
            node_dir = existing_dir or candidate_dirs[0]

            if existing_dir:
                if not os.path.isdir(os.path.join(node_dir, ".git")):
                    add_node_log(f"⚠️ Путь существует, но не является Git-репозиторием: {node_dir}")
                    return
                add_node_log(f"SeedVR2 уже установлен. Обновляем: {node_dir}")
                if run_node_command(["git", "pull", "--ff-only"], cwd=node_dir) != 0:
                    add_node_log("⚠️ Не удалось обновить SeedVR2.")
                    return
            else:
                add_node_log(f"Клонируем SeedVR2 в {node_dir}...")
                if run_node_command(["git", "clone", "--depth", "1", repo_url, node_dir]) != 0:
                    add_node_log("⚠️ Не удалось клонировать SeedVR2.")
                    return

            requirements_path = os.path.join(node_dir, "requirements.txt")
            if not os.path.isfile(requirements_path):
                add_node_log(f"⚠️ requirements.txt не найден: {requirements_path}")
                return

            add_node_log("Устанавливаем зависимости SeedVR2 в окружение ComfyUI...")
            if run_node_command(build_pip_cmd("-r", requirements_path)) != 0:
                add_node_log("⚠️ Установка Python-зависимостей SeedVR2 завершилась с ошибкой.")
                return

            models_dir = os.path.join(COMFY_DIR, "models", "SEEDVR2")
            os.makedirs(models_dir, exist_ok=True)
            copy_example_workflows(node_dir)

            add_node_log("=== SEEDVR2 УСПЕШНО УСТАНОВЛЕН ===")
            add_node_log(f"Модели будут автоматически загружены при первом запуске в {models_dir}")
            add_node_log("Перезапустите ComfyUI во вкладке «Управление и мониторинг».")
        except Exception as exc:
            add_node_log(f"⚠️ Ошибка установки SeedVR2: {exc}")

    threading.Thread(target=worker, daemon=True).start()
    return "Установка/обновление SeedVR2 запущена. Следите за логом ниже."

# Управление токенами
def load_tokens():
    hf_token = ""
    civitai_token = ""
    if os.path.exists(TOKENS_ENV_FILE):
        try:
            with open(TOKENS_ENV_FILE, "r") as f:
                for line in f:
                    if line.startswith("HF_TOKEN="):
                        hf_token = line.split("=", 1)[1].strip().strip("'\"")
                    elif line.startswith("CIVITAI_API_TOKEN="):
                        civitai_token = line.split("=", 1)[1].strip().strip("'\"")
        except Exception:
            pass
    return hf_token, civitai_token

def save_tokens(hf_token, civitai_token):
    os.makedirs(os.path.dirname(TOKENS_ENV_FILE), exist_ok=True)
    try:
        with open(TOKENS_ENV_FILE, "w") as f:
            f.write(f"HF_TOKEN='{hf_token.strip()}'\n")
            f.write(f"CIVITAI_API_TOKEN='{civitai_token.strip()}'\n")
        return "Токены успешно сохранены в ~/.config/comfy-model-downloader/tokens.env"
    except Exception as e:
        return f"Ошибка сохранения токенов: {str(e)}"

def build_downloader_env():
    env = os.environ.copy()
    env["COMFY_DIR"] = COMFY_DIR
    hf_token, civitai_token = load_tokens()
    if hf_token:
        env["HF_TOKEN"] = hf_token
    if civitai_token:
        env["CIVITAI_API_TOKEN"] = civitai_token
    return env, hf_token, civitai_token

# Скачивание моделей
def run_download_model(url, folder, filename):
    if not url.strip():
        return "Пожалуйста, введите URL модели."
    
    if not os.path.exists(DOWNLOADER_SCRIPT):
        return f"Загрузчик не найден: {DOWNLOADER_SCRIPT}"
    
    def worker():
        add_download_log(f"--- Старт загрузки: {time.strftime('%H:%M:%S')} ---")
        add_download_log(f"Ссылка: {url}")
        
        cmd = [DOWNLOADER_SCRIPT, "--download", url, "--yes"]
        if folder and folder != "Автоопределение (Auto-detect)":
            cmd += ["--folder", folder]
        if filename.strip():
            cmd += ["--filename", filename.strip()]
        
        # Запуск процесса
        env, hf_token, civitai_token = build_downloader_env()
        add_download_log(f"Hugging Face token: {'настроен' if hf_token else 'не настроен'}")
        add_download_log(f"Civitai token: {'настроен' if civitai_token else 'не настроен'}")
        
        proc = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )
        
        while True:
            line = proc.stdout.readline()
            if not line:
                break
            
            add_download_log(line.strip())
                
        proc.wait()
        add_download_log(f"--- Загрузка завершена с кодом {proc.returncode} ---")
        
    threading.Thread(target=worker, daemon=True).start()
    return "Загрузка запущена в фоновом режиме. Перейдите к логу ниже для отслеживания."

def get_uploaded_file_path(uploaded_file):
    if uploaded_file is None:
        return ""
    if isinstance(uploaded_file, str):
        return uploaded_file
    if hasattr(uploaded_file, "name"):
        return uploaded_file.name
    return ""

def parse_batch_download_line(line):
    line = line.strip()
    if not line or line.startswith("#"):
        return None

    fields = shlex.split(line)
    if not fields:
        return None

    url = fields[0]
    folder = ""
    i = 1
    while i < len(fields):
        option = fields[i]
        if option == "--folder":
            if i + 1 >= len(fields):
                raise ValueError("после --folder нужна папка")
            folder = fields[i + 1]
            i += 2
        elif option.startswith("--folder="):
            folder = option.split("=", 1)[1]
            i += 1
        elif option.startswith("--"):
            folder = option[2:]
            i += 1
        else:
            raise ValueError(f"неизвестный аргумент '{option}'")

    return url, folder

def read_batch_download_entries(list_path):
    entries = []
    with open(list_path, "r", encoding="utf-8", errors="ignore") as file:
        for line_number, line in enumerate(file, start=1):
            parsed = parse_batch_download_line(line)
            if parsed is None:
                continue
            entries.append((line_number, parsed[0], parsed[1]))
    return entries

def stream_download_process(cmd, env, log_prefix=""):
    proc = subprocess.Popen(
        cmd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    while True:
        line = proc.stdout.readline()
        if not line:
            break
        clean_line = line.strip()
        if clean_line:
            add_download_log(f"{log_prefix}{clean_line}")
    proc.wait()
    return proc.returncode

def run_parallel_batch_download(list_path, parallel_count):
    entries = read_batch_download_entries(list_path)
    if not entries:
        add_download_log("В TXT нет ссылок для загрузки.")
        return

    add_download_log(f"Параллельная загрузка: {len(entries)} моделей, потоков: {parallel_count}")
    hf_token, civitai_token = load_tokens()
    add_download_log(f"Hugging Face token: {'настроен' if hf_token else 'не настроен'}")
    add_download_log(f"Civitai token: {'настроен' if civitai_token else 'не настроен'}")

    tasks = queue.Queue()
    for entry in entries:
        tasks.put(entry)

    results = {"ok": 0, "failed": 0}
    results_lock = threading.Lock()

    def worker(worker_id):
        env, _, _ = build_downloader_env()
        while True:
            try:
                line_number, url, folder = tasks.get_nowait()
            except queue.Empty:
                return

            prefix = f"[W{worker_id} L{line_number}] "
            add_download_log(f"{prefix}Старт: {url}")
            cmd = [DOWNLOADER_SCRIPT, "--download", url, "--yes"]
            if folder:
                cmd += ["--folder", folder]
                add_download_log(f"{prefix}Папка: models/{folder}")

            return_code = stream_download_process(cmd, env, prefix)
            with results_lock:
                if return_code == 0:
                    results["ok"] += 1
                else:
                    results["failed"] += 1
            add_download_log(f"{prefix}Завершено с кодом {return_code}")
            tasks.task_done()

    workers = []
    for index in range(max(1, parallel_count)):
        thread = threading.Thread(target=worker, args=(index + 1,), daemon=True)
        workers.append(thread)
        thread.start()
    for thread in workers:
        thread.join()

    add_download_log(f"Итог параллельной загрузки: успешно {results['ok']}, ошибок {results['failed']}")

def run_download_batch(txt_file, parallel_count):
    list_path = get_uploaded_file_path(txt_file)
    if not list_path:
        return "Пожалуйста, загрузите TXT-файл со списком моделей."

    if not os.path.exists(DOWNLOADER_SCRIPT):
        return f"Загрузчик не найден: {DOWNLOADER_SCRIPT}"

    def worker():
        add_download_log(f"--- Старт пакетной загрузки: {time.strftime('%H:%M:%S')} ---")
        add_download_log(f"TXT: {list_path}")
        parallel = max(1, int(parallel_count or 1))

        add_download_log("Режим: автоопределение папок; построчные флаги --vae/--loras/--checkpoints/--folder поддерживаются")
        env, hf_token, civitai_token = build_downloader_env()
        add_download_log(f"Hugging Face token: {'настроен' if hf_token else 'не настроен'}")
        add_download_log(f"Civitai token: {'настроен' if civitai_token else 'не настроен'}")

        if parallel == 1:
            cmd = [DOWNLOADER_SCRIPT, "--batch", list_path]
            return_code = stream_download_process(cmd, env)
            add_download_log(f"--- Пакетная загрузка завершена с кодом {return_code} ---")
        else:
            run_parallel_batch_download(list_path, parallel)
            add_download_log("--- Параллельная пакетная загрузка завершена ---")

    threading.Thread(target=worker, daemon=True).start()
    return "Пакетная загрузка запущена в фоновом режиме. Лог ниже."

# Файловый менеджер
def list_model_folders():
    models_root = os.path.join(COMFY_DIR, "models")
    if not os.path.exists(models_root):
        return []
    folders = [f for f in os.listdir(models_root) if os.path.isdir(os.path.join(models_root, f))]
    return sorted(folders)

def browse_folder(folder_name):
    if not folder_name:
        return []
    
    target_dir = os.path.join(COMFY_DIR, "models", folder_name)
    if not os.path.exists(target_dir):
        return []
        
    files_data = []
    for entry in os.scandir(target_dir):
        if entry.is_file():
            size_mb = entry.stat().st_size / (1024 * 1024)
            files_data.append([entry.name, f"{size_mb:.2f} MB"])
            
    return sorted(files_data, key=lambda x: x[0])

def delete_model_file(folder_name, file_name):
    if not folder_name or not file_name:
        return "Не выбрана папка или файл", []
        
    file_path = os.path.join(COMFY_DIR, "models", folder_name, file_name)
    if os.path.exists(file_path):
        try:
            os.remove(file_path)
            updated_list = browse_folder(folder_name)
            return f"Файл {file_name} успешно удален.", updated_list
        except Exception as e:
            return f"Не удалось удалить файл: {str(e)}", browse_folder(folder_name)
    return "Файл не найден.", browse_folder(folder_name)

# Полный файловый менеджер для Gradio Control Panel.
def normalize_workspace_path(path):
    raw_path = (path or "").strip()
    if raw_path in ("", ".", "/"):
        return ""
    if os.path.isabs(raw_path):
        raw_path = os.path.relpath(raw_path, FILE_MANAGER_ROOT)
    normalized = os.path.normpath(raw_path)
    if normalized == ".":
        return ""
    if normalized == ".." or normalized.startswith(f"..{os.sep}") or os.path.isabs(normalized):
        raise ValueError("Путь вне /workspace запрещен.")
    return normalized

def resolve_workspace_path(path):
    relative_path = normalize_workspace_path(path)
    absolute_path = os.path.abspath(os.path.join(FILE_MANAGER_ROOT, relative_path))
    root_real = os.path.realpath(FILE_MANAGER_ROOT)
    target_real = os.path.realpath(absolute_path)
    if target_real != root_real and not target_real.startswith(root_real + os.sep):
        raise ValueError("Путь вне /workspace запрещен.")
    return absolute_path, relative_path

def format_file_size(size_bytes):
    value = float(size_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.2f} {unit}"
        value /= 1024

def list_workspace_files(path):
    try:
        absolute_path, relative_path = resolve_workspace_path(path)
        if not os.path.isdir(absolute_path):
            return relative_path, [], "Это не папка."

        rows = []
        for entry in os.scandir(absolute_path):
            try:
                stat = entry.stat(follow_symlinks=False)
                is_dir = entry.is_dir(follow_symlinks=False)
                entry_type = "Папка" if is_dir else "Файл"
                if entry.is_symlink():
                    entry_type = "Ссылка"
                size = "-" if is_dir else format_file_size(stat.st_size)
                modified = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(stat.st_mtime))
                rows.append([entry.name, entry_type, size, modified])
            except OSError as exc:
                rows.append([entry.name, "Ошибка", str(exc), ""])

        rows.sort(key=lambda row: (row[1] != "Папка", row[0].lower()))
        display_path = f"/workspace/{relative_path}".rstrip("/")
        return relative_path, rows, f"Открыто: {display_path or '/workspace'}"
    except Exception as exc:
        return path or "", [], f"Ошибка: {exc}"

def workspace_parent(path):
    try:
        _, relative_path = resolve_workspace_path(path)
        return list_workspace_files(os.path.dirname(relative_path) if relative_path else "")
    except Exception as exc:
        return path or "", [], f"Ошибка: {exc}"

def workspace_open_selected(path, selected_name):
    if not selected_name:
        return list_workspace_files(path)
    try:
        _, relative_path = resolve_workspace_path(path)
        target_path = os.path.join(relative_path, selected_name)
        absolute_path, normalized = resolve_workspace_path(target_path)
        if os.path.isdir(absolute_path):
            return list_workspace_files(normalized)
        current_path, rows, _ = list_workspace_files(relative_path)
        return current_path, rows, f"Выбран файл: {selected_name}"
    except Exception as exc:
        return path or "", [], f"Ошибка: {exc}"

def table_cell_value(table_data, row_index, column_index=0):
    """Read a Dataframe cell for both Gradio array and pandas payloads."""
    try:
        if hasattr(table_data, "iloc"):
            value = table_data.iloc[row_index, column_index]
        elif isinstance(table_data, dict) and "data" in table_data:
            value = table_data["data"][row_index][column_index]
        else:
            value = table_data[row_index][column_index]
        return "" if value is None else str(value)
    except (IndexError, KeyError, TypeError, AttributeError):
        return ""

def select_workspace_entry(table_data, evt: gr.SelectData):
    row_index = evt.index[0] if isinstance(evt.index, (list, tuple)) else evt.index
    selected_name = table_cell_value(table_data, row_index)
    if selected_name:
        return selected_name, f"Выбрано: **{selected_name}**. Для входа в папку нажмите «📂 Открыть»."
    return "", "Не удалось определить выбранную строку. Обновите список и попробуйте снова."

def workspace_root_view():
    path, rows, status = list_workspace_files("")
    return path, rows, status, ""

def workspace_path_view(path):
    current_path, rows, status = list_workspace_files(path)
    return current_path, rows, status, ""

def workspace_parent_view(path):
    current_path, rows, status = workspace_parent(path)
    return current_path, rows, status, ""

def workspace_open_view(path, selected_name):
    previous_path = normalize_workspace_path(path)
    current_path, rows, status = workspace_open_selected(path, selected_name)
    selection = "" if current_path != previous_path else selected_name
    return current_path, rows, status, selection

def make_zip_from_folder(folder_path):
    os.makedirs(FILE_DOWNLOAD_DIR, exist_ok=True)
    base_name = os.path.basename(folder_path.rstrip(os.sep)) or "workspace"
    archive_path = os.path.join(FILE_DOWNLOAD_DIR, f"{base_name}-{int(time.time())}.zip")
    with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for root, _, files in os.walk(folder_path):
            for file_name in files:
                full_path = os.path.join(root, file_name)
                archive_name = os.path.relpath(full_path, os.path.dirname(folder_path))
                archive.write(full_path, archive_name)
    return archive_path

def download_comfy_output_folder():
    output_dir = os.path.join(COMFY_DIR, "output")
    if not os.path.isdir(output_dir):
        return None, f"Папка результатов не найдена: {output_dir}"
    has_files = any(files for _, _, files in os.walk(output_dir))
    if not has_files:
        return None, f"Папка результатов пуста: {output_dir}"
    try:
        return make_zip_from_folder(output_dir), "ZIP создан. Нажмите кнопку «Скачать готовый ZIP»."
    except Exception as exc:
        return None, f"Ошибка упаковки output: {exc}"

def workspace_download_selected(path, selected_name):
    if not selected_name:
        return None, "Не выбран файл или папка."
    try:
        _, relative_path = resolve_workspace_path(path)
        target_path, _ = resolve_workspace_path(os.path.join(relative_path, selected_name))
        if os.path.isdir(target_path):
            return make_zip_from_folder(target_path), f"Папка упакована в ZIP: {selected_name}"
        if os.path.isfile(target_path):
            os.makedirs(FILE_DOWNLOAD_DIR, exist_ok=True)
            download_path = os.path.join(
                FILE_DOWNLOAD_DIR,
                f"{int(time.time())}-{os.path.basename(target_path)}",
            )
            shutil.copy2(target_path, download_path)
            return download_path, f"Файл готов к скачиванию: {selected_name}"
        return None, "Можно скачать только файл или папку."
    except Exception as exc:
        return None, f"Ошибка: {exc}"

def normalize_uploaded_files(uploaded_files):
    if uploaded_files is None:
        return []
    if not isinstance(uploaded_files, list):
        uploaded_files = [uploaded_files]
    paths = []
    for item in uploaded_files:
        if isinstance(item, str):
            paths.append(item)
        elif hasattr(item, "name"):
            paths.append(item.name)
    return [path for path in paths if path]

def workspace_upload_files(path, uploaded_files):
    try:
        destination_dir, relative_path = resolve_workspace_path(path)
        if not os.path.isdir(destination_dir):
            return "Текущий путь не является папкой.", list_workspace_files(relative_path)[1]
        source_paths = normalize_uploaded_files(uploaded_files)
        if not source_paths:
            return "Файлы не выбраны.", list_workspace_files(relative_path)[1]

        copied = 0
        for source_path in source_paths:
            file_name = os.path.basename(source_path)
            if file_name:
                shutil.copy2(source_path, os.path.join(destination_dir, file_name))
                copied += 1
        return f"Загружено файлов: {copied}", list_workspace_files(relative_path)[1]
    except Exception as exc:
        return f"Ошибка: {exc}", []

def workspace_create_folder(path, folder_name):
    try:
        current_dir, relative_path = resolve_workspace_path(path)
        clean_name = os.path.basename((folder_name or "").strip())
        if not clean_name or clean_name in (".", ".."):
            return "Введите имя папки.", list_workspace_files(relative_path)[1]
        os.makedirs(os.path.join(current_dir, clean_name), exist_ok=True)
        return f"Папка создана: {clean_name}", list_workspace_files(relative_path)[1]
    except Exception as exc:
        return f"Ошибка: {exc}", []

def workspace_delete_selected(path, selected_name):
    if not selected_name:
        return "Не выбран файл или папка.", list_workspace_files(path)[1], ""
    try:
        _, relative_path = resolve_workspace_path(path)
        target_path, _ = resolve_workspace_path(os.path.join(relative_path, selected_name))
        if os.path.isdir(target_path):
            shutil.rmtree(target_path)
        else:
            os.remove(target_path)
        return f"Удалено: {selected_name}", list_workspace_files(relative_path)[1], ""
    except Exception as exc:
        return f"Ошибка: {exc}", [], selected_name

def run_workspace_command(path, command):
    if not (command or "").strip():
        return "Введите команду."
    try:
        working_dir, _ = resolve_workspace_path(path)
        if not os.path.isdir(working_dir):
            return "Рабочая папка не найдена."
        completed = subprocess.run(
            command,
            cwd=working_dir,
            shell=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
        )
        output = completed.stdout or ""
        if len(output) > 20000:
            output = output[-20000:]
        return f"$ {command}\n[exit {completed.returncode}]\n{output}"
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        return f"$ {command}\n[timeout]\n{output}"
    except Exception as exc:
        return f"Ошибка: {exc}"

# Создание интерфейса Gradio
with gr.Blocks(title="ComfyUI RunPod Control Panel", theme=gr.themes.Default(primary_hue="orange", secondary_hue="slate")) as demo:
    gr.Markdown(
        """
        # 🚀 ComfyUI RunPod Control Panel
        Управление запуском ComfyUI, мониторинг ресурсов и удобный менеджер моделей.
        """
    )
    
    with gr.Tabs():
        # Вкладка 1: Управление и логи
        with gr.TabItem("📊 Управление и мониторинг"):
            with gr.Row():
                with gr.Column(scale=1):
                    gr.Markdown("### 🔌 Статус ComfyUI")
                    status_indicator = gr.Textbox(label="Текущее состояние", value="Загрузка...", interactive=False)
                    pid_indicator = gr.Textbox(label="Информация о процессе", value="Загрузка...", interactive=False)
                    
                    gr.Markdown("### ⚙️ Параметры запуска")
                    comfy_args = gr.Textbox(
                        label="Аргументы командной строки", 
                        value=DEFAULT_COMFY_ARGS
                    )
                    
                    with gr.Row():
                        btn_start = gr.Button("▶️ Запустить", variant="primary")
                        btn_restart = gr.Button("🔁 Restart", variant="secondary")
                        btn_stop = gr.Button("⏹️ Остановить", variant="stop")
                    
                    with gr.Row():
                        btn_install = gr.Button("🚀 Установить ComfyUI с нуля", variant="secondary")
                        btn_refresh = gr.Button("🔄 Обновить статус")

                    btn_download_output = gr.Button("📦 1. Создать output ZIP", variant="secondary")
                    output_download_file = gr.DownloadButton(
                        label="⬇️ 2. Скачать готовый ZIP",
                        value=None,
                        variant="primary",
                    )
                    output_download_status = gr.Markdown("")
                    
                with gr.Column(scale=2):
                    gr.Markdown("### 📈 Ресурсы системы")
                    system_stats_box = gr.HTML(value="Загрузка статистики ресурсов...")
                    
            gr.Markdown("### 📝 Лог консоли ComfyUI")
            with gr.Row():
                lines_slider = gr.Slider(minimum=10, maximum=500, value=100, step=10, label="Показывать последних строк")
                btn_refresh_logs = gr.Button("🔄 Обновить лог")
            log_output = gr.TextArea(
                label="Логи (comfyui.log)", 
                value="Нажмите кнопку Обновить лог", 
                interactive=False, 
                autofocus=False,
                lines=15
            )

        # Вкладка 2: Загрузчик моделей
        with gr.TabItem("📥 Загрузчик моделей"):
            gr.Markdown("### Настройка токенов доступа (Hugging Face / Civitai)")
            init_hf, init_civi = load_tokens()
            with gr.Row():
                hf_token_input = gr.Textbox(label="Hugging Face Token", value=init_hf, type="password")
                civitai_token_input = gr.Textbox(label="Civitai API Key", value=init_civi, type="password")
            btn_save_tokens = gr.Button("💾 Сохранить токены")
            token_status = gr.Markdown("")
            
            gr.Markdown("---")
            gr.Markdown("### Загрузка новой модели")
            with gr.Row():
                model_url = gr.Textbox(
                    label="URL модели (Прямая ссылка Hugging Face/Civitai)", 
                    placeholder="https://huggingface.co/..."
                )
                custom_filename = gr.Textbox(
                    label="Имя файла модели (опционально)", 
                    placeholder="model.safetensors"
                )
            
            # Получение списка папок
            folders = ["Автоопределение (Auto-detect)"] + list_model_folders()
            dest_folder = gr.Dropdown(
                choices=folders, 
                value="Автоопределение (Auto-detect)", 
                label="Целевая папка (models/...)"
            )
            
            btn_download = gr.Button("⬇️ Начать загрузку", variant="primary")
            download_status = gr.Markdown("")

            gr.Markdown("---")
            gr.Markdown("### Пакетная загрузка из TXT")
            batch_txt_file = gr.File(
                label="TXT-файл: URL и опциональный --тип на каждой строке",
                file_types=[".txt"],
                type="filepath",
            )
            gr.Markdown(
                """
                Формат строк: `URL`, `URL --vae`, `URL --loras`, `URL --checkpoints`, `URL --diffusion_models`, `URL --text_encoders`, `URL --clip_vision`, `URL --controlnet`, `URL --upscale_models`, `URL --embeddings`.
                Без флага папка определяется автоматически.
                """
            )
            with gr.Row():
                batch_parallel_count = gr.Slider(
                    minimum=1,
                    maximum=4,
                    value=1,
                    step=1,
                    label="Параллельных загрузок",
                )
                btn_batch_download = gr.Button("⬇️ Скачать список", variant="primary")
            batch_download_status = gr.Markdown("")
            
            gr.Markdown("### 📋 Прогресс и логи скачивания")
            btn_refresh_dl = gr.Button("🔄 Обновить лог скачивания")
            dl_log_output = gr.TextArea(
                label="Лог comfy_model_downloader.sh", 
                value="Лог пуст", 
                interactive=False,
                lines=10
            )

        # Вкладка 3: Файловый менеджер моделей
        with gr.TabItem("📁 Файловый менеджер"):
            gr.Markdown("### Просмотр и удаление моделей")
            with gr.Row():
                folder_select = gr.Dropdown(choices=list_model_folders(), label="Выберите категорию моделей")
                btn_refresh_folders = gr.Button("🔄 Обновить список категорий")
                
            model_files_table = gr.Dataframe(
                headers=["Имя файла", "Размер"],
                datatype=["str", "str"],
                label="Файлы в выбранной категории",
                interactive=False,
                type="array",
            )
            
            selected_file_name = gr.Textbox(label="Выбранный файл", interactive=False)
            btn_delete_file = gr.Button("❌ Удалить выбранный файл", variant="stop")
            file_manager_status = gr.Markdown("")

        # Вкладка 4: Полный файловый менеджер /workspace
        with gr.TabItem("🗂️ Workspace"):
            initial_ws_path, initial_ws_rows, initial_ws_status = list_workspace_files("")
            with gr.Row():
                workspace_path = gr.Textbox(label="Путь от /workspace", value=initial_ws_path, scale=4)
                selected_workspace_entry = gr.Textbox(label="Выбрано", interactive=False, scale=2)

            with gr.Row():
                btn_workspace_root = gr.Button("🏠 /workspace")
                btn_workspace_up = gr.Button("⬆️ Вверх")
                btn_workspace_open = gr.Button("📂 Открыть")
                btn_workspace_refresh = gr.Button("🔄 Обновить")

            workspace_table = gr.Dataframe(
                headers=["Имя", "Тип", "Размер", "Изменен"],
                datatype=["str", "str", "str", "str"],
                value=initial_ws_rows,
                label="Файлы и папки",
                interactive=False,
                type="array",
            )
            workspace_status = gr.Markdown(initial_ws_status)

            with gr.Row():
                btn_workspace_download = gr.Button("⬇️ Скачать выбранное", variant="primary")
                btn_workspace_delete = gr.Button("❌ Удалить выбранное", variant="stop")
            workspace_download_file = gr.DownloadButton(
                label="⬇️ Скачать готовый файл",
                value=None,
                variant="primary",
            )

            with gr.Row():
                workspace_upload = gr.File(
                    label="Загрузить файлы в текущую папку",
                    file_count="multiple",
                    type="filepath",
                )
                btn_workspace_upload = gr.Button("⬆️ Загрузить", variant="primary")

            with gr.Row():
                workspace_new_folder = gr.Textbox(label="Новая папка", placeholder="folder-name")
                btn_workspace_mkdir = gr.Button("📁 Создать папку")

            gr.Markdown("### Terminal")
            workspace_command = gr.Textbox(label="Команда", placeholder="ls -lah")
            btn_workspace_command = gr.Button("▶️ Выполнить", variant="primary")
            workspace_terminal_output = gr.TextArea(
                label="Вывод",
                value="",
                interactive=False,
                lines=14,
            )

        # Вкладка 5: Установка кастомных нод
        with gr.TabItem("🧩 Установка Custom Nodes"):
            gr.Markdown("### Установка расширений (Custom Nodes) по ссылке Git")
            with gr.Row():
                node_git_url = gr.Textbox(
                    label="URL репозитория ноды на GitHub/GitLab",
                    placeholder="https://github.com/..."
                )
                btn_install_node = gr.Button("🚀 Установить ноду", variant="primary")
            
            gr.Markdown("---")
            gr.Markdown("### ✨ Предустановки популярных расширений")
            with gr.Row():
                btn_install_sparkvsr = gr.Button("🔥 Установить SparkVSR + VideoHelperSuite (Upscaler)", variant="secondary")
                btn_install_seedvr2 = gr.Button("🌱 Установить / обновить SeedVR2 Video Upscaler", variant="secondary")
            
            node_install_status = gr.Markdown("")
            
            gr.Markdown("### 📋 Лог установки нод")
            btn_refresh_node_log = gr.Button("🔄 Обновить лог ноды")
            node_log_output = gr.TextArea(
                label="Лог консоли установки нод",
                value="Лог пуст",
                interactive=False,
                lines=15
            )

    # Автообновление статуса и ресурсов каждые 5 секунд
    auto_refresh_timer = gr.Timer(value=5)

    def periodic_status_update():
        status, pid = get_comfy_status()
        stats = get_system_stats()
        return status, pid, stats

    auto_refresh_timer.tick(periodic_status_update, outputs=[status_indicator, pid_indicator, system_stats_box])

    # Привязка логики к кнопкам Dashboard
    btn_start.click(start_comfy, inputs=[comfy_args], outputs=[status_indicator])
    btn_restart.click(restart_comfy, inputs=[comfy_args], outputs=[status_indicator])
    btn_stop.click(stop_comfy, outputs=[status_indicator])
    btn_install.click(run_installation, outputs=[status_indicator])
    btn_download_output.click(
        download_comfy_output_folder,
        outputs=[output_download_file, output_download_status],
    )
    
    def refresh_dashboard(num_lines):
        status, pid = get_comfy_status()
        stats = get_system_stats()
        logs = read_logs(num_lines)
        return status, pid, stats, logs
        
    btn_refresh.click(periodic_status_update, outputs=[status_indicator, pid_indicator, system_stats_box])
    btn_refresh_logs.click(read_logs, inputs=[lines_slider], outputs=[log_output])
    
    # Привязка логики токенов
    btn_save_tokens.click(save_tokens, inputs=[hf_token_input, civitai_token_input], outputs=[token_status])
    
    # Скачивание моделей
    btn_download.click(
        run_download_model, 
        inputs=[model_url, dest_folder, custom_filename], 
        outputs=[download_status]
    )
    btn_batch_download.click(
        run_download_batch,
        inputs=[batch_txt_file, batch_parallel_count],
        outputs=[batch_download_status],
    )
    btn_refresh_dl.click(get_download_logs, outputs=[dl_log_output])

    # Файловый менеджер
    def update_file_list(folder):
        return browse_folder(folder)
        
    folder_select.change(update_file_list, inputs=[folder_select], outputs=[model_files_table])
    
    btn_refresh_folders.click(
        lambda: gr.Dropdown(choices=list_model_folders()), 
        outputs=[folder_select]
    )
    
    # Выбор строки в таблице
    def select_file_from_table(table_data, evt: gr.SelectData):
        row_index = evt.index[0] if isinstance(evt.index, (list, tuple)) else evt.index
        return table_cell_value(table_data, row_index)
        
    model_files_table.select(select_file_from_table, inputs=[model_files_table], outputs=[selected_file_name])
    
    btn_delete_file.click(
        delete_model_file, 
        inputs=[folder_select, selected_file_name], 
        outputs=[file_manager_status, model_files_table]
    )

    # Полный файловый менеджер /workspace
    workspace_table.select(
        select_workspace_entry,
        inputs=[workspace_table],
        outputs=[selected_workspace_entry, workspace_status],
    )
    workspace_path.submit(
        workspace_path_view,
        inputs=[workspace_path],
        outputs=[workspace_path, workspace_table, workspace_status, selected_workspace_entry],
    )
    btn_workspace_root.click(
        workspace_root_view,
        outputs=[workspace_path, workspace_table, workspace_status, selected_workspace_entry],
    )
    btn_workspace_up.click(
        workspace_parent_view,
        inputs=[workspace_path],
        outputs=[workspace_path, workspace_table, workspace_status, selected_workspace_entry],
    )
    btn_workspace_open.click(
        workspace_open_view,
        inputs=[workspace_path, selected_workspace_entry],
        outputs=[workspace_path, workspace_table, workspace_status, selected_workspace_entry],
    )
    btn_workspace_refresh.click(
        workspace_path_view,
        inputs=[workspace_path],
        outputs=[workspace_path, workspace_table, workspace_status, selected_workspace_entry],
    )
    btn_workspace_download.click(
        workspace_download_selected,
        inputs=[workspace_path, selected_workspace_entry],
        outputs=[workspace_download_file, workspace_status],
    )
    btn_workspace_upload.click(
        workspace_upload_files,
        inputs=[workspace_path, workspace_upload],
        outputs=[workspace_status, workspace_table],
    )
    btn_workspace_mkdir.click(
        workspace_create_folder,
        inputs=[workspace_path, workspace_new_folder],
        outputs=[workspace_status, workspace_table],
    )
    btn_workspace_delete.click(
        workspace_delete_selected,
        inputs=[workspace_path, selected_workspace_entry],
        outputs=[workspace_status, workspace_table, selected_workspace_entry],
    )
    btn_workspace_command.click(
        run_workspace_command,
        inputs=[workspace_path, workspace_command],
        outputs=[workspace_terminal_output],
    )
    workspace_command.submit(
        run_workspace_command,
        inputs=[workspace_path, workspace_command],
        outputs=[workspace_terminal_output],
    )

    # Установка кастомных нод
    btn_install_node.click(
        install_custom_node,
        inputs=[node_git_url],
        outputs=[node_install_status]
    )
    btn_install_sparkvsr.click(
        install_sparkvsr,
        outputs=[node_install_status]
    )
    btn_install_seedvr2.click(
        install_seedvr2,
        outputs=[node_install_status]
    )
    btn_refresh_node_log.click(get_node_logs, outputs=[node_log_output])
    
    # Инициализация при загрузке страницы
    demo.load(
        fn=refresh_dashboard, 
        inputs=[lines_slider], 
        outputs=[status_indicator, pid_indicator, system_stats_box, log_output]
    )

if __name__ == "__main__":
    # На RunPod по умолчанию запускаем ComfyUI вместе с панелью. Отключить можно
    # переменной AUTO_START_COMFY=0 и затем запускать сервер кнопкой в панели.
    auto_start = os.environ.get("AUTO_START_COMFY", "1").strip().lower()
    if auto_start not in {"0", "false", "no", "off"}:
        print(f"Автозапуск ComfyUI: {start_comfy(DEFAULT_COMFY_ARGS)}", flush=True)

    # Запуск Gradio. Порт 7860 по умолчанию.
    # Флаг share=True не рекомендуется запускать без пароля на публичных подах,
    # но bind на 0.0.0.0 позволяет открыть веб-интерфейс через прокси-порт RunPod.
    panel_pass = os.environ.get("PANEL_PASS", "")
    auth = (os.environ.get("PANEL_USER", "admin"), panel_pass) if panel_pass else None
    if auth is None:
        print(
            "ВНИМАНИЕ: PANEL_PASS не задан. Панель с Terminal доступна без пароля!",
            flush=True,
        )
    demo.launch(
        server_name="0.0.0.0",
        server_port=7860,
        auth=auth,
        allowed_paths=[FILE_DOWNLOAD_DIR],
    )
