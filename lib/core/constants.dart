import 'package:flutter/material.dart';

/// JXMusic 全局主题色
class JXColors {
  /// 主品牌色（液态玻璃高光青）
  static const Color primary = Color(0xFF5B8DEF);
  static const Color accent = Color(0xFF7C6FF0);
  static const Color accentCyan = Color(0xFF4FD8F5);
  static const Color accentPink = Color(0xFFF26B8A);

  /// 液态玻璃表面（浅色模式）
  static const Color glassLight = Color(0xCCFFFFFF);
  static const Color glassStrokeLight = Color(0x66FFFFFF);

  /// 液态玻璃表面（深色模式）
  static const Color glassDark = Color(0x33FFFFFF);
  static const Color glassStrokeDark = Color(0x22FFFFFF);

  static const Color bgLight = Color(0xFFE9EEF7);
  static const Color bgDark = Color(0xFF10141C);

  static const Color textPrimary = Color(0xFF1A1F29);
  static const Color textSecondary = Color(0x991A1F29);
  static const Color textOnDark = Color(0xFFF2F5FA);
  static const Color textOnDarkSecondary = Color(0xB3F2F5FA);
}

/// 平台常量
class JXPlatform {
  static const int qq = 0;
  static const int netease = 1;
  static const int kugou = 2;
  static const int local = 3;

  static String name(int platform) {
    switch (platform) {
      case qq:
        return 'QQ音乐';
      case netease:
        return '网易云音乐';
      case kugou:
        return '酷狗音乐';
      case local:
        return '本地音乐';
      default:
        return '未知';
    }
  }

  static Color color(int platform) {
    switch (platform) {
      case qq:
        return Color(0xFF31C27C);
      case netease:
        return Color(0xFFD43C33);
      case kugou:
        return Color(0xFF2A9EFB);
      case local:
        return JXColors.accentCyan;
      default:
        return JXColors.primary;
    }
  }
}

/// 应用级常量
class JXConstants {
  static const String appName = 'JXMusic';
  static const String syncServerBase = 'https://jx.sync.example.com/api';
  static const String dbName = 'jxmusic.db';
  static const String hiveBoxLibrary = 'jx_library';
  static const String hiveBoxSettings = 'jx_settings';
  static const String hiveBoxHistory = 'jx_history';
  static const String hiveBoxPlaylists = 'jx_playlists';
  static const String hiveBoxAccounts = 'jx_accounts';
  static const int maxHistory = 200;
}
