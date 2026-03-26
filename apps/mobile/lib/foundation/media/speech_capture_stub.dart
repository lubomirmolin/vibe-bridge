import 'speech_capture.dart';

SpeechCapture createSpeechCapture() {
  return const UnsupportedSpeechCapture();
}

class UnsupportedSpeechCapture implements SpeechCapture {
  const UnsupportedSpeechCapture();

  @override
  Stream<SpeechCaptureAmplitude> amplitudeStream(Duration interval) {
    return const Stream<SpeechCaptureAmplitude>.empty();
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<bool> hasPermission() async {
    throw const SpeechCaptureException(
      message: 'Voice capture is unavailable in this build.',
      code: 'speech_capture_unsupported',
    );
  }

  @override
  Future<void> start() async {
    throw const SpeechCaptureException(
      message: 'Voice capture is unavailable in this build.',
      code: 'speech_capture_unsupported',
    );
  }

  @override
  Future<SpeechCaptureResult> stop() async {
    throw const SpeechCaptureException(
      message: 'Voice capture is unavailable in this build.',
      code: 'speech_capture_unsupported',
    );
  }
}
