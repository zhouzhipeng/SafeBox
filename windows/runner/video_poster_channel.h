#ifndef RUNNER_VIDEO_POSTER_CHANNEL_H_
#define RUNNER_VIDEO_POSTER_CHANNEL_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

class VideoPosterChannel {
 public:
  explicit VideoPosterChannel(flutter::BinaryMessenger* messenger);
  ~VideoPosterChannel();

  VideoPosterChannel(const VideoPosterChannel&) = delete;
  VideoPosterChannel& operator=(const VideoPosterChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<
      flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool media_foundation_started_ = false;
};

#endif  // RUNNER_VIDEO_POSTER_CHANNEL_H_
