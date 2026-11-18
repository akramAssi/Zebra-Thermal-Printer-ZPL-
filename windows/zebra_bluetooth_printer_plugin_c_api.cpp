#include "include/zebra_bluetooth_printer/zebra_bluetooth_printer_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "zebra_bluetooth_printer_plugin.h"

void ZebraBluetoothPrinterPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  zebra_bluetooth_printer::ZebraBluetoothPrinterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
