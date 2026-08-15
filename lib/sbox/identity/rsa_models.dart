import 'dart:typed_data';

final class SboxRsaPublicKey {
  const SboxRsaPublicKey({required this.modulus, required this.exponent});

  final BigInt modulus;
  final BigInt exponent;

  int get modulusBytes => (modulus.bitLength + 7) ~/ 8;
}

/// Ephemeral RSA private material. It must only live inside a disposable
/// crypto isolate and must never be serialized to persistent storage.
final class SboxRsaPrivateKey {
  const SboxRsaPrivateKey({
    required this.publicKey,
    required this.p,
    required this.q,
    required this.d,
    required this.dP,
    required this.dQ,
    required this.qInv,
  });

  final SboxRsaPublicKey publicKey;
  final BigInt p;
  final BigInt q;
  final BigInt d;
  final BigInt dP;
  final BigInt dQ;
  final BigInt qInv;
}

final class RsaGenerationResult {
  const RsaGenerationResult({
    required this.privateKey,
    required this.pCandidateCount,
    required this.qCandidateCount,
    required this.outerAttemptCount,
  });

  final SboxRsaPrivateKey privateKey;
  final int pCandidateCount;
  final int qCandidateCount;
  final int outerAttemptCount;
}

final class PublicIdentity {
  PublicIdentity({
    required this.rsaPublicKey,
    required List<int> spkiDer,
    required this.spkiPem,
    required List<int> recipientKeyId,
    required List<int> catalogSigningPublicKey,
    required List<int> catalogSignerKeyId,
  }) : spkiDer = Uint8List.fromList(spkiDer),
       recipientKeyId = Uint8List.fromList(recipientKeyId),
       catalogSigningPublicKey = Uint8List.fromList(catalogSigningPublicKey),
       catalogSignerKeyId = Uint8List.fromList(catalogSignerKeyId);

  final SboxRsaPublicKey rsaPublicKey;
  final Uint8List spkiDer;
  final String spkiPem;
  final Uint8List recipientKeyId;
  final Uint8List catalogSigningPublicKey;
  final Uint8List catalogSignerKeyId;
}

final class EphemeralIdentity {
  EphemeralIdentity({
    required this.publicIdentity,
    required this.rsaPrivateKey,
    required List<int> catalogSigningSeed,
    required this.pCandidateCount,
    required this.qCandidateCount,
  }) : catalogSigningSeed = Uint8List.fromList(catalogSigningSeed);

  final PublicIdentity publicIdentity;
  final SboxRsaPrivateKey rsaPrivateKey;
  final Uint8List catalogSigningSeed;
  final int pCandidateCount;
  final int qCandidateCount;

  void disposeControlledSecrets() {
    catalogSigningSeed.fillRange(0, catalogSigningSeed.length, 0);
  }
}
