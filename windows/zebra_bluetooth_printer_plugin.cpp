// Windows speaks the same printer commands as iOS. The behaviors below are
// the ones already fixed on the phone. Do not drop them to "simplify" this
// file:
//
// * Classic Bluetooth serial-port profile, not BLE. Paired printers stay in
//   the list when they are not in an active connection.
// * The session stays open after a print and closes after 5 idle minutes,
//   or when the app exits.
// * If the printer powers off, the dead socket is released immediately so
//   the next connect is not blocked by the old one. That next connect waits
//   and retries instead of reporting the printer as off.
// * A PDF is sent only after apl.enable is pdf. ~HS is not written on that
//   path. A ZQ320 prints the characters "~HS" and skips the receipt when
//   that command arrives before PDF mode.
// * Every PDF byte is written before the call returns. The socket is not
//   closed at the end of the print.
// * ZQ320 Plus does not get its PDF settings restored after the file. A
//   setting written then is read as part of the PDF and the printer locks.
// * No extra Bluetooth permission is required to connect.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <ws2bth.h>
#include <windows.h>
#include <shellapi.h>
#include <VersionHelpers.h>
#include <bluetoothapis.h>
#include <setupapi.h>
#include <winspool.h>
#include <wincodec.h>
#include <objbase.h>

#include "zebra_bluetooth_printer_plugin.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace zebra_bluetooth_printer {
namespace {

constexpr UINT kReplyMessage = WM_APP + 42;
constexpr UINT kEventMessage = WM_APP + 43;
constexpr int64_t kIdleLimitMs = 5 * 60 * 1000;
constexpr int64_t kStaleWindowMs = 30 * 1000;
constexpr int kImagingPrinterClass = 0x0680;

const GUID kSerialPortService = {
    0x00001101, 0x0000, 0x1000, {0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB}};
const GUID kPortsClass = {
    0x4d36e978, 0xe325, 0x11ce, {0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}};
const GUID kWicFactory = {
    0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
const GUID kGray8 = {
    0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f}};

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

struct Fail {
  std::string code;
  std::string message;
  bool failed() const { return !code.empty(); }
};

struct Reply {
  std::shared_ptr<flutter::MethodResult<EncodableValue>> result;
  int kind = 0;
  EncodableValue value;
  std::string code;
  std::string message;
};

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

void Log(const std::string& message) {
  const std::string line = "[ZebraBT] " + message + "\n";
  OutputDebugStringA(line.c_str());
}

std::string Upper(std::string text) {
  for (char& ch : text) {
    ch = static_cast<char>(std::toupper(static_cast<unsigned char>(ch)));
  }
  return text;
}

std::string Trim(std::string text) {
  size_t start = 0;
  while (start < text.size() &&
         std::isspace(static_cast<unsigned char>(text[start]))) {
    start++;
  }
  size_t end = text.size();
  while (end > start &&
         std::isspace(static_cast<unsigned char>(text[end - 1]))) {
    end--;
  }
  text = text.substr(start, end - start);
  if (text.size() >= 2 && text.front() == '"' && text.back() == '"') {
    text = text.substr(1, text.size() - 2);
  }
  return text;
}

int HexValue(char ch) {
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
  if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
  return -1;
}

int ParseInt(const std::string& text, int fallback) {
  if (text.empty()) return fallback;
  size_t index = 0;
  int sign = 1;
  if (text[0] == '-') {
    sign = -1;
    index = 1;
  }
  if (index >= text.size()) return fallback;
  int value = 0;
  for (; index < text.size(); index++) {
    const char ch = text[index];
    if (ch < '0' || ch > '9') return fallback;
    value = value * 10 + (ch - '0');
  }
  return value * sign;
}

std::string WideToUtf8(const wchar_t* text) {
  if (text == nullptr || text[0] == L'\0') return {};
  const int size =
      WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string out(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), size, nullptr, nullptr);
  return out;
}

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (size <= 1) return {};
  std::wstring out(static_cast<size_t>(size - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), size);
  return out;
}

bool ParseMac(const std::string& text, BTH_ADDR* out) {
  unsigned int bytes[6];
  const char* cursor = text.c_str();
  for (int i = 0; i < 6; i++) {
    const int hi = HexValue(cursor[0]);
    const int lo = HexValue(cursor[1]);
    if (hi < 0 || lo < 0) return false;
    bytes[i] = static_cast<unsigned int>(hi * 16 + lo);
    cursor += 2;
    if (i < 5) {
      if (*cursor != ':' && *cursor != '-') return false;
      cursor++;
    }
  }
  if (*cursor != '\0') return false;
  *out = (static_cast<BTH_ADDR>(bytes[0]) << 40) |
         (static_cast<BTH_ADDR>(bytes[1]) << 32) |
         (static_cast<BTH_ADDR>(bytes[2]) << 24) |
         (static_cast<BTH_ADDR>(bytes[3]) << 16) |
         (static_cast<BTH_ADDR>(bytes[4]) << 8) |
         static_cast<BTH_ADDR>(bytes[5]);
  return true;
}

std::string FormatMac(BTH_ADDR address) {
  char buf[18];
  sprintf_s(buf, "%02X:%02X:%02X:%02X:%02X:%02X",
            static_cast<unsigned>((address >> 40) & 0xff),
            static_cast<unsigned>((address >> 32) & 0xff),
            static_cast<unsigned>((address >> 24) & 0xff),
            static_cast<unsigned>((address >> 16) & 0xff),
            static_cast<unsigned>((address >> 8) & 0xff),
            static_cast<unsigned>(address & 0xff));
  return buf;
}

bool IsZebraName(const std::string& name) {
  const std::string upper = Upper(name);
  if (upper.empty()) return false;
  return upper.rfind("XX", 0) == 0 || upper.find("ZEBRA") != std::string::npos ||
         upper.rfind("ZD", 0) == 0 || upper.rfind("ZQ", 0) == 0 ||
         upper.rfind("ZT", 0) == 0 || upper.rfind("GK", 0) == 0 ||
         upper.rfind("GX", 0) == 0 || upper.rfind("QLN", 0) == 0;
}

bool IsLikelyPrinter(const std::string& name, ULONG device_class) {
  if (IsZebraName(name)) return true;
  const int klass = static_cast<int>(device_class & 0x1FFC);
  if (klass == kImagingPrinterClass) return true;
  const int major = static_cast<int>((device_class >> 8) & 0x1F);
  return major == 0x06;
}

bool IsComPort(const std::string& address) {
  const std::string upper = Upper(address);
  std::string port = upper;
  const std::string prefix = "\\\\.\\";
  if (port.rfind(prefix, 0) == 0) port = port.substr(prefix.size());
  if (port.rfind("COM", 0) != 0 || port.size() < 4) return false;
  for (size_t i = 3; i < port.size(); i++) {
    if (!std::isdigit(static_cast<unsigned char>(port[i]))) return false;
  }
  return true;
}

bool SameText(const std::string& left, const std::string& right) {
  return Upper(left) == Upper(right);
}

bool ContainsText(const std::string& haystack, const std::string& needle) {
  if (needle.empty()) return true;
  return Upper(haystack).find(Upper(needle)) != std::string::npos;
}

const EncodableValue* Arg(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(std::string(key)));
  if (it == map.end()) return nullptr;
  return &it->second;
}

std::string AsString(const EncodableValue* value) {
  if (value == nullptr) return {};
  if (const auto* text = std::get_if<std::string>(value)) return *text;
  if (const auto* number = std::get_if<int32_t>(value)) return std::to_string(*number);
  if (const auto* number = std::get_if<int64_t>(value)) return std::to_string(*number);
  return {};
}

int AsInt(const EncodableValue* value, int fallback) {
  if (value == nullptr) return fallback;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  if (const auto* number = std::get_if<int64_t>(value)) return static_cast<int>(*number);
  if (const auto* text = std::get_if<std::string>(value)) return ParseInt(*text, fallback);
  return fallback;
}

struct HostStatus {
  int formats_in_buffer = 0;
  bool partial_format = false;
  bool head_open = false;
  bool paper_out = false;
  bool paused = false;
  bool ribbon_out = false;
  bool head_cold = false;
  bool head_too_hot = false;
  bool buffer_full = false;
  int label_length = 0;
  int labels_remaining = 0;
  bool parsed = false;
};

std::vector<std::string> SplitLines(const std::string& text) {
  std::vector<std::string> lines;
  std::string current;
  for (char ch : text) {
    if (ch == '\n' || ch == '\r') {
      if (!current.empty()) lines.push_back(current);
      current.clear();
      continue;
    }
    if (ch != '\x02' && ch != '\x03') current.push_back(ch);
  }
  if (!current.empty()) lines.push_back(current);
  return lines;
}

std::vector<std::string> SplitComma(const std::string& text) {
  std::vector<std::string> parts;
  std::string current;
  for (char ch : text) {
    if (ch == ',') {
      parts.push_back(Trim(current));
      current.clear();
    } else {
      current.push_back(ch);
    }
  }
  parts.push_back(Trim(current));
  return parts;
}

HostStatus ParseHostStatus(const std::string& raw) {
  HostStatus status;
  const std::vector<std::string> lines = SplitLines(raw);
  if (lines.empty()) return status;
  const std::vector<std::string> communication = SplitComma(lines[0]);
  if (communication.size() < 8) return status;
  const int formats = ParseInt(communication[4], -1);
  if (formats < 0) return status;
  status.parsed = true;
  status.formats_in_buffer = formats;
  status.paper_out = communication.size() > 1 && communication[1] == "1";
  status.paused = communication.size() > 2 && communication[2] == "1";
  status.label_length = ParseInt(communication.size() > 3 ? communication[3] : "", 0);
  status.buffer_full = communication.size() > 5 && communication[5] == "1";
  status.partial_format = communication[7] == "1";
  status.head_cold = communication.size() > 10 && communication[10] == "1";
  status.head_too_hot = communication.size() > 11 && communication[11] == "1";
  if (lines.size() > 1) {
    const std::vector<std::string> function = SplitComma(lines[1]);
    if (function.size() > 2) status.head_open = function[2] == "1";
    if (function.size() > 3) status.ribbon_out = function[3] == "1";
    if (function.size() > 8) status.labels_remaining = ParseInt(function[8], 0);
  }
  return status;
}

