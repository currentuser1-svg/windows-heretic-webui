# windows-heretic-webui

Локальный чат на Windows 11 в одну кнопку:

- **llama.cpp** (официальный релиз с CUDA 12.4) крутится нативно на винде, слушает только `127.0.0.1`
- **Gemma 4 E4B heretic** (GGUF с Hugging Face) + vision-проектор, так что картинки в чат тоже можно кидать
- **Open WebUI** в Docker Desktop (по умолчанию) или нативно через `uv` без Docker

Все на одном компе, наружу ничего не торчит, телеметрия Open WebUI выключена, ключи генерятся локально.

## Требования

- Windows 11 (или Windows 10 2004+), winget
- NVIDIA с 8 ГБ VRAM и драйвер 551+ (GTX 10xx тоже ок: сборка CUDA 12.4 поддерживает Pascal, а сборки CUDA 13 уже нет)
- ~15 ГБ свободного места на диске C:
- Для docker-режима: включенная виртуализация в BIOS (WSL2)

## Быстрый старт

PowerShell, обычный (не админ), копипаст целиком:

```powershell
cd $env:USERPROFILE\Downloads; curl.exe -L -o whw.zip https://github.com/currentuser1-svg/windows-heretic-webui/archive/refs/heads/main.zip; tar -xf whw.zip; .\windows-heretic-webui-main\install.bat
```

Или через git:

```powershell
git clone https://github.com/currentuser1-svg/windows-heretic-webui $env:USERPROFILE\windows-heretic-webui; & $env:USERPROFILE\windows-heretic-webui\install.bat
```

Если Docker Desktop еще не стоял: скрипт поставит WSL2 и Docker Desktop (будут UAC-запросы), попросит перезагрузиться. После ребута один раз открой Docker Desktop, прими лицензию и снова запусти `install.bat`, он продолжит с того же места.

В конце откроется `http://127.0.0.1:3000`. Первый зарегистрированный пользователь становится админом, регайся сразу.

## Что делает install.bat

1. Проверки: свободное место, `nvidia-smi`, версия драйвера
2. Копирует скрипты в `C:\llama\app` (папку с репой потом можно удалить)
3. Через GitHub API берет последний релиз llama.cpp, качает `llama-bXXXX-bin-win-cuda-12.4-x64.zip` и `cudart-llama-bin-win-cuda-12.4-x64.zip` curl'ом, сверяет SHA256 из API, распаковывает в `C:\llama\llama.cpp`, проверяет что видна `CUDA0`
4. Качает модель и mmproj curl'ом с докачкой (`-C -`) и ретраями, SHA256 сверяет с тем, что отдает Hugging Face (`x-linked-etag`)
5. Генерит ключи: API-ключ для llama-server и `WEBUI_SECRET_KEY`
6. Docker-режим: ставит WSL2 + Docker Desktop через winget (если нет), кладет `docker-compose.yml` и `.env`, тянет образ. Native-режим: ставит `uv`, через него Python 3.11 и `open-webui`
7. Ярлыки start/stop на рабочем столе и сразу запуск

Повторный запуск ничего не качает заново: проверяет версию и хэши и пропускает готовое. Оборвалась закачка, просто запусти еще раз.

## Команды

| Файл | Что делает |
|---|---|
| `install.bat` | установка / докачка / починка |
| `start.bat` | поднимает llama-server (скрыто, логи в `C:\llama\logs`) и Open WebUI, открывает браузер |
| `stop.bat` | гасит все, модель и чаты остаются |
| `update.bat` | свежий llama.cpp + свежий образ Open WebUI (или `uv tool upgrade`) |

Параметры install.bat:

```bat
install.bat -Mode native        :: без Docker, Open WebUI через uv
install.bat -Quant Q5_K_M       :: другой квант
install.bat -NoStart            :: только поставить, не запускать
```

## Модель и VRAM 8 ГБ

