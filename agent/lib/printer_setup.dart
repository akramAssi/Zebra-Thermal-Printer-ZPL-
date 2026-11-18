import 'dart:io';

import 'windows_driver.dart';

/// What Windows currently knows about the Zebra, before any permission prompt.
class PrinterMachine {
  const PrinterMachine({
    required this.usbConnected,
    required this.queueReady,
    required this.driverReady,
    required this.driverPackage,
    required this.portReady,
    required this.protectedPrint,
    this.queueName = '',
    this.deviceName = '',
    this.port = '',
    this.printerStatus = '',
    this.workOffline = false,
  });

  final bool usbConnected;
  final bool queueReady;
  final bool driverReady;
  final bool driverPackage;
  final bool portReady;
  final bool protectedPrint;
  final String queueName;
  final String deviceName;
  final String port;

  /// Windows `Get-Printer` status, such as `Normal`, `Offline`, or `PaperOut`.
  final String printerStatus;

  /// Windows "Use Printer Offline" is turned on for this queue.
  final bool workOffline;

  static const empty = PrinterMachine(
    usbConnected: false,
    queueReady: false,
    driverReady: false,
    driverPackage: false,
    portReady: false,
    protectedPrint: false,
  );
}

enum SetupOutcome { ready, needReboot, needInstaller, noDevice, cancelled, failed }

class SetupReport {
  const SetupReport(this.outcome, [this.detail = '']);

  final SetupOutcome outcome;
  final String detail;
}

PrinterMachine parsePrinterMachine(String report) {
  final values = _pairs(report);
  bool flag(String key) => values[key] == '1';
  return PrinterMachine(
    usbConnected: flag('usb'),
    queueReady: flag('queue'),
    driverReady: flag('driver'),
    driverPackage: flag('package'),
    portReady: flag('port_ready'),
    protectedPrint: flag('protected'),
    queueName: values['queue_name'] ?? '',
    deviceName: values['device_name'] ?? '',
    port: values['port'] ?? '',
    printerStatus: values['printer_status'] ?? '',
    workOffline: flag('work_offline'),
  );
}

/// What the window should say about the USB printer.
class PrinterLink {
  const PrinterLink({
    required this.message,
    required this.label,
    required this.detail,
    required this.canPrint,
    required this.showPrinter,
    required this.cableConnected,
  });

  final String message;
  final String label;
  final String detail;
  final bool canPrint;
  final bool showPrinter;
  final bool cableConnected;

  static const unplugged = PrinterLink(
    message: 'The printer is not connected. Plug in the USB cable.',
    label: 'Not connected',
    detail: 'USB cable is unplugged',
    canPrint: false,
    showPrinter: false,
    cableConnected: false,
  );
}

/// USB presence wins over the Windows printer queue. A queue stays installed
/// after the cable is unplugged, so the queue alone is not "ready".
PrinterLink printerLinkFrom(PrinterMachine machine) {
  if (!machine.usbConnected && machine.queueName.isEmpty) {
    return PrinterLink.unplugged;
  }
  if (!machine.usbConnected) {
    return const PrinterLink(
      message: 'The printer is not connected. Plug in the USB cable.',
      label: 'Not connected',
      detail: 'USB cable is unplugged',
      canPrint: false,
      showPrinter: true,
      cableConnected: false,
    );
  }
  if (!machine.queueReady) {
    final name = machine.deviceName.isEmpty ? 'The printer' : machine.deviceName;
    return PrinterLink(
      message: '$name is plugged in.',
      label: 'Plugged in',
      detail: 'USB cable is connected',
      canPrint: false,
      showPrinter: true,
      cableConnected: true,
    );
  }
  if (machine.workOffline) {
    return const PrinterLink(
      message: 'The printer is plugged in, but Windows has it set to offline.',
      label: 'Offline',
      detail: 'USB cable is connected',
      canPrint: false,
      showPrinter: true,
      cableConnected: true,
    );
  }
  switch (machine.printerStatus.toLowerCase()) {
    case 'paperout':
    case 'nopaper':
      return const PrinterLink(
        message: 'The printer is out of paper.',
        label: 'Out of paper',
        detail: 'USB cable is connected',
        canPrint: false,
        showPrinter: true,
        cableConnected: true,
      );
    case 'paperjam':
    case 'jammed':
      return const PrinterLink(
        message: 'The printer has a paper jam.',
        label: 'Paper jam',
        detail: 'USB cable is connected',
        canPrint: false,
        showPrinter: true,
        cableConnected: true,
      );
    case 'dooropen':
      return const PrinterLink(
        message: 'The printer cover is open.',
        label: 'Cover open',
        detail: 'USB cable is connected',
        canPrint: false,
        showPrinter: true,
        cableConnected: true,
      );
    case 'offline':
    case 'notavailable':
    case 'serverunknown':
      return const PrinterLink(
        message: 'The printer is plugged in, but it is turned off or offline.',
        label: 'Offline',
        detail: 'USB cable is connected',
        canPrint: false,
        showPrinter: true,
        cableConnected: true,
      );
    case 'error':
    case 'userintervention':
    case 'outputbinfull':
      return const PrinterLink(
        message: 'The printer needs attention.',
        label: 'Needs attention',
        detail: 'USB cable is connected',
        canPrint: false,
        showPrinter: true,
        cableConnected: true,
      );
    case 'paused':
      return const PrinterLink(
        message: 'The printer is paused in Windows.',
        label: 'Paused',
        detail: 'USB cable is connected',
        canPrint: false,
        showPrinter: true,
        cableConnected: true,
      );
    default:
      return const PrinterLink(
        message: 'Printer is ready.',
        label: 'Ready',
        detail: 'USB cable is connected',
        canPrint: true,
        showPrinter: true,
        cableConnected: true,
      );
  }
}

