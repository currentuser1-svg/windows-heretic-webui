# One-button installer: llama.cpp (CUDA) + heretic GGUF + Open WebUI. Safe to rerun.
param(
    [ValidateSet('', 'docker', 'native')][string]$Mode = '',
    [string]$Quant = '',
    [switch]$Update,
    [switch]$NoStart
)
. (Join-Path $PSScriptRoot 'common.ps1')

if ($Mode) { $Cfg.WebUIMode = $Mode }
if ($Quant) {
    $Cfg.ModelFile = $Cfg.ModelFile -replace '(Q\d_K_[SML]|Q\d_0|BF16|F16)(?=\.gguf$)', $Quant
}

# ====================================================================== preflight
function Test-Preflight {
    Say 'Preflight'
    if ([Environment]::OSVersion.Version.Build -lt 19041) { Die 'Windows 10 2004+ / Windows 11 required' }
    $null = Get-CurlExe
    if (-not (Test-Path (Join-Path $env:SystemRoot 'System32\tar.exe'))) { Die 'tar.exe missing in System32' }

    $drive = (Split-Path -Qualifier $Root).TrimEnd(':')
    $free  = (Get-PSDrive -Name $drive).Free
    Ok ("Free on {0}: {1:N1} GB" -f $drive, ($free / 1GB))
    if ($free -lt 15GB) { Warn 'Less than 15 GB free. Model + llama.cpp + Open WebUI need about 12-15 GB.' }

    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        $gpu = Invoke-Native { & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>$null }
        Ok "GPU: $gpu"
        $drv = ($gpu -split ',')[-1].Trim()
        if ($drv -match '^(\d+)') { if ([int]$Matches[1] -lt 551) { Warn "Driver $drv is old for CUDA 12.4 build. Update NVIDIA driver (551+)." } }
    } else {
        Warn 'nvidia-smi not found. No NVIDIA driver? llama.cpp will run on CPU (slow).'
    }
}

