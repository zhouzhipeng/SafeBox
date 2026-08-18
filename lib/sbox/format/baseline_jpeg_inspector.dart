import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../errors.dart';

final class BaselineJpegInfo {
  const BaselineJpegInfo({required this.width, required this.height});

  final int width;
  final int height;
}

/// A bounded parser for the JPEG subset permitted by SBOX v3.1.
///
/// This is intentionally a marker/table validator, not a JPEG decoder. It
/// runs before any platform image decoder and never allocates based on an
/// untrusted image dimension.
abstract final class BaselineJpegInspector {
  static BaselineJpegInfo inspect(List<int> input) {
    if (input.length < 4 || input.length > SboxProtocol.maxPreviewBytes) {
      throw _invalid();
    }
    final bytes = Uint8List.fromList(input);
    if (bytes[0] != 0xff ||
        bytes[1] != 0xd8 ||
        bytes[bytes.length - 2] != 0xff ||
        bytes[bytes.length - 1] != 0xd9) {
      throw _invalid();
    }

    var offset = 2;
    var markerCount = 1; // SOI
    var app0Count = 0;
    var driCount = 0;
    var sawDqt = false;
    var sawDht = false;
    var sawSof0 = false;
    var sawSos = false;
    var restartInterval = 0;
    final dqtTables = <int>{};
    final dhtTables = <int>{};
    final dhtDcTables = <int>{};
    final dhtAcTables = <int>{};
    List<_JpegComponent>? components;
    late final int width;
    late final int height;

    while (!sawSos) {
      if (offset >= bytes.length - 2) throw _invalid();
      final marker = _readMarker(bytes, offset);
      offset = marker.nextOffset;
      markerCount++;
      if (markerCount > 256) throw _invalid();
      final code = marker.code;
      if (code == 0xd8 || code == 0xd9 || (code >= 0xd0 && code <= 0xd7)) {
        throw _invalid();
      }
      if (code == 0xda) {
        if (!sawSof0 || components == null) throw _invalid();
        final segment = _readSegment(bytes, offset);
        _parseSos(
          bytes,
          segment,
          components,
          dqtTables: dqtTables,
          dhtDcTables: dhtDcTables,
          dhtAcTables: dhtAcTables,
        );
        offset = segment.end;
        sawSos = true;
        continue;
      }

      if (code == 0xe0) {
        app0Count++;
        if (app0Count > 1) throw _invalid();
        final segment = _readSegment(bytes, offset);
        _parseApp0(bytes, segment);
        offset = segment.end;
        continue;
      }
      if (code == 0xdb) {
        sawDqt = true;
        final segment = _readSegment(bytes, offset);
        _parseDqt(bytes, segment, dqtTables);
        offset = segment.end;
        continue;
      }
      if (code == 0xc4) {
        sawDht = true;
        final segment = _readSegment(bytes, offset);
        _parseDht(
          bytes,
          segment,
          dhtTables,
          dhtDcTables,
          dhtAcTables,
        );
        offset = segment.end;
        continue;
      }
      if (code == 0xdd) {
        driCount++;
        if (driCount > 1) throw _invalid();
        final segment = _readSegment(bytes, offset);
        if (segment.length != 4) throw _invalid();
        restartInterval = readUint16BigEndian(bytes, segment.payloadStart);
        offset = segment.end;
        continue;
      }
      if (code == 0xc0) {
        if (sawSof0) throw _invalid();
        final segment = _readSegment(bytes, offset);
        final parsed = _parseSof0(bytes, segment);
        width = parsed.width;
        height = parsed.height;
        components = parsed.components;
        sawSof0 = true;
        offset = segment.end;
        continue;
      }

      // This rejects APP1/Exif, ICC, comments, progressive SOF markers,
      // arithmetic coding markers and every unknown/reserved marker.
      throw _invalid();
    }

    if (!sawDqt || !sawDht || components == null) throw _invalid();
    var expectedRestart = 0;
    var sawRestart = false;
    var sawEoi = false;
    while (offset < bytes.length) {
      final value = bytes[offset];
      if (value != 0xff) {
        offset++;
        continue;
      }
      if (offset + 1 >= bytes.length) throw _invalid();
      final code = bytes[offset + 1];
      if (code == 0x00) {
        offset += 2;
        continue;
      }
      if (code == 0xff) {
        // A literal FF in entropy data must be represented by FF 00. Marker
        // fill bytes are not accepted in the entropy-coded portion.
        throw _invalid();
      }
      if (code >= 0xd0 && code <= 0xd7) {
        if (restartInterval == 0) throw _invalid();
        if (code - 0xd0 != expectedRestart) throw _invalid();
        expectedRestart = (expectedRestart + 1) & 7;
        sawRestart = true;
        offset += 2;
        markerCount++;
        if (markerCount > 256) throw _invalid();
        continue;
      }
      if (code == 0xd9) {
        if (offset != bytes.length - 2) throw _invalid();
        sawEoi = true;
        offset += 2;
        markerCount++;
        if (markerCount > 256) throw _invalid();
        break;
      }
      throw _invalid();
    }
    if (!sawEoi || offset != bytes.length || (sawRestart && restartInterval == 0)) {
      throw _invalid();
    }
    return BaselineJpegInfo(width: width, height: height);
  }

