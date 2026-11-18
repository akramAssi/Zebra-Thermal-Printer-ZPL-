import Flutter
import Network
import UIKit

private let portalNetworkBrowser: NWBrowser = {
  let browser = NWBrowser(
    for: .bonjour(type: "_zebra-printer._tcp", domain: nil),
    using: .tcp
  )
  browser.start(queue: .main)
  return browser
}()

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = portalNetworkBrowser
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
