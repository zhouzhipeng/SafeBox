import 'dart:io';

import 'package:flutter/services.dart';

import 'video_poster_decoder.dart';

/// Uses the native video decoder exposed through the shared Flutter channel.
///
/// The Dart API is deliberately platform-neutral. A platform without a
/// registered backend returns the existing best-effort no-preview fallback;
/// Windows currently registers Media Foundation, while macOS/iOS can register
/// AVFoundation against the same contract without changing product code.
final class FlutterVideoPosterDecoder
    implements VideoPosterDecoder, VideoPosterCandidatesDecoder {
  const FlutterVideoPosterDecoder();

  static const MethodChannel _channel = MethodChannel(
    'com.zhouzhipeng.safebox/video_preview',
  );

  @override
  Future<VideoPosterFrame?> decode(File source) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'extractVideoPoster',
        <String, Object?>{'path': source.path},
      );
      return _parseFrame(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on Object {
      return null;
    }
  }

  @override
  Future<List<VideoPosterFrame>> decodeCandidates(
    File source, {
    int count = defaultVideoPosterCandidateCount,
  }) async {
    if (count < 1) return const <VideoPosterFrame>[];
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'extractVideoPosters',
        <String, Object?>{
          'path': source.path,
          'count': count.clamp(1, defaultVideoPosterCandidateCount).toInt(),
        },
      );
      if (raw is! List) return const <VideoPosterFrame>[];
      final frames = <VideoPosterFrame>[];
      for (final item in raw) {
        final frame = _parseFrame(item);
        if (frame != null) frames.add(frame);
      }
      if (frames.isNotEmpty) return frames;
    } on MissingPluginException {
      // Fall through to the single-frame channel used by older runners.
    } on PlatformException {
      // Fall through to the single-frame channel used by older runners.
    } on Object {
      // Fall through to the single-frame channel used by older runners.
    }
    final first = await decode(source);
    return first == null
        ? const <VideoPosterFrame>[]
        : <VideoPosterFrame>[first];
  }

  static VideoPosterFrame? _parseFrame(Object? value) {
    if (value is! Map<Object?, Object?>) return null;
    final width = _asInt(value['width']);
    final height = _asInt(value['height']);
    final rowStride = _asInt(value['row_stride']);
    final encodedPixels = value['pixels'];
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
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num && value == value.roundToDouble()) return value.toInt();
    return null;
  }
}
