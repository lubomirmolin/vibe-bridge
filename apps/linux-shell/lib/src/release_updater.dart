import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

enum LinuxUpdateAssetKind { tarGz, appImage }

class LinuxUpdateAsset {
  const LinuxUpdateAsset({
    required this.name,
    required this.url,
    required this.kind,
  });

  final String name;
  final Uri url;
  final LinuxUpdateAssetKind kind;
}

class LinuxUpdateCheckResult {
  const LinuxUpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUrl,
    required this.asset,
    required this.checksumsUrl,
  });

  final SemanticVersion currentVersion;
  final SemanticVersion latestVersion;
  final Uri releaseUrl;
  final LinuxUpdateAsset? asset;
  final Uri? checksumsUrl;

  bool get isUpdateAvailable => latestVersion.compareTo(currentVersion) > 0;
}

class GitHubReleaseAssetDto {
  const GitHubReleaseAssetDto({
    required this.name,
    required this.browserDownloadUrl,
  });

  factory GitHubReleaseAssetDto.fromJson(Map<String, dynamic> json) {
    return GitHubReleaseAssetDto(
      name: json['name'] as String,
      browserDownloadUrl: Uri.parse(json['browser_download_url'] as String),
    );
  }

  final String name;
  final Uri browserDownloadUrl;
}

class GitHubReleaseDto {
  const GitHubReleaseDto({
    required this.tagName,
    required this.body,
    required this.htmlUrl,
    required this.assets,
  });

  factory GitHubReleaseDto.fromJson(Map<String, dynamic> json) {
    return GitHubReleaseDto(
      tagName: json['tag_name'] as String,
      body: json['body'] as String?,
      htmlUrl: Uri.parse(json['html_url'] as String),
      assets: (json['assets'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(GitHubReleaseAssetDto.fromJson)
          .toList(growable: false),
    );
  }

  final String tagName;
  final String? body;
  final Uri htmlUrl;
  final List<GitHubReleaseAssetDto> assets;
}

class SemanticVersion implements Comparable<SemanticVersion> {
  const SemanticVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.preReleaseIdentifiers = const <String>[],
  });

  factory SemanticVersion.parse(String rawValue) {
    var candidate = rawValue.trim();
    if (candidate.startsWith(RegExp('[vV]'))) {
      candidate = candidate.substring(1);
    }

    final plusIndex = candidate.indexOf('+');
    if (plusIndex >= 0) {
      candidate = candidate.substring(0, plusIndex);
    }

    final dashIndex = candidate.indexOf('-');
    final numberPart = dashIndex >= 0
        ? candidate.substring(0, dashIndex)
        : candidate;
    final preReleasePart = dashIndex >= 0
        ? candidate.substring(dashIndex + 1)
        : null;
    final numberComponents = numberPart.split('.');
    if (numberComponents.length < 2 || numberComponents.length > 3) {
      throw FormatException('Invalid semantic version: $rawValue');
    }

    final major = int.parse(numberComponents[0]);
    final minor = int.parse(numberComponents[1]);
    final patch = int.parse(
      numberComponents.length > 2 ? numberComponents[2] : '0',
    );
    final preReleaseIdentifiers = preReleasePart != null
        ? preReleasePart.split('.')
        : const <String>[];

    return SemanticVersion(
      major: major,
      minor: minor,
      patch: patch,
      preReleaseIdentifiers: preReleaseIdentifiers,
    );
  }

  final int major;
  final int minor;
  final int patch;
  final List<String> preReleaseIdentifiers;

  @override
  int compareTo(SemanticVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);

    if (preReleaseIdentifiers.isEmpty && other.preReleaseIdentifiers.isEmpty) {
      return 0;
    }
    if (preReleaseIdentifiers.isEmpty) return 1;
    if (other.preReleaseIdentifiers.isEmpty) return -1;

    final count =
        preReleaseIdentifiers.length > other.preReleaseIdentifiers.length
        ? preReleaseIdentifiers.length
        : other.preReleaseIdentifiers.length;

    for (var index = 0; index < count; index += 1) {
      final left = index < preReleaseIdentifiers.length
          ? preReleaseIdentifiers[index]
          : null;
      final right = index < other.preReleaseIdentifiers.length
          ? other.preReleaseIdentifiers[index]
          : null;

      if (left == null && right == null) return 0;
      if (left == null) return -1;
      if (right == null) return 1;
      if (left == right) continue;

      final leftNumeric = int.tryParse(left);
      final rightNumeric = int.tryParse(right);
      if (leftNumeric != null && rightNumeric != null) {
        return leftNumeric.compareTo(rightNumeric);
      }
      if (leftNumeric != null) return -1;
      if (rightNumeric != null) return 1;
      final comparison = left.compareTo(right);
      if (comparison != 0) return comparison;
    }

