# Stop llama-server and Open WebUI. Models and chats stay.
param([switch]$LlamaOnly)
. (Join-Path $PSScriptRoot 'common.ps1')

function Stop-ByPidFile ($name) {
    $pf = Join-Path $Paths.Run "$name.pid"
    if (-not (Test-Path $pf)) { return }
    $procId = (Get-Content $pf -Raw).Trim()
    if ($procId -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
        Invoke-Native { & taskkill.exe /PID $procId /T /F *> $null }
        Ok "Stopped $name (pid $procId)"
    }
    Remove-Item $pf -Force -ErrorAction SilentlyContinue
}

Stop-ByPidFile 'llama-server'
# Also catch instances started by hand from our folder
Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($Paths.Bin, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Stop-Process -Id $_.Id -Force; Ok "Stopped llama-server (pid $($_.Id))" }

if ($LlamaOnly) { return }

if ((Get-Mode) -eq 'docker') {
    $cf = Join-Path $Paths.WebUI 'docker-compose.yml'
    $ef = Join-Path $Paths.WebUI '.env'
    if ((Test-Path $cf) -and (Test-DockerUp)) {
        Invoke-Native { & docker compose -f $cf --env-file $ef stop }
        Ok 'Open WebUI container stopped'
    }
} else {
    Stop-ByPidFile 'open-webui'
}
