#include "video_poster_channel.h"

#include <windows.h>

#include <flutter/standard_method_codec.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;

constexpr char kChannelName[] = "com.zhouzhipeng.safebox/video_preview";
constexpr char kExtractVideoPosterMethod[] = "extractVideoPoster";
constexpr uint64_t kMaxDecodedBytes = 32ULL * 1024ULL * 1024ULL;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
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

bool ReadPath(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::string* path) {
  const auto* arguments = call.arguments();
  if (arguments == nullptr || !std::holds_alternative<flutter::EncodableMap>(
                                  *arguments)) {
    return false;
  }
  const auto& map = std::get<flutter::EncodableMap>(*arguments);
  const auto it = map.find(flutter::EncodableValue("path"));
  if (it == map.end()) return false;
  const auto* value = std::get_if<std::string>(&it->second);
  if (value == nullptr || value->empty()) return false;
  *path = *value;
  return true;
}

HRESULT ExtractVideoPoster(const std::wstring& path, uint32_t* width,
                           uint32_t* height, std::vector<uint8_t>* pixels) {
  if (width == nullptr || height == nullptr || pixels == nullptr) {
    return E_INVALIDARG;
  }

  ComPtr<IMFSourceReader> reader;
  HRESULT hr = MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader);
  if (FAILED(hr)) return hr;

  hr = reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  if (FAILED(hr)) return hr;
  hr = reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), TRUE);
  if (FAILED(hr)) return hr;

  ComPtr<IMFMediaType> output_type;
  hr = MFCreateMediaType(&output_type);
  if (FAILED(hr)) return hr;
  hr = output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (FAILED(hr)) return hr;
  hr = output_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (FAILED(hr)) return hr;
  hr = reader->SetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
      output_type.Get());
  if (FAILED(hr)) {
    hr = output_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    if (FAILED(hr)) return hr;
    hr = reader->SetCurrentMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
        output_type.Get());
    if (FAILED(hr)) return hr;
  }

  ComPtr<IMFMediaType> current_type;
  hr = reader->GetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), &current_type);
  if (FAILED(hr)) return hr;

  UINT32 frame_width = 0;
  UINT32 frame_height = 0;
  hr = MFGetAttributeSize(current_type.Get(), MF_MT_FRAME_SIZE, &frame_width,
                          &frame_height);
  if (FAILED(hr) || frame_width == 0 || frame_height == 0) {
    return E_INVALIDARG;
  }
  const uint64_t pixel_count = static_cast<uint64_t>(frame_width) *
                               static_cast<uint64_t>(frame_height);
  if (pixel_count > kMaxDecodedBytes / 4 ||
      pixel_count > std::numeric_limits<size_t>::max() / 4) {
    return E_OUTOFMEMORY;
  }

  DWORD stream_index = 0;
  DWORD flags = 0;
  LONGLONG timestamp = 0;
  ComPtr<IMFSample> sample;
  for (int attempt = 0; attempt < 64 && sample == nullptr; ++attempt) {
    hr = reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0,
        &stream_index, &flags, &timestamp, &sample);
    if (FAILED(hr)) return hr;
    if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) return MF_E_END_OF_STREAM;
  }
  if (sample == nullptr) return MF_E_END_OF_STREAM;

  ComPtr<IMFMediaBuffer> buffer;
  hr = sample->ConvertToContiguousBuffer(&buffer);
  if (FAILED(hr)) return hr;

  BYTE* source_bytes = nullptr;
  DWORD max_length = 0;
  DWORD current_length = 0;
  hr = buffer->Lock(&source_bytes, &max_length, &current_length);
  if (FAILED(hr)) return hr;

  GUID subtype{};
  hr = current_type->GetGUID(MF_MT_SUBTYPE, &subtype);
  if (FAILED(hr)) {
    buffer->Unlock();
    return hr;
  }
  const bool is_nv12 = IsEqualGUID(subtype, MFVideoFormat_NV12) != FALSE;
  LONG native_stride = is_nv12 ? static_cast<LONG>(frame_width)
                               : static_cast<LONG>(frame_width) * 4;
  UINT32 unsigned_stride = 0;
  if (SUCCEEDED(current_type->GetUINT32(MF_MT_DEFAULT_STRIDE,
                                        &unsigned_stride)) &&
      unsigned_stride != 0) {
    native_stride = static_cast<LONG>(unsigned_stride);
  }
  const int64_t signed_stride = static_cast<int64_t>(native_stride);
  const uint64_t absolute_stride = signed_stride < 0
                                       ? static_cast<uint64_t>(-signed_stride)
                                       : static_cast<uint64_t>(signed_stride);
  const uint64_t minimum_stride = is_nv12
                                      ? static_cast<uint64_t>(frame_width)
                                      : static_cast<uint64_t>(frame_width) * 4;
  const uint64_t chroma_height = (static_cast<uint64_t>(frame_height) + 1) / 2;
  const uint64_t required_source_bytes =
      absolute_stride * (static_cast<uint64_t>(frame_height) +
                         (is_nv12 ? chroma_height : 0));
  if (absolute_stride < minimum_stride ||
      required_source_bytes > current_length) {
    buffer->Unlock();
    return MF_E_INVALIDMEDIATYPE;
  }

  const size_t output_row_bytes = static_cast<size_t>(frame_width) * 4;
  pixels->assign(static_cast<size_t>(pixel_count) * 4, 0);
  if (!is_nv12) {
    for (uint32_t row = 0; row < frame_height; ++row) {
      const uint32_t source_row =
          native_stride < 0 ? frame_height - row - 1 : row;
      const auto* source = source_bytes +
                           static_cast<size_t>(source_row) *
                               static_cast<size_t>(absolute_stride);
      auto* destination = pixels->data() +
                          static_cast<size_t>(row) * output_row_bytes;
      std::memcpy(destination, source, output_row_bytes);
      for (uint32_t column = 0; column < frame_width; ++column) {
        destination[static_cast<size_t>(column) * 4 + 3] = 0xff;
      }
    }
  } else {
    const size_t luma_plane_bytes =
        static_cast<size_t>(absolute_stride) * frame_height;
    const auto* chroma_plane = source_bytes + luma_plane_bytes;
    const auto clamp_byte = [](int value) -> uint8_t {
      return static_cast<uint8_t>(value < 0 ? 0 : value > 255 ? 255 : value);
    };
    for (uint32_t row = 0; row < frame_height; ++row) {
      const uint32_t source_row =
          native_stride < 0 ? frame_height - row - 1 : row;
      const uint32_t chroma_row = source_row / 2;
      const auto* luma = source_bytes +
                         static_cast<size_t>(source_row) *
                             static_cast<size_t>(absolute_stride);
      const auto* chroma = chroma_plane +
                           static_cast<size_t>(chroma_row) *
                               static_cast<size_t>(absolute_stride);
      auto* destination = pixels->data() +
                          static_cast<size_t>(row) * output_row_bytes;
      for (uint32_t column = 0; column < frame_width; ++column) {
        const size_t chroma_column = static_cast<size_t>(column / 2) * 2;
        const int y = static_cast<int>(luma[column]);
        const int u = static_cast<int>(chroma[chroma_column]);
        const int v = static_cast<int>(chroma[chroma_column + 1]);
        const int c = y - 16;
        const int d = u - 128;
        const int e = v - 128;
        auto* pixel = destination + static_cast<size_t>(column) * 4;
        pixel[0] = clamp_byte((298 * c + 516 * d + 128) >> 8);
        pixel[1] = clamp_byte((298 * c - 100 * d - 208 * e + 128) >> 8);
        pixel[2] = clamp_byte((298 * c + 409 * e + 128) >> 8);
        pixel[3] = 0xff;
      }
    }
  }
  buffer->Unlock();

  *width = frame_width;
  *height = frame_height;
  return S_OK;
}

}  // namespace

