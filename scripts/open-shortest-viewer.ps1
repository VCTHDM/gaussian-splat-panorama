$ErrorActionPreference = 'Stop'
$resultDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'jobs/shortest-pilot/results'
$address = 'http://127.0.0.1:8765/viewer/'
try { $null = Invoke-WebRequest -UseBasicParsing -Uri $address -TimeoutSec 2 } catch {
    Start-Process -FilePath 'C:\Users\Administrator\AppData\Local\Programs\Python\Python312\python.exe' -ArgumentList @('-m','http.server','8765','--bind','127.0.0.1') -WorkingDirectory $resultDir -WindowStyle Hidden
    Start-Sleep -Seconds 1
}
Start-Process $address
