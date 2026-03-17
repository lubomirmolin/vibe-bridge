enum PersistenceScope { threadsCache, timelineCache, securityAudit }

extension PersistenceScopeMetadata on PersistenceScope {
  String get fileName {
    switch (this) {
      case PersistenceScope.threadsCache:
        return 'threads-cache.sqlite';
      case PersistenceScope.timelineCache:
        return 'timeline-cache.sqlite';
      case PersistenceScope.securityAudit:
        return 'security-audit.sqlite';
    }
  }

  bool get storesSensitiveData => false;
}

class PersistenceBoundary {
  const PersistenceBoundary({required this.baseDirectory});

  final String baseDirectory;

  String get stateDirectory => '$baseDirectory/state';

  String sqlitePathFor(PersistenceScope scope) =>
      '$stateDirectory/${scope.fileName}';

  bool requiresSecureStore(PersistenceScope scope) => scope.storesSensitiveData;
}
