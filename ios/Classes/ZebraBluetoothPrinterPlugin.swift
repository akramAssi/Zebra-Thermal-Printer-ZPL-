import ExternalAccessory
import Flutter
import UIKit

/// iOS Zebra printing uses the MFi External Accessory protocol `com.zebra.rawport`.
/// iOS does not allow a classic Bluetooth connection by MAC address, so the
/// identifier passed from Dart is the accessory serial number.
public class ZebraBluetoothPrinterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, StreamDelegate {
  private let protocolString = "com.zebra.rawport"
  private let workQueue = DispatchQueue(label: "zebra.bluetooth.printer")

  private var eventSink: FlutterEventSink?
  private var session: EASession?
  private var accessory: EAAccessory?
  private var inputStream: InputStream?
  private var outputStream: OutputStream?
  private var inputBuffer = Data()
  private let bufferLock = NSLock()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ZebraBluetoothPrinterPlugin()
    let channel = FlutterMethodChannel(
      name: "zebra_bluetooth_printer",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: channel)

    let events = FlutterEventChannel(
      name: "zebra_bluetooth_printer_stream",
      binaryMessenger: registrar.messenger()
    )
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "GET_PLATFORM_VERSION":
      result(UIDevice.current.systemVersion)
    case "LIST_PRINTERS":
      result(zebraAccessories().map { accessoryMap($0) })
    case "SHOW_PICKER":
      showPicker(result: result)
    case "CONNECT":
      let identifier = call.arguments as? String ?? ""
      workQueue.async {
        let connected = self.connect(identifier: identifier)
        DispatchQueue.main.async { result(connected) }
      }
    case "DISCONNECT":
      workQueue.async {
        self.disconnect()
        DispatchQueue.main.async { result(true) }
      }
    case "PRINT_ZPL":
      guard let args = call.arguments as? [String], args.count == 2 else {
        result(FlutterError(code: "100", message: "Expected [address, zpl]", details: nil))
        return
      }
      workQueue.async {
        self.finishPrint(result) { try self.printZpl(args[1], identifier: args[0]) }
      }
    case "PRINT_PDF":
      guard let args = call.arguments as? [String], args.count == 2 else {
        result(FlutterError(code: "100", message: "Expected [address, path]", details: nil))
        return
      }
      workQueue.async {
        self.finishPrint(result) { try self.printPdf(path: args[1], identifier: args[0]) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    guard eventCode == .hasBytesAvailable, let input = aStream as? InputStream else { return }
    let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
    defer { chunk.deallocate() }
    while input.hasBytesAvailable {
      let count = input.read(chunk, maxLength: 1024)
      if count <= 0 { break }
      bufferLock.lock()
      inputBuffer.append(chunk, count: count)
      bufferLock.unlock()
    }
  }

  private func finishPrint(_ result: @escaping FlutterResult, _ work: () throws -> Bool) {
    do {
      let printed = try work()
      DispatchQueue.main.async { result(printed) }
    } catch let error as PrinterFailure {
      notify(error.message)
      DispatchQueue.main.async {
        result(FlutterError(code: error.code, message: error.message, details: nil))
      }
    } catch {
      let message = error.localizedDescription
      notify(message)
      DispatchQueue.main.async {
        result(FlutterError(code: "100", message: message, details: nil))
      }
    }
  }

  private func showPicker(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { error in
        if let error = error as NSError?,
           error.domain == EABluetoothAccessoryPickerError.errorDomain,
           error.code == EABluetoothAccessoryPickerError.Code.resultFailed.rawValue {
          result(false)
          return
        }
        result(true)
      }
    }
  }

  private func connect(identifier: String) -> Bool {
    if isOpen, matches(accessory, identifier: identifier) {
      return true
    }
    disconnect()
    guard let match = findAccessory(identifier: identifier) else {
      notify("No paired Zebra printer")
      return false
    }
    return open(match)
  }

  private func printZpl(_ zpl: String, identifier: String) throws -> Bool {
    try ensureConnected(identifier)
    try setVariable("device.languages", value: "zpl")
    guard let data = zpl.data(using: .utf8) else {
      throw PrinterFailure(code: "100", message: "ZPL is not valid text")
    }
    try write(data)
    notify("Printed")
    return true
  }

  private func printPdf(path: String, identifier: String) throws -> Bool {
    try ensureConnected(identifier)
    let file = URL(fileURLWithPath: path)
    guard let pdf = try? Data(contentsOf: file), !pdf.isEmpty else {
      throw PrinterFailure(code: "100", message: "PDF file is empty")
    }
    try setVariable("device.languages", value: "zpl")
    try setVariable("apl.settings", value: scaleSetting())
    try write(pdf)
    notify("Printed")
    return true
  }

  private func ensureConnected(_ identifier: String) throws {
    if isOpen { return }
    if !connect(identifier: identifier) {
      throw PrinterFailure(code: "004", message: "Connection Fail")
    }
  }

  private var isOpen: Bool {
    session != nil && outputStream?.streamStatus == .open
  }

