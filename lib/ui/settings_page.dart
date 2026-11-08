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
import '../services/api/qq_api.dart';
import '../services/tray_service.dart';
import 'glass.dart';

/// 设置页：主题 / 账号 / 同步 / 关于
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub =
        isDark ? JXColors.textOnDarkSecondary : JXColors.textSecondary;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 30),
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
              _SwitchTile(
                icon: Icons.dark_mode_rounded,
                title: '深色模式',
                subtitle: 'iOS26 液态玻璃在深色下效果最佳',
                value: ref.watch(darkModeProvider),
                onChanged: (v) {
                  ref.read(darkModeProvider.notifier).state = v;
                  saveSetting('darkMode', v);
                },
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
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
                    for (final c in const [
                      Color(0xFF5B8DEF),
                      Color(0xFFD43C33),
                      Color(0xFF31C27C),
                      Color(0xFFF26B8A),
                      Color(0xFF7C6FF0),
                    ])
                      GestureDetector(
                        onTap: () {
                          ref.read(themeColorProvider.notifier).state = c;
                          saveSetting('themeColor', c);
                        },
                        child: Container(
                          width: 26,
                          height: 26,
                          margin: const EdgeInsets.only(left: 6),
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
              ),
            ],
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
                  'v0.9.6 · 聚合 QQ音乐 / 网易云 / 酷狗 / 本地',
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

/// 打开平台扫码登录对话框（网易云/QQ 通用），成功后写入对应登录态
Future<void> _showQrLogin(BuildContext context, WidgetRef ref, int platform) async {
  final api = ref.read(musicHubProvider).api(platform);
  if (api == null) return;
  final account = await showDialog<AccountSession>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _QrLoginDialog(
        api: api, title: '${JXPlatform.name(platform)}扫码登录'),
  );
  if (account == null || !context.mounted) return;
  // 持久化登录态（Hive）+ 同步平台客户端 cookie，重启后依然有效
  ref.read(accountProvider(platform).notifier).login(account);
  ref.read(musicHubProvider).api(platform)?.restoreSession(account);
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
  const _QrLoginDialog({required this.api, required this.title});

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
      if (created.qrUrl.isEmpty) {
        setState(() => _hint = _failHint());
        return;
      }
      setState(() {
        _qrData = created.qrUrl;
        _hint = '请使用对应平台 App 扫码登录';
      });
      _timer = Timer.periodic(
          const Duration(seconds: 2), (_) => _poll(created.key));
    } catch (_) {
      if (!mounted) return;
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
      setState(() => _hint = '二维码已过期，请关闭后重试');
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
        Navigator.of(context).pop(session);
        return;
      }
      // 等待态不覆盖提示；接口层明确报错（如过期/参数变更）时展示准确原因，
      // 错误恢复（重新进入等待态）后把提示复位，避免旧错误文案残留。
      final error = widget.api.lastError;
      if (error != null && error.isNotEmpty) {
        setState(() => _hint = error);
      } else if (_hint != '请使用对应平台 App 扫码登录') {
        setState(() => _hint = '请使用对应平台 App 扫码登录');
      }
    } catch (_) {
      // 单次轮询失败忽略，继续下一轮
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
