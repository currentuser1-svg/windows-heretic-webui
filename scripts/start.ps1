# Start llama-server (hidden, localhost only) and Open WebUI, then open the browser.
param([switch]$NoBrowser)
. (Join-Path $PSScriptRoot 'common.ps1')

$st = Get-State
if (-not $st) { Die 'Not installed yet. Run install.bat' }
Ensure-Dir $Paths.Logs; Ensure-Dir $Paths.Run

# ---------------------------------------------------------------- llama-server
$exe    = Join-Path $st.LlamaDir 'llama-server.exe'
$health = "http://127.0.0.1:$($Cfg.LlamaPort)/health"
if (-not (Test-Path $exe))          { Die "Missing $exe. Run install.bat" }
if (-not (Test-Path $st.ModelPath)) { Die "Missing $($st.ModelPath). Run install.bat" }

if (Test-HttpOk $health) {
    Ok 'llama-server already running'
} else {
    $a = @('-m', $st.ModelPath)
    if ($st.MmprojPath -and (Test-Path $st.MmprojPath)) { $a += @('--mmproj', $st.MmprojPath) }
    $a += @(
        '--host', '127.0.0.1', '--port', $Cfg.LlamaPort,
        '--api-key-file', (Get-SecretFile 'llama_api_key'),
        '-a', $Cfg.ModelAlias,
        '-ngl', $Cfg.GpuLayers,
        '-c', $Cfg.ContextSize,
        '--jinja',
        '--temp', $Cfg.Temperature, '--top-p', $Cfg.TopP, '--top-k', $Cfg.TopK
    )
    $a += @($Cfg.LlamaExtraArgs)
    $argStr = ($a | ForEach-Object { Quote-Arg $_ }) -join ' '
    $out = Join-Path $Paths.Logs 'llama-server.out.log'
    $err = Join-Path $Paths.Logs 'llama-server.err.log'

    Say "Starting llama-server: $($Cfg.ModelAlias), ctx $($Cfg.ContextSize), port $($Cfg.LlamaPort)"
    $p = Start-Process -FilePath $exe -ArgumentList $argStr -WorkingDirectory $st.LlamaDir `
            -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    Set-Content -Path (Join-Path $Paths.Run 'llama-server.pid') -Value $p.Id -Encoding ASCII

    $t = 0
    while (-not (Test-HttpOk $health)) {
        Start-Sleep -Seconds 2; $t += 2
        if ($p.HasExited) {
            Write-Host (Get-Content $err -Tail 25 -ErrorAction SilentlyContinue | Out-String)
            Die "llama-server exited (code $($p.ExitCode)). Log: $err. Out of VRAM? Lower ContextSize or pick Q4_K_M."
        }
        if ($t -ge 240) { Die "llama-server did not get ready in 240s. Log: $err" }
    }
    Ok 'llama-server ready'
    $vram = Select-String -Path $err -Pattern 'CUDA0.*(model buffer|KV buffer|compute buffer)' -ErrorAction SilentlyContinue | Select-Object -Last 3
    foreach ($v in $vram) { Write-Host "    $($v.Line.Trim())" }
}

# ---------------------------------------------------------------- Open WebUI
$uiUrl    = "http://127.0.0.1:$($Cfg.WebUIPort)"
$uiHealth = "$uiUrl/health"
$mode     = Get-Mode

if ($mode -eq 'docker') {
    if (-not (Start-DockerDesktop)) { Die 'Docker engine does not answer. Open Docker Desktop and try again.' }
    $cf = Join-Path $Paths.WebUI 'docker-compose.yml'
    $ef = Join-Path $Paths.WebUI '.env'
    Invoke-Native { & docker compose -f $cf --env-file $ef up -d }
    if ($LASTEXITCODE -ne 0) { Die 'docker compose up failed' }
} else {
    if (-not (Test-HttpOk $uiHealth)) {
        Add-UvToPath
        $ow = Get-Command open-webui -ErrorAction SilentlyContinue
        if (-not $ow) { Die 'open-webui not found. Run install.bat -Mode native' }
        $env:DATA_DIR                   = $Paths.WebUIData
        $env:WEBUI_SECRET_KEY           = Get-Secret 'webui_secret_key'
        $env:OPENAI_API_BASE_URL        = "http://127.0.0.1:$($Cfg.LlamaPort)/v1"
        $env:OPENAI_API_KEY             = Get-Secret 'llama_api_key'
        $env:ENABLE_OLLAMA_API          = 'false'
        $env:ANONYMIZED_TELEMETRY       = 'false'
        $env:DO_NOT_TRACK               = 'true'
        $env:SCARF_NO_ANALYTICS         = 'true'
        $env:HF_HUB_DISABLE_TELEMETRY   = '1'
        $env:ENABLE_COMMUNITY_SHARING   = 'false'
        $env:ENABLE_VERSION_UPDATE_CHECK = 'false'
        $env:PYTHONIOENCODING           = 'utf-8'
        $out = Join-Path $Paths.Logs 'open-webui.out.log'
        $err = Join-Path $Paths.Logs 'open-webui.err.log'
        Say 'Starting Open WebUI (native)'
        $p = Start-Process -FilePath $ow.Source -ArgumentList "serve --host 127.0.0.1 --port $($Cfg.WebUIPort)" `
                -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
        Set-Content -Path (Join-Path $Paths.Run 'open-webui.pid') -Value $p.Id -Encoding ASCII
        # secrets out of this process env
        Remove-Item Env:WEBUI_SECRET_KEY, Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
    }
}

Say 'Waiting for Open WebUI (first start downloads embedding models, can take a few minutes)'
$t = 0
while (-not (Test-HttpOk $uiHealth)) {
    Start-Sleep -Seconds 3; $t += 3
    if ($t -ge 600) { Die "Open WebUI did not answer in 10 min. Logs: docker logs open-webui / $($Paths.Logs)" }
}
Ok "Open WebUI: $uiUrl"

if ($mode -eq 'docker') {
    $code = Invoke-Native { & docker exec open-webui curl -s -o /dev/null -w '%{http_code}' "http://host.docker.internal:$($Cfg.LlamaPort)/health" 2>$null }
    if ($code -eq '200') { Ok 'Container sees llama-server' }
    else { Warn "Container can not reach llama-server via host.docker.internal (got '$code'). See README, section Troubleshooting." }
}

if ($Cfg.OpenBrowser -and -not $NoBrowser) { Start-Process $uiUrl }