    return 0;
  }

  @override
  String toString() {
    final base = '$major.$minor.$patch';
    if (preReleaseIdentifiers.isEmpty) {
      return base;
    }
    return '$base-${preReleaseIdentifiers.join('.')}';
  }
}

class ReleaseUpdaterException implements Exception {
  const ReleaseUpdaterException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum LinuxInstallProgressStage { downloading, installing, relaunching }

class LinuxInstallProgress {
  const LinuxInstallProgress._(this.stage, this.fraction);

  const LinuxInstallProgress.downloading(double? fraction)
    : this._(LinuxInstallProgressStage.downloading, fraction);

  const LinuxInstallProgress.installing()
    : this._(LinuxInstallProgressStage.installing, null);

  const LinuxInstallProgress.relaunching()
    : this._(LinuxInstallProgressStage.relaunching, null);

  final LinuxInstallProgressStage stage;
  final double? fraction;
}

abstract class ShellReleaseUpdater {
  Uri get releasesPageUrl;

  Future<LinuxUpdateCheckResult> checkForUpdates({
    required String currentVersion,
  });

  Future<void> prepareAndLaunchInstall(
    LinuxUpdateCheckResult result, {
    void Function(LinuxInstallProgress progress)? onProgress,
  });

  Future<void> openReleasesPage();
}

class GitHubShellReleaseUpdater implements ShellReleaseUpdater {
  GitHubShellReleaseUpdater({
    http.Client? client,
    this.owner = 'lubomirmolin',
    this.repo = 'vibe-bridge',
    String? executablePath,
  }) : _client = client ?? http.Client(),
       _currentExecutablePath = executablePath ?? Platform.resolvedExecutable;

  final http.Client _client;
  final String owner;
  final String repo;
  final String _currentExecutablePath;

  @override
  Uri get releasesPageUrl =>
      Uri.parse('https://github.com/$owner/$repo/releases');

  Uri get _latestReleaseApiUrl =>
      Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');

  @override
  Future<LinuxUpdateCheckResult> checkForUpdates({
    required String currentVersion,
  }) async {
    final current = SemanticVersion.parse(currentVersion);
    final response = await _client.get(
      _latestReleaseApiUrl,
      headers: const <String, String>{
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'VibeBridge-LinuxUpdater',
      },
    );

    if (response.statusCode == 404) {
      throw const ReleaseUpdaterException(
        'No published versioned release exists yet.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ReleaseUpdaterException(
        'GitHub update check failed: HTTP ${response.statusCode}',
      );
    }

    final release = GitHubReleaseDto.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    final latest = SemanticVersion.parse(release.tagName);
    final asset = pickPreferredLinuxAsset(release.assets, _normalizedArch());
    Uri? checksumsUrl;
    for (final releaseAsset in release.assets) {
      if (releaseAsset.name == 'SHA256SUMS') {
        checksumsUrl = releaseAsset.browserDownloadUrl;
        break;
      }
    }

    return LinuxUpdateCheckResult(
      currentVersion: current,
      latestVersion: latest,
      releaseUrl: release.htmlUrl,
      asset: asset,
      checksumsUrl: checksumsUrl,
    );
  }

  @override
  Future<void> prepareAndLaunchInstall(
    LinuxUpdateCheckResult result, {
    void Function(LinuxInstallProgress progress)? onProgress,
  }) async {
    if (!result.isUpdateAvailable) {
      throw const ReleaseUpdaterException('No newer release is available.');
    }

    final asset = result.asset;
    if (asset == null) {
      throw const ReleaseUpdaterException(
        'Latest release has no installable Linux shell asset.',
      );
    }

    onProgress?.call(const LinuxInstallProgress.downloading(0));

    final checksumsUrl = result.checksumsUrl;
    if (checksumsUrl == null) {
      throw const ReleaseUpdaterException(
        'Latest release is missing SHA256SUMS.',
      );
    }

    final manifest = await _fetchChecksumManifest(checksumsUrl);
    final expectedDigest = parseSha256Sums(manifest, asset.name);
    final downloadedAsset = await _downloadVerifiedAsset(
      asset,
      expectedDigest,
      onProgress,
    );

    onProgress?.call(const LinuxInstallProgress.installing());

    switch (asset.kind) {
      case LinuxUpdateAssetKind.appImage:
        await _launchAppImage(downloadedAsset.path);
      case LinuxUpdateAssetKind.tarGz:
        await _launchTarballHelper(downloadedAsset.path);
    }

    onProgress?.call(const LinuxInstallProgress.relaunching());
  }

