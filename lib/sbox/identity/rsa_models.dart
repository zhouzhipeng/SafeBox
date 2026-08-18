import 'dart:typed_data';

/// Public RSA material that may be retained by the application.
final class SboxRsaPublicKey {
  const SboxRsaPublicKey({required this.modulus, required this.exponent});

  final BigInt modulus;
  final BigInt exponent;

  int get modulusBytes => (modulus.bitLength + 7) ~/ 8;
}

/// Ephemeral RSA private material. It must never be serialized.
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

/// RSA-only public identity. No signing identity is part of SBOX 2.0.
final class PublicIdentity {
  PublicIdentity({
    required this.rsaPublicKey,
    required List<int> spkiDer,
    required this.spkiPem,
    required List<int> recipientKeyId,
  }) : spkiDer = Uint8List.fromList(spkiDer),
       recipientKeyId = Uint8List.fromList(recipientKeyId);

  final SboxRsaPublicKey rsaPublicKey;
  final Uint8List spkiDer;
  final String spkiPem;
  final Uint8List recipientKeyId;
}

/// Private identity wrapper whose secret buffers are explicitly disposable.
final class EphemeralIdentity {
  EphemeralIdentity({
    required this.publicIdentity,
    required this.rsaPrivateKey,
    required this.pCandidateCount,
    required this.qCandidateCount,
  });

  final PublicIdentity publicIdentity;
  final SboxRsaPrivateKey rsaPrivateKey;
  final int pCandidateCount;
  final int qCandidateCount;

  void disposeControlledSecrets() {
    // BigInt is immutable in Dart; the containing crypto isolate is the final
    // lifetime boundary for the private integers.
  }
}
