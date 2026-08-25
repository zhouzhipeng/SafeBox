#include "windows_shell_channel.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <cstdint>
#include <string>
#include <variant>

namespace {

constexpr char kChannelName[] = "com.zhouzhipeng.safebox/windows_shell";
constexpr char kOpenPathMethod[] = "openPath";

bool ReadPath(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::string* path) {
  const auto* arguments = call.arguments();
  if (arguments == nullptr ||
      !std::holds_alternative<flutter::EncodableMap>(*arguments)) {
    return false;
  }
  const auto& map = std::get<flutter::EncodableMap>(*arguments);
  const auto it = map.find(flutter::EncodableValue("path"));
  if (it == map.end()) return false;
  const auto* value = std::get_if<std::string>(&it->second);
  if (value == nullptr || value->empty() || value->find('\0') != std::string::npos) {
    return false;
  }
  *path = *value;
  return true;
}

std::wstring Utf8ToWide(const std::string& value) {
  const int required = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (required <= 0) return {};
  std::wstring result(static_cast<size_t>(required), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                         static_cast<int>(value.size()), result.data(),
                         required) != required) {
    return {};
  }
  return result;
}

}  // namespace

WindowsShellChannel::WindowsShellChannel(flutter::BinaryMessenger* messenger,
                                         HWND owner)
    : channel_(
          std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
              messenger, kChannelName,
              &flutter::StandardMethodCodec::GetInstance())),
      owner_(owner) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

WindowsShellChannel::~WindowsShellChannel() {
  if (channel_ != nullptr) channel_->SetMethodCallHandler(nullptr);
  channel_.reset();
}

void WindowsShellChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != kOpenPathMethod) {
    result->NotImplemented();
    return;
  }

  std::string path;
  if (!ReadPath(call, &path)) {
    result->Error("invalid_arguments", "A non-empty path is required");
    return;
  }
  const std::wstring wide_path = Utf8ToWide(path);
  if (wide_path.empty()) {
    result->Error("invalid_arguments", "The path is not valid UTF-8");
    return;
  }

  SHELLEXECUTEINFOW execution{};
  execution.cbSize = sizeof(execution);
  execution.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  execution.hwnd = owner_;
  execution.lpVerb = L"open";
  execution.lpFile = wide_path.c_str();
  execution.nShow = SW_SHOWNORMAL;

  SetLastError(ERROR_SUCCESS);
  if (!ShellExecuteExW(&execution)) {
    const auto error = static_cast<int64_t>(GetLastError());
    result->Error(
        "open_failed", "Windows could not open the requested path",
        flutter::EncodableValue(error));
    return;
  }
  result->Success();
}