  @override
  Future<void> openReleasesPage() async {
    await Process.start('xdg-open', <String>[
      releasesPageUrl.toString(),
    ], mode: ProcessStartMode.detached);
  }

  String _normalizedArch() {
    final machine = _machineArchitecture();
    switch (machine) {
      case 'amd64':
      case 'x86_64':
        return 'x86_64';
      case 'aarch64':
      case 'arm64':
        return 'arm64';
      default:
        return machine;
    }
  }

  String _machineArchitecture() {
    final result = Process.runSync('uname', <String>['-m']);
    if (result.exitCode == 0) {
      final output = (result.stdout as String).trim();
      if (output.isNotEmpty) {
        return output;
      }
    }
    return 'x86_64';
  }

  Future<String> _fetchChecksumManifest(Uri checksumsUrl) async {
    final manifestResponse = await _client.get(
      checksumsUrl,
      headers: const <String, String>{
        'Accept': 'text/plain,application/octet-stream;q=0.9,*/*;q=0.8',
        'User-Agent': 'VibeBridge-LinuxUpdater',
      },
    );
    if (manifestResponse.statusCode < 200 ||
        manifestResponse.statusCode >= 300) {
      throw ReleaseUpdaterException(
        'Could not fetch SHA256SUMS: HTTP ${manifestResponse.statusCode}',
      );
    }

    return manifestResponse.body;
  }

  Future<File> _downloadVerifiedAsset(
    LinuxUpdateAsset asset,
    String expectedDigest,
    void Function(LinuxInstallProgress progress)? onProgress,
  ) async {
    final request = http.Request('GET', asset.url)
      ..headers['Accept'] = 'application/octet-stream'
      ..headers['User-Agent'] = 'VibeBridge-LinuxUpdater';
    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ReleaseUpdaterException(
        'Failed to download update asset: HTTP ${response.statusCode}',
      );
    }

    final tempDir = await Directory.systemTemp.createTemp(
      'vibe-bridge-updater-',
    );
    final destination = File('${tempDir.path}/${asset.name}');
    final sink = destination.openWrite();
    final digestSink = _DigestSink();
    final input = sha256.startChunkedConversion(digestSink);
    var received = 0;
    final total = response.contentLength;

    await for (final chunk in response.stream) {
      sink.add(chunk);
      input.add(chunk);
      received += chunk.length;
      if (total != null && total > 0) {
        onProgress?.call(LinuxInstallProgress.downloading(received / total));
      } else {
        onProgress?.call(const LinuxInstallProgress.downloading(null));
      }
    }

    await sink.close();
    input.close();

    final actualDigest = digestSink.events.single.toString();
    if (actualDigest != expectedDigest) {
      try {
        await destination.delete();
      } catch (_) {
        // Ignore failed cleanup on checksum mismatch.
      }
      throw const ReleaseUpdaterException(
        'Update verification failed: downloaded checksum does not match SHA256SUMS.',
      );
    }

    return destination;
  }

  Future<void> _launchAppImage(String assetPath) async {
    final file = File(assetPath);
    await Process.run('chmod', <String>['755', file.path]);
    await Process.start(
      file.path,
      const <String>[],
      mode: ProcessStartMode.detached,
    );
  }

  Future<void> _launchTarballHelper(String assetPath) async {
    final executable = File(_currentExecutablePath);
    final targetDir = executable.parent;
    final parentDir = targetDir.parent.path;
    final executableName = _basename(executable.path);
    final writableCheck = await Process.run('test', <String>['-w', parentDir]);
    if (writableCheck.exitCode != 0) {
      throw ReleaseUpdaterException(
        'Cannot write to $parentDir. Move the shell to a writable folder or update manually.',
      );
    }

    final helperDir = await Directory.systemTemp.createTemp(
      'vibe-bridge-install-helper-',
    );
    final helperPath = '${helperDir.path}/run-update.sh';
    await File(helperPath).writeAsString(_tarballInstallScript);
    await Process.run('chmod', <String>['700', helperPath]);

    await Process.start('/bin/bash', <String>[
      helperPath,
      '--pid',
      '$pid',
      '--asset',
      assetPath,
      '--target-dir',
      targetDir.path,
      '--executable',
      executableName,
    ], mode: ProcessStartMode.detached);
  }

