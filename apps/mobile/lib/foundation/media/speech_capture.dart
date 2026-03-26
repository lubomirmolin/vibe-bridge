import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'speech_capture_stub.dart'
    if (dart.library.html) 'speech_capture_web.dart'
    if (dart.library.io) 'speech_capture_io.dart'
    as impl;

final speechCaptureProvider = Provider<SpeechCapture>((ref) {
  return impl.createSpeechCapture();
});

abstract class SpeechCapture {
  Future<bool> hasPermission();

  Stream<SpeechCaptureAmplitude> amplitudeStream(Duration interval);

  Future<void> start();

  Future<SpeechCaptureResult> stop();

  Future<void> dispose();
}

class SpeechCaptureResult {
  const SpeechCaptureResult({
    required this.bytes,
    this.fileName = 'voice-message.wav',
  });

  final Uint8List bytes;
  final String fileName;
}

class SpeechCaptureAmplitude {
  const SpeechCaptureAmplitude({required this.current});

  final double current;
}

class SpeechCaptureException implements Exception {
  const SpeechCaptureException({
    required this.message,
    required this.code,
  });

  final String message;
  final String code;

  @override
  String toString() => message;
}
