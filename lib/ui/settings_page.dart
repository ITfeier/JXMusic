import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:window_manager/window_manager.dart';
import '../core/constants.dart';
import '../providers.dart';
import '../services/api/http.dart';
import '../services/api/kugou_api.dart';
import '../services/api/music_api.dart';
import '../services/api/netease_api.dart';
import '../services/api/qq_api.dart';
import '../services/audio_effect.dart';
import '../services/tray_service.dart';
import 'glass.dart';
import 'layout.dart';

/// 设置页：主题 / 账号 / 同步 / 关于
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return ListView(
      // 顶部安全区由壳层 MobilePageSafeArea 统一避让（手机端为 0）；
      // 桌面端保持原来的 20dp，桌面布局零变化。
      padding: EdgeInsets.fromLTRB(
        16,
        jxPageTopInset(context, desktop: 20),
        16,
        30,
      ),
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 16),
          child: Text(
            '设置',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
          ),
        ),

        // ---- 外观 ----
        const _SectionLabel('外观'),
        GlassCard(
          margin: const EdgeInsets.only(bottom: 12),
          child: Column(
            children: [
              // 外观模式：跟随系统 / 浅色 / 深色（三选一胶囊）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.brightness_6_rounded,
                            size: 22,
                            color: isDark
                                ? JXColors.textOnDark
                                : JXColors.textPrimary),
                        const SizedBox(width: 14),
                        const Expanded(
                          child:
                              Text('外观模式', style: TextStyle(fontSize: 14)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        for (final (label, value) in const [
                          ('跟随系统', _ThemeModeChoice.system),
                          ('浅色', _ThemeModeChoice.light),
                          ('深色', _ThemeModeChoice.dark),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _ThemeModePill(
                              label: label,
                              value: value,
                              onChanged: (v) => _pickThemeMode(ref, v),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // 主题色：10 色扩展色板（Wrap 布局，窄屏自动换行）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.palette_rounded,
                            size: 22,
                            color: isDark
                                ? JXColors.textOnDark
                                : JXColors.textPrimary),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Text('主题色', style: TextStyle(fontSize: 14)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final c in JXThemePalette.colors)
                          GestureDetector(
                            onTap: () {
                              ref.read(themeColorProvider.notifier).state = c;
                              saveSetting('themeColor', c);
                            },
                            child: Container(
                              key: ValueKey('themeSwatch${c.toARGB32()}'),
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: ref.watch(themeColorProvider) == c
                                    ? Border.all(color: Colors.white, width: 2)
                                    : null,
                              ),
                              child: ref.watch(themeColorProvider) == c
                                  ? const Icon(Icons.check_rounded,
                                      color: Colors.white, size: 16)
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // ---- 音效 ----
        const _SectionLabel('音效'),
        GlassCard(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.graphic_eq_rounded,
                        size: 22,
                        color: isDark
                            ? JXColors.textOnDark
                            : JXColors.textPrimary),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Text('音效', style: TextStyle(fontSize: 14)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final preset in JXAudioEffects.presets)
                      _AudioEffectPill(preset: preset),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '播放中实时生效，选「原声」恢复无滤镜',
                  style: TextStyle(fontSize: 10.5, color: textSub, height: 1.4),
                ),
              ],
            ),
          ),
        ),

        // ---- 桌面（仅 Windows） ----
        if (Platform.isWindows) ...[
          const _SectionLabel('桌面'),
          GlassCard(
            margin: const EdgeInsets.only(bottom: 12),
            child: Column(
              children: [
                _SwitchTile(
                  icon: Icons.push_pin_rounded,
                  title: '窗口置顶',
                  subtitle: '让播放器始终显示在其他窗口之上',
                  value: ref.watch(alwaysOnTopProvider),
                  onChanged: (v) async {
                    ref.read(alwaysOnTopProvider.notifier).state = v;
                    saveSetting('alwaysOnTop', v);
                    await windowManager.setAlwaysOnTop(v);
                  },
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Text(
                    '快捷键：空格 播放/暂停 · ← → 快退/快进 5 秒 · ↑ ↓ 音量 · M 静音 · N/P 上一首/下一首',
                    style:
                        TextStyle(fontSize: 11, height: 1.6, color: textSub),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.logout_rounded, size: 22, color: textSub),
                  title: const Text('退出应用', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '关闭主窗口时应用会收进系统托盘，退出请用这里或托盘菜单',
                    style: TextStyle(fontSize: 11, color: textSub),
                  ),
                  trailing: Icon(Icons.chevron_right_rounded, color: textSub),
                  onTap: () => TrayService.instance.exitApp(),
                ),
              ],
            ),
          ),
        ],

        // ---- 账号与登录 ----
        const _SectionLabel('账号与登录'),
        GlassCard(
          margin: const EdgeInsets.only(bottom: 12),
          child: Column(
            children: [
              for (final p in const [0, 1, 2])
                _buildAccountTile(context, ref, p, textSub),
            ],
          ),
        ),

        // ---- 云端同步 ----
        const _SectionLabel('云端同步'),
        GlassCard(
          margin: const EdgeInsets.only(bottom: 12),
          child: Column(
            children: [
              _SwitchTile(
                icon: Icons.cloud_sync_rounded,
                title: '跨端同步',
                subtitle: 'Windows 与安卓共享歌单/收藏/历史',
                value: false,
                onChanged: (_) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('云端同步服务开发中，后续版本开放')),
                  );
                },
              ),
            ],
          ),
        ),

        // ---- 关于 ----
        const _SectionLabel('关于'),
        GlassCard(
          child: Column(
            children: [
              ListTile(
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [JXColors.primary, JXColors.accentCyan],
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.graphic_eq_rounded,
                      color: Colors.white, size: 24),
                ),
                title: const Text(JXConstants.appName,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                subtitle: Text(
                  'v0.10.0 · 聚合 QQ音乐 / 网易云 / 酷狗 / 本地',
                  style: TextStyle(fontSize: 11, color: textSub),
                ),
                trailing: const Text('预览版',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 账号登录行：网易云/QQ/酷狗 均已接入官方扫码登录
  Widget _buildAccountTile(BuildContext context, WidgetRef ref, int p,
      Color textSub) {
    final account = ref.watch(accountProvider(p));
    final loggedIn = account != null;
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: JXPlatform.color(p).withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        child: Icon(
          p == 0
              ? Icons.music_note_rounded
              : p == 1
                  ? Icons.graphic_eq_rounded
                  : Icons.headphones_rounded,
          color: JXPlatform.color(p),
          size: 20,
        ),
      ),
      title: Text(
        '${JXPlatform.name(p)} 登录',
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        loggedIn ? '已登录：${account.nickname}' : '扫码登录，可播放 VIP 歌曲',
        style: TextStyle(fontSize: 11, color: textSub),
      ),
      trailing: _StatusBadge(
        text: loggedIn ? '已登录' : '未登录',
        active: loggedIn,
      ),
      onTap: () => _onAccountTap(context, ref, p, loggedIn),
    );
  }
}

/// 账号行点击：未登录走扫码，已登录弹退出确认。
/// 登录态已持久化到 Hive，退出会同时清掉 Hive 存档和平台客户端 cookie。
Future<void> _onAccountTap(
    BuildContext context, WidgetRef ref, int platform, bool loggedIn) async {
  if (!loggedIn) {
    await _showQrLogin(context, ref, platform);
    return;
  }
  final name = JXPlatform.name(platform);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('退出$name登录'),
      content: const Text('退出后需要重新扫码才能播放该平台的 VIP 歌曲。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('退出登录'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  ref.read(accountProvider(platform).notifier).logout();
  ref.read(musicHubProvider).api(platform)?.restoreSession(null);
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('已退出$name登录')));
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

/// 外观模式三选一：跟随系统 / 浅色 / 深色。
enum _ThemeModeChoice { system, light, dark }

/// 选择外观模式并持久化：
/// - system：只开「跟随系统」，深色开关保留当前值（关掉跟随后回到该值）；
/// - light/dark：关掉「跟随系统」，同时写深色开关。
void _pickThemeMode(WidgetRef ref, _ThemeModeChoice value) {
  switch (value) {
    case _ThemeModeChoice.system:
      ref.read(followSystemThemeProvider.notifier).state = true;
      saveSetting('followSystemTheme', true);
    case _ThemeModeChoice.light:
      ref.read(followSystemThemeProvider.notifier).state = false;
      saveSetting('followSystemTheme', false);
      ref.read(darkModeProvider.notifier).state = false;
      saveSetting('darkMode', false);
    case _ThemeModeChoice.dark:
      ref.read(followSystemThemeProvider.notifier).state = false;
      saveSetting('followSystemTheme', false);
      ref.read(darkModeProvider.notifier).state = true;
      saveSetting('darkMode', true);
  }
}

/// 音效预设胶囊：选中填主题色，未选中走液态玻璃表面；
/// 点击即切换 mpv 音频滤镜（PlayerService.setAudioEffect）。
class _AudioEffectPill extends ConsumerWidget {
  const _AudioEffectPill({required this.preset});

  final JXAudioEffectPreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected =
        ref.watch(playerServiceProvider).audioEffect == preset.id;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => ref.read(playerServiceProvider).setAudioEffect(preset.id),
      behavior: HitTestBehavior.opaque,
      child: Container(
        key: ValueKey('audioEffectPill_${preset.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? JXColors.primary
              : (isDark ? JXColors.glassDark : JXColors.glassLight)
                  .withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? JXColors.primary
                : (isDark
                    ? JXColors.glassStrokeDark
                    : JXColors.glassStrokeLight),
          ),
        ),
        child: Text(
          preset.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected
                ? Colors.white
                : (isDark
                    ? JXColors.textOnDarkSecondary
                    : JXColors.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// 外观模式胶囊：选中填主题色，未选中走液态玻璃表面。
class _ThemeModePill extends ConsumerWidget {
  const _ThemeModePill({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final _ThemeModeChoice value;
  final ValueChanged<_ThemeModeChoice> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final followSystem = ref.watch(followSystemThemeProvider);
    final dark = ref.watch(darkModeProvider);
    final current = followSystem
        ? _ThemeModeChoice.system
        : (dark ? _ThemeModeChoice.dark : _ThemeModeChoice.light);
    final selected = current == value;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => onChanged(value),
      behavior: HitTestBehavior.opaque,
      child: Container(
        key: ValueKey('themeModePill_${value.name}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? JXColors.primary
              : (isDark ? JXColors.glassDark : JXColors.glassLight)
                  .withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? JXColors.primary
                : (isDark
                    ? JXColors.glassStrokeDark
                    : JXColors.glassStrokeLight),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected
                ? Colors.white
                : (isDark
                    ? JXColors.textOnDarkSecondary
                    : JXColors.textSecondary),
          ),
        ),
      ),
    );
  }
}


class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final sub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;
    return SwitchListTile(
      secondary: Icon(icon, size: 22, color: color),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 11, color: sub)),
      value: value,
      activeThumbColor: JXColors.primary,
      onChanged: onChanged,
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String text;
  final bool active;
  const _StatusBadge({required this.text, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: (active ? JXColors.primary : Colors.grey)
            .withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: active ? JXColors.primary : Colors.grey,
        ),
      ),
    );
  }
}

