$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Windows.Forms

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$zip = Join-Path $here 'app.zip'
$dest = Join-Path $env:LOCALAPPDATA 'ZebraPrinter'
$exe = Join-Path $dest 'zebra_printer_agent.exe'

if (-not (Test-Path $zip)) {
  [System.Windows.Forms.MessageBox]::Show('The setup package is incomplete.', 'Zebra Printer')
  exit 1
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null

Get-Process zebra_printer_agent -ErrorAction SilentlyContinue | ForEach-Object {
  $path = $_.Path
  if ($path -and $path.StartsWith($dest, [System.StringComparison]::OrdinalIgnoreCase)) {
    Stop-Process -Id $_.Id -Force
  }
}

if (Test-Path $dest) {
  Get-ChildItem $dest -Force | Remove-Item -Recurse -Force
}
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)

$shell = New-Object -ComObject WScript.Shell
foreach ($folder in @(
  [Environment]::GetFolderPath('Desktop'),
  (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
)) {
  $link = $shell.CreateShortcut((Join-Path $folder 'Zebra Printer.lnk'))
  $link.TargetPath = $exe
  $link.WorkingDirectory = $dest
  $link.Description = 'Zebra Printer'
  $link.Save()
}

$already = Get-Process zebra_printer_agent -ErrorAction SilentlyContinue
if (-not $already) {
  Start-Process -FilePath $exe -WorkingDirectory $dest
  $message = 'Zebra Printer is installed and open.'
} else {
  $message = 'Zebra Printer is installed. Close the copy that is already open, then use the desktop shortcut.'
}
[System.Windows.Forms.MessageBox]::Show($message, 'Zebra Printer') | Out-Null
