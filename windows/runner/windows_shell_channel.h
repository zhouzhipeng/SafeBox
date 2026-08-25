#ifndef RUNNER_WINDOWS_SHELL_CHANNEL_H_
#define RUNNER_WINDOWS_SHELL_CHANNEL_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class WindowsShellChannel {
 public:
  WindowsShellChannel(flutter::BinaryMessenger* messenger, HWND owner);
  ~WindowsShellChannel();

  WindowsShellChannel(const WindowsShellChannel&) = delete;
  WindowsShellChannel& operator=(const WindowsShellChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND owner_ = nullptr;
};

#endif  // RUNNER_WINDOWS_SHELL_CHANNEL_H_