# ====================================================================== deploy app copy
function Deploy-App {
    Ensure-Dir $Root
    foreach ($d in @($Paths.Models, $Paths.ModelDir, $Paths.Logs, $Paths.Downloads, $Paths.Run, $Paths.WebUI)) { Ensure-Dir $d }
    $src = (Resolve-Path $AppRoot).Path.TrimEnd('\')
    $dst = $Paths.App.TrimEnd('\')
    if ($src -ieq $dst) { return }
    Say "Copying scripts to $dst"
    Ensure-Dir $dst
    foreach ($item in @('scripts', 'webui')) {
        Ensure-Dir (Join-Path $dst $item)
        Copy-Item -Path (Join-Path $src "$item\*") -Destination (Join-Path $dst $item) -Recurse -Force
    }
    Copy-Item (Join-Path $src '*.bat') $dst -Force
    Copy-Item (Join-Path $src 'config.psd1') $dst -Force
    $lc = Join-Path $src 'config.local.psd1'
    if (Test-Path $lc) { Copy-Item $lc $dst -Force }
}

# ====================================================================== llama.cpp
function Install-LlamaCpp {
    Say 'llama.cpp: checking release'
    $api = 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest'
    if ($Cfg.LlamaCppTag -ne 'latest') { $api = "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$($Cfg.LlamaCppTag)" }
    try {
        $rel = Invoke-RestMethod -Uri $api -UseBasicParsing -Headers @{ 'User-Agent' = 'windows-heretic-webui'; 'Accept' = 'application/vnd.github+json' }
    } catch {
        if (Test-Path (Join-Path $Paths.Bin 'llama-server.exe')) { Warn "GitHub API unreachable, keeping installed llama.cpp ($($_.Exception.Message))"; return }
        Die "GitHub API unreachable: $($_.Exception.Message)"
    }
    $tag = $rel.tag_name
    $verFile = Join-Path $Paths.Bin 'VERSION.txt'
    if ((Test-Path (Join-Path $Paths.Bin 'llama-server.exe')) -and (Test-Path $verFile) -and ((Get-Content $verFile -Raw).Trim() -eq $tag)) {
        Ok "llama.cpp $tag already installed"; return
    }
    $main   = $rel.assets | Where-Object { $_.name -match $Cfg.LlamaCppAsset } | Select-Object -First 1
    $cudart = $rel.assets | Where-Object { $_.name -match $Cfg.CudartAsset }   | Select-Object -First 1
    if (-not $main) { Die "No asset matching $($Cfg.LlamaCppAsset) in $tag" }

    $dl = Join-Path $Paths.Downloads $tag
    $files = @()
    foreach ($a in @($main, $cudart)) {
        if (-not $a) { Warn 'cudart package not found, assuming CUDA runtime is installed system-wide'; continue }
        $sha = $null
        if ($a.digest -and ($a.digest -match '^sha256:([0-9a-f]{64})$')) { $sha = $Matches[1] }
        $dest = Join-Path $dl $a.name
        Invoke-Download $a.browser_download_url $dest $sha @() ([int64]$a.size)
        $files += $dest
    }

    & (Join-Path $PSScriptRoot 'stop.ps1') -LlamaOnly | Out-Null

    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    $tmp = "$($Paths.Bin).new"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Ensure-Dir $tmp
    & $tar -xf $files[0] -C $tmp
    if ($LASTEXITCODE -ne 0) { Die 'Failed to unpack llama.cpp' }
    $srv = Get-ChildItem -Path $tmp -Recurse -Filter 'llama-server.exe' | Select-Object -First 1
    if (-not $srv) { Die 'llama-server.exe not found in the archive' }
    $srvDir = $srv.DirectoryName
    if ($files.Count -gt 1) {
        & $tar -xf $files[1] -C $srvDir
        if ($LASTEXITCODE -ne 0) { Die 'Failed to unpack cudart' }
    }
    if (Test-Path $Paths.Bin) { Remove-Item $Paths.Bin -Recurse -Force }
    Move-Item $srvDir $Paths.Bin
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Set-Content -Path $verFile -Value $tag -Encoding ASCII
    Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue
    Ok "llama.cpp $tag installed to $($Paths.Bin)"

    $dev = Invoke-Native { & (Join-Path $Paths.Bin 'llama-server.exe') --list-devices 2>&1 } | Out-String
    if ($dev -match 'CUDA0') { Ok ('CUDA device: ' + (($dev -split "`n" | Where-Object { $_ -match 'CUDA0' }) -join '').Trim()) }
    else { Warn "No CUDA device visible to llama.cpp. Output:`n$dev" }
}

# ====================================================================== model
function Install-Model {
    $auth = @(Get-HfAuthArgs)
    $base = "https://huggingface.co/$($Cfg.ModelRepo)/resolve/main"
    $list = @($Cfg.ModelFile)
    if ($Cfg.MmprojFile) { $list += $Cfg.MmprojFile }
    foreach ($f in $list) {
        $url  = "$base/$f"
        $dest = Join-Path $Paths.ModelDir $f
        $meta = Get-HfFileMeta $url $auth
        switch -Regex ($meta.Status) {
            '^(401|403)$' { Die "HF says $($meta.Status) for $f. Gated repo? Put token into $($Paths.Secrets)\hf_token.txt" }
            '^404$'       { Die "HF: $f not found in $($Cfg.ModelRepo). Check config.psd1" }
            '^$'          { Warn 'HF HEAD failed, downloading without hash check' }
        }
        if (-not $meta.Sha -and $meta.Status) { Warn "No sha256 from HF for $f, size check only" }
        if ($meta.Size -gt 0) { Say ("{0}: {1:N2} GB" -f $f, ($meta.Size / 1GB)) }
        Invoke-Download $url $dest $meta.Sha $auth $meta.Size
    }
    $hdr = Join-Path $Paths.Secrets 'hf_header.txt'
    if (Test-Path $hdr) { Remove-Item $hdr -Force }
}

# ====================================================================== Open WebUI: docker
function Install-WebUIDocker {
    Add-DockerToPath
    $ddExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (-not (Test-Path $ddExe) -and -not (Test-DockerUp)) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Die 'winget not found. Install "App Installer" from Microsoft Store.' }
        $needReboot = $false
        Invoke-Native { & wsl.exe --status *> $null }
        if ($LASTEXITCODE -ne 0) {
            Say 'Installing WSL2 (UAC prompt)'
            Start-Process -FilePath 'wsl.exe' -ArgumentList '--install --no-distribution' -Verb RunAs -Wait
            $needReboot = $true
        }
        Say 'Installing Docker Desktop via winget (UAC prompt)'
        & winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements --disable-interactivity
        if (-not (Test-Path $ddExe)) { Die 'Docker Desktop install failed' }
        if ($needReboot) {
            Warn 'REBOOT NOW, then run install.bat again. It continues from where it stopped.'
            Warn 'After reboot Docker Desktop asks to accept its license once.'
            exit 0
        }
    }
    if (-not (Start-DockerDesktop)) {
        Die 'Docker engine does not answer. Reboot or open Docker Desktop, accept license, wait for "Engine running", then run install.bat again.'
    }

    Copy-Item (Join-Path $Paths.App 'webui\docker-compose.yml') (Join-Path $Paths.WebUI 'docker-compose.yml') -Force
    $envFile = Join-Path $Paths.WebUI '.env'
    $envText = @(
        'COMPOSE_PROJECT_NAME=heretic-webui'
        "OPENWEBUI_IMAGE=$($Cfg.WebUIImage)"
        "WEBUI_PORT=$($Cfg.WebUIPort)"
        "LLAMA_PORT=$($Cfg.LlamaPort)"
        "LLAMA_API_KEY=$(Get-Secret 'llama_api_key')"
        "WEBUI_SECRET_KEY=$(Get-Secret 'webui_secret_key')"
    ) -join "`n"
    [IO.File]::WriteAllText($envFile, $envText + "`n")
    Protect-File $envFile

    Say 'Pulling Open WebUI image'
    $cf = Join-Path $Paths.WebUI 'docker-compose.yml'
    Invoke-Native { & docker compose -f $cf --env-file $envFile pull }
    if ($LASTEXITCODE -ne 0) { Die 'docker compose pull failed' }
    if ($Update) { Invoke-Native { & docker compose -f $cf --env-file $envFile up -d --remove-orphans } }
    Ok 'Open WebUI (docker) ready'
}

