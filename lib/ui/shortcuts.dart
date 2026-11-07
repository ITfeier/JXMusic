import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// 桌面端快捷键（全局）：
/// 空格 / 媒体播放键 = 播放暂停，←/→ = 快退/快进 5 秒，↑/↓ = 音量，
/// M = 静音，N/P = 下一首/上一首。
///
/// 搜索框等输入控件获得焦点时不拦截按键，避免影响输入。
class JXKeyboardShortcuts extends ConsumerStatefulWidget {
  final Widget child;

  const JXKeyboardShortcuts({super.key, required this.child});

  @override
  ConsumerState<JXKeyboardShortcuts> createState() =>
      _JXKeyboardShortcutsState();
}

class _JXKeyboardShortcutsState extends ConsumerState<JXKeyboardShortcuts> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool _isEditingText() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext != null && focusContext.widget is EditableText;
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (_isEditingText()) return false;

    final player = ref.read(playerServiceProvider);
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      player.toggle();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      player.seek(player.position + const Duration(seconds: 5));
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      final target = player.position - const Duration(seconds: 5);
      player.seek(target < Duration.zero ? Duration.zero : target);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      player.setVolume(player.volume + 5);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      player.setVolume(player.volume - 5);
      return true;
    }
    if (key == LogicalKeyboardKey.keyM) {
      player.toggleMute();
      return true;
    }
    if (key == LogicalKeyboardKey.keyN ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      player.next();
      return true;
    }
    if (key == LogicalKeyboardKey.keyP ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      player.previous();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
