import 'dart:math';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';

class AnimatedBridgeBackground extends StatefulWidget {
  const AnimatedBridgeBackground({super.key, this.sceneScale = 1.2});

  final double sceneScale;

  @override
  State<AnimatedBridgeBackground> createState() =>
      _AnimatedBridgeBackgroundState();
}

class _AnimatedBridgeBackgroundState extends State<AnimatedBridgeBackground>
    with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  final ValueNotifier<double> _timeNotifier = ValueNotifier(0.0);
  StreamSubscription<AccelerometerEvent>? _accelSubscription;
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
      // Lerp the tilt to heavily filter out accelerometer noise (buttery smooth)
      _tiltX += (_targetTiltX - _tiltX) * 0.08;
      _tiltY += (_targetTiltY - _tiltY) * 0.08;

      _timeNotifier.value = elapsed.inMicroseconds / 1000000.0;
    });
    _ticker.start();

    if (_supportsAccelerometerTilt) {
      try {
        _accelSubscription = accelerometerEventStream().listen((
          AccelerometerEvent event,
        ) {
          // Calculate device pitch and roll in degrees
          final pitchDeg = atan2(event.y, event.z) * 180 / pi;
          final rollDeg = atan2(event.x, event.z) * 180 / pi;

          // Parallax mapped to match React's exact 'gamma/beta / 45' physics
          // Neutral position is holding the phone comfortably at a 45 degree tilt.
          final normalizedX = -(rollDeg / 45.0);
          final normalizedY = ((pitchDeg - 45.0) / 45.0);

          _targetTiltX = normalizedX.clamp(-1.0, 1.0) * 40.0;
          _targetTiltY = normalizedY.clamp(-1.0, 1.0) * 40.0;
        });
      } on MissingPluginException {
        // Fall back to the built-in drift animation on platforms without sensors.
      }
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
        // Background color
        Container(color: const Color(0xFF09090B)),

        // Stars
        RepaintBoundary(
          child: Transform.translate(
            offset: Offset(_tiltX * 0.3, _tiltY * 0.3),
            child: CustomPaint(painter: _StarsPainter(seed: 42)),
          ),
        ),

        // The animated bridge and particles
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

        // Gradient masks mapped from the React CSS (Vertical & Horizontal vignette)
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
  final int seed;
  _StarsPainter({required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    final rand = Random(seed);
    final paint = Paint()..color = Colors.white;

    for (int i = 0; i < 50; i++) {
      double x = rand.nextDouble() * size.width;
      double y = rand.nextDouble() * size.height;
      double radius = rand.nextDouble() * 1.5 + 0.5;
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
  final double time;
  final double sceneScale;

  _BridgePainter({required this.time, required this.sceneScale});

  double _getCableY(double x) {
    if (x < 300) {
      final t = (x + 200) / 500;
      return pow(1 - t, 2) * 600 + 2 * (1 - t) * t * 650 + pow(t, 2) * 200;
    } else if (x <= 700) {
      final t = (x - 300) / 400;
      return pow(1 - t, 2) * 200 + 2 * (1 - t) * t * 900 + pow(t, 2) * 200;
    } else {
      final t = (x - 700) / 500;
      return pow(1 - t, 2) * 200 + 2 * (1 - t) * t * 650 + pow(t, 2) * 600;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Map the 0-1000 coordinate system from the React SVG to the physical size
    // and preserve aspect ratio by scaling and translating
    final scale = max(size.width / 1000, size.height / 1000) * sceneScale;
    final dx = (size.width - 1000 * scale) / 2;
    final dy = (size.height - 1000 * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    // Apply the subtle breathing drift for parallax (since we don't have device gyroscope hooked up yet)
    final slowDriftX = sin(time * pi / 4) * 15;
    final slowDriftY = cos(time * pi / 4) * 8;

    // Apply the slight tilt from React: transform="rotate(-5 500 500) translate(0, 50)"
    canvas.translate(500 + slowDriftX, 500 + slowDriftY);
    canvas.rotate(-5 * pi / 180);
    canvas.translate(-500, -450); // -500 + 50 translate

    final solidPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.3);

    final deckPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withValues(alpha: 0.3);

    // Towers
    final towers = [300.0, 700.0];
    for (var tx in towers) {
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

      final bracingY = [200.0, 300.0, 400.0, 500.0, 620.0];
      for (int i = 0; i < bracingY.length; i++) {
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

    // Deck
    canvas.drawLine(
      const Offset(-200, 610),
      const Offset(1200, 610),
      deckPaint,
    );

    // Main suspension cable
    final cablePath = Path()
      ..moveTo(-200, 600)
      ..quadraticBezierTo(50, 650, 300, 200)
      ..quadraticBezierTo(500, 900, 700, 200)
      ..quadraticBezierTo(950, 650, 1200, 600);

    // Glow shadow
    canvas.drawPath(
      cablePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = Colors.white.withValues(alpha: 0.15),
    );

    // Main cable line animated dashes
    // Dash runs infinitely since time strictly grows linearly
    final dashOffset = -(time * 15.0);

    Path dashedCable = Path();
    for (final metric in cablePath.computeMetrics()) {
      double distance = dashOffset % 16.0; // 8 dash + 8 gap
      if (distance < 0) distance += 16.0;
      bool draw = true;
      double currentPos = 0.0;

      while (currentPos < metric.length) {
        final len = draw ? 8.0 : 8.0;
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

    // Vertical suspenders
    for (int i = 0; i < 45; i++) {
      final x = i * 30.0 - 150.0;
      if ((x - 300).abs() < 35 || (x - 700).abs() < 35) continue;

      final y = _getCableY(x);
      if (y > 600) continue;

      // Animate opacity based on phase and time
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

    // Data streams moving across deck
    for (int i = 0; i < 3; i++) {
      final speed = 1.0 + i * 0.5;
      final xOffset = ((time * speed * 50) + (i * 100)) % 1400 - 200.0;

      final streamPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.8);

      for (double x = xOffset; x < 1200; x += 42) {
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
  final double time;
  final double sceneScale;

  _ForegroundParticlesPainter({required this.time, required this.sceneScale});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = max(size.width / 1000, size.height / 1000) * sceneScale;
    final dx = (size.width - 1000 * scale) / 2;
    final dy = (size.height - 1000 * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    // Foreground floating data particles
    final rand = Random(42);
    final particlePaint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1);

    for (int i = 0; i < 15; i++) {
      final xPos = rand.nextDouble() * 1200 - 100;
      final yBase = rand.nextDouble() * 1200 - 100;
      final size = rand.nextDouble() * 4 + 2;

      // Animate y and opacity
      final durationMult = rand.nextDouble() * 3 + 3;
      final delay = rand.nextDouble() * 2;

      final phase = (time / durationMult + delay) % 1.0;
      // y animates 0 -> -20 -> 0
      final yOffset = sin(phase * pi) * -20;
      // opacity animates 0.2 -> 0.6 -> 0.2
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
