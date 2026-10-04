import ExternalAccessory
import Flutter
import Network
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
  private var usingTcp = false
  private var tcpHost = ""
  private var lastConnectError = "Connection Fail"
  private var idleWork: DispatchWorkItem?
  /// Drop the Bluetooth session when nothing has been printed for 5 minutes.
  private let idleLimit: TimeInterval = 5 * 60
  /// While a session is open, check that iOS still lists this accessory.
  private var linkWatch: DispatchWorkItem?
  private var linkMisses = 0
  /// Set when the printer disappears so the next connect waits for it to return.
  private var staleDropAt = Date.distantPast

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
    instance.observeAccessories()
    instance.observeAppLifetime()
  }

  /// A session left open locks the printer, so the next print cannot connect.
  private func observeAppLifetime() {
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(releasePrinterSession),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(releasePrinterSession),
      name: UIApplication.willTerminateNotification,
      object: nil
    )
  }

  @objc private func releasePrinterSession() {
    log("SESSION app closed or background, disconnect")
    disconnect()
  }

  private func noteSessionUsed() {
    idleWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.log("SESSION idle 5 min, disconnect")
      self?.disconnect()
    }
    idleWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + idleLimit, execute: work)
  }

  private func cancelIdleTimer() {
    idleWork?.cancel()
    idleWork = nil
  }

  /// The open session keeps the old connection id (the IAP id in the system
  /// log). iOS will not list the printer again until that id is released,
  /// which otherwise takes a few minutes after the printer is switched off.
  private func noteStaleDrop() {
    let mark = { self.staleDropAt = Date() }
    if Thread.isMainThread {
      mark()
    } else {
      DispatchQueue.main.sync(execute: mark)
    }
  }

  private func droppedStaleRecently() -> Bool {
    onMain { Date().timeIntervalSince(self.staleDropAt) < 30 }
  }

  private func staleSessionReason() -> String? {
    onMain {
      if self.usingTcp { return nil }
      let hasSession = self.session != nil || self.outputStream != nil
      guard hasSession else { return nil }
      guard let held = self.accessory else { return "session without accessory" }
      let status = self.outputStream?.streamStatus ?? .notOpen
      if status == .error || status == .closed || status == .atEnd {
        return "stream \(self.statusLabel(status)) id=\(held.connectionID)"
      }
      let live = EAAccessoryManager.shared().connectedAccessories
      let listed = live.contains { $0.connectionID == held.connectionID }
      if !listed {
        return "id=\(held.connectionID) serial=\(held.serialNumber) not in connectedAccessories (\(live.count))"
      }
      return nil
    }
  }

  @discardableResult
  private func dropStaleSessionIfNeeded() -> Bool {
    guard let reason = staleSessionReason() else { return false }
    log("SESSION stale (\(reason)), dropping old connection")
    noteStaleDrop()
    disconnect()
    return true
  }

  private func startLinkWatch() {
    let start = {
      self.stopLinkWatch()
      let work = DispatchWorkItem { [weak self] in
        self?.checkLink()
      }
      self.linkWatch = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    if Thread.isMainThread {
      start()
    } else {
      DispatchQueue.main.async(execute: start)
    }
  }

  private func stopLinkWatch() {
    let stop = {
      self.linkWatch?.cancel()
      self.linkWatch = nil
    }
    if Thread.isMainThread {
      stop()
    } else {
      DispatchQueue.main.sync(execute: stop)
    }
  }

  /// Powering the printer off removes it from `connectedAccessories` while
  /// our session can stay open. Two misses in a row means the link is gone.
  private func checkLink() {
    guard session != nil, let held = accessory, !usingTcp else { return }
    prepareAccessoryManager()
    let live = EAAccessoryManager.shared().connectedAccessories
    let stillThere = live.contains { $0.connectionID == held.connectionID }
    if stillThere {
      linkMisses = 0
    } else {
      linkMisses += 1
      log("SESSION link watch miss \(linkMisses) id=\(held.connectionID) listed=\(live.count)")
      if linkMisses >= 2 {
        log("SESSION link watch dropping old connection id=\(held.connectionID)")
        linkMisses = 0
        noteStaleDrop()
        disconnect()
        return
      }
    }
    startLinkWatch()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "GET_PLATFORM_VERSION":
      result(UIDevice.current.systemVersion)
    case "LIST_PRINTERS":
      listPrinters(result)
    case "SHOW_PICKER":
      showPicker(result: result)
    case "CONNECT":
      let identifier = call.arguments as? String ?? ""
      workQueue.async {
        let connected = self.connect(identifier: identifier)
        DispatchQueue.main.async {
          if connected {
            result(true)
          } else {
            result(FlutterError(code: "004", message: self.lastConnectError, details: nil))
          }
        }
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
    case "PRINT_PDFS":
      guard let args = call.arguments as? [String], args.count >= 2 else {
        result(FlutterError(code: "100", message: "Expected printer and at least one PDF", details: nil))
        return
      }
      workQueue.async {
        self.finishPrint(result) {
          try self.printPdfs(paths: Array(args.dropFirst()), identifier: args[0])
        }
      }
    case "HOST_IDENTIFICATION":
      let identifier = call.arguments as? String ?? ""
      workQueue.async {
        let host = self.readHostIdentification(identifier)
        DispatchQueue.main.async { result(host) }
      }
    case "SDK":
      let args = call.arguments as? [String: Any] ?? [:]
      workQueue.async {
        do {
          let value = try self.sdk(args)
          DispatchQueue.main.async { result(value) }
        } catch let error as PrinterFailure {
          self.notify(error.message)
          DispatchQueue.main.async {
            result(FlutterError(code: error.code, message: error.message, details: nil))
          }
        } catch {
          let message = error.localizedDescription
          self.notify(message)
          DispatchQueue.main.async {
            result(FlutterError(code: "100", message: message, details: nil))
          }
        }
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
    if eventCode.contains(.hasBytesAvailable), let input = aStream as? InputStream {
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
    if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) {
      let ended = eventCode.contains(.errorOccurred) ? "error" : "end"
      log("stream \(ended) \(streamState(aStream))")
      // Closing the stream inside its own callback crashes. Release on the
      // next turn, and only if this is still the session we opened.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard aStream === self.inputStream || aStream === self.outputStream else { return }
        self.log("SESSION printer closed the link, dropping old connection")
        self.noteStaleDrop()
        self.disconnect()
      }
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

  private func log(_ message: String) {
    NSLog("[ZebraBT] %@", message)
  }

  private func describe(_ accessory: EAAccessory?) -> String {
    guard let accessory else { return "nil" }
    let protocols = accessory.protocolStrings.joined(separator: ",")
    return "name=\(accessory.name) model=\(accessory.modelNumber) serial=\(accessory.serialNumber) id=\(accessory.connectionID) connected=\(accessory.isConnected) protocols=[\(protocols)]"
  }

  /// Register as soon as the plugin loads. Reading `connectedAccessories` in
  /// the same turn as `registerForLocalNotifications` still returns nothing.
  private func observeAccessories() {
    let start = {
      self.log("plugin observeAccessories")
      self.prepareAccessoryManager()
      let center = NotificationCenter.default
      center.addObserver(
        self,
        selector: #selector(self.accessoryDidChange(_:)),
        name: .EAAccessoryDidConnect,
        object: nil
      )
      center.addObserver(
        self,
        selector: #selector(self.accessoryDidChange(_:)),
        name: .EAAccessoryDidDisconnect,
        object: nil
      )
      self.logConnected("after plugin register")
    }
    if Thread.isMainThread {
      start()
    } else {
      DispatchQueue.main.async(execute: start)
    }
  }

  @objc private func accessoryDidChange(_ notification: Notification) {
    log("notification \(notification.name.rawValue)")
    if notification.name == .EAAccessoryDidDisconnect {
      let gone = notification.userInfo?[EAAccessoryKey] as? EAAccessory
      log("accessory disconnected \(describe(gone))")
      let currentId = accessory?.connectionID
      if gone == nil || currentId == nil || gone?.connectionID == currentId {
        // A disconnect we caused ourselves already cleared the accessory.
        // A real power-off still has our session, and the next connect
        // has to wait until iOS lists the printer again.
        if currentId != nil {
          log("SESSION printer left while the session was open id=\(currentId ?? 0)")
          noteStaleDrop()
        }
        disconnect()
      }
    } else if notification.name == .EAAccessoryDidConnect {
      let arrived = notification.userInfo?[EAAccessoryKey] as? EAAccessory
      log("accessory connected \(describe(arrived))")
      if let arrived, let held = accessory,
         arrived.connectionID != held.connectionID,
         matches(arrived, identifier: held.serialNumber) {
        log("SESSION printer returned as id=\(arrived.connectionID), dropping old id=\(held.connectionID)")
        noteStaleDrop()
        disconnect()
      }
    }
    prepareAccessoryManager()
    logConnected("after notification")
  }

  /// The accessory often appears a moment after launch or after the picker
  /// closes. Reply with whatever is connected, and wait briefly when the
  /// list is still empty.
  private func listPrinters(_ result: @escaping FlutterResult) {
    log("LIST_PRINTERS")
    DispatchQueue.main.async {
      self.prepareAccessoryManager()
      _ = self.dropStaleSessionIfNeeded()
      self.publishPrinters(result: result, attempt: 0)
    }
  }

  private func publishPrinters(result: @escaping FlutterResult, attempt: Int) {
    let printers = zebraAccessories()
    log("LIST_PRINTERS attempt=\(attempt) count=\(printers.count)")
    if printers.isEmpty && attempt < 8 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        self.publishPrinters(result: result, attempt: attempt + 1)
      }
      return
    }
    for accessory in printers {
      log("LIST_PRINTERS result \(describe(accessory))")
    }
    result(printers.map { accessoryMap($0) })
  }

  private func showPicker(result: @escaping FlutterResult) {
    let finish: (Bool) -> Void = { value in
      self.log("SHOW_PICKER finish value=\(value)")
      DispatchQueue.main.async { result(value) }
    }
    DispatchQueue.main.async {
      self.log("SHOW_PICKER open")
      self.prepareAccessoryManager()
      EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { error in
        self.log("SHOW_PICKER closed \(self.pickerErrorLabel(error))")
        if let error = error as NSError?,
           error.domain == EABluetoothAccessoryPickerError.errorDomain,
           error.code == EABluetoothAccessoryPickerError.Code.resultFailed.rawValue {
          finish(false)
          return
        }
        self.waitForPrinter(attempt: 0) {
          finish(true)
        }
      }
    }
  }

  private func pickerErrorLabel(_ error: Error?) -> String {
    guard let error = error as NSError? else { return "error=none" }
    let code: String
    if error.domain == EABluetoothAccessoryPickerError.errorDomain {
      switch error.code {
      case EABluetoothAccessoryPickerError.Code.alreadyConnected.rawValue:
        code = "alreadyConnected"
      case EABluetoothAccessoryPickerError.Code.resultNotFound.rawValue:
        code = "resultNotFound"
      case EABluetoothAccessoryPickerError.Code.resultCancelled.rawValue:
        code = "resultCancelled"
      case EABluetoothAccessoryPickerError.Code.resultFailed.rawValue:
        code = "resultFailed"
      default:
        code = "\(error.code)"
      }
    } else {
      code = "\(error.code)"
    }
    return "domain=\(error.domain) code=\(code) \(error.localizedDescription)"
  }

  private func waitForPrinter(attempt: Int, done: @escaping () -> Void) {
    DispatchQueue.main.async {
      let printers = self.zebraAccessories()
      self.log("SHOW_PICKER wait attempt=\(attempt) count=\(printers.count)")
      if !printers.isEmpty || attempt >= 12 {
        done()
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        self.waitForPrinter(attempt: attempt + 1, done: done)
      }
    }
  }

  private func logConnected(_ reason: String) {
    let connected = EAAccessoryManager.shared().connectedAccessories
    log("\(reason) connectedAccessories count=\(connected.count)")
    for accessory in connected {
      log("\(reason) \(describe(accessory))")
    }
  }

  private func connect(identifier: String) -> Bool {
    log("connect identifier=\(identifier) alreadyOpen=\(isOpen)")
    let droppedNow = dropStaleSessionIfNeeded()
    let patient = droppedNow || droppedStaleRecently()
    if hasLiveSession(identifier) {
      log("connect already open")
      noteSessionUsed()
      return true
    }
    log("connect no session, opening a new one")
    if session != nil || outputStream != nil {
      disconnect()
    }
    // After a power cycle the old connection id stays reserved until we
    // close it. The printer then needs a few seconds to show up again.
    let attempts = patient ? 60 : 12
    if patient {
      log("connect waiting for the printer to replace the old connection")
    }
    guard let match = waitForAccessory(identifier, attempts: attempts) else {
      lastConnectError = "Connection Fail: turn Bluetooth off and on, then try again"
      log("connect no accessory for identifier=\(identifier)")
      notify("No paired Zebra printer")
      return false
    }
    log("connect match \(describe(match)) connected=\(match.isConnected)")
    if open(match) { return true }
    // The previous session can still own the port. Drop it and try once more.
    log("connect first open failed \(lastConnectError), releasing session")
    disconnect()
    Thread.sleep(forTimeInterval: 0.4)
    guard let retry = waitForAccessory(identifier) else {
      lastConnectError = "Connection Fail: turn Bluetooth off and on, then try again"
      log("connect retry found no accessory")
      return false
    }
    let retryOpened = open(retry)
    if !retryOpened && lastConnectError == "Connection Fail" {
      lastConnectError = "Connection Fail: session is still open"
    }
    return retryOpened
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
    try printPdfs(paths: [path], identifier: identifier)
    return true
  }

  /// One connection for every page. The session stays open so the next
  /// print can see the printer. It closes after 5 idle minutes, or when
  /// the app goes to the background.
  private func printPdfs(paths: [String], identifier: String, keepOpen: Bool = false) throws -> Bool {
    log("PRINT_PDFS start identifier=\(identifier) files=\(paths.count) keepOpen=\(keepOpen)")
    try ensureConnected(identifier)
    defer {
      log("PRINT_PDFS session stays open")
      noteSessionUsed()
    }
    // A format left from the previous session keeps the Bluetooth logo up.
    // Cancel it on this new session before the receipt is sent.
    _ = try? command("~JA", wait: 0.3)
    log("PRINT_PDFS cancelled leftover format")
    // ~HS is a ZPL status command. If it is sent before PDF mode, a ZQ320
    // prints the characters "~HS" and does not print the receipt.
    log("PRINT_PDFS skip ~HS")
    let previousApl = getVariable("apl.enable") ?? ""
    log("PRINT_PDFS previous apl.enable=\(previousApl)")
    let aplReply = try command("! U1 setvar \"apl.enable\" \"pdf\"")
    log("PRINT_PDFS set apl.enable=pdf reply=\(aplReply)")
    let scale = scaleSetting()
    let scaleReply = try command("! U1 setvar \"apl.settings\" \"\(scale)\"")
    log("PRINT_PDFS set apl.settings=\(scale) reply=\(scaleReply)")
    raisePrintSpeed()
    let previousMedia = getVariable("ezpl.media_type") ?? ""
    log("PRINT_PDFS previous media=\(previousMedia)")
    let mediaReply = (try? command("! U1 setvar \"ezpl.media_type\" \"continuous\"")) ?? ""
    log("PRINT_PDFS set media=continuous reply=\(mediaReply)")
    Thread.sleep(forTimeInterval: 0.2)
    let plus = isZq320Plus()
    log("PRINT_PDFS model plus=\(plus)")
    var totalBytes = 0
    do {
      for path in paths {
        let file = URL(fileURLWithPath: path)
        guard let pdf = try? Data(contentsOf: file), !pdf.isEmpty else {
          log("PRINT_PDFS empty file \(path)")
          throw PrinterFailure(code: "100", message: "PDF file is empty")
        }
        let header = String(data: pdf.prefix(8), encoding: .ascii) ?? ""
        log("PRINT_PDFS file bytes=\(pdf.count) header=\(header) path=\(path)")
        try write(pdf, timeout: 120)
        totalBytes += pdf.count
      }
      // The next PDF follows immediately, so the printer can start it
      // while the previous page is still coming out. One short pause
      // after the last page lets the Plus finish reading before close.
      let pause = plus ? 0.4 : 0.2
      log("PRINT_PDFS bytes sent=\(totalBytes), flush \(pause)s")
      Thread.sleep(forTimeInterval: pause)
    } catch {
      if let failure = error as? PrinterFailure {
        log("PRINT_PDFS failed \(failure.code) \(failure.message)")
      } else {
        log("PRINT_PDFS failed \(error.localizedDescription)")
      }
      if !plus {
        restorePdfSettings(previousApl, previousMedia)
      }
      throw error
    }
    if !plus {
      restorePdfSettings(previousApl, previousMedia)
    } else {
      log("PRINT_PDFS plus skip restore, bytes=\(totalBytes)")
    }
    log("PRINT_PDFS finished")
    notify("Printed")
    return true
  }

  /// The Plus model number is on the accessory. Host id is read before the
  /// PDF, so this command is not mixed into the file.
  private func isZq320Plus() -> Bool {
    let model = onMain { self.accessory?.modelNumber ?? "" }
    let name = onMain { self.accessory?.name ?? "" }
    let host = getVariable("device.host_identification") ?? ""
    let text = "\(model) \(name) \(host)".uppercased()
    let plus = text.contains("PLUS") || text.contains("ZQ32P")
    log("PRINT_PDFS identity model=\(model) name=\(name) host=\(host) plus=\(plus)")
    return plus
  }

  private func restorePdfSettings(_ previousApl: String, _ previousMedia: String) {
    let apl = previousApl.trimmingCharacters(in: .whitespacesAndNewlines)
    if !apl.isEmpty && apl.lowercased() != "pdf" {
      _ = try? command("! U1 setvar \"apl.enable\" \"\(apl)\"")
      log("PRINT_PDFS restore apl.enable=\(apl)")
    }
    restoreMedia(previousMedia)
  }

  private func restoreMedia(_ previousMedia: String) {
    let previous = previousMedia.trimmingCharacters(in: .whitespacesAndNewlines)
    if previous.isEmpty || previous.lowercased() == "continuous" { return }
    try? setVariable("ezpl.media_type", value: previous)
  }

  /// Link-OS status on iOS is the same ~HS reply Android reads:
  /// formats still in the buffer, and a partial format still rendering.
  private func waitUntilPrinterIdle() {
    var unknown = 0
    for _ in 0..<20 {
      guard let status = readHostStatus() else {
        unknown += 1
        if unknown >= 2 { return }
        Thread.sleep(forTimeInterval: 0.2)
        continue
      }
      if status.formatsInBuffer == 0 && !status.partialFormat { return }
      unknown = 0
      Thread.sleep(forTimeInterval: 0.2)
    }
  }

  private func throwIfNotReady() throws {
    guard let status = readHostStatus() else { return }
    if status.headOpen {
      throw PrinterFailure(code: "001", message: "Printer Head is Open")
    }
    if status.paperOut {
      throw PrinterFailure(code: "001", message: "Paper Out")
    }
    if status.paused {
      throw PrinterFailure(code: "001", message: "Fail Print")
    }
  }

  private func readHostStatus() -> HostStatus? {
    guard let raw = try? command("~HS"), !raw.isEmpty else { return nil }
    return HostStatus.parse(raw)
  }

  private func readHostIdentification(_ identifier: String) -> String {
    guard connect(identifier: identifier) else { return "" }
    noteSessionUsed()
    return getVariable("device.host_identification") ?? ""
  }

  private func ensureConnected(_ identifier: String) throws {
    if usingTcp, canReuseSession { return }
    if hasLiveSession(identifier) {
      log("SESSION already open")
      noteSessionUsed()
      return
    }
    log("SESSION missing, opening a new one")
    if !connect(identifier: identifier) {
      throw PrinterFailure(code: "004", message: lastConnectError)
    }
  }

  /// A print can run only on a session that is open and still attached
  /// to this printer. Anything else needs a new connection.
  private func hasLiveSession(_ identifier: String) -> Bool {
    !usingTcp && canReuseSession && matches(accessory, identifier: identifier)
  }

  /// A stream can still look open after the printer is switched off.
  /// Reusing it writes into a dead Bluetooth session. The accessory object
  /// we kept can also still say it is connected after iOS has dropped it
  /// from the live list, which is what blocks the printer for minutes.
  private var canReuseSession: Bool {
    onMain {
      guard self.outputStream?.streamStatus == .open else { return false }
      if self.usingTcp { return true }
      guard self.session != nil, let held = self.accessory else { return false }
      let live = EAAccessoryManager.shared().connectedAccessories
      return live.contains { $0.connectionID == held.connectionID }
    }
  }

  /// External Accessory streams belong to the run loop they were scheduled on.
  /// Reading or writing them from the print queue makes iOS fail the session
  /// with connection error 004.
  private func onMain<T>(_ work: () -> T) -> T {
    if Thread.isMainThread { return work() }
    var value: T!
    DispatchQueue.main.sync {
      value = work()
    }
    return value
  }

  private var isOpen: Bool {
    onMain {
      guard self.outputStream?.streamStatus == .open else { return false }
      return self.session != nil || self.usingTcp
    }
  }

  private func open(_ match: EAAccessory) -> Bool {
    log("open \(describe(match)) protocol=\(protocolString)")
    notify("Connecting...")
    let opened = onMain { () -> Bool in
      guard let session = EASession(accessory: match, forProtocol: self.protocolString) else {
        self.log("open EASession failed")
        self.lastConnectError = "Connection Fail: EASession failed"
        return false
      }
      self.session = session
      self.accessory = match
      self.inputStream = session.inputStream
      self.outputStream = session.outputStream
      self.inputStream?.delegate = self
      self.outputStream?.delegate = self
      for mode in [RunLoop.Mode.default, RunLoop.Mode.common] {
        self.inputStream?.schedule(in: .current, forMode: mode)
        self.outputStream?.schedule(in: .current, forMode: mode)
      }
      self.inputStream?.open()
      self.outputStream?.open()
      return true
    }
    guard opened else {
      notify("Comm Error! Disconnecting")
      disconnect()
      return false
    }
    guard waitUntilOutputOpen() else {
      notify("Comm Error! Disconnecting")
      disconnect()
      return false
    }
    notify("Connected")
    noteSessionUsed()
    startLinkWatch()
    return true
  }

  private func waitUntilOutputOpen() -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let status = onMain { self.outputStream?.streamStatus ?? .notOpen }
      log("open wait status=\(statusLabel(status))")
      if status == .open {
        Thread.sleep(forTimeInterval: 0.3)
        return true
      }
      if status == .error || status == .closed {
        let detail = onMain { self.streamState(self.outputStream) }
        lastConnectError = "Connection Fail: session did not open (\(detail))"
        log("open wait stream \(detail)")
        return false
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    lastConnectError = "Connection Fail: session did not open"
    log("open wait timed out")
    return false
  }

  private func statusLabel(_ status: Stream.Status) -> String {
    switch status {
    case .notOpen: return "notOpen"
    case .opening: return "opening"
    case .open: return "open"
    case .reading: return "reading"
    case .writing: return "writing"
    case .atEnd: return "atEnd"
    case .closed: return "closed"
    case .error: return "error"
    @unknown default: return "unknown"
    }
  }

  private func disconnect() {
    cancelIdleTimer()
    stopLinkWatch()
    let state = onMain { self.streamState(self.outputStream) }
    log("disconnect out=\(state)")
    notify("Disconnecting...")
    let close = {
      self.inputStream?.delegate = nil
      self.outputStream?.delegate = nil
      self.inputStream?.close()
      self.outputStream?.close()
      for mode in [RunLoop.Mode.default, RunLoop.Mode.common] {
        self.inputStream?.remove(from: .current, forMode: mode)
        self.outputStream?.remove(from: .current, forMode: mode)
      }
      self.inputStream = nil
      self.outputStream = nil
      self.session = nil
      self.accessory = nil
      self.usingTcp = false
      self.tcpHost = ""
      self.linkMisses = 0
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

  /// `connectedAccessories` stays empty until the app registers for accessory
  /// notifications, so a paired Zebra never shows up in the list.
  private func prepareAccessoryManager() {
    EAAccessoryManager.shared().registerForLocalNotifications()
  }

  private func zebraAccessories() -> [EAAccessory] {
    let read = { () -> [EAAccessory] in
      self.prepareAccessoryManager()
      // A powered-on Zebra can sit in this list with isConnected false for
      // a moment after the last session closes. Dropping it here made a
      // live printer look switched off.
      let connected = EAAccessoryManager.shared().connectedAccessories
      let matched = connected.filter { self.supportsZebraProtocol($0) }
      if connected.count != matched.count {
        self.log("protocol filter kept \(matched.count) of \(connected.count)")
      }
      if !matched.isEmpty { return matched }
      return connected
    }
    if Thread.isMainThread {
      return read()
    }
    return DispatchQueue.main.sync(execute: read)
  }

  private func supportsZebraProtocol(_ accessory: EAAccessory) -> Bool {
    accessory.protocolStrings.contains { name in
      name.trimmingCharacters(in: .whitespacesAndNewlines)
        .caseInsensitiveCompare(protocolString) == .orderedSame
    }
  }

  private func findAccessory(identifier: String) -> EAAccessory? {
    let printers = zebraAccessories()
    if identifier.isEmpty { return printers.first }
    if let exact = printers.first(where: { matches($0, identifier: identifier) }) {
      return exact
    }
    let zebra = printers.filter { supportsZebraProtocol($0) }
    if zebra.count == 1 { return zebra.first }
    if printers.count == 1 { return printers.first }
    return nil
  }

  /// A paired Zebra can take a moment to appear after the app registers
  /// for accessory notifications. The system pair dialog hides printers
  /// that are already paired, so this wait does not open it.
  private func waitForAccessory(_ identifier: String, attempts: Int = 12) -> EAAccessory? {
    for attempt in 0..<attempts {
      if let match = findAccessory(identifier: identifier) {
        log("connect accessory ready attempt=\(attempt) \(describe(match))")
        return match
      }
      log("connect accessory not listed yet attempt=\(attempt)")
      Thread.sleep(forTimeInterval: 0.25)
    }
    logConnected("connect still missing")
    return nil
  }

  private func matches(_ accessory: EAAccessory?, identifier: String) -> Bool {
    guard let accessory else { return false }
    if identifier.isEmpty { return true }
    let serial = accessory.serialNumber
    let name = accessory.name
    return serial.caseInsensitiveCompare(identifier) == .orderedSame
      || name.caseInsensitiveCompare(identifier) == .orderedSame
      || name.localizedCaseInsensitiveContains(identifier)
      || serial.localizedCaseInsensitiveContains(identifier)
      || String(accessory.connectionID) == identifier
  }

  private func accessoryMap(_ accessory: EAAccessory) -> [String: String] {
    let serial = accessory.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    let address = serial.isEmpty ? String(accessory.connectionID) : serial
    return [
      "name": printerLabel(accessory),
      "address": address,
      "serialNumber": serial,
      "model": accessory.modelNumber,
    ]
  }

  /// iOS accessory names often omit the model. Keep ZQ320 / ZQ520 in the
  /// saved name so the receipt length matches Android.
  private func printerLabel(_ accessory: EAAccessory) -> String {
    let model = accessory.modelNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = accessory.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if model.isEmpty { return name }
    if name.uppercased().contains(model.uppercased()) { return name }
    if name.isEmpty { return model }
    return "\(model) \(name)"
  }

  private func setVariable(_ name: String, value: String) throws {
    _ = try command("! U1 setvar \"\(name)\" \"\(value)\"")
  }

  private func getVariable(_ name: String) -> String? {
    try? command("! U1 getvar \"\(name)\"")
  }

  @discardableResult
  private func command(_ text: String, wait: TimeInterval = 1.2) throws -> String {
    let shown = text
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    log("command \(shown.prefix(120))")
    bufferLock.lock()
    inputBuffer.removeAll()
    bufferLock.unlock()
    var payload = text
    if !payload.hasSuffix("\r\n") { payload += "\r\n" }
    guard let data = payload.data(using: .utf8) else { return "" }
    try write(data)
    let deadline = Date().addingTimeInterval(wait)
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
    let reply = String(data: bytes, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
    log("command reply bytes=\(bytes.count) \(reply.prefix(160))")
    return reply
  }

  private func streamState(_ stream: Stream?) -> String {
    guard let stream else { return "nil" }
    switch stream.streamStatus {
    case .notOpen: return "notOpen"
    case .opening: return "opening"
    case .open: return "open"
    case .reading: return "reading"
    case .writing: return "writing"
    case .atEnd: return "atEnd"
    case .closed: return "closed"
    case .error: return "error \(stream.streamError?.localizedDescription ?? "")"
    @unknown default: return "unknown"
    }
  }

  private func write(_ data: Data, timeout: TimeInterval = 20) throws {
    log("write start bytes=\(data.count)")
    var offset = 0
    let deadline = Date().addingTimeInterval(timeout)
    while offset < data.count {
      if Date() > deadline {
        log("write timeout offset=\(offset) of \(data.count)")
        throw PrinterFailure(code: "001", message: "Fail Print")
      }
      let pending = data.subdata(in: offset..<data.count)
      let result = onMain { () -> (Int, String) in
        guard let output = self.outputStream else { return (-2, "nil") }
        let state = self.streamState(output)
        if output.streamStatus == .error || output.streamStatus == .closed {
          return (-3, state)
        }
        if !output.hasSpaceAvailable || output.streamStatus == .opening {
          return (0, state)
        }
        let written = pending.withUnsafeBytes { raw -> Int in
          guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
          return output.write(base, maxLength: pending.count)
        }
        return (written, state)
      }
      if result.0 == -2 {
        log("write no output stream offset=\(offset)")
        throw PrinterFailure(code: "004", message: "Connection Fail: no stream")
      }
      if result.0 == -3 {
        log("write stream closed status=\(result.1) offset=\(offset)")
        throw PrinterFailure(code: "004", message: "Connection Fail: \(result.1)")
      }
      if result.0 < 0 {
        log("write failed status=\(result.1) offset=\(offset)")
        throw PrinterFailure(code: "001", message: "Fail Print: \(result.1)")
      }
      if result.0 == 0 {
        Thread.sleep(forTimeInterval: 0.02)
        continue
      }
      offset += result.0
    }
    log("write done bytes=\(offset)")
  }

  /// The invoice PDF is 72 mm wide. 100% scale keeps that height so a receipt
  /// that fits the printer stays one label. scale-to-fit on a 4-inch
  /// ZQ520 / ZQ521 stretches the page and splits it.
  ///
  /// The table is gray. Dither turns that gray into a light dot pattern
  /// so the head is not burning a solid black rule on every row.
  private func scaleSetting() -> String {
    let identity = getVariable("device.host_identification") ?? ""
    let model = String(identity.prefix(5))
    if model.hasPrefix("ZQ52") || model.hasPrefix("ZQ32") {
      return "dither scale=100x100"
    }
    let fileWidth = 56.0
    let factor: Double
    switch model {
    case "iMZ22", "QLn22", "ZD410":
      factor = 2.0 / fileWidth * 100
    case "iMZ32", "QLn32", "ZQ510":
      factor = 3.0 / fileWidth * 100
    case "QLn42", "ZD420", "ZD500", "ZT220", "ZT230", "ZT410":
      factor = 4.0 / fileWidth * 100
    case "ZT420":
      factor = 6.5 / fileWidth * 100
    default:
      return "dither scale=100x100"
    }
    let percent = Int(factor)
    return "dither scale=\(percent)x\(percent)"
  }

  /// ZQ320 tops out at 4 inches per second. A table is dense enough that
  /// the printer otherwise drops below that.
  private func raisePrintSpeed() {
    let identity = (getVariable("device.host_identification") ?? "").uppercased()
    guard identity.contains("ZQ32") || identity.contains("ZQ52") else { return }
    let reply = (try? command("! U1 setvar \"media.speed\" \"4\"")) ?? ""
    log("PRINT_PDFS media.speed=4 reply=\(reply)")
  }

  private func sdk(_ args: [String: Any]) throws -> Any? {
    let op = sdkText(args, "op")
    switch op {
    case "discoverNetwork":
      return discoverNetwork(args)
    case "discoverUsb":
      throw PrinterFailure(code: "100", message: "USB printing is available on Android")
    case "connect":
      try requireSession(args)
      return true
    case "disconnect":
      disconnect()
      return true
    case "isConnected":
      return isOpen
    case "status":
      try requireSession(args)
      return statusMap()
    case "get":
      try requireSession(args)
      return getVariable(sdkText(args, "setting")) ?? ""
    case "set":
      try requireSession(args)
      try setVariable(sdkText(args, "setting"), value: sdkText(args, "value"))
      return true
    case "do":
      try requireSession(args)
      return try command("! U1 do \"\(sdkText(args, "command"))\" \"\(sdkText(args, "value"))\"", wait: 2.5)
    case "hostInfo":
      try requireSession(args)
      return hostInfo()
    case "printZpl":
      try requireSession(args)
      try setVariable("device.languages", value: "zpl")
      try throwIfNotReady()
      try write(Data(sdkText(args, "data").utf8))
      return true
    case "printCpcl":
      try requireSession(args)
      try? setVariable("device.languages", value: "cpcl")
      try write(Data(sdkText(args, "data").utf8))
      return true
    case "printRaw":
      try requireSession(args)
      guard let bytes = args["bytes"] as? FlutterStandardTypedData else {
        throw PrinterFailure(code: "100", message: "Expected bytes")
      }
      try write(bytes.data, timeout: 60)
      return true
    case "printPdfs":
      try requireSession(args)
      let paths = args["paths"] as? [String] ?? []
      if paths.isEmpty {
        throw PrinterFailure(code: "100", message: "Expected at least one PDF")
      }
      return try printPdfs(paths: paths, identifier: sdkText(args, "address"), keepOpen: true)
    case "printImage":
      try requireSession(args)
      try printImage(args)
      return true
    case "storeImage":
      try requireSession(args)
      try storeImage(args)
      return true
    case "calibrate":
      try requireSession(args)
      try write(Data("~JC\r\n".utf8))
      return true
    case "printConfigurationLabel":
      try requireSession(args)
      try write(Data("~WC\r\n".utf8))
      return true
    case "printNetworkConfigurationLabel":
      try requireSession(args)
      try write(Data("~WL\r\n".utf8))
      return true
    case "printDirectoryLabel":
      try requireSession(args)
      try write(Data("^XA^WD*:*.*^XZ".utf8))
      return true
    case "feed":
      try requireSession(args)
      try write(Data("^XA^PH^XZ".utf8))
      return true
    case "restoreDefaults":
      try requireSession(args)
      try write(Data("^XA^JUF^XZ".utf8))
      return true
    case "reset":
      try requireSession(args)
      try write(Data("~JR\r\n".utf8))
      return true
    case "listFiles":
      try requireSession(args)
      let drive = sdkText(args, "drive").isEmpty ? "E:" : sdkText(args, "drive")
      let listing = try command("! U1 do \"file.dir\" \"\(drive)\"", wait: 2.5)
      return listing
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.contains(":") && !$0.lowercased().hasPrefix("directory") }
    case "storeFile":
      try requireSession(args)
      try storeFile(printerPath: sdkText(args, "printerPath"), localPath: sdkText(args, "path"))
      return true
    case "sendFile":
      try requireSession(args)
      let file = URL(fileURLWithPath: sdkText(args, "path"))
      let data = try Data(contentsOf: file)
      try write(data, timeout: 60)
      return true
    case "deleteFile":
      try requireSession(args)
      _ = try command("! U1 do \"file.delete\" \"\(sdkText(args, "printerPath"))\"")
      return true
    case "retrieveFile":
      try requireSession(args)
      let body = try command("! U1 do \"file.type\" \"\(sdkText(args, "printerPath"))\"", wait: 3)
      return FlutterStandardTypedData(bytes: Data(body.utf8))
    case "printStoredFormat":
      try requireSession(args)
      try printStoredFormat(args)
      return true
    case "storageInfo":
      try requireSession(args)
      return storageInfo()
    case "odometer":
      try requireSession(args)
      return [
        "odometer.total_label_count": getVariable("odometer.total_label_count") ?? "",
        "odometer.user_label_count": getVariable("odometer.user_label_count") ?? "",
        "odometer.media_marker_count": getVariable("odometer.media_marker_count") ?? "",
        "odometer.headclean_count": getVariable("odometer.headclean_count") ?? "",
      ]
    case "setClock":
      try requireSession(args)
      try setVariable("rtc.date", value: sdkText(args, "date"))
      try setVariable("rtc.time", value: sdkText(args, "time"))
      return true
    default:
      throw PrinterFailure(code: "100", message: "Unknown SDK operation \(op)")
    }
  }

  private func requireSession(_ args: [String: Any]) throws {
    let address = sdkText(args, "address")
    let transport = sdkText(args, "transport")
    if transport == "usb" {
      throw PrinterFailure(code: "100", message: "USB printing is available on Android")
    }
    if address.isEmpty {
      if !isOpen {
        throw PrinterFailure(code: "004", message: "Not Connected")
      }
      return
    }
    if transport == "tcp" {
      try openTcp(host: address, port: sdkNumber(args, "port", 9100))
      return
    }
    if isOpen && !usingTcp && accessory?.serialNumber == address {
      return
    }
    if !connect(identifier: address) {
      throw PrinterFailure(code: "004", message: "Connection Fail")
    }
  }

  private func openTcp(host: String, port: Int) throws {
    if usingTcp && tcpHost == host && isOpen { return }
    disconnect()
    var input: InputStream?
    var output: OutputStream?
    Stream.getStreamsToHost(withName: host, port: port, inputStream: &input, outputStream: &output)
    guard let input, let output else {
      throw PrinterFailure(code: "004", message: "Connection Fail")
    }
    let start = {
      input.delegate = self
      output.delegate = self
      input.schedule(in: .current, forMode: .common)
      output.schedule(in: .current, forMode: .common)
      input.open()
      output.open()
      self.inputStream = input
      self.outputStream = output
      self.usingTcp = true
      self.tcpHost = host
    }
    if Thread.isMainThread {
      start()
    } else {
      DispatchQueue.main.sync(execute: start)
    }
    let deadline = Date().addingTimeInterval(5)
    while output.streamStatus == .opening && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if output.streamStatus != .open {
      disconnect()
      throw PrinterFailure(code: "004", message: "Connection Fail")
    }
    notify("Connected")
  }

  private func statusMap() -> [String: Any] {
    guard let status = readHostStatus() else {
      return [
        "isReadyToPrint": false,
        "isPaused": false,
        "isHeadOpen": false,
        "isPaperOut": false,
        "isRibbonOut": false,
        "isHeadCold": false,
        "isHeadTooHot": false,
        "isReceiveBufferFull": false,
        "isPartialFormatInProgress": false,
        "labelLengthInDots": 0,
        "numberOfFormatsInReceiveBuffer": 0,
        "labelsRemainingInBatch": 0,
        "printMode": "",
      ]
    }
    let ready = !status.paused && !status.headOpen && !status.paperOut && !status.ribbonOut
    return [
      "isReadyToPrint": ready,
      "isPaused": status.paused,
      "isHeadOpen": status.headOpen,
      "isPaperOut": status.paperOut,
      "isRibbonOut": status.ribbonOut,
      "isHeadCold": status.headCold,
      "isHeadTooHot": status.headTooHot,
      "isReceiveBufferFull": status.bufferFull,
      "isPartialFormatInProgress": status.partialFormat,
      "labelLengthInDots": status.labelLength,
      "numberOfFormatsInReceiveBuffer": status.formatsInBuffer,
      "labelsRemainingInBatch": status.labelsRemaining,
      "printMode": "",
    ]
  }

  private func hostInfo() -> [String: String] {
    let keys = [
      "device.host_identification",
      "device.product_name",
      "device.friendly_name",
      "appl.name",
      "device.languages",
      "ezpl.media_type",
      "ezpl.print_width",
      "zpl.label_length",
      "print.tone",
      "media.speed",
      "power.percent_full",
      "ip.addr",
    ]
    var info: [String: String] = [:]
    for key in keys {
      info[key] = getVariable(key) ?? ""
    }
    info["language"] = info["device.languages"] ?? ""
    return info
  }

  private func storageInfo() -> [[String: Any]] {
    let flash = Int(getVariable("memory.flash_free")?.filter(\.isNumber) ?? "") ?? 0
    let ram = Int(getVariable("memory.ram_free")?.filter(\.isNumber) ?? "") ?? 0
    return [
      ["driveLetter": "E", "driveType": "FLASH", "bytesFree": flash, "isPersistent": true],
      ["driveLetter": "R", "driveType": "RAM", "bytesFree": ram, "isPersistent": false],
    ]
  }

  private func printStoredFormat(_ args: [String: Any]) throws {
    var zpl = "^XA^XF\(sdkText(args, "printerPath"))^FS"
    let fields = args["fields"] as? [String: Any] ?? [:]
    let keys = fields.keys.sorted {
      (Int($0) ?? 0) < (Int($1) ?? 0)
    }
    for key in keys {
      let value = fields[key].map { "\($0)" } ?? ""
      zpl += "^FN\(key)^FD\(value)^FS"
    }
    zpl += "^XZ"
    try write(Data(zpl.utf8))
  }

  private func printImage(_ args: [String: Any]) throws {
    let graphic = try graphicCommand(
      path: sdkText(args, "path"),
      width: sdkNumber(args, "width", 0),
      height: sdkNumber(args, "height", 0)
    )
    let zpl = "^XA^FO\(sdkNumber(args, "x", 0)),\(sdkNumber(args, "y", 0))\(graphic)^FS^XZ"
    try write(Data(zpl.utf8), timeout: 60)
  }

  private func storeImage(_ args: [String: Any]) throws {
    let graphic = try graphicCommand(
      path: sdkText(args, "path"),
      width: sdkNumber(args, "width", 0),
      height: sdkNumber(args, "height", 0)
    )
    let zpl = "^XA^DF\(sdkText(args, "printerPath"))^FS^FO0,0\(graphic)^FS^XZ"
    try write(Data(zpl.utf8), timeout: 60)
  }

  private func storeFile(printerPath: String, localPath: String) throws {
    let file = URL(fileURLWithPath: localPath)
    let data = try Data(contentsOf: file)
    if printerPath.uppercased().hasSuffix(".ZPL") {
      let body = String(data: data, encoding: .utf8) ?? ""
      let zpl = "^XA^DF\(printerPath)^FS\(body)^XZ"
      try write(Data(zpl.utf8), timeout: 60)
      return
    }
    let hex = data.map { String(format: "%02X", $0) }.joined()
    let command = "~DY\(printerPath),A,B,\(data.count),\(data.count),\(hex)\r\n"
    try write(Data(command.utf8), timeout: 60)
  }

  private func graphicCommand(path: String, width: Int, height: Int) throws -> String {
    guard let image = UIImage(contentsOfFile: path)?.cgImage else {
      throw PrinterFailure(code: "100", message: "Image file could not be read")
    }
    let targetWidth = width > 0 ? width : image.width
    let targetHeight = height > 0 ? height : image.height
    let bytesPerRow = (targetWidth + 7) / 8
    var pixels = [UInt8](repeating: 255, count: targetWidth * targetHeight)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let context = CGContext(
      data: &pixels,
      width: targetWidth,
      height: targetHeight,
      bitsPerComponent: 8,
      bytesPerRow: targetWidth,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else {
      throw PrinterFailure(code: "100", message: "Image file could not be read")
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    var hex = ""
    hex.reserveCapacity(bytesPerRow * targetHeight * 2)
    for y in 0..<targetHeight {
      for byteIndex in 0..<bytesPerRow {
        var value: UInt8 = 0
        for bit in 0..<8 {
          let x = byteIndex * 8 + bit
          if x >= targetWidth { continue }
          let sample = pixels[y * targetWidth + x]
          if sample < 128 {
            value |= UInt8(0x80 >> bit)
          }
        }
        hex += String(format: "%02X", value)
      }
    }
    let total = bytesPerRow * targetHeight
    return "^GFA,\(total),\(total),\(bytesPerRow),\(hex)"
  }

  private func discoverNetwork(_ args: [String: Any]) -> [[String: Any]] {
    let subnet = sdkText(args, "subnet")
    let parts = subnet.split(separator: ".").map(String.init)
    guard parts.count == 4, let a = parts.first else { return [] }
    let prefix = parts.prefix(3).joined(separator: ".")
    let last = Int(parts[3]) ?? 0
    let hosts: [String]
    if last != 0 && last != 255 {
      hosts = [subnet]
    } else if !prefix.isEmpty && prefix != a {
      hosts = (1...254).map { "\(prefix).\($0)" }
    } else {
      return []
    }
    var found: [[String: Any]] = []
    let queue = DispatchQueue(label: "zebra.network.discover", attributes: .concurrent)
    let group = DispatchGroup()
    let lock = NSLock()
    let slots = DispatchSemaphore(value: 24)
    for host in hosts {
      slots.wait()
      group.enter()
      queue.async {
        defer { slots.signal() }
        if self.probe(host: host, port: UInt16(self.sdkNumber(args, "port", 9100))) {
          lock.lock()
          found.append([
            "name": host,
            "address": host,
            "transport": "tcp",
            "port": self.sdkNumber(args, "port", 9100),
          ])
          lock.unlock()
        }
        group.leave()
      }
    }
    _ = group.wait(timeout: .now() + 12)
    return found.sorted { ($0["address"] as? String ?? "") < ($1["address"] as? String ?? "") }
  }

  private func probe(host: String, port: UInt16) -> Bool {
    let connection = NWConnection(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port) ?? 9100,
      using: .tcp
    )
    let ready = DispatchSemaphore(value: 0)
    var opened = false
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        opened = true
        ready.signal()
      case .failed, .cancelled:
        ready.signal()
      default:
        break
      }
    }
    connection.start(queue: DispatchQueue.global(qos: .utility))
    _ = ready.wait(timeout: .now() + 0.35)
    connection.cancel()
    return opened
  }

  private func sdkText(_ args: [String: Any], _ key: String) -> String {
    args[key].map { "\($0)" } ?? ""
  }

  private func sdkNumber(_ args: [String: Any], _ key: String, _ fallback: Int) -> Int {
    if let value = args[key] as? Int { return value }
    if let value = args[key] as? NSNumber { return value.intValue }
    if let value = args[key] as? String, let parsed = Int(value) { return parsed }
    return fallback
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

/// First two lines of a Zebra ~HS host-status reply.
private struct HostStatus {
  let formatsInBuffer: Int
  let partialFormat: Bool
  let headOpen: Bool
  let paperOut: Bool
  let paused: Bool
  let ribbonOut: Bool
  let headCold: Bool
  let headTooHot: Bool
  let bufferFull: Bool
  let labelLength: Int
  let labelsRemaining: Int

  static func parse(_ raw: String) -> HostStatus? {
    let cleaned = raw
      .replacingOccurrences(of: "\u{02}", with: "")
      .replacingOccurrences(of: "\u{03}", with: "")
    let lines = cleaned
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard let first = lines.first else { return nil }
    let communication = first.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard communication.count >= 8, let formats = Int(communication[4]) else { return nil }
    var headOpen = false
    var ribbonOut = false
    var labelsRemaining = 0
    if lines.count > 1 {
      let function = lines[1].split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if function.count > 2 { headOpen = function[2] == "1" }
      if function.count > 3 { ribbonOut = function[3] == "1" }
      if function.count > 8 { labelsRemaining = Int(function[8]) ?? 0 }
    }
    return HostStatus(
      formatsInBuffer: formats,
      partialFormat: communication[7] == "1",
      headOpen: headOpen,
      paperOut: communication.count > 1 && communication[1] == "1",
      paused: communication.count > 2 && communication[2] == "1",
      ribbonOut: ribbonOut,
      headCold: communication.count > 10 && communication[10] == "1",
      headTooHot: communication.count > 11 && communication[11] == "1",
      bufferFull: communication.count > 5 && communication[5] == "1",
      labelLength: Int(communication.count > 3 ? communication[3] : "") ?? 0,
      labelsRemaining: labelsRemaining
    )
  }
}