VideoPosterChannel::VideoPosterChannel(flutter::BinaryMessenger* messenger)
    : channel_(
          std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
              messenger, kChannelName,
              &flutter::StandardMethodCodec::GetInstance())) {
  media_foundation_started_ = SUCCEEDED(MFStartup(MF_VERSION));
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
}

VideoPosterChannel::~VideoPosterChannel() {
  if (channel_ != nullptr) channel_->SetMethodCallHandler(nullptr);
  channel_.reset();
  if (media_foundation_started_) MFShutdown();
}

void VideoPosterChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != kExtractVideoPosterMethod) {
    result->NotImplemented();
    return;
  }
  if (!media_foundation_started_) {
    result->Error("unsupported", "Media Foundation is unavailable");
    return;
  }

  std::string path;
  if (!ReadPath(call, &path)) {
    result->Error("invalid_arguments", "A video path is required");
    return;
  }
  const std::wstring wide_path = Utf8ToWide(path);
  if (wide_path.empty()) {
    result->Error("invalid_arguments", "The video path is not valid UTF-8");
    return;
  }

  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool uninitialize = SUCCEEDED(initialized);
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<uint8_t> pixels;
  const HRESULT hr = ExtractVideoPoster(wide_path, &width, &height, &pixels);
  if (uninitialize) CoUninitialize();
  if (FAILED(hr)) {
    result->Error("decode_failed", "The video poster could not be decoded");
    return;
  }

  flutter::EncodableMap response;
  response[flutter::EncodableValue("width")] =
      flutter::EncodableValue(static_cast<int32_t>(width));
  response[flutter::EncodableValue("height")] =
      flutter::EncodableValue(static_cast<int32_t>(height));
  response[flutter::EncodableValue("row_stride")] =
      flutter::EncodableValue(static_cast<int32_t>(width * 4));
  response[flutter::EncodableValue("pixels")] =
      flutter::EncodableValue(std::move(pixels));
  result->Success(flutter::EncodableValue(std::move(response)));
}
