import '../constants.dart';
import '../errors.dart';

/// The protocol versions understood by the reader and writer.
final class SboxVersion {
  const SboxVersion(this.major, this.minor);

  static const SboxVersion v30 = SboxVersion(
    SboxProtocol.versionMajor,
    SboxProtocol.versionMinorV30,
  );
  static const SboxVersion v31 = SboxVersion(
    SboxProtocol.versionMajor,
    SboxProtocol.versionMinorV31,
  );
  static const SboxVersion current = v31;

  final int major;
  final int minor;

  int get metadataFormatId => switch (this) {
    v30 => SboxProtocol.metadataFormatIdV30,
    v31 => SboxProtocol.metadataFormatIdV31,
    _ => throw const SboxException(
      SboxErrorCode.unsupportedVersion,
      '不支持此 SBOX 协议版本',
    ),
  };

  bool get isSupported =>
      major == SboxProtocol.versionMajor && (minor == 0 || minor == 1);

  static SboxVersion parse(int major, int minor) {
    if (major != SboxProtocol.versionMajor || (minor != 0 && minor != 1)) {
      throw const SboxException(
        SboxErrorCode.unsupportedVersion,
        '不支持此 SBOX 协议版本',
      );
    }
    return minor == SboxProtocol.versionMinorV30 ? v30 : v31;
  }

  @override
  bool operator ==(Object other) =>
      other is SboxVersion && major == other.major && minor == other.minor;

  @override
  int get hashCode => Object.hash(major, minor);

  @override
  String toString() => '$major.$minor';
}
