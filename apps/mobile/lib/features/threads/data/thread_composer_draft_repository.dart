import 'dart:convert';

import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadComposerDraftRepositoryProvider =
    Provider<ThreadComposerDraftRepository>((ref) {
      return SecureStoreThreadComposerDraftRepository(
        secureStore: ref.watch(appSecureStoreProvider),
      );
    });

abstract class ThreadComposerDraftRepository {
  Future<String?> readDraft(String draftId);

  Future<void> saveDraft(String draftId, String text);

  Future<void> deleteDraft(String draftId);
}

class SecureStoreThreadComposerDraftRepository
    implements ThreadComposerDraftRepository {
  SecureStoreThreadComposerDraftRepository({required SecureStore secureStore})
    : _secureStore = secureStore;

  final SecureStore _secureStore;

  @override
  Future<String?> readDraft(String draftId) async {
    final drafts = await _readDraftMap();
    final value = drafts[draftId];
    if (value == null) {
      return null;
    }

    final normalizedValue = value.trimRight();
    return normalizedValue.isEmpty ? null : normalizedValue;
  }

  @override
  Future<void> saveDraft(String draftId, String text) async {
    final normalizedId = draftId.trim();
    final normalizedText = text.trimRight();
    if (normalizedId.isEmpty || normalizedText.isEmpty) {
      await deleteDraft(normalizedId);
      return;
    }

    final drafts = await _readDraftMap();
    drafts[normalizedId] = normalizedText;
    await _writeDraftMap(drafts);
  }

  @override
  Future<void> deleteDraft(String draftId) async {
    final normalizedId = draftId.trim();
    if (normalizedId.isEmpty) {
      return;
    }

    final drafts = await _readDraftMap();
    if (drafts.remove(normalizedId) == null) {
      return;
    }

    await _writeDraftMap(drafts);
  }

  Future<Map<String, String>> _readDraftMap() async {
    final raw = await _secureStore.readSecret(
      SecureValueKey.threadComposerDraftCache,
    );
    if (raw == null || raw.trim().isEmpty) {
      return <String, String>{};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return <String, String>{};
      }

      final drafts = <String, String>{};
      for (final entry in decoded.entries) {
        final key = entry.key.trim();
        final value = entry.value;
        if (key.isEmpty || value is! String) {
          continue;
        }
        final normalizedValue = value.trimRight();
        if (normalizedValue.isEmpty) {
          continue;
        }
        drafts[key] = normalizedValue;
      }
      return drafts;
    } on FormatException {
      return <String, String>{};
    }
  }

  Future<void> _writeDraftMap(Map<String, String> drafts) async {
    if (drafts.isEmpty) {
      await _secureStore.removeSecret(SecureValueKey.threadComposerDraftCache);
      return;
    }

    await _secureStore.writeSecret(
      SecureValueKey.threadComposerDraftCache,
      jsonEncode(drafts),
    );
  }
}