  static void validate(
    List<int> input, {
    required int width,
    required int height,
  }) {
    final info = inspect(input);
    if (info.width != width || info.height != height) throw _invalid();
  }

  static _Marker _readMarker(Uint8List bytes, int offset) {
    if (offset >= bytes.length || bytes[offset] != 0xff) throw _invalid();
    var cursor = offset;
    while (cursor < bytes.length && bytes[cursor] == 0xff) {
      cursor++;
    }
    if (cursor >= bytes.length || bytes[cursor] == 0x00) throw _invalid();
    return _Marker(code: bytes[cursor], nextOffset: cursor + 1);
  }

  static _Segment _readSegment(Uint8List bytes, int lengthOffset) {
    if (lengthOffset + 2 > bytes.length) throw _invalid();
    final length = readUint16BigEndian(bytes, lengthOffset);
    if (length < 2) throw _invalid();
    final end = lengthOffset + length;
    if (end < lengthOffset || end > bytes.length) throw _invalid();
    return _Segment(
      length: length,
      payloadStart: lengthOffset + 2,
      end: end,
    );
  }

  static void _parseApp0(Uint8List bytes, _Segment segment) {
    if (segment.length != 16 || segment.payloadStart + 14 != segment.end) {
      throw _invalid();
    }
    const identifier = <int>[0x4a, 0x46, 0x49, 0x46, 0x00];
    if (!constantTimeBytesEqual(
          bytes.sublist(segment.payloadStart, segment.payloadStart + 5),
          identifier,
        ) ||
        bytes[segment.payloadStart + 12] != 0 ||
        bytes[segment.payloadStart + 13] != 0) {
      throw _invalid();
    }
  }

  static void _parseDqt(
    Uint8List bytes,
    _Segment segment,
    Set<int> tables,
  ) {
    var cursor = segment.payloadStart;
    while (cursor < segment.end) {
      final tableInfo = bytes[cursor++];
      if ((tableInfo >> 4) != 0) throw _invalid();
      final tableId = tableInfo & 0x0f;
      if (tableId > 3 || !tables.add(tableId)) throw _invalid();
      if (cursor + 64 > segment.end) throw _invalid();
      for (var index = 0; index < 64; index++) {
        if (bytes[cursor + index] == 0) throw _invalid();
      }
      cursor += 64;
    }
    if (cursor != segment.end) throw _invalid();
  }

  static void _parseDht(
    Uint8List bytes,
    _Segment segment,
    Set<int> tables,
    Set<int> dcTables,
    Set<int> acTables,
  ) {
    var cursor = segment.payloadStart;
    while (cursor < segment.end) {
      if (cursor + 17 > segment.end) throw _invalid();
      final tableInfo = bytes[cursor++];
      final tableClass = tableInfo >> 4;
      final tableId = tableInfo & 0x0f;
      if ((tableClass != 0 && tableClass != 1) || tableId > 3) {
        throw _invalid();
      }
      final key = (tableClass << 8) | tableId;
      if (!tables.add(key)) throw _invalid();
      (tableClass == 0 ? dcTables : acTables).add(tableId);
      final counts = <int>[];
      var symbolCount = 0;
      for (var index = 0; index < 16; index++) {
        final count = bytes[cursor++];
        counts.add(count);
        symbolCount += count;
      }
      if (symbolCount < 1 || symbolCount > 256 ||
          cursor + symbolCount > segment.end) {
        throw _invalid();
      }
      var availableCodes = 1;
      for (final count in counts) {
        availableCodes = (availableCodes << 1) - count;
        if (availableCodes < 0) throw _invalid();
      }
      cursor += symbolCount;
    }
    if (cursor != segment.end) throw _invalid();
  }

