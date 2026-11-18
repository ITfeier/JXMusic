/// 音效预设（mpv `af` 音频滤镜链）。
///
/// 预设只持久化稳定 [JXAudioEffectPreset.id]，实际 mpv `af` 字符串由
/// [JXAudioEffects.afFor] 统一换算；未知 id 一律按「原声」处理，
/// 存档漂移/旧版本数据不会崩溃。
class JXAudioEffectPreset {
  const JXAudioEffectPreset({
    required this.id,
    required this.label,
    this.af,
  });

  /// 持久化用的稳定标识（'none' / 'bass' / …）。
  final String id;

  /// 设置页展示名。
  final String label;

  /// mpv `af` 滤镜链；null 表示不加滤镜（原声）。
  final String? af;
}

/// 音效预设目录（顺序即设置页展示顺序）。
///
/// 滤镜链说明（mpv `--af` 语法）：
/// - lavfi=[…] 走 FFmpeg 滤镜（bass 低架均衡 / equalizer 峰值均衡 /
///   aecho 回声 / loudnorm EBU R128 响度归一）；
/// - extrastereo 为 mpv 内建立体声展宽。
class JXAudioEffects {
  JXAudioEffects._();

  /// 原声预设 id（不加任何滤镜）。
  static const String noneId = 'none';

  static const List<JXAudioEffectPreset> presets = <JXAudioEffectPreset>[
    JXAudioEffectPreset(id: 'none', label: '原声'),
    JXAudioEffectPreset(
      id: 'bass',
      label: '重低音',
      af: 'lavfi=[bass=g=6]',
    ),
    JXAudioEffectPreset(
      id: 'vocal',
      label: '人声',
      af: 'lavfi=[equalizer=f=1200:t=q:w=1.4:g=5]',
    ),
    JXAudioEffectPreset(
      id: 'surround',
      label: '3D环绕',
      af: 'extrastereo',
    ),
    JXAudioEffectPreset(
      id: 'reverb',
      label: '演唱会',
      af: 'lavfi=[aecho=0.8:0.9:60:0.35]',
    ),
    JXAudioEffectPreset(
      id: 'loud',
      label: '响度均衡',
      af: 'lavfi=[loudnorm=I=-16:TP=-1.5:LRA=11]',
    ),
  ];

  /// id 是否为已知预设。
  static bool isValid(String id) => presets.any((p) => p.id == id);

  /// id → mpv `af` 滤镜链；原声或未知 id 返回空串
  ///（mpv `set af ""` 即清空滤镜链）。
  static String afFor(String id) {
    for (final preset in presets) {
      if (preset.id == id) return preset.af ?? '';
    }
    return '';
  }

  /// id → 展示名；未知 id 返回「原声」。
  static String labelFor(String id) {
    for (final preset in presets) {
      if (preset.id == id) return preset.label;
    }
    return '原声';
  }
}