EncodableMap StatusMap(const HostStatus& status) {
  EncodableMap map;
  const bool ready = status.parsed && !status.paused && !status.head_open &&
                     !status.paper_out && !status.ribbon_out;
  map[EncodableValue("isReadyToPrint")] = EncodableValue(ready);
  map[EncodableValue("isPaused")] = EncodableValue(status.paused);
  map[EncodableValue("isHeadOpen")] = EncodableValue(status.head_open);
  map[EncodableValue("isPaperOut")] = EncodableValue(status.paper_out);
  map[EncodableValue("isRibbonOut")] = EncodableValue(status.ribbon_out);
  map[EncodableValue("isHeadCold")] = EncodableValue(status.head_cold);
  map[EncodableValue("isHeadTooHot")] = EncodableValue(status.head_too_hot);
  map[EncodableValue("isReceiveBufferFull")] = EncodableValue(status.buffer_full);
  map[EncodableValue("isPartialFormatInProgress")] =
      EncodableValue(status.partial_format);
  map[EncodableValue("labelLengthInDots")] =
      EncodableValue(static_cast<int32_t>(status.label_length));
  map[EncodableValue("numberOfFormatsInReceiveBuffer")] =
      EncodableValue(static_cast<int32_t>(status.formats_in_buffer));
  map[EncodableValue("labelsRemainingInBatch")] =
      EncodableValue(static_cast<int32_t>(status.labels_remaining));
  map[EncodableValue("printMode")] = EncodableValue(std::string());
  return map;
}

EncodableMap EmptyStatus() {
  return StatusMap(HostStatus{});
}

}  // namespace

