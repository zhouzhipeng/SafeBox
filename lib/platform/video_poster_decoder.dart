import 'dart:io';
import 'dart:typed_data';

/// Supplies one decoded video frame to the platform-independent preview
/// encoder. The bytes are owned by this object and must be disposed after the
/// frame has been converted to a preview image.
abstract interface class VideoPosterDecoder {
  Future<VideoPosterFrame?> decode(File source);
}

final class VideoPosterFrame {
  VideoPosterFrame({
    required this.width,
    required this.height,
    required this.rowStride,
    required this.pixels,
  });

  final int width;
  final int height;
  final int rowStride;
  final Uint8List pixels;

  void dispose() {
    pixels.fillRange(0, pixels.length, 0);
  }
}
