import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../sbox/constants.dart';
import '../sbox/errors.dart';
import '../sbox/format/baseline_jpeg_inspector.dart';
import '../sbox/format/bundle_preview.dart';
import 'preview_generation_result.dart';

abstract interface class PreviewGenerator {
  Future<PreviewGenerationResult> generate(File source);
}

/// A bounded static-image generator used by the desktop and mobile product
/// layers. Video is deliberately detected but reported as platform
/// unsupported until a platform poster-frame implementation is installed.
final class PlatformPreviewGenerator implements PreviewGenerator {
  const PlatformPreviewGenerator({
    this.timeout = const Duration(seconds: 8),
    this.maxSourceBytes = 64 * 1024 * 1024,
  });

  final Duration timeout;
  final int maxSourceBytes;

  @override
  Future<PreviewGenerationResult> generate(File source) async {
    try {
      final before = await _snapshot(source);
      if (before == null) {
        return const PreviewUnavailable(
          reason: PreviewUnavailableReason.decodeFailed,
        );
      }
      final result = await _generate(source, before).timeout(timeout);
      await _requireStable(source, before);
      return result;
    } on TimeoutException {
      return const PreviewUnavailable(reason: PreviewUnavailableReason.timeout);
    } on SboxException {
      rethrow;
    } on Object {
      return const PreviewUnavailable(
        reason: PreviewUnavailableReason.decodeFailed,
      );
    }
  }

