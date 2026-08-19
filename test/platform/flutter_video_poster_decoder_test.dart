import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safebox/platform/flutter_video_poster_decoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.zhouzhipeng.safebox/video_preview');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'candidate decoding uses the shared channel on every platform',
    () async {
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedCall = call;
            return <Object?>[_frame(0x30), _frame(0x90)];
          });

      final frames = await const FlutterVideoPosterDecoder().decodeCandidates(
        File('platform-neutral-video.mp4'),
        count: 2,
      );

      expect(capturedCall?.method, 'extractVideoPosters');
      expect(capturedCall?.arguments, <String, Object?>{
        'path': 'platform-neutral-video.mp4',
        'count': 2,
      });
      expect(frames, hasLength(2));
      expect(frames.first.width, 4);
      expect(frames.first.height, 2);
      expect(frames.first.rowStride, 16);
      expect(frames.first.pixels.first, 0x30);
      expect(frames.last.pixels.first, 0x90);
      for (final frame in frames) {
        frame.dispose();
      }
    },
  );
}

Map<String, Object?> _frame(int blue) => <String, Object?>{
  'width': 4,
  'height': 2,
  'row_stride': 16,
  'pixels': Uint8List.fromList(
    List<int>.generate(4 * 2 * 4, (index) => index.isEven ? blue : 0xff),
  ),
};
