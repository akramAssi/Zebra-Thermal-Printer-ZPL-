#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <string>

#include "zebra_bluetooth_printer_plugin.h"

namespace zebra_bluetooth_printer {
namespace test {

TEST(ZebraBluetoothPrinterPlugin, GetPlatformVersion) {
  ZebraBluetoothPrinterPlugin plugin;
  std::string result_string;
  plugin.HandleMethodCall(
      flutter::MethodCall<flutter::EncodableValue>(
          "GET_PLATFORM_VERSION",
          std::make_unique<flutter::EncodableValue>()),
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [&result_string](const flutter::EncodableValue* result) {
            if (result == nullptr) return;
            if (const auto* text = std::get_if<std::string>(result)) {
              result_string = *text;
            }
          },
          nullptr, nullptr));

  EXPECT_TRUE(result_string.rfind("Windows ", 0) == 0);
}

}  // namespace test
}  // namespace zebra_bluetooth_printer
