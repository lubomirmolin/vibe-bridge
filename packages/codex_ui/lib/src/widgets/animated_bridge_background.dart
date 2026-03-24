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

  double _getDeckY(double x) {
    return 600.0 + (x - 250.0) * -0.25;
  }

  double _getDeckThickness(double x) {
    return max(2.0, 20.0 - (x - 250.0) * 0.0266);
  }

  double _getCableY(double x) {
    if (x < 250) {
      final t = (x + 200) / 450;
      return pow(1 - t, 2) * 400 + 2 * (1 - t) * t * 200 + pow(t, 2) * -150;
    } else if (x <= 850) {
      final t = (x - 250) / 600;
      return pow(1 - t, 2) * -150 + 2 * (1 - t) * t * 950 + pow(t, 2) * 250;
    } else {
      final t = (x - 850) / 400;
      return pow(1 - t, 2) * 250 + 2 * (1 - t) * t * 400 + pow(t, 2) * 400;
    }
  }

  void _drawPerspectiveTower(
    Canvas canvas,
    Paint paint, {
    required double cx,
    required double yTop,
    required double yBottom,
    required double wTop,
    required double wBottom,
  }) {
    // Legs
    canvas.drawLine(
      Offset(cx - wTop / 2, yTop),
      Offset(cx - wBottom / 2, yBottom),
      paint,
    );
    canvas.drawLine(
      Offset(cx + wTop / 2, yTop),
      Offset(cx + wBottom / 2, yBottom),
      paint,
    );

    // Top horizontal bars
    canvas.drawLine(
      Offset(cx - wTop / 2 - 5, yTop),
      Offset(cx + wTop / 2 + 5, yTop),
      paint
        ..strokeWidth = 4
        ..color = Colors.white.withValues(alpha: 0.5),
    );
    canvas.drawLine(
      Offset(cx - wTop / 2, yTop + 15),
      Offset(cx + wTop / 2, yTop + 15),
      paint..strokeWidth = 2,
    );

    // reset paint
    paint.strokeWidth = 2;
    paint.color = Colors.white.withValues(alpha: 0.3);

    // Cross bracings
    final height = yBottom - yTop;
    final bracingFractions = [0.15, 0.3, 0.45, 0.6, 0.75, 0.9];
    for (int i = 0; i < bracingFractions.length; i++) {
      final t = bracingFractions[i];
      final cy = yTop + height * t;
      final w = wTop + (wBottom - wTop) * t;

      canvas.drawLine(
        Offset(cx - w / 2, cy),
        Offset(cx + w / 2, cy),
        paint
          ..strokeWidth = 3
          ..color = Colors.white.withValues(alpha: 0.4),
      );
      canvas.drawLine(
        Offset(cx - w / 2, cy + 10),
        Offset(cx + w / 2, cy + 10),
        paint..strokeWidth = 1,
      );

      if (i < bracingFractions.length - 1) {
        final nextT = bracingFractions[i + 1];
        final nextCy = yTop + height * nextT;
        final nextW = wTop + (wBottom - wTop) * nextT;

        canvas.drawLine(
          Offset(cx - w / 2, cy),
          Offset(cx + nextW / 2, nextCy),
          paint
            ..strokeWidth = 1
            ..color = Colors.white.withValues(alpha: 0.3),
        );
        canvas.drawLine(
          Offset(cx + w / 2, cy),
          Offset(cx - nextW / 2, nextCy),
          paint
            ..strokeWidth = 1
            ..color = Colors.white.withValues(alpha: 0.3),
        );
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = max(size.width / 1000, size.height / 1000) * sceneScale;
    final dx = (size.width - 1000 * scale) / 2;
    final dy = (size.height - 1000 * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    final slowDriftX = sin(time * pi / 4) * 15;
    final slowDriftY = cos(time * pi / 4) * 8;

    canvas.translate(slowDriftX, slowDriftY);

    final solidPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.3);

    final deckPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withValues(alpha: 0.3);

    // Towers
    _drawPerspectiveTower(
      canvas,
      solidPaint,
      cx: 250,
      yTop: -150,
      yBottom: 1000,
      wTop: 150,
      wBottom: 250,
    );

    _drawPerspectiveTower(
      canvas,
      solidPaint,
      cx: 850,
      yTop: 250,
      yBottom: 600,
      wTop: 40,
      wBottom: 60,
    );

    // Deck
    final deckPath = Path()
      ..moveTo(-200, _getDeckY(-200))
      ..lineTo(1250, _getDeckY(1250))
      ..lineTo(1250, _getDeckY(1250) + _getDeckThickness(1250))
      ..lineTo(-200, _getDeckY(-200) + _getDeckThickness(-200))
      ..close();

    canvas.drawPath(
      deckPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.white.withValues(alpha: 0.05),
    );
    canvas.drawLine(
      Offset(-200, _getDeckY(-200)),
      Offset(1250, _getDeckY(1250)),
      deckPaint,
    );
    canvas.drawLine(
      Offset(-200, _getDeckY(-200) + _getDeckThickness(-200)),
      Offset(1250, _getDeckY(1250) + _getDeckThickness(1250)),
      deckPaint..strokeWidth = 1,
    );

    // Main suspension cable
    final cablePath = Path()
      ..moveTo(-200, 400)
      ..quadraticBezierTo(25, 200, 250, -150)
      ..quadraticBezierTo(550, 950, 850, 250)
      ..quadraticBezierTo(1050, 400, 1250, 400);

    // Glow shadow
    canvas.drawPath(
      cablePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = Colors.white.withValues(alpha: 0.15),
    );

    // Main cable line animated dashes
    final dashOffset = -(time * 15.0);
    Path dashedCable = Path();
    for (final metric in cablePath.computeMetrics()) {
      double distance = dashOffset % 16.0;
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
    List<double> suspenderXs = [];
    double currentX = -200;
    double currentSpacing = 40;
    while (currentX < 1250) {
      suspenderXs.add(currentX);
      currentSpacing = 40 - (currentX + 200) * 0.025;
      if (currentSpacing < 4) currentSpacing = 4;
      currentX += currentSpacing;
    }

    for (int i = 0; i < suspenderXs.length; i++) {
      final x = suspenderXs[i];
      if ((x - 250).abs() < 25 || (x - 850).abs() < 15) continue;

      final yTopCable = _getCableY(x);
      final yDeck = _getDeckY(x);

      if (yTopCable > yDeck) continue;

      final phase = (i * 0.05 + time * 0.5) % 1.0;
      final opacity = 0.15 + (sin(phase * pi) * 0.6).abs();

      canvas.drawLine(
        Offset(x, yTopCable),
        Offset(x, yDeck),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = max(0.5, 2.0 - (x + 200) * 0.001)
          ..color = Colors.white.withValues(alpha: opacity),
      );
    }

    // Data streams moving across deck
    for (int i = 0; i < 3; i++) {
      final speed = 1.0 + i * 0.5;
      final baseOffset = (time * speed * 150) % 300;

      final streamPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.8);

      double currentStreamX = -200 + baseOffset + (i * 100);
      while (currentStreamX < 1250) {
        double dX = 25;
        double nextX = currentStreamX + dX;

        double yOffset = -5.0 + i * 4.0;

        canvas.drawLine(
          Offset(currentStreamX, _getDeckY(currentStreamX) + yOffset),
          Offset(nextX, _getDeckY(nextX) + yOffset),
          streamPaint,
        );

        currentStreamX += 100; // gap
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