  private func open(_ match: EAAccessory) -> Bool {
    notify("Connecting...")
    var opened = false
    let start = {
      guard let session = EASession(accessory: match, forProtocol: self.protocolString) else { return }
      self.session = session
      self.accessory = match
      self.inputStream = session.inputStream
      self.outputStream = session.outputStream
      self.inputStream?.delegate = self
      self.outputStream?.delegate = self
      self.inputStream?.schedule(in: .current, forMode: .common)
      self.outputStream?.schedule(in: .current, forMode: .common)
      self.inputStream?.open()
      self.outputStream?.open()
      opened = true
    }
    if Thread.isMainThread {
      start()
    } else {
      DispatchQueue.main.sync(execute: start)
    }
    if opened {
      notify("Connected")
    } else {
      notify("Comm Error! Disconnecting")
      disconnect()
    }
    return opened
  }

  private func disconnect() {
    notify("Disconnecting...")
    let close = {
      self.inputStream?.close()
      self.outputStream?.close()
      self.inputStream?.remove(from: .current, forMode: .common)
      self.outputStream?.remove(from: .current, forMode: .common)
      self.inputStream = nil
      self.outputStream = nil
      self.session = nil
      self.accessory = nil
      self.bufferLock.lock()
      self.inputBuffer.removeAll()
      self.bufferLock.unlock()
    }
    if Thread.isMainThread {
      close()
    } else {
      DispatchQueue.main.sync(execute: close)
    }
    notify("Disconnected Printer")
  }

  private func zebraAccessories() -> [EAAccessory] {
    EAAccessoryManager.shared().connectedAccessories.filter {
      $0.protocolStrings.contains(protocolString)
    }
  }

  private func findAccessory(identifier: String) -> EAAccessory? {
    let printers = zebraAccessories()
    if identifier.isEmpty { return printers.first }
    return printers.first { matches($0, identifier: identifier) } ?? (printers.count == 1 ? printers.first : nil)
  }

  private func matches(_ accessory: EAAccessory?, identifier: String) -> Bool {
    guard let accessory else { return false }
    if identifier.isEmpty { return true }
    return accessory.serialNumber == identifier
      || accessory.name == identifier
      || String(accessory.connectionID) == identifier
  }

  private func accessoryMap(_ accessory: EAAccessory) -> [String: String] {
    [
      "name": accessory.name,
      "address": accessory.serialNumber,
      "serialNumber": accessory.serialNumber,
    ]
  }

  private func setVariable(_ name: String, value: String) throws {
    _ = try command("! U1 setvar \"\(name)\" \"\(value)\"")
  }

  private func getVariable(_ name: String) -> String? {
    try? command("! U1 getvar \"\(name)\"")
  }

  @discardableResult
  private func command(_ text: String) throws -> String {
    bufferLock.lock()
    inputBuffer.removeAll()
    bufferLock.unlock()
    var payload = text
    if !payload.hasSuffix("\r\n") { payload += "\r\n" }
    guard let data = payload.data(using: .utf8) else { return "" }
    try write(data)
    let deadline = Date().addingTimeInterval(1.2)
    while Date() < deadline {
      bufferLock.lock()
      let ready = !inputBuffer.isEmpty
      bufferLock.unlock()
      if ready {
        Thread.sleep(forTimeInterval: 0.08)
        break
      }
      Thread.sleep(forTimeInterval: 0.04)
    }
    bufferLock.lock()
    let bytes = inputBuffer
    bufferLock.unlock()
    return String(data: bytes, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
  }

  private func write(_ data: Data) throws {
    guard let output = outputStream else {
      throw PrinterFailure(code: "004", message: "Connection Fail")
    }
    var offset = 0
    let bytes = [UInt8](data)
    let deadline = Date().addingTimeInterval(20)
    while offset < bytes.count {
      if Date() > deadline {
        throw PrinterFailure(code: "001", message: "Fail Print")
      }
      if output.streamStatus == .error || output.streamStatus == .closed {
        throw PrinterFailure(code: "004", message: "Connection Fail")
      }
      if !output.hasSpaceAvailable {
        Thread.sleep(forTimeInterval: 0.02)
        continue
      }
      let written = bytes.withUnsafeBytes { raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
        return output.write(base.advanced(by: offset), maxLength: bytes.count - offset)
      }
      if written < 0 {
        throw PrinterFailure(code: "001", message: "Fail Print")
      }
      offset += written
    }
  }

  /// Matches the Android plugin's model-based `apl.settings` scale.
  private func scaleSetting() -> String {
    let identity = getVariable("device.host_identification") ?? ""
    let model = String(identity.prefix(5))
    let fileWidth = 56.0
    let factor: Double
    switch model {
    case "iMZ22", "QLn22", "ZD410":
      factor = 2.0 / fileWidth * 100
    case "iMZ32", "QLn32", "ZQ510":
      factor = 3.0 / fileWidth * 100
    case "QLn42", "ZQ520", "ZD420", "ZD500", "ZT220", "ZT230", "ZT410":
      factor = 4.0 / fileWidth * 100
    case "ZT420":
      factor = 6.5 / fileWidth * 100
    default:
      return "dither scale-to-fit"
    }
    let percent = Int(factor)
    return "dither scale=\(percent)x\(percent)"
  }

  private func notify(_ message: String) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(message)
    }
  }
}

private struct PrinterFailure: Error {
  let code: String
  let message: String
}
