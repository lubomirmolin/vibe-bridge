import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:vibe_bridge/foundation/media/speech_capture.dart';
import 'package:vibe_bridge/foundation/media/speech_capture_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IoSpeechCapture', () {
    test('resets a stale native recording session before starting', () async {
      final recorder = _FakeAudioRecorder(
        isRecordingResult: true,
        isPausedResult: false,
      );
      final capture = IoSpeechCapture(recorder: recorder);

      await capture.start();

      expect(recorder.cancelCallCount, 1);
      expect(recorder.startCallCount, 1);
      expect(recorder.lastPath, isNotNull);
    });

    test('wraps native start failures as SpeechCaptureException', () async {
      final recorder = _FakeAudioRecorder(
        startError: PlatformException(
          code: 'record',
          message: 'The microphone is already in use.',
        ),
      );
      final capture = IoSpeechCapture(recorder: recorder);

      await expectLater(
        capture.start(),
        throwsA(
          isA<SpeechCaptureException>()
              .having(
                (error) => error.code,
                'code',
                'speech_capture_start_failed',
              )
              .having(
                (error) => error.message,
                'message',
                'The microphone is already in use.',
              ),
        ),
      );
    });
  });
}

class _FakeAudioRecorder implements AudioRecorder {
  _FakeAudioRecorder({
    this.isRecordingResult = false,
    this.isPausedResult = false,
    this.startError,
  });

  final bool isRecordingResult;
  final bool isPausedResult;
  final Object? startError;

  int cancelCallCount = 0;
  int startCallCount = 0;
  String? lastPath;

  @override
  Future<void> cancel() async {
    cancelCallCount++;
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<bool> isPaused() async => isPausedResult;

  @override
  Future<bool> isRecording() async => isRecordingResult;

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) {
    return const Stream<Amplitude>.empty();
  }

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    startCallCount++;
    lastPath = path;
    if (startError != null) {
      throw startError!;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
