import '../bytes.dart';
import '../errors.dart';
import 'canonical_json.dart';
import 'catalog_models.dart';
import 'catalog_signature.dart';

final class CatalogCheckpoint {
  const CatalogCheckpoint({
    required this.catalogId,
    required this.highestGeneration,
    required this.lastCatalogSha256,
    this.lastProviderRevision,
  });

  final String catalogId;
  final int highestGeneration;
  final String lastCatalogSha256;
  final String? lastProviderRevision;
}

enum CatalogContinuity { firstTrusted, unchanged, advanced, historyGap }

CatalogContinuity validateCatalogCheckpoint({
  required SboxCatalog remote,
  required String remoteContainerSha256,
  CatalogCheckpoint? local,
}) {
  if (local == null) {
    return CatalogContinuity.firstTrusted;
  }
  if (remote.catalogId != local.catalogId) {
    throw const SboxException(
      SboxErrorCode.catalogFork,
      'Catalog ID 与已固定的数据源不一致',
    );
  }
  if (remote.generation < local.highestGeneration) {
    throw const SboxException(SboxErrorCode.catalogRollback, '检测到目录回滚，已停止同步');
  }
  if (remote.generation == local.highestGeneration) {
    if (remoteContainerSha256 != local.lastCatalogSha256) {
      throw const SboxException(
        SboxErrorCode.catalogFork,
        '相同代数出现不同 Catalog，目录已分叉',
      );
    }
    return CatalogContinuity.unchanged;
  }
  if (remote.previousCatalogSha256 != local.lastCatalogSha256) {
    return CatalogContinuity.historyGap;
  }
  return CatalogContinuity.advanced;
}

sealed class CatalogOperation {
  const CatalogOperation({required this.entryId});

  final String entryId;
}

final class CreateCatalogEntry extends CatalogOperation {
  CreateCatalogEntry(this.entry) : super(entryId: entry.entryId);

  final CatalogEntry entry;
}

final class UpdateCatalogMetadata extends CatalogOperation {
  const UpdateCatalogMetadata({
    required super.entryId,
    required this.title,
    required this.description,
    required this.tags,
    required this.updatedAt,
  });

  final String title;
  final String description;
  final List<String> tags;
  final String updatedAt;
}

final class ReplaceCatalogPayload extends CatalogOperation {
  const ReplaceCatalogPayload({
    required super.entryId,
    required this.payload,
    required this.originalName,
    required this.mediaType,
    required this.updatedAt,
  });

  final CatalogPayload payload;
  final String originalName;
  final String mediaType;
  final String updatedAt;
}

final class DeleteCatalogEntry extends CatalogOperation {
  const DeleteCatalogEntry({required super.entryId, required this.deletedAt});

  final String deletedAt;
}

sealed class MergeOutcome {
  const MergeOutcome();
}

final class MergedCatalog extends MergeOutcome {
  const MergedCatalog({
    required this.entries,
    required this.tombstones,
    required this.nextGeneration,
  });

  final List<CatalogEntry> entries;
  final List<CatalogTombstone> tombstones;
  final int nextGeneration;
}

final class CatalogMergeConflict {
  const CatalogMergeConflict({
    required this.entryId,
    required this.baseRevision,
    required this.remoteRevision,
    required this.reason,
  });

  final String entryId;
  final int? baseRevision;
  final int? remoteRevision;
  final String reason;
}

final class UserCatalogConflicts extends MergeOutcome {
  const UserCatalogConflicts(this.conflicts);

  final List<CatalogMergeConflict> conflicts;
}

