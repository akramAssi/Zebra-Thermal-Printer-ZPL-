$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$agent = Split-Path -Parent $PSScriptRoot
$release = Join-Path $agent 'build\windows\x64\runner\Release'
$built = Join-Path $release 'zebra_printer_agent.exe'
if (-not (Test-Path $built)) {
  throw "Release build not found: $built"
}
if (-not (Test-Path (Join-Path $release 'driver\zdesigner.inf'))) {
  throw 'The printer driver is missing from the release folder.'
}

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
  throw 'The .NET compiler was not found.'
}

$stage = Join-Path $PSScriptRoot 'stage'
$dist = Join-Path $agent 'dist'
New-Item -ItemType Directory -Force -Path $stage, $dist | Out-Null

$zip = Join-Path $stage 'app.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($release, $zip)

$stub = Join-Path $stage 'stub.exe'
& $csc /nologo /target:winexe /r:System.IO.Compression.FileSystem.dll /out:$stub (Join-Path $PSScriptRoot 'Setup.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $stub)) {
  throw 'The setup program did not compile.'
}

$setup = Join-Path $dist 'ZebraPrinterSetup.exe'
if (Test-Path $setup) { Remove-Item $setup -Force }
$marker = [Text.Encoding]::ASCII.GetBytes('ZEBRAZIP1')
$out = [IO.File]::Create($setup)
try {
  $stubBytes = [IO.File]::ReadAllBytes($stub)
  $out.Write($stubBytes, 0, $stubBytes.Length)
  $out.Write($marker, 0, $marker.Length)
  $zipStream = [IO.File]::OpenRead($zip)
  try { $zipStream.CopyTo($out) } finally { $zipStream.Dispose() }
} finally {
  $out.Dispose()
}

Write-Output $setup
Write-Output ((Get-Item $setup).Length)
