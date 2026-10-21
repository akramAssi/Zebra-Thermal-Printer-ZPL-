import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:zebra_bluetooth_printer/zebra_bluetooth_printer.dart';

/// Wi-Fi networks Windows can see, plus the one this computer is using.
class WifiScan {
  const WifiScan({
    this.current = '',
    this.password = '',
    this.networks = const [],
  });

  final String current;
  final String password;
  final List<String> networks;
}

WifiScan parseWifiScan(String report) {
  var current = '';
  var password = '';
  final networks = <String>[];
  for (final raw in report.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    final split = line.indexOf('=');
    if (split <= 0) continue;
    final key = line.substring(0, split);
    final value = line.substring(split + 1).trim();
    if (value.isEmpty) continue;
    switch (key) {
      case 'current':
        current = value;
      case 'password':
        password = value;
      case 'network':
        if (!networks.contains(value)) networks.add(value);
    }
  }
  if (current.isNotEmpty && !networks.contains(current)) {
    networks.insert(0, current);
  }
  return WifiScan(current: current, password: password, networks: networks);
}

/// Reads the computer's Wi-Fi name, saved password, and nearby network names.
Future<WifiScan> readWifiNetworks() async {
  if (!Platform.isWindows) return const WifiScan();
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      _wifiScript,
    ]);
    return parseWifiScan('${result.stdout}\n${result.stderr}');
  } catch (_) {
    return const WifiScan();
  }
}

/// Sends the network name and password to the printer over the open USB link.
///
/// The printer restarts to join that network. The Windows print queue can
/// send these settings, and it does not return the printer's reply.
Future<String> sendPrinterWifi({
  required ZebraDiscoveredPrinter printer,
  required String ssid,
  required String password,
}) async {
  final name = ssid.trim();
  final key = password.trim();
  if (name.isEmpty) return 'Type the Wi-Fi name.';
  if (name.contains('"') || key.contains('"')) {
    return 'The Wi-Fi name and password cannot contain a quote.';
  }
  if (key.isNotEmpty && (key.length < 8 || key.length > 63)) {
    return 'The password must be 8 to 63 characters. Leave it empty only when the network has no password.';
  }
  final lines = <String>[
    'wlan.enable=on',
    'wlan.ip.protocol=dhcp',
    'wlan.operating_mode=infrastructure',
    'wlan.essid=$name',
    if (key.isEmpty) 'wlan.security=none',
    if (key.isNotEmpty) ...[
      'wlan.wpa.enable=on',
      'wlan.wpa.authentication=psk',
      'wlan.security=wpa psk',
      'wlan.wpa.psk=${wpaPskHex(key, name)}',
    ],
  ];
  final script = StringBuffer();
  for (final line in lines) {
    final split = line.indexOf('=');
    final setting = line.substring(0, split);
    final value = line.substring(split + 1);
    script.writeln('! U1 setvar "$setting" "$value"');
  }
  script.writeln('! U1 do "device.reset" ""');
  await ZebraSdk.printRaw(
    Uint8List.fromList(utf8.encode(script.toString())),
    address: printer.address,
    transport: printer.transport,
    port: printer.port,
  );
  return 'Wi-Fi settings were sent. The printer will restart and join that network.';
}

/// WPA passphrase key: PBKDF2-HMAC-SHA1 of the password, salted with the
/// network name, 4096 rounds. The printer stores these 64 hex digits, not
/// the password text.
String wpaPskHex(String passphrase, String ssid) {
  final bytes = _pbkdf2(
    utf8.encode(passphrase),
    utf8.encode(ssid),
    4096,
    32,
  );
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

Uint8List _pbkdf2(List<int> password, List<int> salt, int iterations, int length) {
  final hmac = Hmac(sha1, password);
  final blocks = (length + 19) ~/ 20;
  final output = BytesBuilder();
  for (var block = 1; block <= blocks; block++) {
    final seed = Uint8List(salt.length + 4)..setRange(0, salt.length, salt);
    seed[salt.length] = (block >> 24) & 0xff;
    seed[salt.length + 1] = (block >> 16) & 0xff;
    seed[salt.length + 2] = (block >> 8) & 0xff;
    seed[salt.length + 3] = block & 0xff;
    var u = Uint8List.fromList(hmac.convert(seed).bytes);
    final mixed = Uint8List.fromList(u);
    for (var round = 1; round < iterations; round++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var index = 0; index < mixed.length; index++) {
        mixed[index] ^= u[index];
      }
    }
    output.add(mixed);
  }
  return output.toBytes().sublist(0, length);
}

const String _wifiScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$interfaces = netsh wlan show interfaces | Out-String
$current = ''
foreach ($line in ($interfaces -split "`r?`n")) {
  if ($line -match '^\s*SSID\s*:\s*(.*)$') {
    $current = $Matches[1].Trim()
    if ($current -ne '') { break }
  }
}
"current=$current"
if ($current -ne '') {
  $dir = Join-Path $env:TEMP 'zebra-wifi-profile'
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $dir | Out-Null
  netsh wlan export profile name="$current" folder="$dir" key=clear | Out-Null
  $xmlFile = Get-ChildItem $dir -Filter '*.xml' | Select-Object -First 1
  if ($xmlFile) {
    try {
      [xml]$doc = Get-Content -LiteralPath $xmlFile.FullName
      $key = [string]$doc.WLANProfile.MSM.security.sharedKey.keyMaterial
      if ($key) { "password=$key" }
    } catch {}
  }
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
$networks = netsh wlan show networks | Out-String
foreach ($line in ($networks -split "`r?`n")) {
  if ($line -match '^\s*SSID\s+\d+\s*:\s*(.*)$') {
    $name = $Matches[1].Trim()
    if ($name -ne '') { "network=$name" }
  }
}
if ($current -ne '') { "network=$current" }
''';