# ====================================================================== Open WebUI: native
function Install-WebUINative {
    Add-UvToPath
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Die 'winget not found. Install "App Installer" from Microsoft Store.' }
        Say 'Installing uv via winget'
        & winget install -e --id astral-sh.uv --accept-package-agreements --accept-source-agreements --disable-interactivity
        Add-UvToPath
        if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { Die 'uv not in PATH. Open a new terminal and run install.bat again.' }
    }
    $env:UV_NO_PROGRESS = '1'
    Ensure-Dir $Paths.WebUIData
    Protect-Path $Paths.WebUIData
    if ($Update) {
        Say 'Upgrading Open WebUI'
        Invoke-Native { & uv tool upgrade open-webui }
    }
    if (-not (Get-Command open-webui -ErrorAction SilentlyContinue)) {
        Say 'Installing Open WebUI (Python 3.11 via uv, several GB, takes a while)'
        Invoke-Native { & uv tool install --python 3.11 open-webui }
        if ($LASTEXITCODE -ne 0) { Die 'uv tool install open-webui failed' }
        Add-UvToPath
    }
    Ok 'Open WebUI (native) ready'
}

# ====================================================================== shortcuts
function New-Shortcuts {
    if (-not $Cfg.DesktopShortcuts) { return }
    $sh = New-Object -ComObject WScript.Shell
    $desk = [Environment]::GetFolderPath('Desktop')
    foreach ($n in @('start', 'stop')) {
        $lnk = $sh.CreateShortcut((Join-Path $desk "Heretic WebUI - $n.lnk"))
        $lnk.TargetPath = Join-Path $Paths.App "$n.bat"
        $lnk.WorkingDirectory = $Paths.App
        $lnk.Save()
    }
    Ok 'Desktop shortcuts created'
}

# ====================================================================== main
Test-Preflight
Deploy-App
Install-LlamaCpp
Install-Model
$null = Get-SecretFile 'llama_api_key'
$null = Get-SecretFile 'webui_secret_key'

Save-State @{
    Mode       = $Cfg.WebUIMode
    LlamaDir   = $Paths.Bin
    ModelPath  = (Join-Path $Paths.ModelDir $Cfg.ModelFile)
    MmprojPath = $(if ($Cfg.MmprojFile) { Join-Path $Paths.ModelDir $Cfg.MmprojFile } else { '' })
}

if ($Cfg.WebUIMode -eq 'docker') { Install-WebUIDocker } else { Install-WebUINative }
New-Shortcuts

Ok 'Install done'
if (-not $NoStart) { & (Join-Path $Paths.App 'scripts\start.ps1'); exit $LASTEXITCODE }