По умолчанию: [llmfan46/gemma-4-E4B-it-ultra-uncensored-heretic-GGUF](https://huggingface.co/llmfan46/gemma-4-E4B-it-ultra-uncensored-heretic-GGUF), Apache-2.0, Heretic v1.2.0 (ARA), отказы 3/100 против 99/100 у оригинала.

| Квант | Файл | Для 8 ГБ |
|---|---|---|
| Q4_K_M | 5.34 GB | дефолт, остается место под контекст 16k и картинки |
| Q5_K_M | 5.76 GB | норм, если винда не жрет много видеопамяти |
| Q6_K | 6.22 GB | впритык, ставь `ContextSize = 8192` или выключи mmproj |
| Q8_0 | 8.03 GB | не влезет целиком |

После старта `start.bat` печатает, сколько реально заняли веса, KV-кэш и compute-буфер на `CUDA0`. Ориентируйся на это.

Любую другую heretic/abliterated GGUF можно подставить в `config.psd1` (`ModelRepo`, `ModelFile`, `MmprojFile`). Для закрытых (gated) репо положи токен в `C:\llama\secrets\hf_token.txt` или в переменную `HF_TOKEN`. Токен передается curl'у через header-файл, в списке процессов его не видно.

Thinking-режим Gemma 4: в Open WebUI добавь в начало системного промпта `<|think|>`.

## Настройки

Все в `config.psd1` в папке репы, потом снова `install.bat`. Основное:

```powershell
InstallRoot = 'C:\llama'
WebUIMode   = 'docker'        # или 'native'
ModelFile   = '...Q4_K_M.gguf'
ContextSize = 16384
GpuLayers   = 'all'           # для старых сборок llama.cpp ставь 99
LlamaExtraArgs = @('-ctk','q8_0','-ctv','q8_0')   # пример: квантованный KV-кэш, больше контекста
```

Свои правки, которые не должны попасть в git, клади в `config.local.psd1` рядом (перекрывает ключи из основного).

## Где что лежит

```
C:\llama\
  app\              скрипты (копия репы)
  llama.cpp\        llama-server.exe, cuda dll, VERSION.txt
  models\gemma4-e4b-heretic\   *.gguf (+ .sha256 метки)
  webui\            docker-compose.yml, .env  (native: data\)
  secrets\          llama_api_key.txt, webui_secret_key.txt
  logs\  run\  state.json
```

## Безопасность и приватность

- llama-server: `--host 127.0.0.1` + `--api-key-file` (ключ не светится в командной строке процесса)
- Open WebUI: порт проброшен только на `127.0.0.1:3000`, из локалки не достать
- `secrets\` и `webui\.env`: ACL сброшен, доступ только у тебя, SYSTEM и Administrators (по SID, работает на русской винде)
- Отключены `ANONYMIZED_TELEMETRY`, `SCARF_NO_ANALYTICS`, `DO_NOT_TRACK`, `HF_HUB_DISABLE_TELEMETRY`, community sharing, проверка обновлений, Ollama API
- Скачанное сверяется по SHA256 (GitHub digest и HF etag)
- Docker Desktop сам по себе шлет статистику: Settings > General > выключи "Send usage statistics"
- При первом старте Open WebUI тянет с Hugging Face модель эмбеддингов для RAG, это нормально. Когда все скачалось, можно добавить в compose `OFFLINE_MODE: "true"`

Нужен доступ с телефона? Не открывай порт в локалку, лучше Tailscale Serve поверх `127.0.0.1:3000`:

```powershell
tailscale serve --bg 3000
```

## Автозапуск при входе

```powershell
schtasks /Create /TN "HereticWebUI" /SC ONLOGON /RL LIMITED /F /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\llama\app\scripts\start.ps1 -NoBrowser"
```

Убрать: `schtasks /Delete /TN "HereticWebUI" /F`

## Проблемы

**Контейнер не видит llama-server** (start.bat пишет предупреждение). Docker Desktop проксирует `host.docker.internal` на localhost хоста, обычно работает из коробки. Проверка:

```powershell
docker exec open-webui curl -s http://host.docker.internal:8080/health
```

Если пусто, глянь что WSL в режиме по умолчанию (не `networkingMode=mirrored` с кривыми настройками) и перезапусти Docker Desktop.

**llama-server падает при старте**: скорее всего не хватило VRAM. Смотри `C:\llama\logs\llama-server.err.log`, уменьши `ContextSize` или квант.

**Модели нет в списке Open WebUI**: Admin Panel > Settings > Connections, адрес `http://host.docker.internal:8080/v1` (native: `http://127.0.0.1:8080/v1`), ключ из `C:\llama\secrets\llama_api_key.txt`. Open WebUI запоминает подключение в своей базе при первом старте, поэтому если удалял `secrets\`, ключ надо обновить там руками.

**Логи**:

```powershell
Get-Content C:\llama\logs\llama-server.err.log -Tail 50 -Wait
docker logs -f open-webui
```

## Удаление

```powershell
C:\llama\app\stop.bat
docker compose -f C:\llama\webui\docker-compose.yml --env-file C:\llama\webui\.env down -v   # -v сносит и чаты
uv tool uninstall open-webui                                                                  # если был native
Remove-Item C:\llama -Recurse -Force
Remove-Item "$([Environment]::GetFolderPath('Desktop'))\Heretic WebUI - *.lnk"
```

Docker Desktop и WSL сносятся через "Установленные приложения", если больше не нужны.
