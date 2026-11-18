#ifndef FLUTTER_PLUGIN_ZEBRA_BLUETOOTH_PRINTER_PLUGIN_H_
#define FLUTTER_PLUGIN_ZEBRA_BLUETOOTH_PRINTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace zebra_bluetooth_printer {

class ZebraBluetoothPrinterPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  ZebraBluetoothPrinterPlugin();

  virtual ~ZebraBluetoothPrinterPlugin();

  ZebraBluetoothPrinterPlugin(const ZebraBluetoothPrinterPlugin&) = delete;
  ZebraBluetoothPrinterPlugin& operator=(const ZebraBluetoothPrinterPlugin&) =
      delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace zebra_bluetooth_printer

#endif  // FLUTTER_PLUGIN_ZEBRA_BLUETOOTH_PRINTER_PLUGIN_H_