/// 打开平台扫码登录对话框（网易云/QQ/酷狗 通用），成功后写入对应登录态
Future<void> _showQrLogin(BuildContext context, WidgetRef ref, int platform) async {
  final api = ref.read(musicHubProvider).api(platform);
  if (api == null) return;
  final account = await showDialog<AccountSession>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _QrLoginDialog(
        api: api,
        title: '${JXPlatform.name(platform)}扫码登录',
        // QQ：说明一键登录为何不可用 + 单设备扫码技巧（截图后相册选图）
        footnote: platform == 0
            ? 'QQ 一键登录需腾讯专用 SDK 且不对三方应用开放，暂仅支持扫码：'
                '请用另一台手机的 QQ 扫码确认；'
                '仅一部手机时，可截图本二维码 → 手机 QQ「扫一扫」→ 右下角'
                '「相册」选择该截图完成确认'
            : null,
        // 网易云/酷狗支持账号密码登录：扫码弹窗里提供切换入口；QQ 仅扫码
        onSwitchToPassword: (platform == 1 || platform == 2)
            ? () => _showPasswordLogin(context, ref, platform)
            : null),
  );
  if (account == null || !context.mounted) return;
  // 持久化登录态（Hive）+ 同步平台客户端 cookie，重启后依然有效
  ref.read(accountProvider(platform).notifier).login(account);
  ref.read(musicHubProvider).api(platform)?.restoreSession(account);
  // 诊断日志：登录成功后刷新一次 provider 状态，确认内存态确实已更新
  final persisted = ref.read(accountProvider(platform));
  debugPrint('[JXMusic][扫码登录] 登录态已写入：platform=$platform '
      'nickname=${persisted?.nickname ?? '-'} '
      'cookies=${persisted?.cookies.length ?? 0} '
      'lastError=${api.lastError ?? '-'}');
  // 降级登录（如酷狗 token 交换失败）时接口层会写 lastError，这里如实提示用户
  final warning = api.lastError;
  final name = JXPlatform.name(platform);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(warning != null && warning.trim().isNotEmpty
          ? '$name 已登录（${account.nickname}），但$warning'
          : '$name登录成功：${account.nickname}'),
    ),
  );
}

