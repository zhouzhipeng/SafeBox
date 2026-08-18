import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:safebox/platform/preview_generation_result.dart';
import 'package:safebox/platform/preview_generator.dart';
import 'package:safebox/platform/video_poster_decoder.dart';
import 'package:safebox/sbox/constants.dart';
import 'package:safebox/sbox/format/baseline_jpeg_inspector.dart';
import 'package:test/test.dart';

void main() {
  test('generates a bounded baseline JPEG from a static PNG', () async {
    final directory = await Directory.systemTemp.createTemp('sbox-preview-');
    final source = File('${directory.path}${Platform.pathSeparator}source.png');
    try {
      final image = img.Image(width: 64, height: 32);
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          image.setPixelRgb(x, y, x * 4, y * 8, 0x40);
        }
      }
      await source.writeAsBytes(img.encodePng(image), flush: true);

      final result = await const PlatformPreviewGenerator().generate(source);
      expect(result, isA<PreviewGenerated>());
      final generated = result as PreviewGenerated;
      expect(generated.detectedSourceMediaType, 'image/png');
      expect(generated.preview.width, 64);
      expect(generated.preview.height, 32);
      expect(generated.preview.encodedLength, lessThanOrEqualTo(10240));
      final info = BaselineJpegInspector.inspect(
        generated.preview.encodedBytes,
      );
      expect(info.width, 64);
      expect(info.height, 32);
      generated.preview.dispose();
    } finally {
      if (await source.exists()) await source.delete();
      await directory.delete();
    }
  });

  test('unsupported media continues without a Preview', () async {
    final directory = await Directory.systemTemp.createTemp('sbox-preview-');
    final source = File('${directory.path}${Platform.pathSeparator}source.gif');
    try {
      await source.writeAsBytes(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
      final result = await const PlatformPreviewGenerator().generate(source);
      expect(
        result,
        isA<PreviewUnavailable>(),
      );
      expect(
        (result as PreviewUnavailable).reason,
        PreviewUnavailableReason.unsupportedMediaType,
      );
    } finally {
      if (await source.exists()) await source.delete();
      await directory.delete();
    }
  });

  test('encodes a platform video poster as a baseline JPEG', () async {
    final directory = await Directory.systemTemp.createTemp('sbox-preview-');
    final source = File('${directory.path}${Platform.pathSeparator}source.mp4');
    try {
      await source.writeAsBytes(<int>[
        0x00,
        0x00,
        0x00,
        0x18,
        0x66,
        0x74,
        0x79,
        0x70,
        0x69,
        0x73,
        0x6f,
        0x6d,
      ], flush: true);
      final pixels = Uint8List(96 * 48 * 4);
      for (var index = 0; index < pixels.length; index += 4) {
        pixels[index] = 0x40;
        pixels[index + 1] = 0x80;
        pixels[index + 2] = 0xc0;
        pixels[index + 3] = 0xff;
      }
      final result = await PlatformPreviewGenerator(
        videoPosterDecoder: _FakeVideoPosterDecoder(
          VideoPosterFrame(
            width: 96,
            height: 48,
            rowStride: 96 * 4,
            pixels: pixels,
          ),
        ),
      ).generate(source);
      expect(result, isA<PreviewGenerated>());
      final generated = result as PreviewGenerated;
      expect(generated.detectedSourceMediaType, 'video/mp4');
      expect(generated.preview.width, 96);
      expect(generated.preview.height, 48);
      BaselineJpegInspector.validate(
        generated.preview.encodedBytes,
        width: 96,
        height: 48,
      );
      generated.preview.dispose();
    } finally {
      if (await source.exists()) await source.delete();
      await directory.delete();
    }
  });

  test('preview constants keep the protocol budgets bounded', () {
    expect(SboxProtocol.maxPreviewBytes, 10240);
    expect(SboxProtocol.maxPreviewDimension, 320);
    expect(SboxProtocol.maxPreviewPixels, 102400);
    expect(SboxProtocol.maxRetainedPreviewBytes, 32 * 1024 * 1024);
  });
}

final class _FakeVideoPosterDecoder implements VideoPosterDecoder {
  _FakeVideoPosterDecoder(this.frame);

  final VideoPosterFrame frame;

  @override
  Future<VideoPosterFrame?> decode(File source) async => frame;
}
