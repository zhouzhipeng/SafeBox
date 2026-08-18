import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:safebox/platform/preview_generation_result.dart';
import 'package:safebox/platform/preview_generator.dart';
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

  test('preview constants keep the protocol budgets bounded', () {
    expect(SboxProtocol.maxPreviewBytes, 10240);
    expect(SboxProtocol.maxPreviewDimension, 320);
    expect(SboxProtocol.maxPreviewPixels, 102400);
    expect(SboxProtocol.maxRetainedPreviewBytes, 32 * 1024 * 1024);
  });
}
