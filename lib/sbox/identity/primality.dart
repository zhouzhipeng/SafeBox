import '../bytes.dart';
import 'hmac_drbg.dart';
import 'rsa_identity_profile1.dart';
import 'rsa_models.dart';

final class DeterministicRsa3072Generator {
  DeterministicRsa3072Generator(this._drbg);

  final HmacDrbgSha256 _drbg;

  static final BigInt _publicExponent = BigInt.from(
    RsaIdentityProfile1.publicExponent,
  );
  static final BigInt _upperBound = BigInt.one << RsaIdentityProfile1.primeBits;
  static final BigInt _lowerBound = _calculateLowerBound();
  static final BigInt _minimumPrimeDifference = BigInt.one << 1436;
  static final List<int> _trialPrimes = _sieveOddPrimes(65521);

  RsaGenerationResult generate() {
    for (var outerAttempt = 1; outerAttempt <= 16; outerAttempt++) {
      final pResult = _generatePrime(
        maxCandidates: 5 * RsaIdentityProfile1.rsaBits,
      );
      final qResult = _generatePrime(
        maxCandidates: 10 * RsaIdentityProfile1.rsaBits,
        otherPrime: pResult.prime,
      );
      final result = _buildResult(pResult, qResult, outerAttempt);
      if (result != null) return result;
    }
    throw StateError('Deterministic RSA outer attempt limit exhausted');
  }

  /// Runs the same frozen deterministic algorithm while periodically yielding
  /// to the host event loop. This keeps Flutter Web able to paint progress and
  /// handle browser events during the expensive RSA-3072 prime search.
  Future<RsaGenerationResult> generateCooperatively({
    int yieldEveryCandidates = 16,
  }) async {
    if (yieldEveryCandidates < 1) {
      throw ArgumentError.value(yieldEveryCandidates, 'yieldEveryCandidates');
    }
    for (var outerAttempt = 1; outerAttempt <= 16; outerAttempt++) {
      final pResult = await _generatePrimeCooperatively(
        maxCandidates: 5 * RsaIdentityProfile1.rsaBits,
        yieldEveryCandidates: yieldEveryCandidates,
      );
      final qResult = await _generatePrimeCooperatively(
        maxCandidates: 10 * RsaIdentityProfile1.rsaBits,
        otherPrime: pResult.prime,
        yieldEveryCandidates: yieldEveryCandidates,
      );
      final result = _buildResult(pResult, qResult, outerAttempt);
      if (result != null) return result;
      await Future<void>.delayed(Duration.zero);
    }
    throw StateError('Deterministic RSA outer attempt limit exhausted');
  }

  RsaGenerationResult? _buildResult(
    _PrimeResult pResult,
    _PrimeResult qResult,
    int outerAttempt,
  ) {
    var p = pResult.prime;
    var q = qResult.prime;
    final lambda = _lcm(p - BigInt.one, q - BigInt.one);
    final d = _publicExponent.modInverse(lambda);
    if (d <= (BigInt.one << RsaIdentityProfile1.primeBits)) {
      return null;
    }

    if (q > p) {
      final temporary = p;
      p = q;
      q = temporary;
    }

    final modulus = p * q;
    if (modulus.bitLength != RsaIdentityProfile1.rsaBits) {
      throw StateError('Deterministic RSA modulus has an invalid bit length');
    }
    if ((_publicExponent * d) % lambda != BigInt.one) {
      throw StateError('Deterministic RSA inverse self-check failed');
    }

    final publicKey = SboxRsaPublicKey(
      modulus: modulus,
      exponent: _publicExponent,
    );
    final privateKey = SboxRsaPrivateKey(
      publicKey: publicKey,
      p: p,
      q: q,
      d: d,
      dP: d % (p - BigInt.one),
      dQ: d % (q - BigInt.one),
      qInv: q.modInverse(p),
    );
    return RsaGenerationResult(
      privateKey: privateKey,
      pCandidateCount: pResult.candidateCount,
      qCandidateCount: qResult.candidateCount,
      outerAttemptCount: outerAttempt,
    );
  }

  _PrimeResult _generatePrime({
    required int maxCandidates,
    BigInt? otherPrime,
  }) {
    for (
      var candidateCount = 1;
      candidateCount <= maxCandidates;
      candidateCount++
    ) {
      final candidate = _nextPrimeCandidate(otherPrime: otherPrime);
      if (candidate != null) return _PrimeResult(candidate, candidateCount);
    }
    throw StateError('Deterministic RSA prime candidate limit exhausted');
  }

  Future<_PrimeResult> _generatePrimeCooperatively({
    required int maxCandidates,
    required int yieldEveryCandidates,
    BigInt? otherPrime,
  }) async {
    for (
      var candidateCount = 1;
      candidateCount <= maxCandidates;
      candidateCount++
    ) {
      final candidate = _nextPrimeCandidate(otherPrime: otherPrime);
      if (candidate != null) return _PrimeResult(candidate, candidateCount);
      if (candidateCount % yieldEveryCandidates == 0) {
        // A timer turn (rather than a microtask) gives the browser a chance to
        // render Flutter's busy state and process input between CPU slices.
        await Future<void>.delayed(Duration.zero);
      }
    }
    throw StateError('Deterministic RSA prime candidate limit exhausted');
  }

