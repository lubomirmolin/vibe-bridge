import 'dart:collection';

import 'package:codex_ui/codex_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

const double macosWindowChromeHeight = 44;
const double _macosWindowTrafficLightInset = 84;
const double _macosWindowChromeButtonSize = 28;

bool get isMacosWindowChromeEnabled =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

@immutable
class MacosWindowChromeConfiguration {
  const MacosWindowChromeConfiguration({
    this.leadingActions = const <MacosWindowChromeAction>[],
    this.trailingActions = const <MacosWindowChromeAction>[],
  });

  final List<MacosWindowChromeAction> leadingActions;
  final List<MacosWindowChromeAction> trailingActions;
}

@immutable
class MacosWindowChromeAction {
  const MacosWindowChromeAction({
    required this.icon,
    required this.onPressed,
    this.key,
    this.tooltip,
    this.tintColor = AppTheme.textMuted,
    this.isActive = false,
  });

  final PhosphorIconData icon;
  final VoidCallback? onPressed;
  final Key? key;
  final String? tooltip;
  final Color tintColor;
  final bool isActive;
}

class MacosWindowChromeScope extends StatefulWidget {
  const MacosWindowChromeScope({
    super.key,
    required this.configuration,
    required this.child,
  });

  final MacosWindowChromeConfiguration configuration;
  final Widget child;

  @override
  State<MacosWindowChromeScope> createState() => _MacosWindowChromeScopeState();
}

class _MacosWindowChromeScopeState extends State<MacosWindowChromeScope> {
  final Object _token = Object();

  @override
  void initState() {
    super.initState();
    _syncConfiguration();
  }

  @override
  void didUpdateWidget(covariant MacosWindowChromeScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncConfiguration();
  }

  @override
  void dispose() {
    _macosWindowChromeRegistry.remove(_token);
    super.dispose();
  }

  void _syncConfiguration() {
    if (!isMacosWindowChromeEnabled) {
      return;
    }
    _macosWindowChromeRegistry.upsert(_token, widget.configuration);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final _macosWindowChromeConfiguration =
    ValueNotifier<MacosWindowChromeConfiguration>(
      const MacosWindowChromeConfiguration(),
    );
final _macosWindowChromeRegistry = _MacosWindowChromeRegistry();

final class _MacosWindowChromeRegistry {
  final LinkedHashMap<Object, MacosWindowChromeConfiguration> _entries =
      LinkedHashMap<Object, MacosWindowChromeConfiguration>();
  bool _publishScheduled = false;

  void upsert(Object token, MacosWindowChromeConfiguration configuration) {
    _entries[token] = configuration;
    _publish();
  }

  void remove(Object token) {
    if (_entries.remove(token) == null) {
      return;
    }
    _publish();
  }

  void _publish() {
    final nextValue = _entries.isEmpty
        ? const MacosWindowChromeConfiguration()
        : _entries.values.last;

    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      _macosWindowChromeConfiguration.value = nextValue;
      return;
    }

    if (_publishScheduled) {
      return;
    }

    _publishScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _publishScheduled = false;
      _macosWindowChromeConfiguration.value = _entries.isEmpty
          ? const MacosWindowChromeConfiguration()
          : _entries.values.last;
    });
  }
}

class MacosWindowChromeFrame extends StatelessWidget {
  const MacosWindowChromeFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isMacosWindowChromeEnabled) {
      return child;
    }

    return ColoredBox(
      color: AppTheme.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: macosWindowChromeHeight,
            child: _MacosWindowChromeBar(),
          ),
          Positioned.fill(top: macosWindowChromeHeight, child: child),
        ],
      ),
    );
  }
}

class _MacosWindowChromeBar extends StatelessWidget {
  const _MacosWindowChromeBar();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MacosWindowChromeConfiguration>(
      valueListenable: _macosWindowChromeConfiguration,
      builder: (context, configuration, _) {
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppTheme.surfaceZinc800.withValues(alpha: 0.96),
                      AppTheme.background.withValues(alpha: 0.9),
                    ],
                  ),
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(
                start: _macosWindowTrafficLightInset,
                end: 16,
              ),
              child: Row(
                children: [
                  _MacosWindowChromeActionStrip(
                    actions: configuration.leadingActions,
                  ),
                  const Spacer(),
                  _MacosWindowChromeActionStrip(
                    actions: configuration.trailingActions,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MacosWindowChromeActionStrip extends StatelessWidget {
  const _MacosWindowChromeActionStrip({required this.actions});

  final List<MacosWindowChromeAction> actions;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < actions.length; index++) ...[
          if (index > 0) const SizedBox(width: 6),
          _MacosWindowChromeButton(action: actions[index]),
        ],
      ],
    );
  }
}

class _MacosWindowChromeButton extends StatelessWidget {
  const _MacosWindowChromeButton({required this.action});

  final MacosWindowChromeAction action;

  @override
  Widget build(BuildContext context) {
    final foregroundColor = action.onPressed == null
        ? AppTheme.textSubtle
        : action.isActive
        ? AppTheme.textMain
        : action.tintColor;
    final backgroundColor = action.isActive
        ? AppTheme.surfaceZinc800.withValues(alpha: 0.92)
        : Colors.transparent;

    final button = MouseRegion(
      cursor: action.onPressed == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: action.key,
          borderRadius: BorderRadius.circular(8),
          onTap: action.onPressed,
          child: SizedBox(
            width: _macosWindowChromeButtonSize,
            height: _macosWindowChromeButtonSize,
            child: Center(
              child: PhosphorIcon(
                action.icon,
                size: 16,
                color: foregroundColor,
              ),
            ),
          ),
        ),
      ),
    );

    if (action.tooltip == null || action.tooltip!.isEmpty) {
      return button;
    }

    return _MacosWindowChromeTooltip(message: action.tooltip!, child: button);
  }
}

class _MacosWindowChromeTooltip extends StatefulWidget {
  const _MacosWindowChromeTooltip({required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  State<_MacosWindowChromeTooltip> createState() =>
      _MacosWindowChromeTooltipState();
}

class _MacosWindowChromeTooltipState extends State<_MacosWindowChromeTooltip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          widget.child,
          Positioned(
            top: _macosWindowChromeButtonSize + 8,
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                opacity: _hovered ? 1 : 0,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  offset: _hovered ? Offset.zero : const Offset(0, -0.12),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceZinc800,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.28),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        widget.message,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textMain,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
