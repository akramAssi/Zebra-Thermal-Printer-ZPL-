import 'dart:io';

/// One document waiting in the Windows printer queue.
class PrintJob {
  const PrintJob({
    required this.id,
    required this.status,
    required this.name,
  });

  final int id;
  final String status;
  final String name;

  String get title => name.trim().isEmpty ? 'Print job' : name.trim();
}

enum CancelJobsResult { cleared, needPermission, failed }

/// Lines from `Get-PrintJob`. A name may contain `|`.
List<PrintJob> parsePrintJobs(String report) {
  final jobs = <PrintJob>[];
  for (final raw in report.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (!line.startsWith('job|')) continue;
    final parts = line.split('|');
    if (parts.length < 4) continue;
    final id = int.tryParse(parts[1].trim());
    if (id == null) continue;
    jobs.add(
      PrintJob(
        id: id,
        status: parts[2].trim(),
        name: parts.sublist(3).join('|').trim(),
      ),
    );
  }
  return jobs;
}

const String _listScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$printer = Get-Printer | Where-Object { $_.Name -match 'ZDesigner|Zebra' -or $_.DriverName -match 'ZDesigner|Zebra' } | Select-Object -First 1
if (-not $printer) { exit 0 }
Get-PrintJob -PrinterName $printer.Name | ForEach-Object {
  $name = ([string]$_.DocumentName) -replace "[\r\n]", ' '
  $status = ([string]$_.JobStatus) -replace "[\r\n]", ' '
  "job|$($_.Id)|$status|$name"
}
''';

/// Null when Windows could not be checked. An empty list means the queue is clear.
Future<List<PrintJob>?> readPrintJobs() async {
  if (!Platform.isWindows) return const [];
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      _listScript,
    ]);
    if (result.exitCode != 0 && '${result.stdout}'.trim().isEmpty) return null;
    return parsePrintJobs('${result.stdout}');
  } catch (_) {
    return null;
  }
}

/// Removes the jobs. A stuck "Printing" job needs one Windows permission
/// prompt so the print spooler can drop it.
Future<CancelJobsResult> cancelPrintJobs(List<int> ids) async {
  if (!Platform.isWindows || ids.isEmpty) return CancelJobsResult.failed;
  final removed = await _removePrintJobs(ids);
  if (removed == null) return CancelJobsResult.failed;
  if (removed == 0) return CancelJobsResult.cleared;
  final restarted = await _restartPrintSpooler();
  if (!restarted) return CancelJobsResult.needPermission;
  final left = await readPrintJobs();
  if (left == null) return CancelJobsResult.failed;
  final pending = left.where((job) => ids.contains(job.id)).length;
  return pending == 0 ? CancelJobsResult.cleared : CancelJobsResult.failed;
}

Future<int?> _removePrintJobs(List<int> ids) async {
  final idList = ids.join(',');
  final script = '''
\$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
\$printer = Get-Printer | Where-Object { \$_.Name -match 'ZDesigner|Zebra' -or \$_.DriverName -match 'ZDesigner|Zebra' } | Select-Object -First 1
if (-not \$printer) { 'left=0'; exit 0 }
foreach (\$id in @($idList)) {
  Remove-PrintJob -PrinterName \$printer.Name -ID \$id -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500
\$wanted = @($idList)
\$left = @(Get-PrintJob -PrinterName \$printer.Name | Where-Object { \$wanted -contains \$_.Id })
"left=\$(\$left.Count)"
''';
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]);
    final match = RegExp(r'left=(\d+)').firstMatch('${result.stdout}');
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  } catch (_) {
    return null;
  }
}

Future<bool> _restartPrintSpooler() async {
  final script = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}zebra-agent-clear-queue.ps1',
  );
  final log = File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}zebra-agent-clear-queue.txt',
  );
  if (log.existsSync()) log.deleteSync();
  await script.writeAsString(r'''
$ErrorActionPreference = 'Continue'
Restart-Service Spooler -Force
Set-Content -Path (Join-Path $env:TEMP 'zebra-agent-clear-queue.txt') -Encoding ascii -Value 'result=cleared'
''');
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
    if (launch.contains('cancelled')) return false;
    if (!log.existsSync()) return false;
    return (await log.readAsString()).contains('cleared');
  } catch (_) {
    return false;
  }
}
