$ErrorActionPreference = 'Stop'

$agent = Split-Path -Parent $PSScriptRoot
Set-Location $agent

# The running app locks zebra_bluetooth_printer_plugin.dll and the build fails.
Get-Process zebra_printer_agent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

flutter build windows
if ($LASTEXITCODE -ne 0) {
  throw 'flutter build windows failed.'
}

& (Join-Path $PSScriptRoot 'make-setup.ps1')