SetupReport parseSetupReport(String report) {
  final values = _pairs(report);
  final outcome = switch (values['result']) {
    'ready' => SetupOutcome.ready,
    'need_reboot' => SetupOutcome.needReboot,
    'need_installer' => SetupOutcome.needInstaller,
    'no_device' => SetupOutcome.noDevice,
    'cancelled' => SetupOutcome.cancelled,
    _ => SetupOutcome.failed,
  };
  return SetupReport(outcome, values['detail'] ?? '');
}

Map<String, String> _pairs(String report) {
  final values = <String, String>{};
  for (final raw in report.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    final split = line.indexOf('=');
    if (split <= 0) continue;
    values[line.substring(0, split)] = line.substring(split + 1).trim();
  }
  return values;
}

/// Reads the printer, the driver, and Windows protected print mode.
/// Returns null when Windows could not be checked, so the window does not
/// invent a ready state.
Future<PrinterMachine?> readPrinterMachine() async {
  if (!Platform.isWindows) return PrinterMachine.empty;
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      _inspectScript,
    ]);
    final text = '${result.stdout}'.trim();
    if (text.isEmpty) return null;
    return parsePrinterMachine(text);
  } catch (_) {
    return null;
  }
}

/// Turns off protected printing, installs the Zebra driver, and creates the
/// USB printer queue. Windows shows one permission prompt.
Future<SetupReport> preparePrinter() async {
  if (!Platform.isWindows) {
    return const SetupReport(SetupOutcome.failed, 'Windows only');
  }
  final installer = findBundledDriverPackage() ?? '';
  final script = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}zebra-agent-setup.ps1',
  );
  final safeInstaller = installer.replaceAll("'", "''");
  await script.writeAsString(
    _setupScript.replaceAll('__INSTALLER__', safeInstaller),
  );
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-Command',
      """
try {
  \$p = Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', '${script.path.replaceAll("'", "''")}'
  )
  if (\$null -eq \$p) { 'result=cancelled' } else { 'result=ran' }
} catch {
  'result=cancelled'
}
""",
    ]);
    final launch = '${result.stdout}'.toLowerCase();
    if (launch.contains('cancelled')) {
      return const SetupReport(SetupOutcome.cancelled);
    }
    final log = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}zebra-agent-setup.txt',
    );
    if (!log.existsSync()) {
      return const SetupReport(SetupOutcome.failed, 'Setup did not finish.');
    }
    return parseSetupReport(await log.readAsString());
  } catch (error) {
    return SetupReport(SetupOutcome.failed, '$error');
  }
}

Future<void> restartComputerForPrinter() {
  return Process.run('shutdown.exe', [
    '/r',
    '/t',
    '20',
    '/c',
    'Restarting to finish the printer setup. Leave the printer plugged in.',
  ]);
}

