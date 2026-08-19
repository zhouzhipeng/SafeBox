#include "video_poster_channel.h"

#include <windows.h>

#include <flutter/standard_method_codec.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <functional>
#include <limits>
#include <random>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;

constexpr char kChannelName[] = "com.zhouzhipeng.safebox/video_preview";
constexpr char kExtractVideoPosterMethod[] = "extractVideoPoster";
constexpr char kExtractVideoPostersMethod[] = "extractVideoPosters";
constexpr int32_t kDefaultCandidateCount = 5;
constexpr int32_t kMaxCandidateCount = 5;
constexpr uint64_t kMaxDecodedBytes = 32ULL * 1024ULL * 1024ULL;
constexpr uint32_t kMaxReturnedFrameDimension = 640;

struct DecodedVideoFrame {
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<uint8_t> pixels;
};

// MF_MT_FRAME_SIZE can include codec padding. The minimum display aperture is
// the part of that frame that contains valid picture data.
struct FrameAperture {
  uint32_t left = 0;
  uint32_t top = 0;
  uint32_t width = 0;
  uint32_t height = 0;
};

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

int32_t ReadCandidateCount(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  int32_t count = kDefaultCandidateCount;
  const auto* arguments = call.arguments();
  if (arguments == nullptr || !std::holds_alternative<flutter::EncodableMap>(
                                  *arguments)) {
    return count;
  }
  const auto& map = std::get<flutter::EncodableMap>(*arguments);
  const auto it = map.find(flutter::EncodableValue("count"));
  if (it == map.end()) return count;
  if (const auto* int32_value = std::get_if<int32_t>(&it->second)) {
    count = *int32_value;
  } else if (const auto* int64_value = std::get_if<int64_t>(&it->second)) {
    if (*int64_value > std::numeric_limits<int32_t>::max()) {
      count = kMaxCandidateCount;
    } else if (*int64_value < std::numeric_limits<int32_t>::min()) {
      count = 1;
    } else {
      count = static_cast<int32_t>(*int64_value);
    }
  }
  return std::clamp(count, 1, kMaxCandidateCount);
}

bool ReadVideoArea(IMFMediaType* media_type, REFGUID attribute,
                   uint32_t frame_width, uint32_t frame_height,
                   FrameAperture* aperture) {
  if (media_type == nullptr || aperture == nullptr) return false;

  UINT32 blob_size = 0;
  if (FAILED(media_type->GetBlobSize(attribute, &blob_size)) ||
      blob_size < sizeof(MFVideoArea)) {
    return false;
  }

  MFVideoArea area{};
  if (FAILED(media_type->GetBlob(attribute,
                                reinterpret_cast<UINT8*>(&area),
                                sizeof(area), nullptr))) {
    return false;
  }

  const int64_t left = static_cast<int64_t>(area.OffsetX.value);
  const int64_t top = static_cast<int64_t>(area.OffsetY.value);
  const int64_t width = static_cast<int64_t>(area.Area.cx);
  const int64_t height = static_cast<int64_t>(area.Area.cy);
  if (left < 0 || top < 0 || width <= 0 || height <= 0 ||
      left + width > frame_width || top + height > frame_height) {
    return false;
  }

  aperture->left = static_cast<uint32_t>(left);
  aperture->top = static_cast<uint32_t>(top);
  aperture->width = static_cast<uint32_t>(width);
  aperture->height = static_cast<uint32_t>(height);
  return true;
}

FrameAperture ReadDisplayAperture(IMFMediaType* media_type,
                                  uint32_t frame_width,
                                  uint32_t frame_height) {
  FrameAperture aperture;
  aperture.width = frame_width;
  aperture.height = frame_height;
  if (ReadVideoArea(media_type, MF_MT_MINIMUM_DISPLAY_APERTURE, frame_width,
                    frame_height, &aperture)) {
    return aperture;
  }
  // Some sources expose only the geometric aperture. It is still preferable
  // to crop it when it is a valid sub-rectangle of the decoded frame.
  ReadVideoArea(media_type, MF_MT_GEOMETRIC_APERTURE, frame_width,
                frame_height, &aperture);
  return aperture;
}

