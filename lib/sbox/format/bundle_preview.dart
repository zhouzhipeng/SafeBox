import 'dart:typed_data';

import '../constants.dart';
import '../errors.dart';
import 'bundle_manifest.dart';

enum BundlePreviewCodec {
  baselineJpeg(SboxProtocol.previewCodecBaselineJpeg);

  const BundlePreviewCodec(this.wireId);

  final int wireId;

  static BundlePreviewCodec fromWireId(int value) {
    for (final codec in values) {
      if (codec.wireId == value) return codec;
    }
    throw const SboxException(
      SboxErrorCode.invalidManifest,
      'Preview 编码格式无效',
    );
  }
}

/// An encoded, single-frame preview carried inside Metadata Block v2.
///
/// The byte array is copied on input and through [encodedBytes]. The view
/// getter is reserved for bounded, read-only UI presentation so a widget
/// rebuild does not allocate another copy of the encoded JPEG.
final class BundlePreview {
  BundlePreview({
    required this.codec,
    required this.width,
    required this.height,
    required List<int> encodedBytes,
  }) : _encodedBytes = Uint8List.fromList(encodedBytes) {
    if (width < 1 ||
        width > SboxProtocol.maxPreviewDimension ||
        height < 1 ||
        height > SboxProtocol.maxPreviewDimension ||
        width > SboxProtocol.maxPreviewPixels ~/ height ||
        _encodedBytes.isEmpty ||
        _encodedBytes.length > SboxProtocol.maxPreviewBytes) {
      throw const SboxException(
        SboxErrorCode.invalidManifest,
        'Preview 参数无效',
      );
    }
  }

  final BundlePreviewCodec codec;
  final int width;
  final int height;
  final Uint8List _encodedBytes;

  Uint8List get encodedBytes => Uint8List.fromList(_encodedBytes);

  /// A non-owning view for consumers such as Flutter's image decoder.
  /// Callers must not mutate it or retain it after [dispose].
  Uint8List get encodedBytesView => _encodedBytes;

  int get encodedLength => _encodedBytes.length;

  BundlePreview copy() => BundlePreview(
    codec: codec,
    width: width,
    height: height,
    encodedBytes: _encodedBytes,
  );

  void dispose() => _encodedBytes.fillRange(0, _encodedBytes.length, 0);
}

final class BundleMetadata {
  const BundleMetadata({required this.manifest, this.preview});

  final BundleManifest manifest;
  final BundlePreview? preview;
}
