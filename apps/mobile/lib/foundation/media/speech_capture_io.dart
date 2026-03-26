import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'speech_capture.dart';

SpeechCapture createSpeechCapture() {
  return IoSpeechCapture();
}

class IoSpeechCapture implements SpeechCapture {
  IoSpeechCapture({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  String? _recordingPath;

  @override
  Stream<SpeechCaptureAmplitude> amplitudeStream(Duration interval) {
    return _recorder.onAmplitudeChanged(interval).map(
      (amplitude) => SpeechCaptureAmplitude(current: amplitude.current),
    );
  }

  @override
  Future<void> dispose() async {
    await _recorder.dispose();
  }

  @override
  Future<bool> hasPermission() {
    return _recorder.hasPermission();
  }

  @override
  Future<void> start() async {
    final recordingDirectory = await Directory.systemTemp.createTemp(
      'codex-mobile-companion-speech-',
    );
    final recordingPath = '${recordingDirectory.path}/voice-message.wav';
    _recordingPath = recordingPath;
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: recordingPath,
    );
  }

  @override
  Future<SpeechCaptureResult> stop() async {
    final resolvedPath = await _recorder.stop() ?? _recordingPath;
    if (resolvedPath == null || resolvedPath.trim().isEmpty) {
      throw const SpeechCaptureException(
        message: 'No audio was captured for transcription.',
        code: 'speech_invalid_audio',
      );
    }

    try {
      final file = File(resolvedPath);
      final bytes = await file.readAsBytes();
      return SpeechCaptureResult(bytes: Uint8List.fromList(bytes));
    } on FileSystemException {
      throw const SpeechCaptureException(
        message: 'Couldn’t read the recording for transcription.',
        code: 'speech_capture_read_failed',
      );
    } finally {
      await _cleanupRecording(resolvedPath);
      _recordingPath = null;
    }
  }

  Future<void> _cleanupRecording(String recordingPath) async {
    final directory = File(recordingPath).parent;
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