  BigInt? _nextPrimeCandidate({BigInt? otherPrime}) {
    var candidate = bytesToBigInt(_drbg.generate(192));
    if (candidate.isEven) {
      candidate += BigInt.one;
    }
    if (candidate < _lowerBound || candidate >= _upperBound) {
      return null;
    }
    if ((candidate - BigInt.one).gcd(_publicExponent) != BigInt.one) {
      return null;
    }
    if (_hasSmallPrimeFactor(candidate)) {
      return null;
    }
    if (!_millerRabin(candidate, 4)) {
      return null;
    }
    if (!_generalLucasProbablePrime(candidate)) {
      return null;
    }
    if (otherPrime != null &&
        (candidate - otherPrime).abs() <= _minimumPrimeDifference) {
      return null;
    }
    return candidate;
  }

  bool _hasSmallPrimeFactor(BigInt candidate) {
    for (final prime in _trialPrimes) {
      if (candidate % BigInt.from(prime) == BigInt.zero) {
        return true;
      }
    }
    return false;
  }

  bool _millerRabin(BigInt candidate, int rounds) {
    var oddPart = candidate - BigInt.one;
    var powerOfTwo = 0;
    while (oddPart.isEven) {
      oddPart >>= 1;
      powerOfTwo++;
    }

    for (var round = 0; round < rounds; round++) {
      BigInt base;
      do {
        base = bytesToBigInt(_drbg.generate(192));
      } while (base <= BigInt.one || base >= candidate - BigInt.one);

      var value = base.modPow(oddPart, candidate);
      if (value == BigInt.one || value == candidate - BigInt.one) {
        continue;
      }

      var probablyPrime = false;
      for (var index = 1; index < powerOfTwo; index++) {
        value = (value * value) % candidate;
        if (value == candidate - BigInt.one) {
          probablyPrime = true;
          break;
        }
        if (value == BigInt.one) {
          return false;
        }
      }
      if (!probablyPrime) {
        return false;
      }
    }
    return true;
  }

  static bool _generalLucasProbablePrime(BigInt candidate) {
    final root = integerSquareRoot(candidate);
    if (root * root == candidate) {
      return false;
    }

    var absoluteD = BigInt.from(5);
    var positive = true;
    late BigInt d;
    while (true) {
      d = positive ? absoluteD : -absoluteD;
      final jacobi = _jacobi(d, candidate);
      if (jacobi == 0) {
        return false;
      }
      final q = (BigInt.one - d) ~/ BigInt.from(4);
      if (jacobi == -1 && candidate.gcd(q.abs()) == BigInt.one) {
        break;
      }
      absoluteD += BigInt.two;
      positive = !positive;
    }

    final bits = (candidate + BigInt.one).toRadixString(2);
    var u = BigInt.one;
    var v = BigInt.one;
    for (var index = 1; index < bits.length; index++) {
      final uTemporary = positiveMod(u * v, candidate);
      final vTemporary = _modularHalf(v * v + d * u * u, candidate);
      if (bits.codeUnitAt(index) == 0x31) {
        u = _modularHalf(uTemporary + vTemporary, candidate);
        v = _modularHalf(vTemporary + d * uTemporary, candidate);
      } else {
        u = uTemporary;
        v = vTemporary;
      }
    }
    return u == BigInt.zero;
  }

  static BigInt _modularHalf(BigInt value, BigInt modulus) {
    var reduced = positiveMod(value, modulus);
    if (reduced.isOdd) {
      reduced += modulus;
    }
    return (reduced >> 1) % modulus;
  }

  static int _jacobi(BigInt numerator, BigInt denominator) {
    if (denominator <= BigInt.zero || denominator.isEven) {
      throw ArgumentError('Jacobi denominator must be a positive odd integer');
    }
    var a = positiveMod(numerator, denominator);
    var n = denominator;
    var result = 1;
    while (a != BigInt.zero) {
      while (a.isEven) {
        a >>= 1;
        final residue = (n % BigInt.from(8)).toInt();
        if (residue == 3 || residue == 5) {
          result = -result;
        }
      }
      final temporary = a;
      a = n;
      n = temporary;
      if (a % BigInt.from(4) == BigInt.from(3) &&
          n % BigInt.from(4) == BigInt.from(3)) {
        result = -result;
      }
      a %= n;
    }
    return n == BigInt.one ? result : 0;
  }

  static BigInt _calculateLowerBound() {
    final radicand = BigInt.one << (RsaIdentityProfile1.rsaBits - 1);
    final floor = integerSquareRoot(radicand);
    return floor * floor == radicand ? floor : floor + BigInt.one;
  }

  static BigInt _lcm(BigInt left, BigInt right) =>
      (left ~/ left.gcd(right)) * right;

  static List<int> _sieveOddPrimes(int maximum) {
    final composite = List<bool>.filled(maximum + 1, false);
    final primes = <int>[];
    for (var candidate = 3; candidate <= maximum; candidate += 2) {
      if (composite[candidate]) {
        continue;
      }
      primes.add(candidate);
      if (candidate * candidate <= maximum) {
        for (
          var multiple = candidate * candidate;
          multiple <= maximum;
          multiple += candidate * 2
        ) {
          composite[multiple] = true;
        }
      }
    }
    return List<int>.unmodifiable(primes);
  }
}

final class _PrimeResult {
  const _PrimeResult(this.prime, this.candidateCount);

  final BigInt prime;
  final int candidateCount;
}