void CropFrameToAperture(const FrameAperture& aperture,
                         uint32_t frame_width, uint32_t frame_height,
                         DecodedVideoFrame* frame) {
  if (frame == nullptr ||
      (aperture.left == 0 && aperture.top == 0 &&
       aperture.width == frame_width && aperture.height == frame_height)) {
    return;
  }

  const size_t source_row_bytes = static_cast<size_t>(frame_width) * 4;
  const size_t destination_row_bytes = static_cast<size_t>(aperture.width) * 4;
  std::vector<uint8_t> cropped(
      static_cast<size_t>(aperture.width) * aperture.height * 4, 0);
  for (uint32_t row = 0; row < aperture.height; ++row) {
    const auto* source = frame->pixels.data() +
                         static_cast<size_t>(aperture.top + row) *
                             source_row_bytes +
                         static_cast<size_t>(aperture.left) * 4;
    auto* destination = cropped.data() +
                        static_cast<size_t>(row) * destination_row_bytes;
    std::memcpy(destination, source, destination_row_bytes);
  }
  frame->pixels.swap(cropped);
  frame->width = aperture.width;
  frame->height = aperture.height;
}

HRESULT OpenVideoReader(const std::wstring& path,
                        ComPtr<IMFSourceReader>* reader,
                        ComPtr<IMFMediaType>* current_type,
                        uint32_t* width, uint32_t* height,
                        FrameAperture* display_aperture) {
  if (reader == nullptr || current_type == nullptr || width == nullptr ||
      height == nullptr || display_aperture == nullptr) {
    return E_INVALIDARG;
  }

  ComPtr<IMFAttributes> reader_attributes;
  HRESULT hr = MFCreateAttributes(&reader_attributes, 1);
  if (FAILED(hr)) return hr;
  // This conversion path is explicitly intended for small, software-created
  // thumbnails and avoids handing the Dart side an unconverted YUV surface.
  hr = reader_attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING,
                                    TRUE);
  if (FAILED(hr)) return hr;

  hr = MFCreateSourceReaderFromURL(
      path.c_str(), reader_attributes.Get(), reader->ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;

  hr = (*reader)->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  if (FAILED(hr)) return hr;
  hr = (*reader)->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), TRUE);
  if (FAILED(hr)) return hr;

  ComPtr<IMFMediaType> output_type;
  hr = MFCreateMediaType(&output_type);
  if (FAILED(hr)) return hr;
  hr = output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (FAILED(hr)) return hr;
  hr = output_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (FAILED(hr)) return hr;
  hr = (*reader)->SetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
      output_type.Get());
  if (FAILED(hr)) {
    hr = output_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    if (FAILED(hr)) return hr;
    hr = (*reader)->SetCurrentMediaType(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr,
        output_type.Get());
    if (FAILED(hr)) return hr;
  }

  hr = (*reader)->GetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
      current_type->ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;

  UINT32 frame_width = 0;
  UINT32 frame_height = 0;
  hr = MFGetAttributeSize((*current_type).Get(), MF_MT_FRAME_SIZE,
                          &frame_width, &frame_height);
  if (FAILED(hr) || frame_width == 0 || frame_height == 0) return E_INVALIDARG;

  const uint64_t pixel_count = static_cast<uint64_t>(frame_width) *
                               static_cast<uint64_t>(frame_height);
  if (pixel_count > kMaxDecodedBytes / 4 ||
      pixel_count > std::numeric_limits<size_t>::max() / 4) {
    return E_OUTOFMEMORY;
  }
  *width = frame_width;
  *height = frame_height;
  *display_aperture =
      ReadDisplayAperture((*current_type).Get(), frame_width, frame_height);
  return S_OK;
}

