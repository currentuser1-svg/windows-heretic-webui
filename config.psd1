@{
    # Where everything lives. No spaces recommended.
    InstallRoot      = 'C:\llama'

    # Open WebUI mode: 'docker' (Docker Desktop + compose) or 'native' (uv + Python 3.11, no Docker)
    WebUIMode        = 'docker'

    # ---------- llama.cpp ----------
    # 'latest' or a fixed tag like 'b10455'
    LlamaCppTag      = 'latest'
    # CUDA 12.4 build works on GTX 10xx (Pascal) and newer. CUDA 13 builds dropped Pascal.
    LlamaCppAsset    = '^llama-b\d+-bin-win-cuda-12\.4-x64\.zip$'
    CudartAsset      = '^cudart-llama-bin-win-cuda-12\.4-x64\.zip$'

    # ---------- model (Hugging Face) ----------
    ModelRepo        = 'llmfan46/gemma-4-E4B-it-ultra-uncensored-heretic-GGUF'
    # Quants in this repo: Q4_K_M 5.34GB | Q5_K_S 5.69GB | Q5_K_M 5.76GB | Q6_K 6.22GB | Q8_0 8.03GB
    ModelFile        = 'gemma-4-E4B-it-ultra-uncensored-heretic-Q4_K_M.gguf'
    # Vision projector (pictures in chat). Empty string = text only, saves VRAM.
    MmprojFile       = 'gemma-4-E4B-it-mmproj-BF16.gguf'
    ModelFolder      = 'gemma4-e4b-heretic'
    # Name shown in Open WebUI model list instead of the file path
    ModelAlias       = 'gemma4-e4b-heretic'

    # ---------- llama-server ----------
    LlamaPort        = 8080
    GpuLayers        = 'all'
    ContextSize      = 16384
    # Gemma 4 recommended sampling
    Temperature      = '1.0'
    TopP             = '0.95'
    TopK             = 64
    # Any extra llama-server flags, e.g. @('-ctk','q8_0','-ctv','q8_0')
    LlamaExtraArgs   = @()

    # ---------- Open WebUI ----------
    WebUIPort        = 3000
    WebUIImage       = 'ghcr.io/open-webui/open-webui:main'

    # Open browser after start.bat
    OpenBrowser      = $true
    # Create desktop shortcuts for start/stop
    DesktopShortcuts = $true
}