  String get _tarballInstallScript => r'''
#!/bin/bash
set -euo pipefail

PID=""
ASSET_PATH=""
TARGET_DIR=""
EXECUTABLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)
      PID="$2"
      shift 2
      ;;
    --asset)
      ASSET_PATH="$2"
      shift 2
      ;;
    --target-dir)
      TARGET_DIR="$2"
      shift 2
      ;;
    --executable)
      EXECUTABLE="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$PID" || -z "$ASSET_PATH" || -z "$TARGET_DIR" || -z "$EXECUTABLE" ]]; then
  echo "Missing required updater arguments" >&2
  exit 2
fi

TARGET_PARENT="$(dirname "$TARGET_DIR")"
if [[ ! -w "$TARGET_PARENT" ]]; then
  echo "No write permission to $TARGET_PARENT" >&2
  exit 3
fi

for _ in {1..900}; do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

if kill -0 "$PID" 2>/dev/null; then
  echo "Timed out waiting for app process $PID to exit" >&2
  exit 4
fi

WORK_DIR="$(mktemp -d /tmp/vibe-bridge-linux-updater.XXXXXX)"
INCOMING_DIR="$TARGET_PARENT/.incoming.$$"
BACKUP_DIR="$TARGET_PARENT/.backup.$$"

cleanup() {
  rm -rf "$WORK_DIR"
}

rollback_install() {
  if [[ -d "$BACKUP_DIR" && ! -e "$TARGET_DIR" ]]; then
    mv "$BACKUP_DIR" "$TARGET_DIR" || true
  fi
}

fail() {
  rollback_install
  echo "$1" >&2
  cleanup
  exit 5
}

tar -xzf "$ASSET_PATH" -C "$WORK_DIR" || fail "Failed to extract update payload"

SOURCE_ROOT="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ -z "$SOURCE_ROOT" || ! -d "$SOURCE_ROOT" ]]; then
  fail "Update payload did not contain a bundle directory"
fi

rm -rf "$INCOMING_DIR" "$BACKUP_DIR"
cp -R "$SOURCE_ROOT" "$INCOMING_DIR" || fail "Failed to stage update payload"

if [[ -e "$TARGET_DIR" ]]; then
  mv "$TARGET_DIR" "$BACKUP_DIR" || fail "Failed to backup current bundle"
fi

if ! mv "$INCOMING_DIR" "$TARGET_DIR"; then
  fail "Failed to move updated bundle into place"
fi

rm -rf "$BACKUP_DIR"
chmod 755 "$TARGET_DIR/$EXECUTABLE" >/dev/null 2>&1 || true
"$TARGET_DIR/$EXECUTABLE" >/dev/null 2>&1 &

cleanup
exit 0
''';
}

class _DigestSink implements Sink<Digest> {
  final List<Digest> events = <Digest>[];

  @override
  void add(Digest data) {
    events.add(data);
  }

  @override
  void close() {}
}

LinuxUpdateAsset? pickPreferredLinuxAsset(
  List<GitHubReleaseAssetDto> assets,
  String arch,
) {
  final prefix = 'codex-mobile-companion-linux-$arch-';
  final candidates = assets
      .where((asset) {
        final lowered = asset.name.toLowerCase();
        return lowered.startsWith(prefix);
      })
      .toList(growable: false);

  for (final suffix in <String>['.tar.gz', '.appimage']) {
    for (final asset in candidates) {
      if (asset.name.toLowerCase().endsWith(suffix)) {
        return LinuxUpdateAsset(
          name: asset.name,
          url: asset.browserDownloadUrl,
          kind: suffix == '.tar.gz'
              ? LinuxUpdateAssetKind.tarGz
              : LinuxUpdateAssetKind.appImage,
        );
      }
    }
  }

  return null;
}

String parseSha256Sums(String manifest, String assetName) {
  for (final rawLine in const LineSplitter().convert(manifest)) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    final match = RegExp(r'^([A-Fa-f0-9]{64})\s+\*?(.+)$').firstMatch(line);
    if (match == null) {
      continue;
    }
    if (match.group(2) == assetName) {
      return match.group(1)!.toLowerCase();
    }
  }

  throw ReleaseUpdaterException(
    'Update verification failed: $assetName is missing from SHA256SUMS.',
  );
}

String _basename(String path) {
  final separator = Platform.pathSeparator;
  final segments = path.split(separator);
  return segments.isEmpty ? path : segments.last;
}
