import 'dart:io';

import 'package:flutter/services.dart';

final class AuthorizedDirectorySelection {
  const AuthorizedDirectorySelection({
    required this.reference,
    required this.platform,
    required this.displayName,
  });

  final String reference;
  final String platform;
  final String displayName;
}

final class AuthorizedDirectoryMirrorResult {
  const AuthorizedDirectoryMirrorResult({
    required this.fileCount,
    required this.totalBytes,
    required this.catalogPresent,
  });

  final int fileCount;
  final int totalBytes;
  final bool catalogPresent;
}

abstract interface class AuthorizedDirectoryGateway {
  bool get isSupported;

  bool get supportsFileExport;

  Future<AuthorizedDirectorySelection?> chooseDirectory();

  Future<AuthorizedDirectoryMirrorResult> mirrorCiphertext({
    required String reference,
    required String destinationRoot,
  });

  Future<void> release(String reference);

  Future<void> protectTemporaryPlaintextRoot(String path);

  Future<bool> exportFile({
    required String sourcePath,
    required String suggestedName,
    required String mimeType,
  });
}

/// Bridges system-owned directory capabilities into an application-private,
/// permanent ciphertext mirror. No plaintext, mnemonic or key material is
/// accepted by this API. Generic provider directories remain read-only because
/// SAF/File Provider does not promise compare-and-swap or atomic replacement.
final class MethodChannelAuthorizedDirectoryGateway
    implements AuthorizedDirectoryGateway {
  const MethodChannelAuthorizedDirectoryGateway();

  static const MethodChannel _channel = MethodChannel(
    'com.zhouzhipeng.safebox/authorized_directory',
  );

  @override
  bool get isSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  bool get supportsFileExport => Platform.isAndroid || Platform.isIOS;

  @override
  Future<AuthorizedDirectorySelection?> chooseDirectory() async {
    if (!isSupported) return null;
    final value = await _channel.invokeMapMethod<String, Object?>(
      'chooseDirectory',
    );
    if (value == null) return null;
    final reference = value['reference'];
    final platform = value['platform'];
    final displayName = value['display_name'];
    if (reference is! String ||
        reference.isEmpty ||
        reference.length > 1024 * 1024 ||
        reference.contains('\u0000') ||
        platform is! String ||
        displayName is! String ||
        displayName.isEmpty) {
      throw const FormatException('Invalid authorized directory selection');
    }
    return AuthorizedDirectorySelection(
      reference: reference,
      platform: platform,
      displayName: displayName,
    );
  }

  @override
  Future<AuthorizedDirectoryMirrorResult> mirrorCiphertext({
    required String reference,
    required String destinationRoot,
  }) async {
    if (!isSupported) {
      throw UnsupportedError('Authorized directories are not supported');
    }
    final value = await _channel.invokeMapMethod<String, Object?>(
      'mirrorCiphertext',
      <String, Object?>{
        'reference': reference,
        'destination_root': destinationRoot,
        'maximum_depth': 32,
        'maximum_files': 100000,
        'maximum_file_bytes': 1024 * 1024 * 1024 * 1024,
      },
    );
    if (value == null ||
        value['file_count'] is! int ||
        value['total_bytes'] is! int ||
        value['catalog_present'] is! bool) {
      throw const FormatException('Invalid authorized directory result');
    }
    return AuthorizedDirectoryMirrorResult(
      fileCount: value['file_count']! as int,
      totalBytes: value['total_bytes']! as int,
      catalogPresent: value['catalog_present']! as bool,
    );
  }

  @override
  Future<void> release(String reference) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('releaseDirectory', <String, Object?>{
      'reference': reference,
    });
  }

  @override
  Future<void> protectTemporaryPlaintextRoot(String path) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>(
      'protectTemporaryPlaintext',
      <String, Object?>{'path': path},
    );
  }

  @override
  Future<bool> exportFile({
    required String sourcePath,
    required String suggestedName,
    required String mimeType,
  }) async {
    if (!supportsFileExport) {
      throw UnsupportedError('System file export is not supported');
    }
    if (sourcePath.isEmpty ||
        suggestedName.isEmpty ||
        suggestedName.length > 255 ||
        suggestedName == '.' ||
        suggestedName == '..' ||
        suggestedName.contains('/') ||
        suggestedName.contains('\\') ||
        suggestedName.contains('\u0000') ||
        mimeType.isEmpty ||
        mimeType.length > 255 ||
        mimeType.contains('\u0000')) {
      throw const FormatException('Invalid system export arguments');
    }
    return await _channel.invokeMethod<bool>('exportFile', <String, Object?>{
          'source_path': sourcePath,
          'suggested_name': suggestedName,
          'mime_type': mimeType,
        }) ??
        false;
  }
}