struct ZebraBluetoothPrinterPlugin::Impl {
  Impl() {
    WSADATA data = {};
    wsa_ready_ = WSAStartup(MAKEWORD(2, 2), &data) == 0;

    WNDCLASSW window_class = {};
    window_class.lpfnWndProc = ReplyWindowProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"ZebraBluetoothPrinterReply";
    RegisterClassW(&window_class);
    hwnd_ = CreateWindowExW(0, window_class.lpszClassName, L"", 0, 0, 0, 0, 0,
                            HWND_MESSAGE, nullptr, window_class.hInstance, nullptr);
    if (hwnd_ != nullptr) {
      SetWindowLongPtrW(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    }

    worker_ = std::thread([this] { WorkerLoop(); });
    idle_thread_ = std::thread([this] { IdleLoop(); });
    link_thread_ = std::thread([this] { LinkLoop(); });
  }

  ~Impl() {
    stop_side_threads_.store(true);
    if (idle_thread_.joinable()) idle_thread_.join();
    if (link_thread_.joinable()) link_thread_.join();
    const SOCKET open_socket = socket_.load();
    if (open_socket != INVALID_SOCKET) shutdown(open_socket, SD_BOTH);
    if (com_ != INVALID_HANDLE_VALUE) CancelIoEx(com_, nullptr);
    {
      std::lock_guard<std::mutex> lock(queue_mu_);
      stop_worker_ = true;
    }
    queue_cv_.notify_all();
    if (worker_.joinable()) worker_.join();
    Disconnect(false);
    if (hwnd_ != nullptr) {
      MSG message;
      while (PeekMessageW(&message, hwnd_, kReplyMessage, kEventMessage, PM_REMOVE)) {
        DispatchMessageW(&message);
      }
      DestroyWindow(hwnd_);
      hwnd_ = nullptr;
    }
    if (messenger_ != nullptr && channel_ != nullptr) {
      channel_->SetMethodCallHandler(nullptr);
    }
    if (messenger_ != nullptr && event_channel_ != nullptr) {
      event_channel_->SetStreamHandler(nullptr);
    }
    if (wsa_ready_) WSACleanup();
  }

  void Attach(flutter::BinaryMessenger* messenger) {
    messenger_ = messenger;
    channel_ =
        std::make_unique<flutter::MethodChannel<EncodableValue>>(
            messenger, "zebra_bluetooth_printer",
            &flutter::StandardMethodCodec::GetInstance());
    event_channel_ =
        std::make_unique<flutter::EventChannel<EncodableValue>>(
            messenger, "zebra_bluetooth_printer_stream",
            &flutter::StandardMethodCodec::GetInstance());
    event_channel_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<flutter::EventSink<EncodableValue>>&& events) {
              event_sink_ = std::move(events);
              return std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>();
            },
            [this](const EncodableValue*) {
              event_sink_.reset();
              return std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>();
            }));
  }

  void Handle(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const std::string& method = call.method_name();
    if (method == "GET_PLATFORM_VERSION") {
      result->Success(EncodableValue(PlatformVersion()));
      return;
    }
    if (method == "SHOW_PICKER") {
      const HINSTANCE opened = ShellExecuteW(nullptr, L"open", L"ms-settings:bluetooth",
                                             nullptr, nullptr, SW_SHOWNORMAL);
      result->Success(EncodableValue(reinterpret_cast<INT_PTR>(opened) > 32));
      return;
    }
    Post([this, method, args = call.arguments() ? *call.arguments() : EncodableValue(),
          result = std::shared_ptr<flutter::MethodResult<EncodableValue>>(
              result.release())]() mutable {
      Dispatch(method, args, std::move(result));
    });
  }

  flutter::BinaryMessenger* messenger_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> event_sink_;

 private:
  static LRESULT CALLBACK ReplyWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                           LPARAM lparam) {
    if (message == kReplyMessage) {
      auto* reply = reinterpret_cast<Reply*>(lparam);
      if (reply != nullptr && reply->result) {
        if (reply->kind == 1) {
          reply->result->Error(reply->code, reply->message);
        } else if (reply->kind == 2) {
          reply->result->NotImplemented();
        } else {
          reply->result->Success(reply->value);
        }
      }
      delete reply;
      return 0;
    }
    if (message == kEventMessage) {
      auto* impl = reinterpret_cast<Impl*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
      auto* text = reinterpret_cast<std::string*>(lparam);
      if (impl != nullptr && impl->event_sink_ && text != nullptr) {
        impl->event_sink_->Success(EncodableValue(*text));
      }
      delete text;
      return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  void Post(std::function<void()> job) {
    {
      std::lock_guard<std::mutex> lock(queue_mu_);
      if (stop_worker_) return;
      jobs_.push_back(std::move(job));
    }
    queue_cv_.notify_one();
  }

  void WorkerLoop() {
    for (;;) {
      std::function<void()> job;
      {
        std::unique_lock<std::mutex> lock(queue_mu_);
        queue_cv_.wait(lock, [this] { return stop_worker_ || !jobs_.empty(); });
        if (jobs_.empty()) return;
        job = std::move(jobs_.front());
        jobs_.pop_front();
      }
      job();
    }
  }

  void WaitSide(int total_ms) {
    int left = total_ms;
    while (left > 0 && !stop_side_threads_.load()) {
      const int slice = left > 200 ? 200 : left;
      Sleep(slice);
      left -= slice;
    }
  }

  void IdleLoop() {
    while (!stop_side_threads_.load()) {
      WaitSide(10000);
      if (stop_side_threads_.load()) return;
      const int64_t used = last_used_ms_.load();
      if (!session_open_.load() || used == 0) continue;
      if (NowMs() - used < kIdleLimitMs) continue;
      Log("SESSION idle 5 min, disconnect");
      Post([this] { Disconnect(false); });
    }
  }

  void LinkLoop() {
    int misses = 0;
    while (!stop_side_threads_.load()) {
      WaitSide(1000);
      if (stop_side_threads_.load()) return;
      if (!session_open_.load() || kind_ == Kind::kSpooler) {
        misses = 0;
        continue;
      }
      if (!peer_closed_.load()) {
        misses = 0;
        continue;
      }
      misses++;
      Log("SESSION link watch miss " + std::to_string(misses));
      if (misses < 2) continue;
      misses = 0;
      Log("SESSION link watch dropping old connection");
      Post([this] { Disconnect(true); });
    }
  }

  enum class Kind { kNone, kSocket, kCom, kSpooler };

  void Dispatch(const std::string& method, const EncodableValue& args,
                std::shared_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (method == "LIST_PRINTERS") {
      EncodableList rows;
      if (!ListPrinters(&rows)) {
        FinishError(std::move(result), "004", last_error_);
      } else {
        Finish(std::move(result), EncodableValue(rows));
      }
      return;
    }
    if (method == "CONNECT") {
      const std::string address = std::get_if<std::string>(&args) ? *std::get_if<std::string>(&args) : std::string();
      if (ConnectBluetooth(address)) {
        Finish(std::move(result), EncodableValue(true));
      } else {
        FinishError(std::move(result), "004", last_error_);
      }
      return;
    }
    if (method == "DISCONNECT") {
      Disconnect(false);
      Finish(std::move(result), EncodableValue(true));
      return;
    }
    if (method == "PRINT_ZPL" || method == "PRINT_PDF" || method == "PRINT_PDFS") {
      const auto* list = std::get_if<EncodableList>(&args);
      if (list == nullptr || list->size() < 2) {
        FinishError(std::move(result), "100", "Expected printer and payload");
        return;
      }
      const std::string address = AsString(&(*list)[0]);
      Fail error;
      if (method == "PRINT_ZPL") {
        error = PrintZpl(AsString(&(*list)[1]), address);
      } else if (method == "PRINT_PDF") {
        error = PrintPdfs({AsString(&(*list)[1])}, address);
      } else {
        std::vector<std::string> paths;
        for (size_t i = 1; i < list->size(); i++) paths.push_back(AsString(&(*list)[i]));
        error = PrintPdfs(paths, address);
      }
      if (error.failed()) {
        Notify(error.message);
        FinishError(std::move(result), error.code, error.message);
      } else {
        Finish(std::move(result), EncodableValue(true));
      }
      return;
    }
    if (method == "HOST_IDENTIFICATION") {
      const std::string address =
          std::get_if<std::string>(&args) ? *std::get_if<std::string>(&args) : std::string();
      Finish(std::move(result), EncodableValue(ReadHost(address)));
      return;
    }
    if (method == "SDK") {
      const auto* map = std::get_if<EncodableMap>(&args);
      if (map == nullptr) {
        FinishError(std::move(result), "100", "Expected SDK arguments");
        return;
      }
      EncodableValue value;
      const Fail error = RunSdk(*map, &value);
      if (error.failed()) {
        Notify(error.message);
        FinishError(std::move(result), error.code, error.message);
      } else {
        Finish(std::move(result), value);
      }
      return;
    }
    FinishNotImplemented(std::move(result));
  }

  void Finish(std::shared_ptr<flutter::MethodResult<EncodableValue>> result,
              EncodableValue value) {
    PostReply(std::move(result), 0, std::move(value), "", "");
  }

  void FinishError(std::shared_ptr<flutter::MethodResult<EncodableValue>> result,
                   const std::string& code, const std::string& message) {
    PostReply(std::move(result), 1, EncodableValue(), code, message);
  }

  void FinishNotImplemented(
      std::shared_ptr<flutter::MethodResult<EncodableValue>> result) {
    PostReply(std::move(result), 2, EncodableValue(), "", "");
  }

  void PostReply(std::shared_ptr<flutter::MethodResult<EncodableValue>> result,
                 int kind, EncodableValue value, const std::string& code,
                 const std::string& message) {
    auto* reply = new Reply();
    reply->result = std::move(result);
    reply->kind = kind;
    reply->value = std::move(value);
    reply->code = code;
    reply->message = message;
    if (hwnd_ == nullptr || !PostMessageW(hwnd_, kReplyMessage, 0, reinterpret_cast<LPARAM>(reply))) {
      if (reply->result) {
        if (kind == 1) reply->result->Error(code, message);
        else if (kind == 2) reply->result->NotImplemented();
        else reply->result->Success(reply->value);
      }
      delete reply;
    }
  }

  void Notify(const std::string& message) {
    if (hwnd_ == nullptr) return;
    PostMessageW(hwnd_, kEventMessage, 0, reinterpret_cast<LPARAM>(new std::string(message)));
  }

  static std::string PlatformVersion() {
    std::string version = "Windows ";
    if (IsWindows10OrGreater()) {
      version += "10+";
    } else if (IsWindows8OrGreater()) {
      version += "8";
    } else if (IsWindows7OrGreater()) {
      version += "7";
    }
    return version;
  }

  void NoteUsed() { last_used_ms_.store(NowMs()); }

  bool DropIfStale() {
    if (!session_open_.load()) return false;
    if (kind_ == Kind::kSpooler) return false;
    if (!peer_closed_.load()) return false;
    Log("SESSION stale, dropping old connection");
    Disconnect(true);
    return true;
  }

  bool HasLive(const std::string& address, const std::string& transport, int port) {
    if (!session_open_.load() || peer_closed_.load()) return false;
    if (transport == "tcp") {
      return kind_ == Kind::kSocket && using_tcp_ && SameText(connected_address_, address) &&
             connected_port_ == port;
    }
    if (transport == "usb") {
      return (kind_ == Kind::kCom || kind_ == Kind::kSpooler) &&
             SameText(connected_address_, address);
    }
    if (kind_ != Kind::kSocket || using_tcp_) return false;
    if (address.empty()) return true;
    return SameText(connected_address_, address) ||
           SameText(connected_name_, address) ||
           ContainsText(connected_name_, address);
  }

  Fail Ensure(const std::string& address, const std::string& transport, int port) {
    if (address.empty()) {
      if (!session_open_.load() || peer_closed_.load()) {
        return Fail{"004", "Not Connected"};
      }
      NoteUsed();
      return {};
    }
    if (transport == "tcp") return OpenTcp(address, port);
    if (transport == "usb") return OpenUsb(address);
    if (HasLive(address, "bluetooth", 0)) {
      NoteUsed();
      return {};
    }
    if (!ConnectBluetooth(address)) return Fail{"004", last_error_};
    return {};
  }

  bool ConnectBluetooth(const std::string& identifier) {
    const bool dropped = DropIfStale();
    const bool patient = dropped || (NowMs() - stale_at_ms_.load() < kStaleWindowMs);
    if (HasLive(identifier, "bluetooth", 0)) {
      Log("connect already open");
      NoteUsed();
      return true;
    }
    if (session_open_.load()) Disconnect(false);
    if (patient) Log("connect waiting for the printer to replace the old connection");
    const int64_t deadline = NowMs() + (patient ? 15000 : 0);
    const int timeout_ms = patient ? 2000 : 8000;
    if (TryBluetooth(identifier, timeout_ms)) return true;
    Disconnect(false);
    Sleep(patient ? 250 : 400);
    if (!patient) {
      if (TryBluetooth(identifier, 4000)) return true;
      Disconnect(false);
      if (last_error_.empty() || last_error_ == "Connection Fail") {
        last_error_ = "Connection Fail: session is still open";
      }
      return false;
    }
    while (NowMs() < deadline) {
      if (TryBluetooth(identifier, timeout_ms)) return true;
      Disconnect(false);
      Sleep(250);
    }
    last_error_ = "Connection Fail: turn Bluetooth off and on, then try again";
    Log("connect no printer for identifier=" + identifier);
    Notify("No paired Zebra printer");
    return false;
  }

  bool TryBluetooth(const std::string& identifier, int timeout_ms) {
    BTH_ADDR address = 0;
    std::string name;
    if (!ResolveBluetooth(identifier, &address, &name)) {
      last_error_ = "Connection Fail";
      return false;
    }
    Notify("Connecting...");
    if (!OpenRfcomm(address, timeout_ms)) return false;
    kind_ = Kind::kSocket;
    using_tcp_ = false;
    connected_address_ = FormatMac(address);
    connected_name_ = name.empty() ? connected_address_ : name;
    connected_port_ = 0;
    session_open_.store(true);
    peer_closed_.store(false);
    StartSocketReader();
    NoteUsed();
    Notify("Connected");
    Log("connect open " + connected_name_ + " " + connected_address_);
    return true;
  }

  bool ResolveBluetooth(const std::string& identifier, BTH_ADDR* address, std::string* name) {
    std::vector<PrinterHit> hits = RememberedPrinters(false);
    if (!identifier.empty()) {
      BTH_ADDR parsed = 0;
      if (ParseMac(identifier, &parsed)) {
        *address = parsed;
        for (const PrinterHit& hit : hits) {
          if (hit.address == parsed) *name = hit.name;
        }
        return true;
      }
    }
    if (identifier.empty()) {
      if (hits.empty()) hits = RememberedPrinters(true);
      if (hits.empty()) return false;
      *address = hits.front().address;
      *name = hits.front().name;
      return true;
    }
    for (const PrinterHit& hit : hits) {
      if (SameText(hit.mac, identifier) || SameText(hit.name, identifier) ||
          ContainsText(hit.name, identifier)) {
        *address = hit.address;
        *name = hit.name;
        return true;
      }
    }
    return false;
  }

  bool OpenRfcomm(BTH_ADDR address, int timeout_ms) {
    if (OpenRfcommPort(address, 0, &kSerialPortService, timeout_ms)) return true;
    ULONG port = 0;
    if (!LookupPort(address, &port)) return false;
    return OpenRfcommPort(address, port, nullptr, timeout_ms);
  }

  bool OpenRfcommPort(BTH_ADDR address, ULONG port, const GUID* service, int timeout_ms) {
    SOCKET sock = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
    if (sock == INVALID_SOCKET) {
      last_error_ = "Connection Fail";
      return false;
    }
    SOCKADDR_BTH remote = {};
    remote.addressFamily = AF_BTH;
    remote.btAddr = address;
    remote.port = port;
    if (service != nullptr) remote.serviceClassId = *service;
    u_long non_blocking = 1;
    ioctlsocket(sock, FIONBIO, &non_blocking);
    const int started = connect(sock, reinterpret_cast<SOCKADDR*>(&remote), sizeof(remote));
    if (started != 0 && WSAGetLastError() != WSAEWOULDBLOCK) {
      last_error_ = "Connection Fail";
      closesocket(sock);
      return false;
    }
    fd_set writers;
    FD_ZERO(&writers);
    FD_SET(sock, &writers);
    timeval wait = {};
    wait.tv_sec = timeout_ms / 1000;
    wait.tv_usec = (timeout_ms % 1000) * 1000;
    const int selected = select(0, nullptr, &writers, nullptr, &wait);
    int so_error = 0;
    int so_len = sizeof(so_error);
    getsockopt(sock, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&so_error), &so_len);
    non_blocking = 0;
    ioctlsocket(sock, FIONBIO, &non_blocking);
    if (selected <= 0 || so_error != 0) {
      last_error_ = "Connection Fail";
      closesocket(sock);
      return false;
    }
    const DWORD read_timeout = 500;
    const DWORD write_timeout = 20000;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&read_timeout),
               sizeof(read_timeout));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&write_timeout),
               sizeof(write_timeout));
    socket_.store(sock);
    return true;
  }

  bool LookupPort(BTH_ADDR address, ULONG* port) {
    wchar_t context[40];
    swprintf_s(context, L"(%02X:%02X:%02X:%02X:%02X:%02X)",
               static_cast<unsigned>((address >> 40) & 0xff),
               static_cast<unsigned>((address >> 32) & 0xff),
               static_cast<unsigned>((address >> 24) & 0xff),
               static_cast<unsigned>((address >> 16) & 0xff),
               static_cast<unsigned>((address >> 8) & 0xff),
               static_cast<unsigned>(address & 0xff));
    GUID service = kSerialPortService;
    WSAQUERYSETW query = {};
    query.dwSize = sizeof(query);
    query.dwNameSpace = NS_BTH;
    query.lpServiceClassId = &service;
    query.lpszContext = context;
    HANDLE lookup = nullptr;
    if (WSALookupServiceBeginW(&query, LUP_RETURN_ADDR | LUP_FLUSHCACHE, &lookup) != 0) {
      return false;
    }
    DWORD size = 8192;
    std::vector<unsigned char> buffer(size);
    auto* result = reinterpret_cast<WSAQUERYSETW*>(buffer.data());
    result->dwSize = sizeof(WSAQUERYSETW);
    const int next = WSALookupServiceNextW(lookup, LUP_RETURN_ADDR, &size, result);
    bool found = false;
    if (next == 0 && result->lpcsaBuffer != nullptr && result->dwNumberOfCsAddrs > 0) {
      auto* remote = reinterpret_cast<SOCKADDR_BTH*>(result->lpcsaBuffer[0].RemoteAddr.lpSockaddr);
      if (remote != nullptr && remote->addressFamily == AF_BTH && remote->port != 0) {
        *port = remote->port;
        found = true;
      }
    }
    WSALookupServiceEnd(lookup);
    return found;
  }

  Fail OpenTcp(const std::string& host, int port) {
    if (HasLive(host, "tcp", port)) {
      NoteUsed();
      return {};
    }
    Disconnect(false);
    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) return Fail{"004", "Connection Fail"};
    sockaddr_in remote = {};
    remote.sin_family = AF_INET;
    remote.sin_port = htons(static_cast<u_short>(port <= 0 ? 9100 : port));
    if (inet_pton(AF_INET, host.c_str(), &remote.sin_addr) != 1) {
      closesocket(sock);
      return Fail{"004", "Connection Fail"};
    }
    u_long non_blocking = 1;
    ioctlsocket(sock, FIONBIO, &non_blocking);
    const int started = connect(sock, reinterpret_cast<sockaddr*>(&remote), sizeof(remote));
    if (started != 0 && WSAGetLastError() != WSAEWOULDBLOCK) {
      closesocket(sock);
      return Fail{"004", "Connection Fail"};
    }
    fd_set writers;
    FD_ZERO(&writers);
    FD_SET(sock, &writers);
    timeval wait = {};
    wait.tv_sec = 5;
    if (select(0, nullptr, &writers, nullptr, &wait) <= 0) {
      closesocket(sock);
      return Fail{"004", "Connection Fail"};
    }
    non_blocking = 0;
    ioctlsocket(sock, FIONBIO, &non_blocking);
    const DWORD read_timeout = 500;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&read_timeout),
               sizeof(read_timeout));
    socket_.store(sock);
    kind_ = Kind::kSocket;
    using_tcp_ = true;
    connected_address_ = host;
    connected_name_ = host;
    connected_port_ = port <= 0 ? 9100 : port;
    session_open_.store(true);
    peer_closed_.store(false);
    StartSocketReader();
    NoteUsed();
    Notify("Connected");
    return {};
  }

  Fail OpenUsb(const std::string& address) {
    if (HasLive(address, "usb", 0)) {
      NoteUsed();
      return {};
    }
    Disconnect(false);
    if (IsComPort(address)) return OpenCom(address);
    return OpenSpooler(address);
  }

  Fail OpenCom(const std::string& address) {
    std::wstring path = Utf8ToWide(address);
    if (path.rfind(L"\\\\.\\", 0) != 0) path = L"\\\\.\\" + path;
    HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                OPEN_EXISTING, 0, nullptr);
    if (handle == INVALID_HANDLE_VALUE) return Fail{"004", "Connection Fail"};
    DCB dcb = {};
    dcb.DCBlength = sizeof(dcb);
    if (!GetCommState(handle, &dcb)) {
      CloseHandle(handle);
      return Fail{"004", "Connection Fail"};
    }
    dcb.BaudRate = CBR_115200;
    dcb.ByteSize = 8;
    dcb.Parity = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    SetCommState(handle, &dcb);
    COMMTIMEOUTS timeouts = {};
    timeouts.ReadIntervalTimeout = 50;
    timeouts.ReadTotalTimeoutConstant = 500;
    timeouts.WriteTotalTimeoutConstant = 20000;
    SetCommTimeouts(handle, &timeouts);
    com_ = handle;
    kind_ = Kind::kCom;
    using_tcp_ = false;
    connected_address_ = address;
    connected_name_ = address;
    session_open_.store(true);
    peer_closed_.store(false);
    StartComReader();
    NoteUsed();
    Notify("Connected");
    return {};
  }

  Fail OpenSpooler(const std::string& address) {
    HANDLE printer = nullptr;
    const std::wstring name = Utf8ToWide(address);
    if (!OpenPrinterW(const_cast<LPWSTR>(name.c_str()), &printer, nullptr)) {
      return Fail{"004", "Connection Fail"};
    }
    printer_ = printer;
    kind_ = Kind::kSpooler;
    using_tcp_ = false;
    connected_address_ = address;
    connected_name_ = address;
    session_open_.store(true);
    peer_closed_.store(false);
    NoteUsed();
    Notify("Connected");
    return {};
  }

  void StartSocketReader() {
    JoinReader();
    stop_reader_.store(false);
    reader_ = std::thread([this] {
      std::vector<char> buf(1024);
      while (!stop_reader_.load()) {
        const SOCKET sock = socket_.load();
        if (sock == INVALID_SOCKET) break;
        const int count = recv(sock, buf.data(), static_cast<int>(buf.size()), 0);
        if (count > 0) {
          std::lock_guard<std::mutex> lock(buffer_mu_);
          input_.insert(input_.end(), buf.begin(), buf.begin() + count);
          continue;
        }
        if (stop_reader_.load()) break;
        const int error = WSAGetLastError();
        if (count < 0 && (error == WSAETIMEDOUT || error == WSAEWOULDBLOCK)) continue;
        peer_closed_.store(true);
        Log("SESSION printer closed the link");
        break;
      }
    });
  }

  void StartComReader() {
    JoinReader();
    stop_reader_.store(false);
    reader_ = std::thread([this] {
      std::vector<char> buf(1024);
      while (!stop_reader_.load()) {
        DWORD count = 0;
        if (!ReadFile(com_, buf.data(), static_cast<DWORD>(buf.size()), &count, nullptr)) {
          if (!stop_reader_.load()) peer_closed_.store(true);
          break;
        }
        if (count == 0) continue;
        std::lock_guard<std::mutex> lock(buffer_mu_);
        input_.insert(input_.end(), buf.begin(), buf.begin() + static_cast<int>(count));
      }
    });
  }

  void JoinReader() {
    stop_reader_.store(true);
    const SOCKET sock = socket_.load();
    if (sock != INVALID_SOCKET) shutdown(sock, SD_BOTH);
    if (com_ != INVALID_HANDLE_VALUE) CancelIoEx(com_, nullptr);
    if (reader_.joinable()) reader_.join();
    stop_reader_.store(false);
  }

  void Disconnect(bool stale) {
    if (stale) stale_at_ms_.store(NowMs());
    if (!session_open_.load() && socket_.load() == INVALID_SOCKET &&
        com_ == INVALID_HANDLE_VALUE && printer_ == nullptr) {
      return;
    }
    Log(stale ? "disconnect stale" : "disconnect");
    Notify("Disconnecting...");
    session_open_.store(false);
    JoinReader();
    const SOCKET sock = socket_.exchange(INVALID_SOCKET);
    if (sock != INVALID_SOCKET) closesocket(sock);
    if (com_ != INVALID_HANDLE_VALUE) {
      CloseHandle(com_);
      com_ = INVALID_HANDLE_VALUE;
    }
    if (printer_ != nullptr) {
      ClosePrinter(printer_);
      printer_ = nullptr;
    }
    kind_ = Kind::kNone;
    using_tcp_ = false;
    connected_address_.clear();
    connected_name_.clear();
    connected_port_ = 0;
    peer_closed_.store(false);
    {
      std::lock_guard<std::mutex> lock(buffer_mu_);
      input_.clear();
    }
    last_used_ms_.store(0);
    Notify("Disconnected Printer");
  }

  Fail Write(const uint8_t* data, size_t size, int timeout_ms) {
    if (size == 0) return {};
    if (kind_ == Kind::kSpooler) return WriteSpooler(data, size);
    if (kind_ == Kind::kCom) return WriteCom(data, size, timeout_ms);
    return WriteSocket(data, size, timeout_ms);
  }

  Fail WriteSocket(const uint8_t* data, size_t size, int timeout_ms) {
    const SOCKET sock = socket_.load();
    if (sock == INVALID_SOCKET) return Fail{"004", "Connection Fail: no stream"};
    u_long non_blocking = 1;
    ioctlsocket(sock, FIONBIO, &non_blocking);
    size_t offset = 0;
    const int64_t deadline = NowMs() + timeout_ms;
    while (offset < size) {
      if (NowMs() > deadline) {
        non_blocking = 0;
        ioctlsocket(sock, FIONBIO, &non_blocking);
        return Fail{"001", "Fail Print"};
      }
      const int count = send(sock, reinterpret_cast<const char*>(data + offset),
                             static_cast<int>(size - offset), 0);
      if (count > 0) {
        offset += static_cast<size_t>(count);
        continue;
      }
      const int error = WSAGetLastError();
      if (count < 0 && (error == WSAEWOULDBLOCK || error == WSAEINPROGRESS)) {
        fd_set writers;
        FD_ZERO(&writers);
        FD_SET(sock, &writers);
        timeval wait = {};
        wait.tv_usec = 200000;
        if (select(0, nullptr, &writers, nullptr, &wait) < 0) {
          peer_closed_.store(true);
          return Fail{"004", "Connection Fail"};
        }
        continue;
      }
      peer_closed_.store(true);
      non_blocking = 0;
      ioctlsocket(sock, FIONBIO, &non_blocking);
      return Fail{"004", "Connection Fail"};
    }
    non_blocking = 0;
    ioctlsocket(sock, FIONBIO, &non_blocking);
    return {};
  }

  Fail WriteCom(const uint8_t* data, size_t size, int timeout_ms) {
    size_t offset = 0;
    const int64_t deadline = NowMs() + timeout_ms;
    while (offset < size) {
      if (NowMs() > deadline) return Fail{"001", "Fail Print"};
      DWORD written = 0;
      if (!WriteFile(com_, data + offset, static_cast<DWORD>(size - offset), &written, nullptr)) {
        peer_closed_.store(true);
        return Fail{"004", "Connection Fail"};
      }
      if (written == 0) {
        Sleep(20);
        continue;
      }
      offset += written;
    }
    return {};
  }

  Fail WriteSpooler(const uint8_t* data, size_t size) {
    if (printer_ == nullptr) return Fail{"004", "Connection Fail"};
    DOC_INFO_1W doc = {};
    doc.pDocName = const_cast<LPWSTR>(L"Zebra");
    doc.pDatatype = const_cast<LPWSTR>(L"RAW");
    if (StartDocPrinterW(printer_, 1, reinterpret_cast<LPBYTE>(&doc)) == 0) {
      return Fail{"001", "Fail Print"};
    }
    if (!StartPagePrinter(printer_)) {
      EndDocPrinter(printer_);
      return Fail{"001", "Fail Print"};
    }
    size_t offset = 0;
    while (offset < size) {
      DWORD written = 0;
      if (!WritePrinter(printer_, const_cast<uint8_t*>(data + offset),
                        static_cast<DWORD>(size - offset), &written)) {
        EndPagePrinter(printer_);
        EndDocPrinter(printer_);
        return Fail{"001", "Fail Print"};
      }
      if (written == 0) break;
      offset += written;
    }
    EndPagePrinter(printer_);
    EndDocPrinter(printer_);
    if (offset != size) return Fail{"001", "Fail Print"};
    return {};
  }

  Fail Command(const std::string& text, int wait_ms, std::string* reply) {
    {
      std::lock_guard<std::mutex> lock(buffer_mu_);
      input_.clear();
    }
    std::string payload = text;
    if (payload.size() < 2 || payload.substr(payload.size() - 2) != "\r\n") {
      payload += "\r\n";
    }
    const Fail wrote = Write(reinterpret_cast<const uint8_t*>(payload.data()), payload.size(), 20000);
    if (wrote.failed()) return wrote;
    const int64_t deadline = NowMs() + wait_ms;
    bool ready = false;
    while (NowMs() < deadline) {
      {
        std::lock_guard<std::mutex> lock(buffer_mu_);
        ready = !input_.empty();
      }
      if (ready) {
        Sleep(80);
        break;
      }
      Sleep(40);
    }
    std::string bytes;
    {
      std::lock_guard<std::mutex> lock(buffer_mu_);
      bytes.assign(input_.begin(), input_.end());
    }
    if (reply != nullptr) *reply = Trim(bytes);
    return {};
  }

  std::string GetVar(const std::string& name) {
    std::string reply;
    if (Command("! U1 getvar \"" + name + "\"", 1200, &reply).failed()) return {};
    return reply;
  }

  Fail SetVar(const std::string& name, const std::string& value) {
    std::string reply;
    return Command("! U1 setvar \"" + name + "\" \"" + value + "\"", 1200, &reply);
  }

  Fail WriteText(const std::string& text, int timeout_ms) {
    return Write(reinterpret_cast<const uint8_t*>(text.data()), text.size(), timeout_ms);
  }

  HostStatus ReadStatus() {
    std::string reply;
    if (Command("~HS", 1200, &reply).failed()) return {};
    return ParseHostStatus(reply);
  }

  Fail ThrowIfNotReady() {
    const HostStatus status = ReadStatus();
    if (!status.parsed) return {};
    if (status.head_open) return Fail{"001", "Printer Head is Open"};
    if (status.paper_out) return Fail{"001", "Paper Out"};
    if (status.paused) return Fail{"001", "Fail Print"};
    return {};
  }

  std::string ReadHost(const std::string& identifier) {
    if (!ConnectBluetooth(identifier)) return {};
    NoteUsed();
    return GetVar("device.host_identification");
  }

  Fail PrintZpl(const std::string& zpl, const std::string& identifier) {
    const Fail connected = Ensure(identifier, "bluetooth", 0);
    if (connected.failed()) return connected;
    const Fail language = SetVar("device.languages", "zpl");
    if (language.failed()) return language;
    const Fail wrote = WriteText(zpl, 20000);
    if (wrote.failed()) return wrote;
    NoteUsed();
    Notify("Printed");
    return {};
  }

  bool IsPlus() {
    const std::string host = GetVar("device.host_identification");
    const std::string product = GetVar("device.product_name");
    const std::string text = Upper(connected_name_ + " " + host + " " + product);
    return text.find("PLUS") != std::string::npos || text.find("ZQ32P") != std::string::npos;
  }

  std::string ScaleSetting() {
    const std::string identity = GetVar("device.host_identification");
    const std::string model = identity.size() >= 5 ? identity.substr(0, 5) : identity;
    if (model.rfind("ZQ52", 0) == 0 || model.rfind("ZQ32", 0) == 0) {
      return "dither scale=100x100";
    }
    const double file_width = 56.0;
    double factor = 0;
    if (model == "iMZ22" || model == "QLn22" || model == "ZD410") {
      factor = 2.0 / file_width * 100;
    } else if (model == "iMZ32" || model == "QLn32" || model == "ZQ510") {
      factor = 3.0 / file_width * 100;
    } else if (model == "QLn42" || model == "ZD420" || model == "ZD500" || model == "ZT220" ||
               model == "ZT230" || model == "ZT410") {
      factor = 4.0 / file_width * 100;
    } else if (model == "ZT420") {
      factor = 6.5 / file_width * 100;
    } else {
      return "dither scale=100x100";
    }
    const int percent = static_cast<int>(factor);
    return "dither scale=" + std::to_string(percent) + "x" + std::to_string(percent);
  }

  void RaiseSpeed() {
    const std::string identity = Upper(GetVar("device.host_identification") + " " + connected_name_);
    if (identity.find("ZQ32") == std::string::npos && identity.find("ZQ52") == std::string::npos) {
      return;
    }
    std::string reply;
    Command("! U1 setvar \"media.speed\" \"4\"", 1200, &reply);
  }

  void RestorePdf(const std::string& previous_apl, const std::string& previous_media) {
    const std::string apl = Trim(previous_apl);
    if (!apl.empty() && Upper(apl) != "PDF") {
      SetVar("apl.enable", apl);
    }
    const std::string media = Trim(previous_media);
    if (media.empty() || Upper(media) == "CONTINUOUS") return;
    SetVar("ezpl.media_type", media);
  }

  Fail PrintPdfs(const std::vector<std::string>& paths, const std::string& identifier) {
    Log("PRINT_PDFS start files=" + std::to_string(paths.size()));
    const Fail connected = Ensure(identifier, "bluetooth", 0);
    if (connected.failed()) return connected;
    std::string ignored;
    Command("~JA", 300, &ignored);
    // ~HS before PDF mode is printed as text by a ZQ320. Do not send it here.
    Log("PRINT_PDFS skip ~HS");
    const std::string previous_apl = GetVar("apl.enable");
    std::string apl_reply;
    const Fail apl = Command("! U1 setvar \"apl.enable\" \"pdf\"", 1200, &apl_reply);
    if (apl.failed()) return apl;
    const std::string scale = ScaleSetting();
    std::string scale_reply;
    const Fail scaled = Command("! U1 setvar \"apl.settings\" \"" + scale + "\"", 1200, &scale_reply);
    if (scaled.failed()) return scaled;
    RaiseSpeed();
    const std::string previous_media = GetVar("ezpl.media_type");
    Command("! U1 setvar \"ezpl.media_type\" \"continuous\"", 1200, &ignored);
    Sleep(200);
    const bool plus = IsPlus();
    for (const std::string& path : paths) {
      const std::wstring wide = Utf8ToWide(path);
      HANDLE file = CreateFileW(wide.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file == INVALID_HANDLE_VALUE) {
        if (!plus) RestorePdf(previous_apl, previous_media);
        NoteUsed();
        return Fail{"100", "PDF file is empty"};
      }
      LARGE_INTEGER length = {};
      GetFileSizeEx(file, &length);
      if (length.QuadPart <= 0) {
        CloseHandle(file);
        if (!plus) RestorePdf(previous_apl, previous_media);
        NoteUsed();
        return Fail{"100", "PDF file is empty"};
      }
      std::vector<uint8_t> bytes(static_cast<size_t>(length.QuadPart));
      DWORD read = 0;
      const BOOL ok = ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &read, nullptr);
      CloseHandle(file);
      if (!ok || read == 0) {
        if (!plus) RestorePdf(previous_apl, previous_media);
        NoteUsed();
        return Fail{"100", "PDF file is empty"};
      }
      bytes.resize(read);
      const Fail wrote = Write(bytes.data(), bytes.size(), 120000);
      if (wrote.failed()) {
        if (!plus) RestorePdf(previous_apl, previous_media);
        NoteUsed();
        return wrote;
      }
    }
    // The file is already in the printer. Wait out the short flush before
    // any later command, and do not close Bluetooth here.
    Sleep(plus ? 400 : 200);
    if (!plus) RestorePdf(previous_apl, previous_media);
    NoteUsed();
    Notify("Printed");
    Log("PRINT_PDFS finished");
    return {};
  }

  Fail RunSdk(const EncodableMap& args, EncodableValue* out) {
    const std::string op = AsString(Arg(args, "op"));
    const std::string address = AsString(Arg(args, "address"));
    const std::string transport = AsString(Arg(args, "transport"));
    const int port = AsInt(Arg(args, "port"), 9100);
    auto session = [&]() -> Fail {
      const std::string use = transport.empty() ? "bluetooth" : transport;
      return Ensure(address, use, port);
    };
    if (op == "discoverNetwork") {
      *out = EncodableValue(DiscoverNetwork(args));
      return {};
    }
    if (op == "discoverUsb") {
      *out = EncodableValue(DiscoverUsb());
      return {};
    }
    if (op == "connect") {
      const Fail error = session();
      if (error.failed()) return error;
      *out = EncodableValue(true);
      return {};
    }
    if (op == "disconnect") {
      Disconnect(false);
      *out = EncodableValue(true);
      return {};
    }
    if (op == "isConnected") {
      *out = EncodableValue(session_open_.load() && !peer_closed_.load());
      return {};
    }
    if (op == "status") {
      const Fail error = session();
      if (error.failed()) return error;
      const HostStatus status = ReadStatus();
      *out = EncodableValue(status.parsed ? StatusMap(status) : EmptyStatus());
      NoteUsed();
      return {};
    }
    if (op == "get") {
      const Fail error = session();
      if (error.failed()) return error;
      *out = EncodableValue(GetVar(AsString(Arg(args, "setting"))));
      NoteUsed();
      return {};
    }
    if (op == "set") {
      const Fail error = session();
      if (error.failed()) return error;
      const Fail wrote = SetVar(AsString(Arg(args, "setting")), AsString(Arg(args, "value")));
      if (wrote.failed()) return wrote;
      *out = EncodableValue(true);
      NoteUsed();
      return {};
    }
    if (op == "do") {
      const Fail error = session();
      if (error.failed()) return error;
      std::string reply;
      const Fail wrote = Command("! U1 do \"" + AsString(Arg(args, "command")) + "\" \"" +
                                     AsString(Arg(args, "value")) + "\"",
                                 2500, &reply);
      if (wrote.failed()) return wrote;
      *out = EncodableValue(reply);
      NoteUsed();
      return {};
    }
    if (op == "hostInfo") {
      const Fail error = session();
      if (error.failed()) return error;
      *out = EncodableValue(HostInfo());
      NoteUsed();
      return {};
    }
    if (op == "printZpl") {
      const Fail error = session();
      if (error.failed()) return error;
      const Fail language = SetVar("device.languages", "zpl");
      if (language.failed()) return language;
      const Fail ready = ThrowIfNotReady();
      if (ready.failed()) return ready;
      const Fail wrote = WriteText(AsString(Arg(args, "data")), 20000);
      if (wrote.failed()) return wrote;
      *out = EncodableValue(true);
      NoteUsed();
      return {};
    }
    if (op == "printCpcl") {
      const Fail error = session();
      if (error.failed()) return error;
      SetVar("device.languages", "cpcl");
      const Fail wrote = WriteText(AsString(Arg(args, "data")), 20000);
      if (wrote.failed()) return wrote;
      *out = EncodableValue(true);
      NoteUsed();
      return {};
    }
    if (op == "printRaw") {
      const Fail error = session();
      if (error.failed()) return error;
      const auto* bytes = std::get_if<std::vector<uint8_t>>(Arg(args, "bytes"));
      if (bytes == nullptr) return Fail{"100", "Expected bytes"};
      const Fail wrote = Write(bytes->data(), bytes->size(), 60000);
      if (wrote.failed()) return wrote;
      *out = EncodableValue(true);
      NoteUsed();
      return {};
    }
    if (op == "printPdfs") {
      const auto* list = std::get_if<EncodableList>(Arg(args, "paths"));
      if (list == nullptr || list->empty()) return Fail{"100", "Expected at least one PDF"};
      std::vector<std::string> paths;
      for (const EncodableValue& item : *list) paths.push_back(AsString(&item));
      const std::string use = transport.empty() ? "bluetooth" : transport;
      const Fail error = Ensure(address, use, port);
      if (error.failed()) return error;
      const Fail printed = PrintPdfs(paths, "");
      if (printed.failed()) return printed;
      *out = EncodableValue(true);
      return {};
    }
    if (op == "printImage" || op == "storeImage") {
      const Fail error = session();
      if (error.failed()) return error;
      const Fail wrote = op == "printImage" ? PrintImage(args) : StoreImage(args);
      if (wrote.failed()) return wrote;
      *out = EncodableValue(true);
      NoteUsed();
      return {};
    }
    if (op == "calibrate" || op == "printConfigurationLabel" ||
        op == "printNetworkConfigurationLabel" || op == "printDirectoryLabel" ||
        op == "feed" || op == "restoreDefaults" || op == "reset") {
      const Fail error = session();
      if (error.failed()) return error;
      const char* command = "~JC\r\n";
      if (op == "printConfigurationLabel") command = "~WC\r\n";
      if (op == "printNetworkConfigurationLabel") command = "~WL\r\n";
      if (op == "printDirectoryLabel") command = "^XA^WD*:*.*^XZ";
      if (op == "feed") command = "^XA^PH^XZ";
      if (op == "restoreDefaults") command = "^XA^JUF^XZ";
      if (op == "reset") command = "~JR\r\n";
      const Fail wrote = WriteText(command, 20000);
      if (wrote.failed()) return wrote;
      *out = EncodableValue(true);
      NoteUsed();
      return {};
    }
    if (op == "listFiles") {
      const Fail error = session();
      if (error.failed()) return error;
      std::string drive = AsString(Arg(args, "drive"));
      if (drive.empty()) drive = "E:";
      std::string listing;
      const Fail wrote = Command("! U1 do \"file.dir\" \"" + drive + "\"", 2500, &listing);
      if (wrote.failed()) return wrote;
      EncodableList files;
      std::string line;
      listing.push_back('\n');
      for (char ch : listing) {
        if (ch != '\n' && ch != '\r') {
          line.push_back(ch);
          continue;
        }
        const std::string trimmed = Trim(line);
        line.clear();
        if (trimmed.find(':') == std::string::npos) continue;
        if (Upper(trimmed).rfind("DIRECTORY", 0) == 0) continue;
        files.push_back(EncodableValue(trimmed));
      }
      *out = EncodableValue(files);
      NoteUsed();
      return {};
    }
    if (op == "storeFile") {
      const Fail error = session();
      if (error.failed()) return error;
      const Fail wrote =
          StoreFile(AsString(Arg(args, "printerPath")), AsString(Arg(args, "path")));
      if (wrote.failed()) return wrote;
      *out = EncodableValue(true);
      NoteUsed();
      return {};
    }
    if (op == "sendFile") {
      const Fail error = session();
      if (error.failed()) return error;
      std::vector<uint8_t> bytes;
      if (!ReadLocal(AsString(Arg(args, "path")), &bytes) || bytes.empty()) {
        return Fail{"100", "PDF file is empty"};
      }
      const Fail wrote = Write(bytes.data(), bytes.size(), 60000);
      if (wrote.failed()) return wrote;
      *out = EncodableValue(true);
      NoteUsed();
      return {};
    }
    if (op == "deleteFile") {
      const Fail error = session();
      if (error.failed()) return error;
      std::string reply;
      const Fail wrote =
          Command("! U1 do \"file.delete\" \"" + AsString(Arg(args, "printerPath")) + "\"", 1200,
                  &reply);
      if (wrote.failed()) return wrote;
      *out = EncodableValue(true);
      NoteUsed();
      return {};
    }
    if (op == "retrieveFile") {
      const Fail error = session();
      if (error.failed()) return error;
      std::string body;
      const Fail wrote =
          Command("! U1 do \"file.type\" \"" + AsString(Arg(args, "printerPath")) + "\"", 3000,
                  &body);
      if (wrote.failed()) return wrote;
      *out = EncodableValue(std::vector<uint8_t>(body.begin(), body.end()));
      NoteUsed();
      return {};
    }
    if (op == "printStoredFormat") {
      const Fail error = session();
      if (error.failed()) return error;
      const Fail wrote = PrintStoredFormat(args);
      if (wrote.failed()) return wrote;
      *out = EncodableValue(true);
      NoteUsed();
      return {};
    }
    if (op == "storageInfo") {
      const Fail error = session();
      if (error.failed()) return error;
      *out = EncodableValue(StorageInfo());
      NoteUsed();
      return {};
    }
    if (op == "odometer") {
      const Fail error = session();
      if (error.failed()) return error;
      EncodableMap map;
      map[EncodableValue("odometer.total_label_count")] =
          EncodableValue(GetVar("odometer.total_label_count"));
      map[EncodableValue("odometer.user_label_count")] =
          EncodableValue(GetVar("odometer.user_label_count"));
      map[EncodableValue("odometer.media_marker_count")] =
          EncodableValue(GetVar("odometer.media_marker_count"));
      map[EncodableValue("odometer.headclean_count")] =
          EncodableValue(GetVar("odometer.headclean_count"));
      *out = EncodableValue(map);
      NoteUsed();
      return {};
    }
    if (op == "setClock") {
      const Fail error = session();
      if (error.failed()) return error;
      const Fail date = SetVar("rtc.date", AsString(Arg(args, "date")));
      if (date.failed()) return date;
      const Fail time = SetVar("rtc.time", AsString(Arg(args, "time")));
      if (time.failed()) return time;
      *out = EncodableValue(true);
      NoteUsed();
      return {};
    }
    return Fail{"100", "Unknown SDK operation " + op};
  }

  EncodableMap HostInfo() {
    const char* keys[] = {
        "device.host_identification", "device.product_name", "device.friendly_name",
        "appl.name", "device.languages", "ezpl.media_type", "ezpl.print_width",
        "zpl.label_length", "print.tone", "media.speed", "power.percent_full", "ip.addr"};
    EncodableMap info;
    for (const char* key : keys) {
      info[EncodableValue(std::string(key))] = EncodableValue(GetVar(key));
    }
    const EncodableValue language = info[EncodableValue("device.languages")];
    info[EncodableValue("language")] = language;
    return info;
  }

  EncodableList StorageInfo() {
    const int flash = ParseInt(Digits(GetVar("memory.flash_free")), 0);
    const int ram = ParseInt(Digits(GetVar("memory.ram_free")), 0);
    EncodableList drives;
    EncodableMap flash_drive;
    flash_drive[EncodableValue("driveLetter")] = EncodableValue(std::string("E"));
    flash_drive[EncodableValue("driveType")] = EncodableValue(std::string("FLASH"));
    flash_drive[EncodableValue("bytesFree")] = EncodableValue(static_cast<int32_t>(flash));
    flash_drive[EncodableValue("isPersistent")] = EncodableValue(true);
    EncodableMap ram_drive;
    ram_drive[EncodableValue("driveLetter")] = EncodableValue(std::string("R"));
    ram_drive[EncodableValue("driveType")] = EncodableValue(std::string("RAM"));
    ram_drive[EncodableValue("bytesFree")] = EncodableValue(static_cast<int32_t>(ram));
    ram_drive[EncodableValue("isPersistent")] = EncodableValue(false);
    drives.push_back(EncodableValue(flash_drive));
    drives.push_back(EncodableValue(ram_drive));
    return drives;
  }

  static std::string Digits(const std::string& text) {
    std::string out;
    for (char ch : text) {
      if (ch >= '0' && ch <= '9') out.push_back(ch);
    }
    return out;
  }

  Fail PrintStoredFormat(const EncodableMap& args) {
    std::string zpl = "^XA^XF" + AsString(Arg(args, "printerPath")) + "^FS";
    const auto* fields = std::get_if<EncodableMap>(Arg(args, "fields"));
    std::vector<std::pair<int, std::string>> ordered;
    if (fields != nullptr) {
      for (const auto& entry : *fields) {
        ordered.push_back({ParseInt(AsString(&entry.first), 0), AsString(&entry.second)});
      }
    }
    std::sort(ordered.begin(), ordered.end(),
              [](const auto& a, const auto& b) { return a.first < b.first; });
    for (const auto& field : ordered) {
      zpl += "^FN" + std::to_string(field.first) + "^FD" + field.second + "^FS";
    }
    zpl += "^XZ";
    return WriteText(zpl, 20000);
  }

  Fail PrintImage(const EncodableMap& args) {
    std::string graphic;
    const Fail built = GraphicCommand(AsString(Arg(args, "path")), AsInt(Arg(args, "width"), 0),
                                      AsInt(Arg(args, "height"), 0), &graphic);
    if (built.failed()) return built;
    const std::string zpl = "^XA^FO" + std::to_string(AsInt(Arg(args, "x"), 0)) + "," +
                            std::to_string(AsInt(Arg(args, "y"), 0)) + graphic + "^FS^XZ";
    return WriteText(zpl, 60000);
  }

  Fail StoreImage(const EncodableMap& args) {
    std::string graphic;
    const Fail built = GraphicCommand(AsString(Arg(args, "path")), AsInt(Arg(args, "width"), 0),
                                      AsInt(Arg(args, "height"), 0), &graphic);
    if (built.failed()) return built;
    const std::string zpl =
        "^XA^DF" + AsString(Arg(args, "printerPath")) + "^FS^FO0,0" + graphic + "^FS^XZ";
    return WriteText(zpl, 60000);
  }

  Fail StoreFile(const std::string& printer_path, const std::string& local_path) {
    std::vector<uint8_t> bytes;
    if (!ReadLocal(local_path, &bytes)) return Fail{"100", "Image file could not be read"};
    if (Upper(printer_path).size() >= 4 &&
        Upper(printer_path).rfind(".ZPL") == Upper(printer_path).size() - 4) {
      const std::string body(bytes.begin(), bytes.end());
      return WriteText("^XA^DF" + printer_path + "^FS" + body + "^XZ", 60000);
    }
    std::string hex;
    hex.reserve(bytes.size() * 2);
    char pair[3];
    for (uint8_t byte : bytes) {
      sprintf_s(pair, "%02X", byte);
      hex += pair;
    }
    const std::string command = "~DY" + printer_path + ",A,B," + std::to_string(bytes.size()) +
                                "," + std::to_string(bytes.size()) + "," + hex + "\r\n";
    return WriteText(command, 60000);
  }

  static bool ReadLocal(const std::string& path, std::vector<uint8_t>* out) {
    const std::wstring wide = Utf8ToWide(path);
    HANDLE file = CreateFileW(wide.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER length = {};
    if (!GetFileSizeEx(file, &length) || length.QuadPart < 0) {
      CloseHandle(file);
      return false;
    }
    out->resize(static_cast<size_t>(length.QuadPart));
    DWORD read = 0;
    const BOOL ok = out->empty()
                        ? TRUE
                        : ReadFile(file, out->data(), static_cast<DWORD>(out->size()), &read, nullptr);
    CloseHandle(file);
    if (!ok) return false;
    out->resize(read);
    return true;
  }

  Fail GraphicCommand(const std::string& path, int width, int height, std::string* zpl) {
    const HRESULT start = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninit = start == S_OK;
    IWICImagingFactory* factory = nullptr;
    HRESULT hr = CoCreateInstance(kWicFactory, nullptr, CLSCTX_INPROC_SERVER,
                                  __uuidof(IWICImagingFactory), reinterpret_cast<void**>(&factory));
    if (FAILED(hr) || factory == nullptr) {
      if (uninit) CoUninitialize();
      return Fail{"100", "Image file could not be read"};
    }
    IWICBitmapDecoder* decoder = nullptr;
    const std::wstring wide = Utf8ToWide(path);
    hr = factory->CreateDecoderFromFilename(wide.c_str(), nullptr, GENERIC_READ,
                                            WICDecodeMetadataCacheOnLoad, &decoder);
    IWICBitmapFrameDecode* frame = nullptr;
    if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame);
    UINT src_w = 0;
    UINT src_h = 0;
    if (SUCCEEDED(hr)) hr = frame->GetSize(&src_w, &src_h);
    const UINT target_w = width > 0 ? static_cast<UINT>(width) : src_w;
    const UINT target_h = height > 0 ? static_cast<UINT>(height) : src_h;
    IWICBitmapScaler* scaler = nullptr;
    IWICBitmapSource* source = frame;
    if (SUCCEEDED(hr) && (target_w != src_w || target_h != src_h)) {
      hr = factory->CreateBitmapScaler(&scaler);
      if (SUCCEEDED(hr)) {
        hr = scaler->Initialize(frame, target_w, target_h, WICBitmapInterpolationModeNearestNeighbor);
        source = scaler;
      }
    }
    IWICFormatConverter* converter = nullptr;
    if (SUCCEEDED(hr)) hr = factory->CreateFormatConverter(&converter);
    if (SUCCEEDED(hr)) {
      hr = converter->Initialize(source, kGray8, WICBitmapDitherTypeNone, nullptr, 0.0,
                                 WICBitmapPaletteTypeCustom);
    }
    std::vector<uint8_t> pixels;
    if (SUCCEEDED(hr) && target_w > 0 && target_h > 0) {
      pixels.resize(static_cast<size_t>(target_w) * target_h);
      hr = converter->CopyPixels(nullptr, target_w, static_cast<UINT>(pixels.size()), pixels.data());
    } else {
      hr = E_FAIL;
    }
    if (converter) converter->Release();
    if (scaler) scaler->Release();
    if (frame) frame->Release();
    if (decoder) decoder->Release();
    factory->Release();
    if (uninit) CoUninitialize();
    if (FAILED(hr)) return Fail{"100", "Image file could not be read"};

    const int bytes_per_row = static_cast<int>((target_w + 7) / 8);
    std::string hex;
    hex.reserve(static_cast<size_t>(bytes_per_row) * target_h * 2);
    char pair[3];
    for (UINT y = 0; y < target_h; y++) {
      for (int byte_index = 0; byte_index < bytes_per_row; byte_index++) {
        uint8_t value = 0;
        for (int bit = 0; bit < 8; bit++) {
          const int x = byte_index * 8 + bit;
          if (x >= static_cast<int>(target_w)) continue;
          const uint8_t sample = pixels[static_cast<size_t>(y) * target_w + static_cast<size_t>(x)];
          if (sample < 128) value |= static_cast<uint8_t>(0x80 >> bit);
        }
        sprintf_s(pair, "%02X", value);
        hex += pair;
      }
    }
    const int total = bytes_per_row * static_cast<int>(target_h);
    *zpl = "^GFA," + std::to_string(total) + "," + std::to_string(total) + "," +
           std::to_string(bytes_per_row) + "," + hex;
    return {};
  }

  struct PrinterHit {
    std::string name;
    std::string mac;
    BTH_ADDR address = 0;
  };

  std::vector<PrinterHit> RememberedPrinters(bool inquiry) {
    std::vector<PrinterHit> hits;
    BLUETOOTH_DEVICE_SEARCH_PARAMS search = {};
    search.dwSize = sizeof(search);
    search.fReturnAuthenticated = TRUE;
    search.fReturnRemembered = TRUE;
    search.fReturnConnected = TRUE;
    search.fReturnUnknown = inquiry ? TRUE : FALSE;
    search.fIssueInquiry = inquiry ? TRUE : FALSE;
    search.cTimeoutMultiplier = inquiry ? 4 : 0;
    search.hRadio = nullptr;
    BLUETOOTH_DEVICE_INFO info = {};
    info.dwSize = sizeof(info);
    const HBLUETOOTH_DEVICE_FIND find = BluetoothFindFirstDevice(&search, &info);
    if (find == nullptr) return hits;
    for (;;) {
      const std::string name = WideToUtf8(info.szName);
      if (IsLikelyPrinter(name, info.ulClassofDevice)) {
        PrinterHit hit;
        hit.address = info.Address.ullLong;
        hit.mac = FormatMac(hit.address);
        hit.name = name.empty() ? hit.mac : name;
        bool duplicate = false;
        for (const PrinterHit& existing : hits) {
          if (existing.address == hit.address) duplicate = true;
        }
        if (!duplicate) hits.push_back(hit);
      }
      info.dwSize = sizeof(info);
      if (!BluetoothFindNextDevice(find, &info)) break;
    }
    BluetoothFindDeviceClose(find);
    return hits;
  }

  bool HasRadio() {
    HANDLE radio = nullptr;
    BLUETOOTH_FIND_RADIO_PARAMS params = {};
    params.dwSize = sizeof(params);
    const HBLUETOOTH_RADIO_FIND find = BluetoothFindFirstRadio(&params, &radio);
    if (find == nullptr) return false;
    CloseHandle(radio);
    BluetoothFindRadioClose(find);
    return true;
  }

  bool ListPrinters(EncodableList* rows) {
    DropIfStale();
    if (!HasRadio()) {
      return true;
    }
    std::vector<PrinterHit> hits = RememberedPrinters(false);
    const std::vector<PrinterHit> nearby = RememberedPrinters(true);
    for (const PrinterHit& hit : nearby) {
      bool duplicate = false;
      for (const PrinterHit& existing : hits) {
        if (existing.address == hit.address) duplicate = true;
      }
      if (!duplicate) hits.push_back(hit);
    }
    for (const PrinterHit& hit : hits) {
      EncodableMap row;
      row[EncodableValue("name")] = EncodableValue(hit.name);
      row[EncodableValue("address")] = EncodableValue(hit.mac);
      row[EncodableValue("serialNumber")] = EncodableValue(hit.mac);
      rows->push_back(EncodableValue(row));
    }
    Log("LIST_PRINTERS count=" + std::to_string(rows->size()));
    return true;
  }

  EncodableList DiscoverUsb() {
    EncodableList rows;
    EnumComPorts(&rows);
    EnumZebraQueues(&rows);
    return rows;
  }

  void EnumComPorts(EncodableList* rows) {
    const HDEVINFO devices = SetupDiGetClassDevsW(&kPortsClass, nullptr, nullptr, DIGCF_PRESENT);
    if (devices == INVALID_HANDLE_VALUE) return;
    SP_DEVINFO_DATA info = {};
    info.cbSize = sizeof(info);
    for (DWORD index = 0; SetupDiEnumDeviceInfo(devices, index, &info); index++) {
      wchar_t friendly[512] = {};
      SetupDiGetDeviceRegistryPropertyW(devices, &info, SPDRP_FRIENDLYNAME, nullptr,
                                        reinterpret_cast<PBYTE>(friendly), sizeof(friendly), nullptr);
      wchar_t hardware[512] = {};
      SetupDiGetDeviceRegistryPropertyW(devices, &info, SPDRP_HARDWAREID, nullptr,
                                        reinterpret_cast<PBYTE>(hardware), sizeof(hardware), nullptr);
      const std::string name = WideToUtf8(friendly);
      const std::string id = Upper(WideToUtf8(hardware));
      if (!IsZebraName(name) && id.find("VID_0A5F") == std::string::npos) continue;
      HKEY key = SetupDiOpenDevRegKey(devices, &info, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_READ);
      if (key == INVALID_HANDLE_VALUE) continue;
      wchar_t port[64] = {};
      DWORD port_size = sizeof(port);
      DWORD type = 0;
      const LONG read = RegQueryValueExW(key, L"PortName", nullptr, &type, reinterpret_cast<LPBYTE>(port),
                                         &port_size);
      RegCloseKey(key);
      if (read != ERROR_SUCCESS) continue;
      const std::string com = WideToUtf8(port);
      EncodableMap row;
      row[EncodableValue("name")] = EncodableValue(name.empty() ? com : name);
      row[EncodableValue("address")] = EncodableValue(com);
      row[EncodableValue("transport")] = EncodableValue(std::string("usb"));
      row[EncodableValue("port")] = EncodableValue(static_cast<int32_t>(0));
      rows->push_back(EncodableValue(row));
    }
    SetupDiDestroyDeviceInfoList(devices);
  }

  void EnumZebraQueues(EncodableList* rows) {
    DWORD needed = 0;
    DWORD count = 0;
    EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr, 2, nullptr, 0, &needed,
                  &count);
    if (needed == 0) return;
    std::vector<uint64_t> storage((static_cast<size_t>(needed) / sizeof(uint64_t)) + 1);
    auto* bytes = reinterpret_cast<LPBYTE>(storage.data());
    const DWORD capacity = static_cast<DWORD>(storage.size() * sizeof(uint64_t));
    if (!EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, nullptr, 2, bytes, capacity,
                       &needed, &count)) {
      return;
    }
    auto* info = reinterpret_cast<PRINTER_INFO_2W*>(storage.data());
    for (DWORD i = 0; i < count; i++) {
      const std::string name = WideToUtf8(info[i].pPrinterName);
      const std::string driver = WideToUtf8(info[i].pDriverName);
      if (!IsZebraName(name) && !IsZebraName(driver) &&
          Upper(name + driver).find("ZEBRA") == std::string::npos) {
        continue;
      }
      EncodableMap row;
      row[EncodableValue("name")] = EncodableValue(name);
      row[EncodableValue("address")] = EncodableValue(name);
      row[EncodableValue("transport")] = EncodableValue(std::string("usb"));
      row[EncodableValue("port")] = EncodableValue(static_cast<int32_t>(0));
      rows->push_back(EncodableValue(row));
    }
  }

  EncodableList DiscoverNetwork(const EncodableMap& args) {
    const std::string subnet = AsString(Arg(args, "subnet"));
    const int port = AsInt(Arg(args, "port"), 9100);
    std::vector<std::string> parts;
    std::string current;
    for (char ch : subnet) {
      if (ch == '.') {
        parts.push_back(current);
        current.clear();
      } else {
        current.push_back(ch);
      }
    }
    parts.push_back(current);
    EncodableList rows;
    if (parts.size() != 4) return rows;
    const int last = ParseInt(parts[3], 0);
    std::vector<std::string> hosts;
    if (last != 0 && last != 255) {
      hosts.push_back(subnet);
    } else {
      const std::string prefix = parts[0] + "." + parts[1] + "." + parts[2];
      if (prefix == parts[0]) return rows;
      for (int host = 1; host <= 254; host++) {
        hosts.push_back(prefix + "." + std::to_string(host));
      }
    }
    std::vector<std::pair<std::string, SOCKET>> batch;
    size_t index = 0;
    while (index < hosts.size()) {
      batch.clear();
      const size_t end = std::min(index + 24, hosts.size());
      for (size_t i = index; i < end; i++) {
        SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (sock == INVALID_SOCKET) continue;
        u_long non_blocking = 1;
        ioctlsocket(sock, FIONBIO, &non_blocking);
        sockaddr_in remote = {};
        remote.sin_family = AF_INET;
        remote.sin_port = htons(static_cast<u_short>(port));
        if (inet_pton(AF_INET, hosts[i].c_str(), &remote.sin_addr) != 1) {
          closesocket(sock);
          continue;
        }
        connect(sock, reinterpret_cast<sockaddr*>(&remote), sizeof(remote));
        batch.push_back(std::make_pair(hosts[i], sock));
      }
      fd_set writers;
      FD_ZERO(&writers);
      for (const auto& item : batch) FD_SET(item.second, &writers);
      timeval wait = {};
      wait.tv_usec = 350000;
      if (!batch.empty()) select(0, nullptr, &writers, nullptr, &wait);
      for (const auto& item : batch) {
        int so_error = 1;
        int so_len = sizeof(so_error);
        getsockopt(item.second, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&so_error), &so_len);
        if (FD_ISSET(item.second, &writers) && so_error == 0) {
          EncodableMap row;
          row[EncodableValue("name")] = EncodableValue(item.first);
          row[EncodableValue("address")] = EncodableValue(item.first);
          row[EncodableValue("transport")] = EncodableValue(std::string("tcp"));
          row[EncodableValue("port")] = EncodableValue(static_cast<int32_t>(port));
          rows.push_back(EncodableValue(row));
        }
        closesocket(item.second);
      }
      index = end;
    }
    return rows;
  }

  HWND hwnd_ = nullptr;
  bool wsa_ready_ = false;
  std::thread worker_;
  std::thread idle_thread_;
  std::thread link_thread_;
  std::thread reader_;
  std::mutex queue_mu_;
  std::condition_variable queue_cv_;
  std::deque<std::function<void()>> jobs_;
  bool stop_worker_ = false;
  std::atomic<bool> stop_side_threads_{false};
  std::atomic<bool> stop_reader_{false};
  std::atomic<bool> session_open_{false};
  std::atomic<bool> peer_closed_{false};
  std::atomic<int64_t> last_used_ms_{0};
  std::atomic<int64_t> stale_at_ms_{0};
  std::atomic<SOCKET> socket_{INVALID_SOCKET};
  HANDLE com_ = INVALID_HANDLE_VALUE;
  HANDLE printer_ = nullptr;
  Kind kind_ = Kind::kNone;
  bool using_tcp_ = false;
  std::string connected_address_;
  std::string connected_name_;
  int connected_port_ = 0;
  std::string last_error_ = "Connection Fail";
  std::mutex buffer_mu_;
  std::vector<char> input_;
};

void ZebraBluetoothPrinterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<ZebraBluetoothPrinterPlugin>();
  plugin->impl_->Attach(registrar->messenger());
  plugin->impl_->channel_->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

ZebraBluetoothPrinterPlugin::ZebraBluetoothPrinterPlugin() : impl_(std::make_unique<Impl>()) {}

ZebraBluetoothPrinterPlugin::~ZebraBluetoothPrinterPlugin() = default;

void ZebraBluetoothPrinterPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  impl_->Handle(method_call, std::move(result));
}

}  // namespace zebra_bluetooth_printer
