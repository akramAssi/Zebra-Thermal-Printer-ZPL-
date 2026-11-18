import 'dart:io';

import 'package:flutter/foundation.dart';

const Duration agentLogRetention = Duration(hours: 24);

/// Prints one line to the debug console and keeps the same line in
/// `zebra_printer_agent.log` beside the exe. Lines older than 24 hours
/// are removed on the next write.
void agentLog(String message) {
  final now = DateTime.now();
  final line = '${now.toIso8601String()} [zebra] $message';
  debugPrint('[zebra] $message');
  try {
    final file = File.fromUri(
      File(Platform.resolvedExecutable).parent.uri.resolve(
        'zebra_printer_agent.log',
      ),
    );
    final previous = file.existsSync() ? file.readAsLinesSync() : const <String>[];
    final kept = retainRecentLogs(previous, now);
    kept.add(line);
    file.writeAsStringSync('${kept.join('\n')}\n', flush: true);
  } catch (error) {
    debugPrint('[zebra] Could not write zebra_printer_agent.log: $error');
  }
}

/// Keeps lines whose timestamp is inside the last 24 hours.
List<String> retainRecentLogs(Iterable<String> lines, DateTime now) {
  final cutoff = now.subtract(agentLogRetention);
  final kept = <String>[];
  for (final raw in lines) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    final time = logLineTime(line);
    if (time != null && !time.isBefore(cutoff)) {
      kept.add(line);
    }
  }
  return kept;
}

DateTime? logLineTime(String line) {
  final space = line.indexOf(' ');
  if (space <= 0) return null;
  return DateTime.tryParse(line.substring(0, space));
}