  Future<PreviewGenerationResult> _generate(
    File source,
    _FileSnapshot before,
  ) async {
    final prefixLength = before.length.clamp(0, 1024 * 1024).toInt();
    final prefix = await _readRange(source, prefixLength);
    final probe = _probeMedia(prefix);
    if (probe.kind == _MediaKind.video) {
      return PreviewUnavailable(
        reason: PreviewUnavailableReason.platformUnsupported,
        detectedSourceMediaType: probe.mediaType,
      );
    }
    if (probe.kind != _MediaKind.staticImage) {
      return PreviewUnavailable(
        reason: PreviewUnavailableReason.unsupportedMediaType,
        detectedSourceMediaType: probe.mediaType,
      );
    }
    final dimensions = probe.dimensions;
    if (dimensions == null) {
      return PreviewUnavailable(
        reason: PreviewUnavailableReason.decodeFailed,
        detectedSourceMediaType: probe.mediaType,
      );
    }
    if (dimensions.width < 1 ||
        dimensions.height < 1 ||
        dimensions.width > 100000 ||
        dimensions.height > 100000 ||
        dimensions.width * dimensions.height > 32 * 1024 * 1024) {
      return PreviewUnavailable(
        reason: PreviewUnavailableReason.resourceLimit,
        detectedSourceMediaType: probe.mediaType,
      );
    }
    if (before.length > maxSourceBytes) {
      return PreviewUnavailable(
        reason: PreviewUnavailableReason.resourceLimit,
        detectedSourceMediaType: probe.mediaType,
      );
    }
    final bytes = await source.readAsBytes();
    try {
      final decoded = img.decodeImage(bytes, frame: 0);
      if (decoded == null || decoded.numFrames != 1) {
        return PreviewUnavailable(
          reason: decoded == null
              ? PreviewUnavailableReason.decodeFailed
              : PreviewUnavailableReason.unsupportedMediaType,
          detectedSourceMediaType: probe.mediaType,
        );
      }
      final oriented = img.bakeOrientation(decoded);
      final target = _targetDimensions(oriented.width, oriented.height);
      final resized = img.copyResize(
        oriented,
        width: target.width,
        height: target.height,
        interpolation: img.Interpolation.average,
      );
      final rgb = _flattenToRgb(resized);
      try {
        for (final quality in const <int>[72, 64, 56, 48, 40, 32]) {
          final encoded = img.encodeJpg(
            rgb,
            quality: quality,
            chroma: img.JpegChroma.yuv444,
          );
          if (encoded.length > SboxProtocol.maxPreviewBytes) continue;
          try {
            BaselineJpegInspector.validate(
              encoded,
              width: target.width,
              height: target.height,
            );
            return PreviewGenerated(
              preview: BundlePreview(
                codec: BundlePreviewCodec.baselineJpeg,
                width: target.width,
                height: target.height,
                encodedBytes: encoded,
              ),
              detectedSourceMediaType: probe.mediaType!,
            );
          } on SboxException {
            // Try the next quality/size candidate below.
          }
        }
        for (final dimension in const <int>[288, 256, 224, 192, 160, 128, 96]) {
          if (dimension >= target.longestSide) continue;
          final smaller = _targetDimensions(
            oriented.width,
            oriented.height,
            maximum: dimension,
          );
          final candidate = img.copyResize(
            oriented,
            width: smaller.width,
            height: smaller.height,
            interpolation: img.Interpolation.average,
          );
          final candidateRgb = _flattenToRgb(candidate);
          try {
            for (final quality in const <int>[72, 64, 56, 48, 40, 32]) {
              final encoded = img.encodeJpg(
                candidateRgb,
                quality: quality,
                chroma: img.JpegChroma.yuv444,
              );
              if (encoded.length > SboxProtocol.maxPreviewBytes) continue;
              try {
                BaselineJpegInspector.validate(
                  encoded,
                  width: smaller.width,
                  height: smaller.height,
                );
                return PreviewGenerated(
                  preview: BundlePreview(
                    codec: BundlePreviewCodec.baselineJpeg,
                    width: smaller.width,
                    height: smaller.height,
                    encodedBytes: encoded,
                  ),
                  detectedSourceMediaType: probe.mediaType!,
                );
              } on SboxException {
                // Continue through the bounded candidate set.
              }
            }
          } finally {
            candidateRgb.clear();
          }
        }
      } finally {
        rgb.clear();
      }
      return PreviewUnavailable(
        reason: PreviewUnavailableReason.encodeFailed,
        detectedSourceMediaType: probe.mediaType,
      );
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<_FileSnapshot?> _snapshot(File source) async {
    try {
      final stat = await source.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      return _FileSnapshot(length: stat.size, modified: stat.modified);
    } on FileSystemException {
      return null;
    }
  }

  Future<Uint8List> _readRange(File source, int length) async {
    if (length == 0) return Uint8List(0);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in source.openRead(0, length)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  _MediaProbe _probeMedia(Uint8List bytes) {
    if (_hasPrefix(bytes, const <int>[0xff, 0xd8, 0xff])) {
      final dimensions = _jpegDimensions(bytes);
      return _MediaProbe(
        kind: _MediaKind.staticImage,
        mediaType: 'image/jpeg',
        dimensions: dimensions,
      );
    }
    if (_hasPrefix(bytes, const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
      if (_containsAscii(bytes, 'acTL')) {
        return const _MediaProbe(
          kind: _MediaKind.animated,
          mediaType: 'image/png',
        );
      }
      if (bytes.length < 24 || !_containsAsciiAt(bytes, 12, 'IHDR')) {
        return const _MediaProbe(kind: _MediaKind.unknown);
      }
      return _MediaProbe(
        kind: _MediaKind.staticImage,
        mediaType: 'image/png',
        dimensions: _Dimensions(
          width: _uint32(bytes, 16),
          height: _uint32(bytes, 20),
        ),
      );
    }
    if (_hasPrefix(bytes, const <int>[0x52, 0x49, 0x46, 0x46]) &&
        bytes.length >= 12 &&
        _containsAsciiAt(bytes, 8, 'WEBP')) {
      if (_containsAscii(bytes, 'ANIM')) {
        return const _MediaProbe(
          kind: _MediaKind.animated,
          mediaType: 'image/webp',
        );
      }
      final dimensions = _webpDimensions(bytes);
      return _MediaProbe(
        kind: _MediaKind.staticImage,
        mediaType: 'image/webp',
        dimensions: dimensions,
      );
    }
    if (_containsAsciiAt(bytes, 4, 'ftyp')) {
      return const _MediaProbe(kind: _MediaKind.video, mediaType: 'video/mp4');
    }
    return const _MediaProbe(kind: _MediaKind.unknown);
  }

  static img.Image _flattenToRgb(img.Image source) {
    final output = img.Image(
      width: source.width,
      height: source.height,
      numChannels: 3,
    )..clear(img.ColorRgb8(0x10, 0x18, 0x20));
    img.compositeImage(output, source, blend: img.BlendMode.alpha);
    output.exif.clear();
    return output;
  }

  Future<void> _requireStable(File source, _FileSnapshot before) async {
    final after = await _snapshot(source);
    if (after == null ||
        after.length != before.length ||
        after.modified != before.modified) {
      throw const SboxException(
        SboxErrorCode.inputChanged,
        '输入在 Preview 生成期间发生变化',
      );
    }
  }

  static _Dimensions _targetDimensions(
    int width,
    int height, {
    int maximum = SboxProtocol.maxPreviewDimension,
  }) {
    final longest = width > height ? width : height;
    final scale = longest <= maximum ? 1.0 : maximum / longest;
    return _Dimensions(
      width: (width * scale).round().clamp(1, maximum).toInt(),
      height: (height * scale).round().clamp(1, maximum).toInt(),
    );
  }

  static bool _hasPrefix(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (bytes[index] != prefix[index]) return false;
    }
    return true;
  }

  static bool _containsAscii(List<int> bytes, String value) {
    final needle = value.codeUnits;
    for (var index = 0; index + needle.length <= bytes.length; index++) {
      if (_containsAsciiAt(bytes, index, value)) return true;
    }
    return false;
  }

  static bool _containsAsciiAt(List<int> bytes, int offset, String value) {
    final needle = value.codeUnits;
    if (offset < 0 || offset + needle.length > bytes.length) return false;
    for (var index = 0; index < needle.length; index++) {
      if (bytes[offset + index] != needle[index]) return false;
    }
    return true;
  }

  static int _uint32(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static int _uint32Le(List<int> bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static _Dimensions? _jpegDimensions(List<int> bytes) {
    var offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset] != 0xff) {
        offset++;
        continue;
      }
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) return null;
      final marker = bytes[offset++];
      if (marker == 0xda || marker == 0xd9) return null;
      if (marker == 0xd8 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (offset + 2 > bytes.length) return null;
      final length = (bytes[offset] << 8) | bytes[offset + 1];
      if (length < 2 || offset + length > bytes.length) return null;
      if ((marker >= 0xc0 && marker <= 0xc3) ||
          (marker >= 0xc5 && marker <= 0xc7) ||
          (marker >= 0xc9 && marker <= 0xcb) ||
          (marker >= 0xcd && marker <= 0xcf)) {
        if (length < 7) return null;
        return _Dimensions(
          width: (bytes[offset + 5] << 8) | bytes[offset + 6],
          height: (bytes[offset + 3] << 8) | bytes[offset + 4],
        );
      }
      offset += length;
    }
    return null;
  }

  static _Dimensions? _webpDimensions(List<int> bytes) {
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final type = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final length = _uint32Le(bytes, offset + 4);
      if (length < 0 || offset + 8 + length > bytes.length) return null;
      if (type == 'VP8X' && length >= 10) {
        final width = 1 + bytes[offset + 12] +
            (bytes[offset + 13] << 8) +
            (bytes[offset + 14] << 16);
        final height = 1 + bytes[offset + 15] +
            (bytes[offset + 16] << 8) +
            (bytes[offset + 17] << 16);
        return _Dimensions(width: width, height: height);
      }
      if (type == 'VP8 ' && length >= 10 && offset + 18 <= bytes.length) {
        return _Dimensions(
          width: bytes[offset + 14] | (bytes[offset + 15] << 8),
          height: bytes[offset + 16] | (bytes[offset + 17] << 8),
        );
      }
      if (type == 'VP8L' && length >= 5 && offset + 12 <= bytes.length) {
        final bits = bytes.sublist(offset + 9, offset + 13);
        if (bits.length == 4 && bits[0] == 0x2f) {
          final value = bits[1] | (bits[2] << 8) | (bits[3] << 16);
          return _Dimensions(
            width: 1 + (value & 0x3fff),
            height: 1 + ((value >> 14) & 0x3fff),
          );
        }
      }
      offset += 8 + length + (length.isOdd ? 1 : 0);
    }
    return null;
  }
}

final class _FileSnapshot {
  const _FileSnapshot({required this.length, required this.modified});

  final int length;
  final DateTime modified;
}

enum _MediaKind { staticImage, animated, video, unknown }

final class _MediaProbe {
  const _MediaProbe({
    required this.kind,
    this.mediaType,
    this.dimensions,
  });

  final _MediaKind kind;
  final String? mediaType;
  final _Dimensions? dimensions;
}

final class _Dimensions {
  const _Dimensions({required this.width, required this.height});

  final int width;
  final int height;

  int get longestSide => width > height ? width : height;
}
