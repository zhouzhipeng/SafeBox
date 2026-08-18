import '../sbox/format/bundle_preview.dart';

enum PreviewUnavailableReason {
  userDisabled,
  unsupportedMediaType,
  platformUnsupported,
  decodeFailed,
  encodeFailed,
  timeout,
  resourceLimit,
  metadataCapacity,
  existingV30,
  existingV31WithoutPreview,
  inputChanged,
}

sealed class PreviewGenerationResult {
  const PreviewGenerationResult();
}

final class PreviewGenerated extends PreviewGenerationResult {
  const PreviewGenerated({
    required this.preview,
    required this.detectedSourceMediaType,
  });

  final BundlePreview preview;
  final String detectedSourceMediaType;
}

final class PreviewUnavailable extends PreviewGenerationResult {
  const PreviewUnavailable({
    required this.reason,
    this.detectedSourceMediaType,
  });

  final PreviewUnavailableReason reason;
  final String? detectedSourceMediaType;
}
