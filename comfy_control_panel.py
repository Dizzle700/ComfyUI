#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import subprocess
import signal
import time
import shutil
import threading
import gradio as gr
import psutil

# Определение путей
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
COMFY_DIR = os.environ.get("COMFY_DIR", "/workspace/ComfyUI" if os.path.exists("/workspace") else os.path.join(BASE_DIR, "ComfyUI"))
LOG_FILE = os.path.join(COMFY_DIR, "comfyui.log")
DOWNLOADER_SCRIPT = os.path.join(BASE_DIR, "comfy_model_downloader.sh")
TOKENS_ENV_FILE = os.path.expanduser("~/.config/comfy-model-downloader/tokens.env")

# Состояние процесса ComfyUI
comfy_process = None
process_lock = threading.Lock()

# Лог скачивания моделей
download_logs = []
download_lock = threading.Lock()

def add_download_log(text):
    with download_lock:
        download_logs.append(text)
        if len(download_logs) > 100:
            download_logs.pop(0)

def get_download_logs():
    with download_lock:
        return "\n".join(download_logs)

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
    
    # Парсим аргументы
    arg_list = args.split()
    
    # Определяем исполняемый файл python (в venv или глобальный)
    venv_python = os.path.join(COMFY_DIR, ".venv", "bin", "python")
    python_exe = venv_python if os.path.exists(venv_python) else "python3"

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
        
        time.sleep(2) # Даем процессу инициализироваться
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
            if comfy_process is not None:
                os.killpg(os.getpgid(comfy_process.pid), signal.SIGKILL)
                comfy_process = None
                return "Процесс принудительно убит (SIGKILL)."
        except:
            pass
        return f"Ошибка при остановке: {str(e)}"

is_installing = False
install_lock = threading.Lock()

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
            except:
                pass
        finally:
            with install_lock:
                is_installing = False
                
    threading.Thread(target=worker, daemon=True).start()
    return "Установка запущена! Следите за логами в окне справа (нажмите '🔄 Обновить лог')."

