import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../bytes.dart';
import '../constants.dart';
import '../engine/container_codec.dart';
import '../engine/job_control.dart';
import '../engine/streaming_container.dart';
import '../errors.dart';
import '../format/header.dart';
import '../identity/bip39_identity.dart';
import '../identity/ephemeral_mnemonic.dart';
import '../identity/rsa_models.dart';
import 'catalog_models.dart';
import 'catalog_signature.dart';

final class PreparedCatalogContainer {
  PreparedCatalogContainer._({
    required List<int> bytes,
    required this.header,
    required List<int> sha256,
  }) : bytes = Uint8List.fromList(bytes),
       sha256 = Uint8List.fromList(sha256);

  final Uint8List bytes;
  final SboxHeader header;
  final Uint8List sha256;
}

final class OpenedCatalogContainer {
  OpenedCatalogContainer._({
    required this.catalog,
    required this.header,
    required List<int> containerSha256,
  }) : containerSha256 = Uint8List.fromList(containerSha256);

  final VerifiedCatalog catalog;
  final SboxHeader header;
  final Uint8List containerSha256;
}

/// Encrypts a Catalog with the recipient public key only.
///
/// The outer SBOX container still authenticates the plaintext with
/// AES-256-GCM after the DEK is wrapped by RSA-OAEP. This path deliberately
/// omits the legacy Ed25519 author signature because producing that signature
/// would require the mnemonic/private key during an encryption-only task.
Future<PreparedCatalogContainer> createCatalogContainerWithPublicKey({
  required SboxCatalog catalog,
  required PublicIdentity expectedIdentity,
  SboxEncryptionRandomness? randomness,
}) async {
  Uint8List? plaintext;
  try {
    plaintext = CatalogSignatureCodec().encodePublicKeyOnly(
      catalog: catalog,
      expectedIdentity: expectedIdentity,
    );
    if (plaintext.length > 16 * 1024 * 1024) {
      throw const SboxException(
        SboxErrorCode.limits,
        'Catalog JSON 超过 16 MiB 上限',
      );
    }
    return await _encryptCatalogPlaintext(
      plaintext: plaintext,
      expectedIdentity: expectedIdentity,
      randomness: randomness,
    );
  } finally {
    plaintext?.fillRange(0, plaintext.length, 0);
  }
}

Future<PreparedCatalogContainer> createCatalogContainerWithMnemonic({
  required SboxCatalog catalog,
  required EphemeralMnemonic mnemonic,
  required PublicIdentity expectedIdentity,
  SboxEncryptionRandomness? randomness,
}) async {
  EphemeralIdentity? ephemeral;
  Uint8List? plaintext;
  try {
    ephemeral = await SboxIdentityDeriver().deriveIdentity(
      mnemonic.revealForDerivation(),
    );
    if (!constantTimeBytesEqual(
          ephemeral.publicIdentity.recipientKeyId,
          expectedIdentity.recipientKeyId,
        ) ||
        !constantTimeBytesEqual(
          ephemeral.publicIdentity.catalogSignerKeyId,
          expectedIdentity.catalogSignerKeyId,
        )) {
      throw const SboxException(SboxErrorCode.keyMismatch, '助记词与当前身份不匹配');
    }
    final signed = await CatalogSignatureCodec().sign(
      catalog: catalog,
      catalogSigningSeed: ephemeral.catalogSigningSeed,
      expectedIdentity: expectedIdentity,
    );
    plaintext = signed.encodePlaintext();
    if (plaintext.length > 16 * 1024 * 1024) {
      throw const SboxException(
        SboxErrorCode.limits,
        'Catalog JSON 超过 16 MiB 上限',
      );
    }

    // Catalog signing is complete. Release all private identity material before
    // public-key-only container encryption begins.
    ephemeral.disposeControlledSecrets();
    ephemeral = null;
    mnemonic.dispose();

    return await _encryptCatalogPlaintext(
      plaintext: plaintext,
      expectedIdentity: expectedIdentity,
      randomness: randomness,
    );
  } finally {
    plaintext?.fillRange(0, plaintext.length, 0);
    ephemeral?.disposeControlledSecrets();
    mnemonic.dispose();
  }
}