const String _inspectScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Bit($value) { if ($value) { '1' } else { '0' } }
$wpp = 0
try { $wpp = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP').WindowsProtectedPrintMode } catch {}
$device = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^USB\\VID_0A5F' } | Select-Object -First 1
$drivers = @(Get-PrinterDriver | Where-Object { $_.Name -match 'ZDesigner|Zebra' })
$queues = @(Get-Printer | Where-Object { $_.Name -match 'ZDesigner|Zebra' -or $_.DriverName -match 'ZDesigner|Zebra' })
$package = @(Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'zdesigner.inf_*')
$port = ''
$list = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\USB Monitor\UsbPortList'
if ($list) {
  foreach ($item in $list.PSObject.Properties) {
    if ($item.Name -like 'PS*') { continue }
    if ("$($item.Value)" -match 'vid_0a5f') { $port = $item.Name; break }
  }
}
$spool = @(Get-PrinterPort | ForEach-Object { $_.Name.TrimEnd(':') })
$portReady = $port -ne '' -and ($spool -contains $port)
$queueName = ''
$printerStatus = ''
$workOffline = $false
if ($queues.Count -gt 0) {
  $queueName = [string]$queues[0].Name
  $printerStatus = [string]$queues[0].PrinterStatus
  try {
    $match = Get-CimInstance -ClassName Win32_Printer | Where-Object { $_.Name -eq $queueName } | Select-Object -First 1
    if ($match) { $workOffline = [bool]$match.WorkOffline }
  } catch {}
}
$deviceName = ''
if ($device) { $deviceName = [string]$device.FriendlyName }
"usb=$(Bit $device)"
"queue=$(Bit ($queues.Count -gt 0))"
"driver=$(Bit ($drivers.Count -gt 0))"
"package=$(Bit ($package.Count -gt 0))"
"port_ready=$(Bit $portReady)"
"protected=$(Bit ($wpp -eq 1))"
"work_offline=$(Bit $workOffline)"
"queue_name=$queueName"
"device_name=$deviceName"
"port=$port"
"printer_status=$printerStatus"
''';

const String _setupScript = r'''
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$log = Join-Path $env:TEMP 'zebra-agent-setup.txt'
$installer = '__INSTALLER__'
function Finish([string]$result, [string]$detail) {
  Set-Content -Path $log -Encoding utf8 -Value ("result=$result`r`ndetail=$detail")
  exit 0
}
$wppKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP'
New-Item -Path $wppKey -Force | Out-Null
$wpp = 0
try { $wpp = [int](Get-ItemProperty $wppKey).WindowsProtectedPrintMode } catch {}
if ($wpp -eq 1) {
  Set-ItemProperty -Path $wppKey -Name WindowsProtectedPrintMode -Type DWord -Value 0
}
function Driver-Present {
  $dirs = @(Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'zdesigner.inf_*' -ErrorAction SilentlyContinue)
  $named = @(Get-PrinterDriver -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'ZDesigner|Zebra' })
  return ($dirs.Count -gt 0 -or $named.Count -gt 0)
}
if (-not (Driver-Present)) {
  if ($installer -ne '' -and (Test-Path -LiteralPath $installer)) {
    if ($installer -like '*.inf') {
      & pnputil.exe /add-driver "$installer" /install | Out-Null
    } else {
      Start-Process -FilePath $installer -Wait
    }
  }
  if (-not (Driver-Present)) { Finish 'need_installer' 'ZDesigner' }
}
$device = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^USB\\VID_0A5F' } | Select-Object -First 1
if (-not $device) { Finish 'no_device' '' }
$deviceName = [string]$device.FriendlyName
$inf = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'zdesigner.inf_*' |
  ForEach-Object { Join-Path $_.FullName 'zdesigner.inf' } |
  Where-Object { Test-Path $_ } |
  Select-Object -First 1
$model = ''
if ($deviceName -match 'ZQ\s*\d+\s*Plus') { $model = ($Matches[0] -replace '\s+', ' ') }
elseif ($deviceName -match 'Z[QD]\s*\d+') { $model = ($Matches[0] -replace '\s+', '') }
$driverName = ''
if ($inf) {
  foreach ($line in Select-String -Path $inf -Pattern '^"ZDesigner [^"]+"=') {
    if ($line.Line -match '^"([^"]+)"') {
      $candidate = $Matches[1]
      if ($model -ne '' -and $candidate -like "*$model*(ZPL)*") { $driverName = $candidate; break }
      if ($model -ne '' -and $candidate -like "*$model*" -and $driverName -eq '') { $driverName = $candidate }
    }
  }
}
if ($driverName -eq '') { $driverName = 'ZDesigner ZQ320 Plus (ZPL)' }
$haveDriver = Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue
if (-not $haveDriver -and $inf) {
  Add-PrinterDriver -Name $driverName -InfPath $inf -ErrorAction SilentlyContinue | Out-Null
  $haveDriver = Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue
}
if (-not $haveDriver -and $installer -ne '' -and $installer -notlike '*.inf' -and (Test-Path -LiteralPath $installer)) {
  Start-Process -FilePath $installer -Wait
  if ($inf) { Add-PrinterDriver -Name $driverName -InfPath $inf -ErrorAction SilentlyContinue | Out-Null }
  $haveDriver = Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue
}
if (-not $haveDriver) { Finish 'need_installer' $driverName }
$port = ''
$serial = ''
if ($device.InstanceId -match '\\([^\\]+)$') { $serial = $Matches[1].ToLower() }
$list = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\USB Monitor\UsbPortList' -ErrorAction SilentlyContinue
if ($list) {
  foreach ($item in $list.PSObject.Properties) {
    if ($item.Name -like 'PS*') { continue }
    $path = "$($item.Value)".ToLower()
    if ($path -notmatch 'vid_0a5f') { continue }
    if ($serial -ne '' -and $path -notmatch [regex]::Escape($serial)) { continue }
    $port = $item.Name
    break
  }
}
Restart-Service Spooler -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$spool = @(Get-PrinterPort | ForEach-Object { $_.Name.TrimEnd(':') })
$existing = @(Get-Printer | Where-Object { $_.Name -match 'ZDesigner|Zebra' -or $_.DriverName -match 'ZDesigner|Zebra' })
if ($existing.Count -gt 0) { Finish 'ready' ([string]$existing[0].Name) }
if ($port -eq '' -or ($spool -notcontains $port)) { Finish 'need_reboot' $port }
try {
  Add-Printer -Name $driverName -DriverName $driverName -PortName $port -ErrorAction Stop
  Finish 'ready' $driverName
} catch {
  Finish 'need_reboot' $_.Exception.Message
}
''';