HRESULT ReadFrame(IMFSourceReader* reader, IMFMediaType* current_type,
                  uint32_t frame_width, uint32_t frame_height,
                  const FrameAperture& display_aperture,
                  bool seek, LONGLONG seek_position,
                  DecodedVideoFrame* frame) {
  if (reader == nullptr || current_type == nullptr || frame == nullptr) {
    return E_INVALIDARG;
  }

  HRESULT hr = S_OK;
  if (seek) {
    PROPVARIANT position;
    PropVariantInit(&position);
    position.vt = VT_I8;
    position.hVal.QuadPart = seek_position;
    // GUID_NULL selects Media Foundation's default 100-nanosecond media-time
    // position format for IMFSourceReader::SetCurrentPosition.
    hr = reader->SetCurrentPosition(GUID_NULL, position);
    PropVariantClear(&position);
    if (FAILED(hr)) return hr;
  }

  DWORD stream_index = 0;
  DWORD flags = 0;
  LONGLONG timestamp = 0;
  ComPtr<IMFSample> sample;
  for (int attempt = 0; attempt < 64 && sample == nullptr; ++attempt) {
    sample.Reset();
    hr = reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0,
        &stream_index, &flags, &timestamp, &sample);
    if (FAILED(hr)) return hr;
    if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
      return MF_E_END_OF_STREAM;
    }
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
  const uint64_t chroma_height =
      (static_cast<uint64_t>(frame_height) + 1) / 2;
  const uint64_t required_source_bytes =
      absolute_stride * (static_cast<uint64_t>(frame_height) +
                         (is_nv12 ? chroma_height : 0));
  if (absolute_stride < minimum_stride || required_source_bytes > current_length) {
    buffer->Unlock();
    return MF_E_INVALIDMEDIATYPE;
  }

  const size_t output_row_bytes = static_cast<size_t>(frame_width) * 4;
  const uint64_t pixel_count = static_cast<uint64_t>(frame_width) *
                               static_cast<uint64_t>(frame_height);
  frame->pixels.assign(static_cast<size_t>(pixel_count) * 4, 0);
  if (!is_nv12) {
    for (uint32_t row = 0; row < frame_height; ++row) {
      const uint32_t source_row =
          native_stride < 0 ? frame_height - row - 1 : row;
      const auto* source = source_bytes +
                           static_cast<size_t>(source_row) *
                               static_cast<size_t>(absolute_stride);
      auto* destination = frame->pixels.data() +
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
      auto* destination = frame->pixels.data() +
                          static_cast<size_t>(row) * output_row_bytes;
      for (uint32_t column = 0; column < frame_width; ++column) {
        const size_t chroma_column = static_cast<size_t>(column / 2) * 2;
        if (chroma_column + 1 >= absolute_stride) {
          buffer->Unlock();
          return MF_E_INVALIDMEDIATYPE;
        }
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

  frame->width = frame_width;
  frame->height = frame_height;
  CropFrameToAperture(display_aperture, frame_width, frame_height, frame);

  const uint32_t source_width = frame->width;
  const uint32_t source_height = frame->height;
  const size_t source_row_bytes = static_cast<size_t>(source_width) * 4;
  uint32_t returned_width = source_width;
  uint32_t returned_height = source_height;
  if (source_width > kMaxReturnedFrameDimension ||
      source_height > kMaxReturnedFrameDimension) {
    if (source_width >= source_height) {
      returned_width = kMaxReturnedFrameDimension;
      returned_height = std::max<uint32_t>(
          1, static_cast<uint32_t>((static_cast<uint64_t>(source_height) *
                                    returned_width) /
                                   source_width));
    } else {
      returned_height = kMaxReturnedFrameDimension;
      returned_width = std::max<uint32_t>(
          1, static_cast<uint32_t>((static_cast<uint64_t>(source_width) *
                                    returned_height) /
                                   source_height));
    }
    const size_t resized_row_bytes = static_cast<size_t>(returned_width) * 4;
    std::vector<uint8_t> resized(
        static_cast<size_t>(returned_width) * returned_height * 4, 0);
    for (uint32_t row = 0; row < returned_height; ++row) {
      const uint32_t source_row = std::min<uint32_t>(
          source_height - 1,
          static_cast<uint32_t>((static_cast<uint64_t>(row) * source_height) /
                                returned_height));
      for (uint32_t column = 0; column < returned_width; ++column) {
        const uint32_t source_column = std::min<uint32_t>(
            source_width - 1,
            static_cast<uint32_t>((static_cast<uint64_t>(column) * source_width) /
                                  returned_width));
        const auto* source = frame->pixels.data() +
                             static_cast<size_t>(source_row) *
                                 source_row_bytes +
                             static_cast<size_t>(source_column) * 4;
        auto* destination = resized.data() +
                            static_cast<size_t>(row) * resized_row_bytes +
                            static_cast<size_t>(column) * 4;
        std::memcpy(destination, source, 4);
      }
    }
    frame->pixels.swap(resized);
  }
  frame->width = returned_width;
  frame->height = returned_height;
  return S_OK;
}

LONGLONG ReadDuration(IMFSourceReader* reader) {
  if (reader == nullptr) return 0;
  PROPVARIANT duration;
  PropVariantInit(&duration);
  const HRESULT hr = reader->GetPresentationAttribute(
      static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
      &duration);
  LONGLONG result = 0;
  if (SUCCEEDED(hr)) {
    if (duration.vt == VT_I8 && duration.hVal.QuadPart > 0) {
      result = duration.hVal.QuadPart;
    } else if (duration.vt == VT_UI8 &&
               duration.uhVal.QuadPart > 0 &&
               duration.uhVal.QuadPart <=
                   static_cast<ULONGLONG>(std::numeric_limits<LONGLONG>::max())) {
      result = static_cast<LONGLONG>(duration.uhVal.QuadPart);
    }
  }
  PropVariantClear(&duration);
  return result;
}

LONGLONG ReadFramePeriod(IMFMediaType* current_type) {
  if (current_type == nullptr) return 0;
  UINT32 numerator = 0;
  UINT32 denominator = 0;
  if (FAILED(MFGetAttributeRatio(current_type, MF_MT_FRAME_RATE, &numerator,
                                 &denominator)) ||
      numerator == 0 || denominator == 0) {
    return 0;
  }
  constexpr LONGLONG kMediaTimeUnitsPerSecond = 10000000;
  const uint64_t scaled = static_cast<uint64_t>(kMediaTimeUnitsPerSecond) *
                          static_cast<uint64_t>(denominator);
  const uint64_t period = (scaled + numerator - 1) / numerator;
  if (period == 0 ||
      period > static_cast<uint64_t>(std::numeric_limits<LONGLONG>::max())) {
    return 0;
  }
  return static_cast<LONGLONG>(period);
}

HRESULT ExtractVideoPosters(const std::wstring& path, int32_t count,
                            std::vector<DecodedVideoFrame>* frames) {
  if (frames == nullptr || count < 1) return E_INVALIDARG;
  frames->clear();

  ComPtr<IMFSourceReader> reader;
  ComPtr<IMFMediaType> current_type;
  uint32_t width = 0;
  uint32_t height = 0;
  FrameAperture display_aperture;
  HRESULT hr = OpenVideoReader(path, &reader, &current_type, &width, &height,
                               &display_aperture);
  if (FAILED(hr)) return hr;

  const LONGLONG duration = ReadDuration(reader.Get());
  const LONGLONG frame_period = ReadFramePeriod(current_type.Get());
  const auto now = std::chrono::steady_clock::now().time_since_epoch().count();
  const auto seed = static_cast<uint64_t>(now) ^
                    static_cast<uint64_t>(std::hash<std::wstring>{}(path));
  std::mt19937_64 random(seed);
  std::vector<LONGLONG> positions;
  positions.reserve(static_cast<size_t>(count));

  if (duration > 0 && frame_period > 0) {
    const LONGLONG total_frames = duration / frame_period;
    const LONGLONG first_frame =
        std::min<LONGLONG>(10, std::max<LONGLONG>(total_frames - 1, 0));
    positions.push_back(first_frame * frame_period);

    if (count > 1 && total_frames > first_frame + 1) {
      const LONGLONG lower_frame =
          std::min<LONGLONG>(std::max<LONGLONG>(first_frame + 1, 20),
                             total_frames - 1);
      const LONGLONG upper_frame = total_frames - 1;
      if (lower_frame == upper_frame) {
        positions.push_back(upper_frame * frame_period);
      } else {
        std::uniform_int_distribution<LONGLONG> distribution(lower_frame,
                                                              upper_frame);
        std::vector<LONGLONG> selected_frames;
        selected_frames.reserve(static_cast<size_t>(count - 1));
        for (int32_t index = 1; index < count; ++index) {
          LONGLONG frame_index = distribution(random);
          for (int attempt = 0; attempt < 12; ++attempt) {
            bool duplicate = false;
            for (const auto existing : selected_frames) {
              if (frame_index == existing) {
                duplicate = true;
                break;
              }
            }
            if (!duplicate) break;
            frame_index = distribution(random);
          }
          selected_frames.push_back(frame_index);
          positions.push_back(frame_index * frame_period);
        }
      }
    }
  } else {
    const LONGLONG lower = frame_period > 0
                               ? frame_period * 10
                               : std::max<LONGLONG>(duration / 20, 1);
    const LONGLONG upper =
        duration > lower ? std::max<LONGLONG>(lower, duration - duration / 20)
                         : lower;
    std::uniform_int_distribution<LONGLONG> distribution(lower, upper);
    for (int32_t index = 0; index < count; ++index) {
      positions.push_back(index == 0 ? lower : distribution(random));
    }
  }

  for (const auto position : positions) {
    DecodedVideoFrame frame;
    if (SUCCEEDED(ReadFrame(reader.Get(), current_type.Get(), width, height,
                            display_aperture, true, position, &frame))) {
      frames->push_back(std::move(frame));
    }
  }

  if (frames->empty()) return MF_E_END_OF_STREAM;
  return S_OK;
}

flutter::EncodableMap EncodeFrame(DecodedVideoFrame frame) {
  flutter::EncodableMap response;
  response[flutter::EncodableValue("width")] =
      flutter::EncodableValue(static_cast<int32_t>(frame.width));
  response[flutter::EncodableValue("height")] =
      flutter::EncodableValue(static_cast<int32_t>(frame.height));
  response[flutter::EncodableValue("row_stride")] =
      flutter::EncodableValue(static_cast<int32_t>(frame.width * 4));
  response[flutter::EncodableValue("pixels")] =
      flutter::EncodableValue(std::move(frame.pixels));
  return response;
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
  const bool multiple = call.method_name() == kExtractVideoPostersMethod;
  if (!multiple && call.method_name() != kExtractVideoPosterMethod) {
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
  std::vector<DecodedVideoFrame> frames;
  const HRESULT hr = ExtractVideoPosters(
      wide_path, multiple ? ReadCandidateCount(call) : 1, &frames);
  if (uninitialize) CoUninitialize();
  if (FAILED(hr) || frames.empty()) {
    result->Error("decode_failed", "The video poster could not be decoded");
    return;
  }

  if (!multiple) {
    result->Success(flutter::EncodableValue(EncodeFrame(std::move(frames.front()))));
    return;
  }

  flutter::EncodableList response;
  response.reserve(frames.size());
  for (auto& frame : frames) {
    response.emplace_back(EncodeFrame(std::move(frame)));
  }
  result->Success(flutter::EncodableValue(std::move(response)));
}