Future<PreparedCatalogContainer> _encryptCatalogPlaintext({
  required Uint8List plaintext,
  required PublicIdentity expectedIdentity,
  SboxEncryptionRandomness? randomness,
}) async {
  final bytes = await SboxContainerCodec().encryptBytes(
    recipient: expectedIdentity,
    contentKind: SboxContentKind.catalog,
    originalName: 'catalog.json',
    mediaType: 'application/vnd.sbox.catalog+json',
    data: plaintext,
    randomness: randomness,
  );
  if (bytes.length > 20 * 1024 * 1024) {
    throw const SboxException(
      SboxErrorCode.limits,
      'catalog.sbox 超过 20 MiB 上限',
    );
  }
  return PreparedCatalogContainer._(
    bytes: bytes,
    header: SboxHeader.parse(bytes),
    sha256: sha256Bytes(bytes),
  );
}

Future<OpenedCatalogContainer> openCatalogContainerWithMnemonic({
  required List<int> container,
  required EphemeralMnemonic mnemonic,
  required PublicIdentity expectedIdentity,
  required JobControl control,
  String? expectedCatalogId,
}) async {
  if (container.length > 20 * 1024 * 1024) {
    mnemonic.dispose();
    throw const SboxException(
      SboxErrorCode.limits,
      'catalog.sbox 超过 20 MiB 上限',
    );
  }
  final consumer = _BoundedByteConsumer(16 * 1024 * 1024);
  final sink = IOSink(consumer);
  Uint8List? plaintext;
  try {
    final verifiedOuter = await decryptSingleContainerWithMnemonic(
      input: Stream<List<int>>.value(container),
      stagedPlaintext: sink,
      mnemonic: mnemonic,
      expectedIdentity: expectedIdentity,
      control: control,
    );
    if (verifiedOuter.metadata.contentKind != SboxContentKind.catalog ||
        verifiedOuter.metadata.originalName != 'catalog.json' ||
        verifiedOuter.metadata.mediaType !=
            'application/vnd.sbox.catalog+json') {
      throw const SboxException(SboxErrorCode.catalog, 'SBOX 容器不是规范 Catalog');
    }
    plaintext = consumer.takeBytes();
    final catalog = await CatalogSignatureCodec().verify(
      plaintext: plaintext,
      expectedIdentity: expectedIdentity,
      expectedCatalogId: expectedCatalogId,
    );
    return OpenedCatalogContainer._(
      catalog: catalog,
      header: verifiedOuter.header,
      containerSha256: sha256Bytes(container),
    );
  } finally {
    plaintext?.fillRange(0, plaintext.length, 0);
    mnemonic.dispose();
    await consumer.close();
  }
}

final class _BoundedByteConsumer implements StreamConsumer<List<int>> {
  _BoundedByteConsumer(this.maximumLength);

  final int maximumLength;
  // The streaming decryptor overwrites each authenticated record buffer after
  // IOSink.flush(), so this in-memory Catalog consumer must retain a copy.
  final BytesBuilder _builder = BytesBuilder(copy: true);
  bool _closed = false;
  bool _taken = false;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    if (_closed) {
      throw StateError('Consumer is closed');
    }
    await for (final chunk in stream) {
      if (_builder.length + chunk.length > maximumLength) {
        throw const SboxException(
          SboxErrorCode.limits,
          'Catalog JSON 超过 16 MiB 上限',
        );
      }
      _builder.add(chunk);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  Uint8List takeBytes() {
    if (!_closed || _taken) {
      throw StateError('Catalog plaintext is not ready');
    }
    _taken = true;
    return _builder.takeBytes();
  }
}