def read_logs(num_lines=50):
    if not os.path.exists(LOG_FILE):
        return "Файл логов пуст или ещё не создан."
    
    try:
        with open(LOG_FILE, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
            tail = lines[-int(num_lines):]
            return "".join(tail)
    except Exception as e:
        return f"Не удалось прочитать логи: {str(e)}"

# Установка кастомных нод
node_logs = []
node_lock = threading.Lock()

def add_node_log(text):
    with node_lock:
        node_logs.append(text)
        if len(node_logs) > 100:
            node_logs.pop(0)

def get_node_logs():
    with node_lock:
        return "\n".join(node_logs)

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
            venv_python = os.path.join(COMFY_DIR, ".venv", "bin", "python")
            if os.path.exists(venv_python):
                cmd = ["uv", "pip", "install", "--python", venv_python, "-r", req_file]
            else:
                cmd = ["uv", "pip", "install", "--system", "-r", req_file]
                
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

        # 3. Установка Python зависимостей
        venv_python = os.path.join(COMFY_DIR, ".venv", "bin", "python")
        is_venv = os.path.exists(venv_python)
        
        # Зависимости для ComfyUI-Spark
        spark_req = os.path.join(spark_plugin_symlink, "requirements.txt")
        if os.path.exists(spark_req):
            add_node_log("Устанавливаем зависимости для ComfyUI-Spark...")
            cmd = ["uv", "pip", "install", "--python" if is_venv else "--system", venv_python if is_venv else "-r", spark_req]
            if not is_venv:
                cmd = ["uv", "pip", "install", "--system", "-r", spark_req]
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
            cmd = ["uv", "pip", "install", "--python" if is_venv else "--system", venv_python if is_venv else "-r", vhs_req]
            if not is_venv:
                cmd = ["uv", "pip", "install", "--system", "-r", vhs_req]
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            while True:
                line = proc.stdout.readline()
                if not line: break
                add_node_log(line.strip())
            proc.wait()
            
        # Дополнительные зависимости
        add_node_log("Устанавливаем дополнительные пакеты (peft, einops, fal-client)...")
        cmd_extra = ["uv", "pip", "install", "--python" if is_venv else "--system", venv_python if is_venv else "peft>=0.9.0", "einops>=0.6.0", "fal-client", "requests"]
        if not is_venv:
            cmd_extra = ["uv", "pip", "install", "--system", "peft>=0.9.0", "einops>=0.6.0", "fal-client", "requests"]
        subprocess.run(cmd_extra, check=True)
        
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
        add_node_log("Перезапустите ComfyUI через вкладку Управление.")

    threading.Thread(target=worker, daemon=True).start()
    return "Процесс установки SparkVSR и VideoHelperSuite запущен в фоновом режиме. Логи смотрите ниже."

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

# Скачивание моделей
def run_download_model(url, folder, filename):
    if not url.strip():
        return "Пожалуйста, введите URL модели."
    
    if not os.path.exists(DOWNLOADER_SCRIPT):
        return f"Загрузчик не найден: {DOWNLOADER_SCRIPT}"
    
    def worker():
        add_download_log(f"--- Старт загрузки: {time.strftime('%H:%M:%S')} ---")
        add_download_log(f"Ссылка: {url}")
        
        cmd = [DOWNLOADER_SCRIPT, "--download"]
        if folder and folder != "Автоопределение (Auto-detect)":
            cmd += ["--folder", folder]
        
        # Запуск процесса
        env = os.environ.copy()
        env["COMFY_DIR"] = COMFY_DIR
        
        # Если пользователь ввел кастомное имя
        proc = subprocess.Popen(
            cmd,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )
        
        # Нам нужно передать имя файла в stdin, если загрузчик его запрашивает
        # Загрузчик запрашивает:
        # 1) Имя файла [default]: 
        # 2) Подтверждение (если автоопределение не сработало или выбор ручной)
        # Мы пишем интерактивный мост для неинтерактивного скрипта:
        
        has_sent_filename = False
        while True:
            line = proc.stdout.readline()
            if not line:
                break
            
            clean_line = line.strip()
            add_download_log(clean_line)
            
            # Обнаружение запроса имени файла
            if "Имя файла [" in line or "Имя файла:" in line:
                if not has_sent_filename:
                    val = filename.strip() + "\n" if filename.strip() else "\n"
                    proc.stdin.write(val)
                    proc.stdin.flush()
                    has_sent_filename = True
            
            # Обнаружение запросов выбора папок или согласия на перезапись
            elif "Номер папки:" in line:
                proc.stdin.write("\n") # по умолчанию
                proc.stdin.flush()
            elif "Перезаписать?" in line or "Продолжить?" in line:
                proc.stdin.write("y\n")
                proc.stdin.flush()
            elif "принять, m — выбрать" in line:
                proc.stdin.write("\n") # принять автоопределение
                proc.stdin.flush()
                
        proc.wait()
        add_download_log(f"--- Загрузка завершена с кодом {proc.returncode} ---")
        
    threading.Thread(target=worker, daemon=True).start()
    return "Загрузка запущена в фоновом режиме. Перейдите к логу ниже для отслеживания."

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
                        value="--listen 0.0.0.0 --port 8188 --highvram"
                    )
                    
                    with gr.Row():
                        btn_start = gr.Button("▶️ Запустить", variant="primary")
                        btn_stop = gr.Button("⏹️ Остановить", variant="stop")
                    
                    with gr.Row():
                        btn_install = gr.Button("🚀 Установить ComfyUI с нуля", variant="secondary")
                        btn_refresh = gr.Button("🔄 Обновить статус")
                    
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
                interactive=False
            )
            
            selected_file_name = gr.Textbox(label="Выбранный файл", interactive=False)
            btn_delete_file = gr.Button("❌ Удалить выбранный файл", variant="stop")
            file_manager_status = gr.Markdown("")

        # Вкладка 4: Установка кастомных нод
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
            
            node_install_status = gr.Markdown("")
            
            gr.Markdown("### 📋 Лог установки нод")
            btn_refresh_node_log = gr.Button("🔄 Обновить лог ноды")
            node_log_output = gr.TextArea(
                label="Лог консоли установки нод",
                value="Лог пуст",
                interactive=False,
                lines=15
            )

    # Таймер для автообновления статуса и ресурсов
    def periodic_status_update():
        status, pid = get_comfy_status()
        stats = get_system_stats()
        return status, pid, stats

    # Привязка логики к кнопкам Dashboard
    btn_start.click(start_comfy, inputs=[comfy_args], outputs=[status_indicator])
    btn_stop.click(stop_comfy, outputs=[status_indicator])
    btn_install.click(run_installation, outputs=[status_indicator])
    
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
    def select_file_from_table(evt: gr.SelectData):
        # Таблица возвращает список списков, evt.index содержит [строка, колонка]
        # Нам нужно имя файла, которое находится в первой колонке выбранной строки
        return evt.value
        
    model_files_table.select(select_file_from_table, outputs=[selected_file_name])
    
    btn_delete_file.click(
        delete_model_file, 
        inputs=[folder_select, selected_file_name], 
        outputs=[file_manager_status, model_files_table]
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
    btn_refresh_node_log.click(get_node_logs, outputs=[node_log_output])
    
    # Инициализация при загрузке страницы
    demo.load(
        fn=refresh_dashboard, 
        inputs=[lines_slider], 
        outputs=[status_indicator, pid_indicator, system_stats_box, log_output]
    )

if __name__ == "__main__":
    # Запуск Gradio. Порт 7860 по умолчанию.
    # Флаг share=True не рекомендуется запускать без пароля на публичных подах,
    # но bind на 0.0.0.0 позволяет открыть веб-интерфейс через прокси-порт RunPod.
    demo.launch(server_name="0.0.0.0", server_port=7860)
