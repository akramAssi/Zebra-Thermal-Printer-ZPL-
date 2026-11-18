import 'dart:io';

/// USB on Windows needs the ZDesigner driver from Zebra Setup Utilities.
/// Bluetooth and a network printer on port 9100 do not.
class WindowsDriverStatus {
  const WindowsDriverStatus({
    required this.installed,
    required this.installerPath,
    this.checkFailed = false,
  });

  final bool installed;
  final String installerPath;
  final bool checkFailed;

  bool get canInstall => !installed && installerPath.isNotEmpty;
}

/// True when the Windows driver list names a Zebra or ZDesigner driver.
bool driverInstalledFromReport(String report) {
  return RegExp(r'zdesigner|zebra', caseSensitive: false).hasMatch(report);
}

Future<WindowsDriverStatus> checkWindowsDriver() async {
  final installerPath = findDriverInstaller() ?? '';
  if (!Platform.isWindows) {
    return WindowsDriverStatus(installed: true, installerPath: installerPath);
  }
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      _driverReportScript,
    ]);
    final report = '${result.stdout}\n${result.stderr}';
    if (result.exitCode != 0 && '${result.stdout}'.trim().isEmpty) {
      return WindowsDriverStatus(
        installed: false,
        installerPath: installerPath,
        checkFailed: true,
      );
    }
    return WindowsDriverStatus(
      installed: driverInstalledFromReport(report),
      installerPath: installerPath,
    );
  } catch (_) {
    return WindowsDriverStatus(
      installed: false,
      installerPath: installerPath,
      checkFailed: true,
    );
  }
}

/// Opens the packaged installer with the Windows administrator prompt.
///
/// Returns a short message for the agent window.
Future<String> installWindowsDriver(String installerPath) async {
  if (!Platform.isWindows) return 'The driver install runs on Windows.';
  if (installerPath.isEmpty || !File(installerPath).existsSync()) {
    return 'The driver installer is not in this app.';
  }
  final quoted = "'${installerPath.replaceAll("'", "''")}'";
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-Command',
      '''
try {
  \$p = Start-Process -FilePath $quoted -Verb RunAs -Wait -PassThru
  if (\$null -eq \$p) { 'cancelled' } else { 'exit:' + \$p.ExitCode }
} catch {
  'cancelled'
}
''',
    ]);
    final output = '${result.stdout}'.toLowerCase();
    if (output.contains('cancelled')) {
      return 'Driver install was cancelled.';
    }
    return 'Installer finished. Plug the printer in with USB, then press Find printers.';
  } catch (error) {
    return 'Could not start the driver installer. $error';
  }
}

/// Bundled `zdesigner.inf`, or `ZebraDriver.exe` beside the app.
String? findBundledDriverPackage() {
  final inf = _findNamedFile('zdesigner.inf');
  if (inf != null) return inf;
  return findDriverInstaller();
}

/// `ZebraDriver.exe` beside the app, or the first installer in `driver/`.
String? findDriverInstaller() {
  final besideApp = File(
    _join(File(Platform.resolvedExecutable).parent.path, 'ZebraDriver.exe'),
  );
  if (besideApp.existsSync()) return besideApp.path;

  final folders = [
    Directory(_join(File(Platform.resolvedExecutable).parent.path, 'driver')),
    Directory(_join(Directory.current.path, 'driver')),
  ];
  final found = <String>[];
  for (final folder in folders) {
    if (!folder.existsSync()) continue;
    for (final entity in folder.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last.toLowerCase();
      if (!name.endsWith('.exe')) continue;
      if (name == 'zebra_printer_agent.exe') continue;
      found.add(entity.path);
    }
  }
  if (found.isEmpty) return null;
  found.sort();
  for (final path in found) {
    final name = path.split(Platform.pathSeparator).last.toLowerCase();
    if (name == 'zebradriver.exe') return path;
  }
  return found.first;
}

const String _driverReportScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lines = New-Object System.Collections.Generic.List[string]
Get-CimInstance Win32_PrinterDriver | ForEach-Object { $lines.Add([string]$_.Name) }
Get-CimInstance Win32_Printer | ForEach-Object { $lines.Add(([string]$_.Name) + ' ' + ([string]$_.DriverName)) }
$lines.Add((pnputil /enum-drivers | Out-String))
$lines -join "`n"
''';

String? _findNamedFile(String name) {
  final wanted = name.toLowerCase();
  final folders = [
    Directory(_join(File(Platform.resolvedExecutable).parent.path, 'driver')),
    Directory(_join(Directory.current.path, 'driver')),
  ];
  for (final folder in folders) {
    if (!folder.existsSync()) continue;
    for (final entity in folder.listSync(recursive: true)) {
      if (entity is! File) continue;
      final found = entity.uri.pathSegments.last.toLowerCase();
      if (found == wanted) return entity.path;
    }
  }
  return null;
}

String _join(String directory, String name) {
  if (directory.endsWith('\\') || directory.endsWith('/')) {
    return '$directory$name';
  }
  return '$directory${Platform.pathSeparator}$name';
}
