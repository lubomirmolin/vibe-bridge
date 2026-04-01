import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

class AnimatedBridgeBackground extends StatefulWidget {
  const AnimatedBridgeBackground({
    super.key,
    this.sceneScale = 1.2,
    this.frozen = false,
  });

  final double sceneScale;
  final bool frozen;

  @override
  State<AnimatedBridgeBackground> createState() =>
      _AnimatedBridgeBackgroundState();
}

class _AnimatedBridgeBackgroundState extends State<AnimatedBridgeBackground>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  final ValueNotifier<double> _timeNotifier = ValueNotifier(0.0);
  StreamSubscription<AccelerometerEvent>? _accelSubscription;
  Duration _animationStartedAt = Duration.zero;
  Duration _lastElapsed = Duration.zero;
  double _tiltX = 0;
  double _tiltY = 0;
  double _targetTiltX = 0;
  double _targetTiltY = 0;

  bool get _supportsAccelerometerTilt =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _lastElapsed = elapsed;
      if (widget.frozen) {
        _tiltX = 0;
        _tiltY = 0;
        _timeNotifier.value = 0.0;
        return;
      }

      // Lerp the tilt to heavily filter out accelerometer noise.
      _tiltX += (_targetTiltX - _tiltX) * 0.08;
      _tiltY += (_targetTiltY - _tiltY) * 0.08;

      final relativeElapsed = elapsed - _animationStartedAt;
      _timeNotifier.value = relativeElapsed.inMicroseconds / 1000000.0;
    });
    _ticker.start();

    if (_supportsAccelerometerTilt) {
      try {
        _accelSubscription = accelerometerEventStream().listen((
          AccelerometerEvent event,
        ) {
          final pitchDeg = atan2(event.y, event.z) * 180 / pi;
          final rollDeg = atan2(event.x, event.z) * 180 / pi;

          final normalizedX = -(rollDeg / 45.0);
          final normalizedY = (pitchDeg - 45.0) / 45.0;

          _targetTiltX = normalizedX.clamp(-1.0, 1.0) * 40.0;
          _targetTiltY = normalizedY.clamp(-1.0, 1.0) * 40.0;
        });
      } on MissingPluginException {
        // Fall back to the built-in drift animation on platforms without sensors.
      }
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedBridgeBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frozen && !widget.frozen) {
      _animationStartedAt = _lastElapsed;
    }
    if (!oldWidget.frozen && widget.frozen) {
      _targetTiltX = 0;
      _targetTiltY = 0;
      _tiltX = 0;
      _tiltY = 0;
      _timeNotifier.value = 0.0;
    }
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    _ticker.dispose();
    _timeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: const Color(0xFF09090B)),
        RepaintBoundary(
          child: Transform.translate(
            offset: Offset(_tiltX * 0.3, _tiltY * 0.3),
            child: CustomPaint(painter: _StarsPainter(seed: 42)),
          ),
        ),
        RepaintBoundary(
          child: ValueListenableBuilder<double>(
            valueListenable: _timeNotifier,
            builder: (context, timeValue, child) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  Transform.translate(
                    offset: Offset(_tiltX * 1.0, _tiltY * 1.0),
                    child: Opacity(
                      opacity: 0.4,
                      child: CustomPaint(
                        painter: _BridgePainter(
                          time: timeValue,
                          sceneScale: widget.sceneScale,
                        ),
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(_tiltX * 2.5, _tiltY * 2.5),
                    child: CustomPaint(
                      painter: _ForegroundParticlesPainter(
                        time: timeValue,
                        sceneScale: widget.sceneScale,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF09090B),
                Colors.transparent,
                Color(0xFF09090B),
              ],
              stops: [0.0, 0.5, 1.0],
            ),
          ),
        ),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Color(0xFF09090B),
                Colors.transparent,
                Color(0xFF09090B),
              ],
              stops: [0.0, 0.5, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

class _StarsPainter extends CustomPainter {
  const _StarsPainter({required this.seed});

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rand = Random(seed);
    final paint = Paint()..color = Colors.white;

    for (var i = 0; i < 50; i++) {
      final x = rand.nextDouble() * size.width;
      final y = rand.nextDouble() * size.height;
      final radius = rand.nextDouble() * 1.5 + 0.5;
      paint.color = Colors.white.withValues(
        alpha: rand.nextDouble() * 0.3 + 0.1,
      );
      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BridgePainter extends CustomPainter {
  _BridgePainter({required this.time, required this.sceneScale});

  final double time;
  final double sceneScale;

  double _getCableY(double x) {
    if (x < 300) {
      final t = (x + 500) / 800;
      return pow(1 - t, 2) * 600 + 2 * (1 - t) * t * 650 + pow(t, 2) * 200;
    } else if (x <= 700) {
      final t = (x - 300) / 400;
      return pow(1 - t, 2) * 200 + 2 * (1 - t) * t * 900 + pow(t, 2) * 200;
    } else {
      final t = (x - 700) / 800;
      return pow(1 - t, 2) * 200 + 2 * (1 - t) * t * 650 + pow(t, 2) * 600;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Zoom out more
    final zoomOutFactor = 0.6;
    final scale =
        max(size.width / 1000, size.height / 1000) * sceneScale * zoomOutFactor;
    final dx = (size.width - 1000 * scale) / 2;
    final dy = (size.height - 1000 * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    final slowDriftX = sin(time * pi / 4) * 15;
    final slowDriftY = cos(time * pi / 4) * 8;

    canvas.translate(500 + slowDriftX, 500 + slowDriftY);
    canvas.rotate(-5 * pi / 180);
    // Squash height locally
    canvas.scale(1.0, 0.7);
    canvas.translate(-500, -450);

    final solidPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.3);

    final deckPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withValues(alpha: 0.3);

    const towers = [300.0, 700.0];
    for (final tx in towers) {
      canvas.drawLine(Offset(tx - 20, 100), Offset(tx - 35, 700), solidPaint);
      canvas.drawLine(Offset(tx + 20, 100), Offset(tx + 35, 700), solidPaint);

      canvas.drawLine(
        Offset(tx - 25, 100),
        Offset(tx + 25, 100),
        solidPaint
          ..strokeWidth = 4
          ..color = Colors.white.withValues(alpha: 0.5),
      );
      canvas.drawLine(
        Offset(tx - 22, 115),
        Offset(tx + 22, 115),
        solidPaint..strokeWidth = 2,
      );
      canvas.drawLine(
        Offset(tx - 18, 130),
        Offset(tx + 18, 130),
        solidPaint..strokeWidth = 1,
      );

      const bracingY = [200.0, 300.0, 400.0, 500.0, 620.0];
      for (var i = 0; i < bracingY.length; i++) {
        final cy = bracingY[i];
        final widthAtY = 20 + ((cy - 100) / 600) * 15;

        canvas.drawLine(
          Offset(tx - widthAtY, cy),
          Offset(tx + widthAtY, cy),
          solidPaint
            ..strokeWidth = 3
            ..color = Colors.white.withValues(alpha: 0.4),
        );
        canvas.drawLine(
          Offset(tx - widthAtY, cy + 10),
          Offset(tx + widthAtY, cy + 10),
          solidPaint..strokeWidth = 1,
        );

        if (i < bracingY.length - 1) {
          final nextCy = bracingY[i + 1];
          final nextWidth = 20 + ((nextCy - 100) / 600) * 15;
          canvas.drawLine(
            Offset(tx - widthAtY, cy),
            Offset(tx + nextWidth, nextCy),
            solidPaint
              ..strokeWidth = 1
              ..color = Colors.white.withValues(alpha: 0.3),
          );
          canvas.drawLine(
            Offset(tx + widthAtY, cy),
            Offset(tx - nextWidth, nextCy),
            solidPaint
              ..strokeWidth = 1
              ..color = Colors.white.withValues(alpha: 0.3),
          );
        }
      }
    }

    canvas.drawLine(
      const Offset(-500, 610),
      const Offset(1500, 610),
      deckPaint,
    );

    final cablePath = Path()
      ..moveTo(-500, 600)
      ..quadraticBezierTo(-100, 650, 300, 200)
      ..quadraticBezierTo(500, 900, 700, 200)
      ..quadraticBezierTo(1100, 650, 1500, 600);

    canvas.drawPath(
      cablePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = Colors.white.withValues(alpha: 0.15),
    );

    final dashOffset = -(time * 15.0);
    final dashedCable = Path();
    for (final metric in cablePath.computeMetrics()) {
      var distance = dashOffset % 16.0;
      if (distance < 0) {
        distance += 16.0;
      }
      var draw = true;
      var currentPos = 0.0;

      while (currentPos < metric.length) {
        const len = 8.0;
        if (draw) {
          final start = currentPos - distance;
          final end = start + len;
          if (end > 0 && start < metric.length) {
            dashedCable.addPath(
              metric.extractPath(max(0, start), min(metric.length, end)),
              Offset.zero,
            );
          }
        }
        currentPos += len;
        draw = !draw;
      }
    }

    canvas.drawPath(
      dashedCable,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white.withValues(alpha: 0.9),
    );

    for (var i = 0; i < 70; i++) {
      final x = i * 30.0 - 500.0;
      if ((x - 300).abs() < 35 || (x - 700).abs() < 35) {
        continue;
      }

      final y = _getCableY(x);
      if (y > 600) {
        continue;
      }

      final phase = (i * 0.05 + time * 0.5) % 1.0;
      final opacity = 0.2 + (sin(phase * pi) * 0.6).abs();

      canvas.drawLine(
        Offset(x, y),
        Offset(x, 600),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: opacity),
      );
    }

    for (var i = 0; i < 3; i++) {
      final speed = 1.0 + i * 0.5;
      final xOffset = ((time * speed * 50) + (i * 100)) % 2000 - 500.0;

      final streamPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.8);

      for (var x = xOffset; x < 1500; x += 42) {
        canvas.drawLine(
          Offset(x, 585.0 + i * 5),
          Offset(x + 2, 585.0 + i * 5),
          streamPaint,
        );
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BridgePainter oldDelegate) {
    return oldDelegate.time != time || oldDelegate.sceneScale != sceneScale;
  }
}

class _ForegroundParticlesPainter extends CustomPainter {
  _ForegroundParticlesPainter({required this.time, required this.sceneScale});

  final double time;
  final double sceneScale;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = max(size.width / 1000, size.height / 1000) * sceneScale;
    final dx = (size.width - 1000 * scale) / 2;
    final dy = (size.height - 1000 * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    final rand = Random(42);
    final particlePaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1);

    for (var i = 0; i < 15; i++) {
      final xPos = rand.nextDouble() * 1200 - 100;
      final yBase = rand.nextDouble() * 1200 - 100;
      final size = rand.nextDouble() * 4 + 2;
      final durationMult = rand.nextDouble() * 3 + 3;
      final delay = rand.nextDouble() * 2;

      final phase = (time / durationMult + delay) % 1.0;
      final yOffset = sin(phase * pi) * -20;
      final opacity = 0.2 + sin(phase * pi) * 0.4;

      particlePaint.color = Colors.white.withValues(alpha: opacity);
      canvas.drawCircle(Offset(xPos, yBase + yOffset), size / 2, particlePaint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ForegroundParticlesPainter oldDelegate) {
    return oldDelegate.time != time || oldDelegate.sceneScale != sceneScale;
  }
}
