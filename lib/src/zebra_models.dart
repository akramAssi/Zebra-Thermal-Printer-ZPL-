/// How the phone reaches the printer.
enum ZebraTransport {
  /// Classic Bluetooth on Android. Made-for-iPhone accessory on iOS.
  /// [ZebraDiscoveredPrinter.address] is a MAC address on Android and the
  /// accessory serial number on iOS.
  bluetooth,

  /// Raw TCP, usually port 9100. The same socket the Link-OS SDK opens
  /// with `TcpConnection`.
  tcp,

  /// USB host. Android only. [ZebraDiscoveredPrinter.address] is the
  /// Android USB device name.
  usb,
}

/// A printer returned by discovery.
class ZebraDiscoveredPrinter {
  const ZebraDiscoveredPrinter({
    required this.name,
    required this.address,
    required this.transport,
    this.port = 9100,
    this.discoveryData = const {},
  });

  final String name;
  final String address;
  final ZebraTransport transport;
  final int port;
  final Map<String, String> discoveryData;

  factory ZebraDiscoveredPrinter.fromMap(Map<dynamic, dynamic> map) {
    final data = <String, String>{};
    final raw = map['discovery'];
    if (raw is Map) {
      raw.forEach((key, value) {
        data['$key'] = '$value';
      });
    }
    return ZebraDiscoveredPrinter(
      name: (map['name'] ?? map['address'] ?? '').toString(),
      address: (map['address'] ?? '').toString(),
      transport: zebraTransportFromName(map['transport']?.toString()),
      port: _asInt(map['port'], 9100),
      discoveryData: data,
    );
  }
}

/// Link-OS [PrinterStatus], filled from the SDK on Android and from the
/// `~HS` reply on iOS.
class ZebraPrinterStatus {
  const ZebraPrinterStatus({
    required this.isReadyToPrint,
    required this.isPaused,
    required this.isHeadOpen,
    required this.isPaperOut,
    required this.isRibbonOut,
    required this.isHeadCold,
    required this.isHeadTooHot,
    required this.isReceiveBufferFull,
    required this.isPartialFormatInProgress,
    required this.labelLengthInDots,
    required this.numberOfFormatsInReceiveBuffer,
    required this.labelsRemainingInBatch,
    required this.printMode,
  });

  final bool isReadyToPrint;
  final bool isPaused;
  final bool isHeadOpen;
  final bool isPaperOut;
  final bool isRibbonOut;
  final bool isHeadCold;
  final bool isHeadTooHot;
  final bool isReceiveBufferFull;
  final bool isPartialFormatInProgress;
  final int labelLengthInDots;
  final int numberOfFormatsInReceiveBuffer;
  final int labelsRemainingInBatch;
  final String printMode;

  factory ZebraPrinterStatus.fromMap(Map<dynamic, dynamic> map) {
    return ZebraPrinterStatus(
      isReadyToPrint: _asBool(map['isReadyToPrint']),
      isPaused: _asBool(map['isPaused']),
      isHeadOpen: _asBool(map['isHeadOpen']),
      isPaperOut: _asBool(map['isPaperOut']),
      isRibbonOut: _asBool(map['isRibbonOut']),
      isHeadCold: _asBool(map['isHeadCold']),
      isHeadTooHot: _asBool(map['isHeadTooHot']),
      isReceiveBufferFull: _asBool(map['isReceiveBufferFull']),
      isPartialFormatInProgress: _asBool(map['isPartialFormatInProgress']),
      labelLengthInDots: _asInt(map['labelLengthInDots'], 0),
      numberOfFormatsInReceiveBuffer:
          _asInt(map['numberOfFormatsInReceiveBuffer'], 0),
      labelsRemainingInBatch: _asInt(map['labelsRemainingInBatch'], 0),
      printMode: (map['printMode'] ?? '').toString(),
    );
  }

  Map<String, Object> toMap() => {
        'isReadyToPrint': isReadyToPrint,
        'isPaused': isPaused,
        'isHeadOpen': isHeadOpen,
        'isPaperOut': isPaperOut,
        'isRibbonOut': isRibbonOut,
        'isHeadCold': isHeadCold,
        'isHeadTooHot': isHeadTooHot,
        'isReceiveBufferFull': isReceiveBufferFull,
        'isPartialFormatInProgress': isPartialFormatInProgress,
        'labelLengthInDots': labelLengthInDots,
        'numberOfFormatsInReceiveBuffer': numberOfFormatsInReceiveBuffer,
        'labelsRemainingInBatch': labelsRemainingInBatch,
        'printMode': printMode,
      };
}

/// One drive reported by Link-OS `getStorageInfo`.
class ZebraStorageInfo {
  const ZebraStorageInfo({
    required this.driveLetter,
    required this.driveType,
    required this.bytesFree,
    required this.isPersistent,
  });

  final String driveLetter;
  final String driveType;
  final int bytesFree;
  final bool isPersistent;

  factory ZebraStorageInfo.fromMap(Map<dynamic, dynamic> map) {
    return ZebraStorageInfo(
      driveLetter: (map['driveLetter'] ?? '').toString(),
      driveType: (map['driveType'] ?? '').toString(),
      bytesFree: _asInt(map['bytesFree'], 0),
      isPersistent: _asBool(map['isPersistent']),
    );
  }
}

/// A `^FN` field inside a stored ZPL format. This is the same information
/// `FormatUtil.getVariableFields` returns.
class ZebraFormatField {
  const ZebraFormatField({required this.number, this.name = ''});

  final int number;
  final String name;
}

/// Reads `^FN` fields out of a ZPL format.
class ZebraFormat {
  static final RegExp _field = RegExp(r'\^FN(\d+)(?:\s*"([^"]*)")?');

  static List<ZebraFormatField> fields(String zpl) {
    final found = <int, ZebraFormatField>{};
    for (final match in _field.allMatches(zpl)) {
      final number = int.tryParse(match.group(1) ?? '');
      if (number == null) continue;
      found.putIfAbsent(
        number,
        () => ZebraFormatField(number: number, name: match.group(2) ?? ''),
      );
    }
    final list = found.values.toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    return list;
  }
}

ZebraTransport zebraTransportFromName(String? name) {
  switch ((name ?? '').toLowerCase()) {
    case 'tcp':
    case 'network':
      return ZebraTransport.tcp;
    case 'usb':
      return ZebraTransport.usb;
    default:
      return ZebraTransport.bluetooth;
  }
}

int _asInt(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? fallback;
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  final text = '$value'.toLowerCase();
  return text == 'true' || text == '1';
}