  static _Sof0 _parseSof0(Uint8List bytes, _Segment segment) {
    if (segment.payloadStart + 6 > segment.end) throw _invalid();
    final precision = bytes[segment.payloadStart];
    final height = readUint16BigEndian(bytes, segment.payloadStart + 1);
    final width = readUint16BigEndian(bytes, segment.payloadStart + 3);
    final componentCount = bytes[segment.payloadStart + 5];
    if (precision != 8 ||
        width < 1 ||
        width > SboxProtocol.maxPreviewDimension ||
        height < 1 ||
        height > SboxProtocol.maxPreviewDimension ||
        width > SboxProtocol.maxPreviewPixels ~/ height ||
        (componentCount != 1 && componentCount != 3) ||
        segment.length != 8 + 3 * componentCount) {
      throw _invalid();
    }
    final components = <_JpegComponent>[];
    final ids = <int>{};
    var samplingSum = 0;
    var cursor = segment.payloadStart + 6;
    for (var index = 0; index < componentCount; index++) {
      final id = bytes[cursor++];
      final sampling = bytes[cursor++];
      final h = sampling >> 4;
      final v = sampling & 0x0f;
      final qtable = bytes[cursor++];
      if (!ids.add(id) || h < 1 || h > 4 || v < 1 || v > 4 || qtable > 3) {
        throw _invalid();
      }
      samplingSum += h * v;
      components.add(_JpegComponent(id: id, qtable: qtable));
    }
    if (samplingSum > 10 || cursor != segment.end) throw _invalid();
    return _Sof0(width: width, height: height, components: components);
  }

  static void _parseSos(
    Uint8List bytes,
    _Segment segment,
    List<_JpegComponent> components, {
    required Set<int> dqtTables,
    required Set<int> dhtDcTables,
    required Set<int> dhtAcTables,
  }) {
    if (segment.payloadStart >= segment.end) throw _invalid();
    final count = bytes[segment.payloadStart];
    if (count != components.length ||
        segment.length != 6 + 2 * count ||
        segment.payloadStart + 4 + 2 * count != segment.end) {
      throw _invalid();
    }
    final componentIds = components.map((component) => component.id).toSet();
    final seen = <int>{};
    var cursor = segment.payloadStart + 1;
    for (var index = 0; index < count; index++) {
      final id = bytes[cursor++];
      final tables = bytes[cursor++];
      final dc = tables >> 4;
      final ac = tables & 0x0f;
      if (!componentIds.contains(id) || !seen.add(id) || dc > 3 || ac > 3) {
        throw _invalid();
      }
      final component = components.firstWhere((value) => value.id == id);
      if (!dqtTables.contains(component.qtable) ||
          !dhtDcTables.contains(dc) ||
          !dhtAcTables.contains(ac)) {
        throw _invalid();
      }
    }
    final ss = bytes[cursor++];
    final se = bytes[cursor++];
    final approximation = bytes[cursor];
    if (seen.length != components.length ||
        ss != 0 ||
        se != 63 ||
        approximation != 0 ||
        cursor + 1 != segment.end) {
      throw _invalid();
    }
  }

  static SboxException _invalid() => const SboxException(
    SboxErrorCode.invalidManifest,
    'Preview JPEG 结构无效',
  );
}

final class _Marker {
  const _Marker({required this.code, required this.nextOffset});

  final int code;
  final int nextOffset;
}

final class _Segment {
  const _Segment({
    required this.length,
    required this.payloadStart,
    required this.end,
  });

  final int length;
  final int payloadStart;
  final int end;
}

final class _JpegComponent {
  const _JpegComponent({required this.id, required this.qtable});

  final int id;
  final int qtable;
}

final class _Sof0 {
  const _Sof0({
    required this.width,
    required this.height,
    required this.components,
  });

  final int width;
  final int height;
  final List<_JpegComponent> components;
}
