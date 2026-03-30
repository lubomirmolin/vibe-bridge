import 'dart:io';

import 'package:flutter/services.dart';
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
    return _recorder
        .onAmplitudeChanged(interval)
        .map((amplitude) => SpeechCaptureAmplitude(current: amplitude.current));
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
    await _resetActiveRecordingSession();
    final recordingDirectory = await Directory.systemTemp.createTemp(
      'vibe-bridge-speech-',
    );
    final recordingPath = '${recordingDirectory.path}/voice-message.wav';
    _recordingPath = recordingPath;
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: recordingPath,
      );
    } on PlatformException catch (error) {
      await _cleanupRecording(recordingPath);
      _recordingPath = null;
      throw SpeechCaptureException(
        message: _startFailureMessage(error.message),
        code: 'speech_capture_start_failed',
      );
    } catch (_) {
      await _cleanupRecording(recordingPath);
      _recordingPath = null;
      throw const SpeechCaptureException(
        message: 'Couldn’t start recording right now. Please try again.',
        code: 'speech_capture_start_failed',
      );
    }
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

  Future<void> _resetActiveRecordingSession() async {
    try {
      if (await _recorder.isPaused() || await _recorder.isRecording()) {
        await _recorder.cancel();
      }
    } catch (_) {
      // If the plugin cannot report its state, continue with a fresh start attempt.
    }
  }

  String _startFailureMessage(String? nativeMessage) {
    final trimmedMessage = nativeMessage?.trim();
    if (trimmedMessage == null || trimmedMessage.isEmpty) {
      return 'Couldn’t start recording right now. Please try again.';
    }

    return trimmedMessage;
  }
}
