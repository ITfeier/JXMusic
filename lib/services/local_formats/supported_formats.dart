/// 本地音乐支持的音频扩展名清单（扫描识别与 UI 文案共用）。
class LocalAudioFormats {
  LocalAudioFormats._();

  /// 直接交给播放器（libmpv）的常见格式。
  static const Set<String> commonExtensions = {
    'mp3',
    'flac',
    'm4a',
    'aac',
    'ogg',
    'opus',
    'wav',
    'wma',
    'ape',
    'aiff',
    'aif',
    'dsf',
    'dff',
    'mka',
  };

  /// 三大平台加密格式（需要解码后才能播放）。
  static const Set<String> encryptedExtensions = {
    // 网易云
    'ncm',
    // QQ 音乐 QMC 系（v1 静态 / v2 嵌密钥）
    'qmc0',
    'qmc2',
    'qmc3',
    'qmcflac',
    'qmcogg',
    'mflac',
    'mflac0',
    'mgg',
    'mgg1',
    'bkcmp3',
    'bkcflac',
    'tkm',
    '666c6163',
    '6d7033',
    '6f6767',
    '6d3461',
    '776176',
    // 酷狗 KGM / KGMA / VPR，以及 KGG（cryptoVersion=5，仅识别后提示暂不支持）
    'kgm',
    'kgma',
    'vpr',
    'kgg',
  };

  /// 可扫描的全部扩展名。
  static Set<String> get allExtensions => {
    ...commonExtensions,
    ...encryptedExtensions,
  };

  static bool isCommon(String ext) =>
      commonExtensions.contains(ext.toLowerCase());

  static bool isEncrypted(String ext) =>
      encryptedExtensions.contains(ext.toLowerCase());

  /// 给 UI 展示的平台来源标签（识别不出返回 null）。
  static String? platformLabel(String ext) {
    switch (ext.toLowerCase()) {
      case 'ncm':
        return '网易云加密';
      case 'kgm':
      case 'kgma':
      case 'vpr':
      case 'kgg':
        return '酷狗加密';
      default:
        if (encryptedExtensions.contains(ext.toLowerCase())) return 'QQ加密';
        return null;
    }
  }
}