/// 平台扫码登录对话框（玻璃卡片风格）
/// 兼容两种二维码载体：网易云为二维码文本，QQ 为官方返回的二维码图片（data URI）
class _QrLoginDialog extends StatefulWidget {
  final MusicPlatformApi api;
  final String title;

  /// 底部说明文案（如 QQ 一键登录不可用的原因），不需要时传 null
  final String? footnote;

  /// 切换到账号密码登录的回调（不支持账密的平台传 null）
  final VoidCallback? onSwitchToPassword;
  const _QrLoginDialog({
    required this.api,
    required this.title,
    this.footnote,
    this.onSwitchToPassword,
  });

  @override
  State<_QrLoginDialog> createState() => _QrLoginDialogState();
}

class _QrLoginDialogState extends State<_QrLoginDialog> {
  String? _qrData;
  String _hint = '加载二维码中...';
  Timer? _timer;
  int _polls = 0;
  bool _done = false;

  /// 轮询互斥：兑换登录态最长 10~20 秒，2 秒定时器不能在兑换未完成时再发一次，
  /// 否则同一酷狗 token / QQ ptsigx 可能被并发兑换多次，或先落降级会话、后到成功结果。
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _create();
  }

  Future<void> _create() async {
    try {
      final created = await widget.api.createQrLogin();
      if (!mounted || _done) return;
      debugPrint('[JXMusic][扫码登录] 取码完成：qrUrl ${created.qrUrl.isEmpty ? '空' : '已生成'}'
          '，key 长度=${created.key.length}');
      if (created.qrUrl.isEmpty) {
        setState(() => _hint = _failHint());
        debugPrint('[JXMusic][扫码登录] 取码失败：$_hint');
        return;
      }
      setState(() {
        _qrData = created.qrUrl;
        _hint = '请使用对应平台 App 扫码登录';
      });
      _timer = Timer.periodic(
          const Duration(seconds: 2), (_) => _poll(created.key));
    } catch (e) {
      if (!mounted) return;
      // 隐私（QA D-01）：不打印原始异常串（可能含请求 URL/参数），只打接口层原因或异常类型
      debugPrint('[JXMusic][扫码登录] 取码异常：'
          '${widget.api.lastError ?? e.runtimeType}');
      setState(() => _hint = _failHint());
    }
  }

  /// 各平台取码失败的提示：优先用接口层回报的具体原因（lastError），
  /// 避免笼统的"二维码获取失败"或写死 403/502。
  String _failHint() {
    final detail = widget.api.lastError;
    if (detail != null && detail.trim().isNotEmpty) return detail;
    if (widget.api is QQMusicApi) {
      return 'QQ 二维码获取失败：请检查网络后重试（QQ 扫码接口偶发风控）';
    }
    if (widget.api is KuGouApi) {
      return '酷狗二维码获取失败：请检查网络后重试（酷狗登录接口可能变更）';
    }
    return '二维码获取失败，请重试';
  }

  Future<void> _poll(String key) async {
    if (_done || _polling) return;
    if (_polls >= 60) {
      _timer?.cancel();
      final detail = widget.api.lastError;
      debugPrint('[JXMusic][扫码登录] 轮询超时（2 分钟）：'
          'lastError=${detail ?? '-'}');
      setState(() => _hint = detail != null && detail.trim().isNotEmpty
          ? detail
          : '二维码已过期，请关闭后重试');
      return;
    }
    _polls++;
    _polling = true;
    try {
      final session = await widget.api.pollQrLogin(key);
      if (!mounted || _done) return;
      if (session != null) {
        _done = true;
        _timer?.cancel();
        debugPrint('[JXMusic][扫码登录] 轮询成功：'
            'nickname=${session.nickname} cookies=${session.cookies.length}');
        Navigator.of(context).pop(session);
        return;
      }
      // QQ：轮询已拿到 code=0（扫码已在服务端确认）而 API 仍返回 null，
      // 说明本轮兑换已执行且失败；必须停止轮询，否则同一二维码会被
      // 2 秒定时器反复兑换（2026-11-09 实扫观测到连续兑换 5+ 次）。
      if (widget.api is QQMusicApi &&
          (widget.api as QQMusicApi).qrScanConfirmed) {
        _done = true;
        _timer?.cancel();
        final detail = widget.api.lastError;
        debugPrint('[JXMusic][扫码登录] QQ 扫码已确认但兑换失败，停止轮询：'
            'lastError=${detail ?? '-'}');
        setState(() => _hint = detail != null && detail.trim().isNotEmpty
            ? detail
            : 'QQ 扫码已确认，但换取登录态失败，请关闭后重新获取二维码');
        return;
      }
      // 等待态不覆盖提示；接口层明确报错（如过期/参数变更）时展示准确原因，
      // 错误恢复（重新进入等待态）后把提示复位，避免旧错误文案残留。
      // 网易云 802「已扫码待确认」通过 qrHint 展示，不当成错误。
      final hint =
          widget.api is NeteaseApi ? (widget.api as NeteaseApi).qrHint : null;
      final error = widget.api.lastError;
      if (error != null && error.isNotEmpty) {
        setState(() => _hint = error);
      } else if (hint != null && hint.isNotEmpty) {
        setState(() => _hint = hint);
      } else if (_hint != '请使用对应平台 App 扫码登录') {
        setState(() => _hint = '请使用对应平台 App 扫码登录');
      }
    } catch (e) {
      // 单次轮询失败不再静默：优先展示接口层原因，否则给出网络层原因（下一轮会自动重试）
      final detail = widget.api.lastError;
      // 隐私（QA D-01）：日志不打印原始异常串（可能含请求 URL），只打类型/接口层原因
      debugPrint('[JXMusic][扫码登录] 轮询异常：${detail ?? '-'}'
          '（${e.runtimeType}）');
      if (!mounted) return;
      setState(() => _hint = detail != null && detail.trim().isNotEmpty
          ? detail
          : '扫码登录轮询失败：${e.runtimeType}（正在自动重试）');
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _buildQr() {
    final data = _qrData;
    if (data == null) {
      return const Center(
          child: CircularProgressIndicator(color: JXColors.primary));
    }
    if (data.startsWith('data:image/')) {
      // QQ 官方二维码图片（base64 data URI）
      final comma = data.indexOf(',');
      if (comma > 0) {
        try {
          final bytes = base64Decode(data.substring(comma + 1));
          return Image.memory(bytes, width: 184, height: 184, fit: BoxFit.contain);
        } catch (_) {
          // fallthrough 按文本渲染
        }
      }
    }
    return QrImageView(
      data: data,
      version: QrVersions.auto,
      size: 184,
      backgroundColor: Colors.white,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 320,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        decoration: BoxDecoration(
          color: isDark ? JXColors.glassDark : JXColors.glassLight,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isDark
                ? JXColors.glassStrokeDark
                : JXColors.glassStrokeLight,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            Container(
              width: 200,
              height: 200,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: _buildQr(),
            ),
            const SizedBox(height: 14),
            Text(_hint,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500)),
            if (widget.footnote != null) ...[
              const SizedBox(height: 6),
              Text(widget.footnote!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 10, color: Colors.grey)),
            ],
            if (widget.onSwitchToPassword != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: TextButton(
                  onPressed: () {
                    _timer?.cancel();
                    Navigator.of(context).pop();
                    widget.onSwitchToPassword!();
                  },
                  child: const Text('使用账号密码登录',
                      style: TextStyle(fontSize: 12)),
                ),
              ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 打开账号密码登录对话框（网易云手机号/邮箱、酷狗账号/手机号），成功后写入登录态
Future<void> _showPasswordLogin(
    BuildContext context, WidgetRef ref, int platform) async {
  final api = ref.read(musicHubProvider).api(platform);
  if (api == null) return;
  final account = await showDialog<AccountSession>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PasswordLoginDialog(api: api, platform: platform),
  );
  if (account == null || !context.mounted) return;
  // 持久化登录态（Hive）+ 同步平台客户端 cookie，与扫码登录同一落盘链路
  ref.read(accountProvider(platform).notifier).login(account);
  ref.read(musicHubProvider).api(platform)?.restoreSession(account);
  final name = JXPlatform.name(platform);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('$name登录成功：${account.nickname}')),
  );
}

/// 账号密码登录对话框（玻璃卡片风格；密码仅用于本次请求，不落盘）
class _PasswordLoginDialog extends StatefulWidget {
  final MusicPlatformApi api;
  final int platform;
  const _PasswordLoginDialog({required this.api, required this.platform});

  @override
  State<_PasswordLoginDialog> createState() => _PasswordLoginDialogState();
}

class _PasswordLoginDialogState extends State<_PasswordLoginDialog> {
  final TextEditingController _user = TextEditingController();
  final TextEditingController _pwd = TextEditingController();
  // 手机验证码登录（酷狗 /v7/send_mobile_code + login_by_verifycode；
  // 网易云 weapi /sms/captcha/sent + eapi login/cellphone captcha）
  final TextEditingController _smsMobile = TextEditingController();
  final TextEditingController _smsCode = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _smsMode = false;
  bool _sending = false;
  int _countdown = 0;
  Timer? _countdownTimer;

  @override
  void dispose() {
    _user.dispose();
    _pwd.dispose();
    _smsMobile.dispose();
    _smsCode.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  /// 酷狗发送短信验证码，成功后 60 秒倒计时防重发
  Future<void> _sendCode() async {
    if (_sending || _countdown > 0) return;
    final mobile = _smsMobile.text.trim();
    if (mobile.isEmpty) {
      setState(() => _error = '请输入手机号');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    bool ok = false;
    try {
      ok = await widget.api.sendSmsCode(mobile);
    } catch (e) {
      debugPrint('[JXMusic][验证码登录] 发码异常：${e.runtimeType}');
    }
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _sending = false;
        _error = widget.api.lastError ?? '验证码发送失败，请稍后重试';
      });
      return;
    }
    setState(() {
      _sending = false;
      _countdown = 60;
      _error = null;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) t.cancel();
    });
  }

  Future<void> _submit() async {
    if (_loading) return;
    if (_smsMode) {
      final mobile = _smsMobile.text.trim();
      final code = _smsCode.text.trim();
      if (mobile.isEmpty || code.isEmpty) {
        setState(() => _error = '请输入手机号和验证码');
        return;
      }
      setState(() {
        _loading = true;
        _error = null;
      });
      AccountSession? session;
      try {
        session = await widget.api.loginBySmsCode(mobile, code);
      } catch (e) {
        debugPrint('[JXMusic][验证码登录] 异常：${e.runtimeType}');
      }
      if (!mounted) return;
      if (session == null) {
        setState(() {
          _loading = false;
          _error = widget.api.lastError ?? '登录失败，请稍后重试';
        });
        return;
      }
      Navigator.of(context).pop(session);
      return;
    }
    final user = _user.text.trim();
    final pwd = _pwd.text;
    if (user.isEmpty || pwd.isEmpty) {
      setState(() =>
          _error = '请输入${widget.platform == 1 ? '手机号' : '账号'}和密码');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    AccountSession? session;
    try {
      session = await widget.api.loginByPassword(user, pwd);
    } catch (e) {
      // 隐私（QA D-01）：不打印原始异常串（可能含请求参数），只打异常类型
      debugPrint('[JXMusic][账密登录] 异常：${e.runtimeType}');
    }
    if (!mounted) return;
    if (session == null) {
      setState(() {
        _loading = false;
        _error = widget.api.lastError ?? '登录失败，请稍后重试';
      });
      return;
    }
    Navigator.of(context).pop(session);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isNetease = widget.platform == 1;
    final isKugou = widget.platform == 2;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 320,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        decoration: BoxDecoration(
          color: isDark ? JXColors.glassDark : JXColors.glassLight,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isDark
                ? JXColors.glassStrokeDark
                : JXColors.glassStrokeLight,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${JXPlatform.name(widget.platform)}账号登录',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            // 酷狗 / 网易云支持密码、手机验证码两种方式，顶部提供切换
            if (isKugou || isNetease) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _modeChip('密码登录', !_smsMode, () {
                    if (!_smsMode) return;
                    setState(() {
                      _smsMode = false;
                      _error = null;
                    });
                  }),
                  const SizedBox(width: 8),
                  _modeChip('验证码登录', _smsMode, () {
                    if (_smsMode) return;
                    setState(() {
                      _smsMode = true;
                      _error = null;
                    });
                  }),
                ],
              ),
            ],
            const SizedBox(height: 18),
            if (_smsMode) ...[
              TextField(
                controller: _smsMobile,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: '手机号',
                  hintText: isNetease ? '网易云绑定的手机号' : '酷狗账号绑定的手机号',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _smsCode,
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(
                        labelText: '验证码',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed:
                        (_sending || _countdown > 0) ? null : _sendCode,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(96, 48),
                    ),
                    child: Text(
                      _sending
                          ? '发送中'
                          : (_countdown > 0 ? '${_countdown}s' : '获取验证码'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isNetease
                    ? '验证码将发送到网易云账号绑定的手机号；若提示网络环境风险'
                        '（-460），请切换网络（如手机流量）后重试'
                    : '验证码将发送到酷狗账号绑定的手机号，部分未绑定手机号的'
                        '账号请改用密码或扫码登录',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ] else ...[
              TextField(
                controller: _user,
                keyboardType:
                    isNetease ? TextInputType.phone : TextInputType.text,
                decoration: InputDecoration(
                  labelText: isNetease ? '手机号' : '账号 / 手机号',
                  hintText: isNetease ? '中国大陆手机号，也可输入邮箱' : '酷狗账号或手机号',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pwd,
                obscureText: true,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: '密码',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isNetease
                    ? '账号需已在网易云 App 设置过密码；若提示网络环境风险，'
                        '请切换网络（如手机流量）重试或改用扫码登录'
                    : '账号需已在酷狗 App 设置过密码，否则请改用扫码登录',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFFE5484D))),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _loading ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: JXColors.primary,
                foregroundColor: Colors.white,
              ),
              child: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('登录'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _loading ? null : () => Navigator.of(context).pop(),
              child: const Text('取消', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  /// 登录方式切换标签（选中高亮主题色）
  Widget _modeChip(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: active ? JXColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? JXColors.primary : Colors.grey),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : Colors.grey,
          ),
        ),
      ),
    );
  }
}
