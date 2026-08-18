import 'dart:io';

import 'package:flutter/services.dart';

import 'video_poster_decoder.dart';

/// Uses the native video decoder exposed by the desktop runner. The current
/// native implementation is Windows Media Foundation; other platforms keep
/// the existing best-effort no-preview fallback until their native decoder is
/// wired to the same channel.
final class FlutterVideoPosterDecoder implements VideoPosterDecoder {
  const FlutterVideoPosterDecoder();

  static const MethodChannel _channel = MethodChannel(
    'com.zhouzhipeng.safebox/video_preview',
  );

  @override
  Future<VideoPosterFrame?> decode(File source) async {
    if (!Platform.isWindows) return null;
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'extractVideoPoster',
        <String, Object?>{'path': source.path},
      );
      if (raw is! Map<Object?, Object?>) return null;
      final width = _asInt(raw['width']);
      final height = _asInt(raw['height']);
      final rowStride = _asInt(raw['row_stride']);
      final encodedPixels = raw['pixels'];
      if (width == null ||
          height == null ||
          rowStride == null ||
          encodedPixels == null) {
        return null;
      }
      final pixels = encodedPixels is Uint8List
          ? Uint8List.fromList(encodedPixels)
          : encodedPixels is List<int>
          ? Uint8List.fromList(encodedPixels)
          : null;
      if (pixels == null) return null;
      return VideoPosterFrame(
        width: width,
        height: height,
        rowStride: rowStride,
        pixels: pixels,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on Object {
      return null;
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num && value == value.roundToDouble()) return value.toInt();
    return null;
  }
}