MergeOutcome mergeCatalog({
  required VerifiedCatalog base,
  required VerifiedCatalog remote,
  required List<CatalogOperation> pending,
}) {
  final baseCatalog = base.catalog;
  final remoteCatalog = remote.catalog;
  if (baseCatalog.catalogId != remoteCatalog.catalogId ||
      baseCatalog.recipientKeyId != remoteCatalog.recipientKeyId ||
      baseCatalog.signerKeyId != remoteCatalog.signerKeyId) {
    throw const SboxException(
      SboxErrorCode.catalogFork,
      'Catalog 合并身份或 Catalog ID 不一致',
    );
  }

  final baseEntries = <String, CatalogEntry>{
    for (final entry in baseCatalog.entries) entry.entryId: entry,
  };
  final remoteEntries = <String, CatalogEntry>{
    for (final entry in remoteCatalog.entries) entry.entryId: entry,
  };
  final remoteTombstones = <String, CatalogTombstone>{
    for (final tombstone in remoteCatalog.tombstones)
      tombstone.entryId: tombstone,
  };
  final conflicts = <CatalogMergeConflict>[];
  final touched = <String>{};

  for (final operation in pending) {
    if (!touched.add(operation.entryId)) {
      throw const SboxException(SboxErrorCode.catalog, '同一次合并不能重复修改同一目录条目');
    }
    final baseEntry = baseEntries[operation.entryId];
    final remoteEntry = remoteEntries[operation.entryId];
    final remoteTombstone = remoteTombstones[operation.entryId];
    final remoteMatchesBase =
        _entryEqual(baseEntry, remoteEntry) && remoteTombstone == null;

    if (operation is CreateCatalogEntry) {
      if (baseEntry != null) {
        throw const SboxException(
          SboxErrorCode.catalog,
          'Create 操作的 entry_id 已存在于共同基线',
        );
      }
      if (remoteEntry == null && remoteTombstone == null) {
        remoteEntries[operation.entryId] = operation.entry;
      } else if (!_entryEqual(remoteEntry, operation.entry)) {
        conflicts.add(
          CatalogMergeConflict(
            entryId: operation.entryId,
            baseRevision: null,
            remoteRevision: remoteEntry?.revision ?? remoteTombstone?.revision,
            reason: '两端创建了相同 entry_id 的不同内容',
          ),
        );
      }
      continue;
    }

    if (baseEntry == null) {
      throw const SboxException(SboxErrorCode.catalog, '目录操作引用了共同基线中不存在的条目');
    }
    if (!remoteMatchesBase) {
      conflicts.add(
        CatalogMergeConflict(
          entryId: operation.entryId,
          baseRevision: baseEntry.revision,
          remoteRevision: remoteEntry?.revision ?? remoteTombstone?.revision,
          reason: remoteTombstone == null ? '远端与本地同时修改了同一条目' : '远端删除与本地修改发生冲突',
        ),
      );
      continue;
    }

    switch (operation) {
      case UpdateCatalogMetadata():
        remoteEntries[operation.entryId] = CatalogEntry(
          entryId: baseEntry.entryId,
          revision: baseEntry.revision + 1,
          title: operation.title,
          description: operation.description,
          originalName: baseEntry.originalName,
          mediaType: baseEntry.mediaType,
          payload: baseEntry.payload,
          tags: operation.tags,
          createdAt: baseEntry.createdAt,
          updatedAt: operation.updatedAt,
        );
      case ReplaceCatalogPayload():
        remoteEntries[operation.entryId] = CatalogEntry(
          entryId: baseEntry.entryId,
          revision: baseEntry.revision + 1,
          title: baseEntry.title,
          description: baseEntry.description,
          originalName: operation.originalName,
          mediaType: operation.mediaType,
          payload: operation.payload,
          tags: baseEntry.tags,
          createdAt: baseEntry.createdAt,
          updatedAt: operation.updatedAt,
        );
      case DeleteCatalogEntry():
        remoteEntries.remove(operation.entryId);
        remoteTombstones[operation.entryId] = CatalogTombstone(
          entryId: operation.entryId,
          revision: baseEntry.revision + 1,
          deletedAt: operation.deletedAt,
        );
      case CreateCatalogEntry():
        throw StateError('Create operation handled above');
    }
  }

  if (conflicts.isNotEmpty) {
    return UserCatalogConflicts(
      List<CatalogMergeConflict>.unmodifiable(conflicts),
    );
  }
  final entries = remoteEntries.values.toList()
    ..sort((left, right) => left.entryId.compareTo(right.entryId));
  final tombstones = remoteTombstones.values.toList()
    ..sort((left, right) => left.entryId.compareTo(right.entryId));
  return MergedCatalog(
    entries: List<CatalogEntry>.unmodifiable(entries),
    tombstones: List<CatalogTombstone>.unmodifiable(tombstones),
    nextGeneration: remoteCatalog.generation + 1,
  );
}

bool _entryEqual(CatalogEntry? left, CatalogEntry? right) {
  if (left == null || right == null) {
    return left == right;
  }
  final leftBytes = CatalogCanonicalJson.encodeUtf8(left.toJson());
  final rightBytes = CatalogCanonicalJson.encodeUtf8(right.toJson());
  return constantTimeBytesEqual(leftBytes, rightBytes);
}
