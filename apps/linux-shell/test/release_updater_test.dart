import 'package:codex_linux_shell/src/release_updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pickPreferredLinuxAsset prefers tarball over AppImage', () {
    final assets = <GitHubReleaseAssetDto>[
      GitHubReleaseAssetDto(
        name: 'codex-mobile-companion-linux-x86_64-1.0.0.AppImage',
        browserDownloadUrl: Uri.parse(
          'https://github.com/lubomirmolin/vibe-bridge/releases/download/v1.0.0/codex-mobile-companion-linux-x86_64-1.0.0.AppImage',
        ),
      ),
      GitHubReleaseAssetDto(
        name: 'codex-mobile-companion-linux-x86_64-1.0.0.tar.gz',
        browserDownloadUrl: Uri.parse(
          'https://github.com/lubomirmolin/vibe-bridge/releases/download/v1.0.0/codex-mobile-companion-linux-x86_64-1.0.0.tar.gz',
        ),
      ),
    ];

    final preferred = pickPreferredLinuxAsset(assets, 'x86_64');

    expect(preferred, isNotNull);
    expect(preferred!.kind, LinuxUpdateAssetKind.tarGz);
  });

  test('parseSha256Sums finds matching digest for asset name', () {
    const manifest = '''
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  codex-mobile-companion-linux-x86_64-1.0.0.tar.gz
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  codex-mobile-companion-macos-arm64-1.0.0.zip
''';

    final digest = parseSha256Sums(
      manifest,
      'codex-mobile-companion-linux-x86_64-1.0.0.tar.gz',
    );

    expect(
      digest,
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
  });

  test('parseSha256Sums finds matching digest when manifest includes dist prefix', () {
    const manifest = '''
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  dist/codex-mobile-companion-linux-x86_64-1.0.0.tar.gz
''';

    final digest = parseSha256Sums(
      manifest,
      'codex-mobile-companion-linux-x86_64-1.0.0.tar.gz',
    );

    expect(
      digest,
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
  });

  test('semantic version orders pre-release before stable', () {
    expect(
      SemanticVersion.parse(
            '1.2.3-beta.1',
          ).compareTo(SemanticVersion.parse('1.2.3')) <
          0,
      isTrue,
    );
  });
}
