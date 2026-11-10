import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/constants.dart';
import '../models/song.dart';
import '../services/local_format_service.dart';
import '../services/local_formats/format_decoder.dart';
import '../services/local_music.dart';
import '../services/local_paths.dart';
import 'dir_browser.dart';
import 'glass.dart';
import 'layout.dart';

/// 播放队列回调：由外层（providers/playback 集成方）注入，页面不直接依赖播放链路。
typedef PlayQueueCallback = void Function(List<Song> queue, int index);

/// 本地音乐页（自定义多目录扫描 + 加密格式解密播放）。
///
/// 依赖全部通过构造函数注入，便于 widget 测试用 fake 替换（不碰真实 Hive/文件系统）：
/// - [musicService]：多目录扫描；
/// - [formatService]：加密格式判断/解密/缓存；
/// - [pathsStore]：扫描目录配置持久化；
/// - [playQueue]：播放动作回调（播放全部/点击歌曲）。
///
/// `providers.dart` / `playback.dart` 的挂接由集成方负责（本页不 import 播放逻辑）。
class LocalPage extends StatefulWidget {
  const LocalPage({
    super.key,
    this.musicService,
    this.formatService,
    this.pathsStore,
    this.playQueue,
    this.autoScan = true,
    this.androidOverride,
    this.permissionChecker,
    this.permissionRequester,
  });

  final LocalMusicService? musicService;
  final LocalFormatService? formatService;
  final LocalPathsStore? pathsStore;
  final PlayQueueCallback? playQueue;

  /// 打开页面后是否自动扫描已配置目录（PRD：「下次打开自动扫描」）。
  /// 测试可关掉以避免异步时序干扰。
  final bool autoScan;

  /// 仅测试用：强制按 Android 平台渲染权限相关 UI。
  final bool? androidOverride;

  /// 仅测试用：注入「所有文件访问」权限查询/请求。
  final Future<bool> Function()? permissionChecker;
  final Future<bool> Function()? permissionRequester;

  @override
  State<LocalPage> createState() => _LocalPageState();
}

class _LocalPageState extends State<LocalPage> with WidgetsBindingObserver {
  late final LocalMusicService _musicService;
  late final LocalFormatService _formatService;
  late final LocalPathsStore _pathsStore;

  List<String> _scanPaths = const <String>[];
  final List<Song> _songs = <Song>[];
  final List<ScanPathError> _scanErrors = <ScanPathError>[];
  bool _initialized = false;
  bool _loading = false;
  bool _hasFileAccess = true;
  bool _requestingPermission = false;
  int _found = 0;
  String? _fatalError;

  bool get _isAndroid =>
      widget.androidOverride ??
      (defaultTargetPlatform == TargetPlatform.android);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pathsStore = widget.pathsStore ?? LocalPathsStore();
    _musicService =
        widget.musicService ?? LocalMusicService(pathsStore: _pathsStore);
    _formatService =
        widget.formatService ??
        LocalFormatService(decoders: const <EncryptedAudioDecoder>[]);
    _hasFileAccess = !_isAndroid;
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isAndroid) {
      unawaited(_onResumed());
    }
  }

  Future<void> _onResumed() async {
    if (!_isAndroid) return;
    // manageExternalStorage.request() 跳系统设置后返回值不可信：回到前台必须
    // 重新复核授权状态并刷新横幅（ADR-004 v1.0 D6 / 评审 R-7）。
    await _refreshPermission();
    if (!mounted || !_hasFileAccess || _loading) return;
    if (_songs.isEmpty && _scanPaths.isNotEmpty) await _scan();
  }

  Future<void> _init() async {
    await _refreshPermission();
    List<String> paths = const <String>[];
    try {
      paths = await _pathsStore.load();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _scanPaths = paths;
      _initialized = true;
    });
    if (widget.autoScan && paths.isNotEmpty && _hasFileAccess) {
      await _scan();
    }
  }

  Future<void> _refreshPermission() async {
    if (!_isAndroid) {
      if (mounted) setState(() => _hasFileAccess = true);
      return;
    }
    var granted = false;
    try {
      granted =
          await (widget.permissionChecker ?? _checkFileAccessPermission)();
    } catch (_) {
      granted = false;
    }
    if (!mounted) return;
    setState(() => _hasFileAccess = granted);
  }

  Future<void> _requestPermission() async {
    if (_requestingPermission) return;
    setState(() => _requestingPermission = true);
    try {
      await (widget.permissionRequester ?? _requestFileAccessPermission)();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _requestingPermission = false);
    // 请求的返回值不可信：立即复核一次；从系统授权页返回时
    // AppLifecycleState.resumed 还会再复核一次并刷新横幅。
    await _refreshPermission();
    if (!mounted || !_hasFileAccess) return;
    // 授权后刷新目录并自动扫描
    if (_scanPaths.isEmpty) {
      List<String> paths = const <String>[];
      try {
        paths = await _pathsStore.load();
      } catch (_) {}
      if (!mounted) return;
      setState(() => _scanPaths = paths);
    }
    await _scan();
  }

  /// 任意路径扫描的权限门禁（ADR-004 D6 / R-7 + 评审 R-19）：
  /// - Android 11+：唯一门禁是「所有文件访问」（manageExternalStorage）；
  /// - Android 10 及以下没有该权限，退回存储权限（storage）；
  /// - 两者任一 granted 即视为已授权；非 Android 平台由调用方直接跳过。
  static Future<bool> _checkFileAccessPermission() async {
    try {
      if (await Permission.manageExternalStorage.isGranted) return true;
    } catch (_) {}
    // Android 10 及以下的退路；API 30+ 上 storage 会被系统直接拒绝，无害。
    try {
      return await Permission.storage.isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _requestFileAccessPermission() async {
    // 先申请「所有文件访问」（Android 11+），未授权再退回存储权限（Android 10-）。
    // request() 跳系统设置，返回值不可信，真实结果由 onResume 复核后刷新横幅。
    try {
      if ((await Permission.manageExternalStorage.request()).isGranted) {
        return true;
      }
    } catch (_) {}
    try {
      if ((await Permission.storage.request()).isGranted) return true;
    } catch (_) {}
    return false;
  }

  Future<void> _scan() async {
    if (_loading) return;
    if (_scanPaths.isEmpty) {
      if (!mounted) return;
      setState(() {
        _songs.clear();
        _scanErrors.clear();
        _fatalError = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _found = 0;
      _fatalError = null;
      _scanErrors.clear();
    });
    try {
      final result = await _musicService.scanDirectories(
        _scanPaths,
        onProgress: (found) {
          if (mounted && _loading) setState(() => _found = found);
        },
      );
      if (!mounted) return;
      setState(() {
        _songs
          ..clear()
          ..addAll(result.songs);
        _scanErrors
          ..clear()
          ..addAll(result.errors);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _fatalError = '扫描失败：${_errorText(e)}';
      });
    }
  }

  /// 播放列表第 [index] 首：加密歌曲先解密（带进度），失败弹原因，成功后回调播放。
  Future<void> _playAt(int index) async {
    if (index < 0 || index >= _songs.length) return;
    final song = _songs[index];
    final path = song.audioUrl ?? '';
    final encrypted = path.isNotEmpty && _formatService.isEncryptedPath(path);
    if (!encrypted) {
      widget.playQueue?.call(List<Song>.of(_songs), index);
      return;
    }

    Object? result;
    try {
      result = await showDialog<Object?>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _DecryptProgressDialog(song: song, formatService: _formatService),
      );
    } catch (e) {
      result = e;
    }
    if (!mounted) return;

    if (result is File) {
      // 解密成功（返回缓存文件路径）：QMC/KGM 首次播放后回填标签并刷新列表
      // （ADR-004 D4 / 评审 R-17）；audioUrl 仍保留源文件路径。
      try {
        final enriched = await _musicService.enrichFromDecrypted(song, result);
        if (mounted && index < _songs.length) {
          setState(() => _songs[index] = enriched);
        }
      } catch (e) {
        debugPrint('[JXMusic] 回填加密歌曲标签失败: $e');
      }
      if (!mounted) return;
      // 播放回调传「原始列表 + 原始索引」，Song.audioUrl 保留源路径，
      // 解密结果由播放链路 resolver 命中缓存。
      widget.playQueue?.call(List<Song>.of(_songs), index);
      return;
    }
    if (result != null) {
      final message = result is FormatDecodeException
          ? result.message
          : '解密失败：${_errorText(result)}';
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('无法播放'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    widget.playQueue?.call(List<Song>.of(_songs), index);
  }

  Future<int> _safeCacheBytes() async {
    try {
      return await _formatService.cacheSizeBytes();
    } catch (_) {
      return 0;
    }
  }

  Future<int> _safeCacheCount() async {
    try {
      return await _formatService.cacheFileCount();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _openDirectorySheet() async {
    final cacheBytes = await _safeCacheBytes();
    final cacheCount = await _safeCacheCount();
    List<String> quickPaths = _scanPaths;
    try {
      quickPaths = await _pathsStore.defaultCandidates();
    } catch (_) {}
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DirectoryManagerSheet(
        paths: _scanPaths,
        quickPaths: quickPaths,
        cacheBytes: cacheBytes,
        cacheCount: cacheCount,
        onAddPath: _addPath,
        onRemovePath: _removePath,
        onScan: _scan,
        onClearCache: _formatService.clearCache,
      ),
    );
  }

  Future<List<String>> _addPath(String path) async {
    try {
      final updated = await _pathsStore.add(path);
      if (mounted) setState(() => _scanPaths = List<String>.of(updated));
      return updated;
    } catch (e) {
      debugPrint('[JXMusic] 添加扫描目录失败: $e');
      return List<String>.of(_scanPaths);
    }
  }

  Future<List<String>> _removePath(String path) async {
    try {
      final updated = await _pathsStore.remove(path);
      if (mounted) setState(() => _scanPaths = List<String>.of(updated));
      return updated;
    } catch (e) {
      debugPrint('[JXMusic] 删除扫描目录失败: $e');
      return List<String>.of(_scanPaths);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? JXColors.textOnDark : JXColors.textPrimary;
    final textSub = isDark
        ? JXColors.textOnDarkSecondary
        : JXColors.textSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // 顶部安全区由壳层 MobilePageSafeArea 统一避让（手机端为 0）；
          // 桌面端保持原来的 20dp，桌面布局零变化。
          padding: EdgeInsets.fromLTRB(
            20,
            jxPageTopInset(context, desktop: 20),
            16,
            4,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '本地音乐',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _headerSummary(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: textSub),
                    ),
                  ],
                ),
              ),
              GlassButton(
                text: '扫描目录',
                icon: Icons.folder_open_rounded,
                onPressed: _openDirectorySheet,
              ),
            ],
          ),
        ),
        if (_isAndroid && !_hasFileAccess) _buildPermissionBanner(textColor),
        Expanded(child: _buildBody(textColor, textSub)),
      ],
    );
  }

  String _headerSummary() {
    if (!_initialized) return '正在读取扫描目录…';
    if (_loading) return '正在扫描…已发现 $_found 首';
    if (_scanPaths.isEmpty) return '未配置扫描目录，点「扫描目录」添加';
    return '${_scanPaths.length} 个目录 · ${_songs.length} 首';
  }

  Widget _buildPermissionBanner(Color textColor) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: JXColors.accentPink.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: JXColors.accentPink.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.folder_shared_outlined,
            size: 18,
            color: JXColors.accentPink,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '需要「所有文件访问」权限才能扫描自定义目录',
              style: TextStyle(fontSize: 12, color: textColor, height: 1.3),
            ),
          ),
          TextButton(
            onPressed: _requestingPermission ? null : _requestPermission,
            child: const Text('去授权', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(Color textColor, Color textSub) {
    if (!_initialized) {
      return const Center(
        child: CircularProgressIndicator(color: JXColors.primary),
      );
    }
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: JXColors.primary),
            const SizedBox(height: 14),
            Text(
              '正在扫描…已发现 $_found 首',
              style: TextStyle(fontSize: 13, color: textSub),
            ),
          ],
        ),
      );
    }
    if (_fatalError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _fatalError!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.redAccent),
          ),
        ),
      );
    }

    final children = <Widget>[];
    if (_scanErrors.isNotEmpty) children.add(_buildErrors(textSub));
    if (_songs.isEmpty) {
      children.add(_buildEmpty(textColor, textSub));
    } else {
      children.add(_buildPlayAllRow(textSub));
      for (var i = 0; i < _songs.length; i++) {
        children.add(_buildSongTile(i, textColor, textSub));
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      children: children,
    );
  }

  Widget _buildErrors(Color textSub) {
    const shown = 5;
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 16,
                color: JXColors.accentPink,
              ),
              const SizedBox(width: 6),
              Text(
                '部分目录扫描失败（${_scanErrors.length}）',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          for (final error in _scanErrors.take(shown))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${error.path}\n${error.message}',
                style: TextStyle(fontSize: 10.5, color: textSub, height: 1.35),
              ),
            ),
          if (_scanErrors.length > shown)
            Text(
              '…还有 ${_scanErrors.length - shown} 条错误',
              style: TextStyle(fontSize: 10.5, color: textSub),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty(Color textColor, Color textSub) {
    return Padding(
      padding: const EdgeInsets.only(top: 56, left: 20, right: 20),
      child: Column(
        children: [
          Icon(Icons.library_music_outlined, size: 56, color: textSub),
          const SizedBox(height: 12),
          Text(
            '未发现音乐文件',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点右上角「扫描目录」添加音乐目录后重新扫描；'
            '支持 NCM/QMC/MFLAC/MGG/KGM/VPR 解密播放',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: textSub, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayAllRow(Color textSub) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 6),
      child: Row(
        children: [
          GlassButton(
            text: '播放全部',
            icon: Icons.play_arrow_rounded,
            primary: true,
            height: 38,
            onPressed: () => _playAt(0),
          ),
          const SizedBox(width: 10),
          Text(
            '共 ${_songs.length} 首',
            style: TextStyle(fontSize: 12, color: textSub),
          ),
        ],
      ),
    );
  }

  Widget _buildSongTile(int index, Color textColor, Color textSub) {
    final song = _songs[index];
    final path = song.audioUrl ?? '';
    final encrypted = path.isNotEmpty && _formatService.isEncryptedPath(path);
    final encryptionLabel = encrypted
        ? (_formatService.platformLabel(path) ?? '加密格式')
        : null;
    // `.kgg`（KGM cryptoVersion=5）离线无解：列表可见并标「暂不支持」，
    // 点击播放由解码器抛中文原因，页面照常弹窗（ADR-004 D7 / 评审 R-16）。
    final unsupportedKgg =
        encrypted && _formatService.extensionOf(path) == 'kgg';
    final chipText = encrypted
        ? '$encryptionLabel · ${unsupportedKgg ? '暂不支持' : '需解密'}'
        : null;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: GlassCover(
        url: song.coverUrl,
        size: 44,
        borderRadius: BorderRadius.circular(10),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: textColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (chipText != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: JXColors.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: JXColors.primary.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                chipText,
                style: const TextStyle(fontSize: 9.5, color: JXColors.primary),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        '${song.artist} · ${song.album}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: textSub),
      ),
      trailing: GlassIconButton(
        icon: Icons.play_arrow_rounded,
        size: 36,
        color: JXColors.primary,
        onPressed: () => _playAt(index),
      ),
      onTap: () => _playAt(index),
    );
  }

  static String _errorText(Object error) {
    if (error is FormatDecodeException) return error.message;
    return '$error';
  }
}

/// 解密进度对话框：解密成功 pop(null)，失败 pop(异常)。
class _DecryptProgressDialog extends StatefulWidget {
  const _DecryptProgressDialog({
    required this.song,
    required this.formatService,
  });

  final Song song;
  final LocalFormatService formatService;

  @override
  State<_DecryptProgressDialog> createState() => _DecryptProgressDialogState();
}

class _DecryptProgressDialogState extends State<_DecryptProgressDialog> {
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final file = await widget.formatService.ensureDecrypted(
        widget.song,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress.clamp(0.0, 1.0).toDouble());
        },
      );
      if (mounted) Navigator.of(context).pop(file);
    } catch (e) {
      if (mounted) Navigator.of(context).pop(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final percent = (_progress * 100).clamp(0, 100).toStringAsFixed(0);
    return AlertDialog(
      title: const Text('正在解密…'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: _progress <= 0 ? null : _progress,
            color: JXColors.primary,
            backgroundColor: JXColors.primary.withValues(alpha: 0.15),
          ),
          const SizedBox(height: 8),
          Text('$percent%', style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}

/// 音乐目录管理底部弹层：已配置目录增删、缓存占用清理、开始扫描。
class _DirectoryManagerSheet extends StatefulWidget {
  const _DirectoryManagerSheet({
    required this.paths,
    required this.quickPaths,
    required this.cacheBytes,
    required this.cacheCount,
    required this.onAddPath,
    required this.onRemovePath,
    required this.onScan,
    required this.onClearCache,
  });

  final List<String> paths;
  final List<String> quickPaths;
  final int cacheBytes;
  final int cacheCount;
  final Future<List<String>> Function(String path) onAddPath;
  final Future<List<String>> Function(String path) onRemovePath;
  final Future<void> Function() onScan;
  final Future<int> Function() onClearCache;

  @override
  State<_DirectoryManagerSheet> createState() => _DirectoryManagerSheetState();
}

class _DirectoryManagerSheetState extends State<_DirectoryManagerSheet> {
  late List<String> _paths;
  late int _cacheBytes;
  late int _cacheCount;

  @override
  void initState() {
    super.initState();
    _paths = List<String>.of(widget.paths);
    _cacheBytes = widget.cacheBytes;
    _cacheCount = widget.cacheCount;
  }

  Future<void> _addFromBrowser() async {
    final picked = await showDirectoryPickerDialog(
      context,
      initialPath: _paths.isNotEmpty ? _paths.first : null,
      quickPaths: widget.quickPaths,
    );
    if (picked == null || picked.trim().isEmpty) return;
    await _add(picked.trim());
  }

  Future<void> _addFromInput() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => const _ManualPathInputDialog(),
    );
    if (value == null || value.isEmpty) return;
    await _add(value);
  }

  Future<void> _add(String path) async {
    try {
      final updated = await widget.onAddPath(path);
      if (!mounted) return;
      setState(() => _paths = List<String>.of(updated));
    } catch (e) {
      debugPrint('[JXMusic] 添加目录失败: $e');
    }
  }

  Future<void> _remove(String path) async {
    try {
      final updated = await widget.onRemovePath(path);
      if (!mounted) return;
      setState(() => _paths = List<String>.of(updated));
    } catch (e) {
      debugPrint('[JXMusic] 删除目录失败: $e');
    }
  }

  Future<void> _clearCache() async {
    try {
      await widget.onClearCache();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _cacheBytes = 0;
      _cacheCount = 0;
    });
  }

  void _startScan() {
    Navigator.of(context).pop();
    unawaited(widget.onScan());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSub = isDark
        ? JXColors.textOnDarkSecondary
        : JXColors.textSecondary;
    final sheetHeight = (MediaQuery.of(context).size.height * 0.78).clamp(
      320.0,
      640.0,
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: SizedBox(
          height: sheetHeight,
          child: GlassCard(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '音乐目录管理',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    GlassIconButton(
                      icon: Icons.close_rounded,
                      size: 30,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '扫描以下目录并合并去重；加密格式解密后才能播放',
                  style: TextStyle(fontSize: 11, color: textSub),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _paths.isEmpty
                      ? Center(
                          child: Text(
                            '还没有添加扫描目录',
                            style: TextStyle(fontSize: 12, color: textSub),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _paths.length,
                          itemBuilder: (context, index) {
                            final path = _paths[index];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(
                                Icons.folder_rounded,
                                size: 20,
                                color: JXColors.primary,
                              ),
                              title: Text(
                                path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 20,
                                ),
                                tooltip: '删除目录',
                                onPressed: () => _remove(path),
                              ),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    GlassButton(
                      text: '开始扫描',
                      icon: Icons.search_rounded,
                      primary: true,
                      height: 38,
                      onPressed: _paths.isEmpty ? null : _startScan,
                    ),
                    GlassButton(
                      text: '浏览目录…',
                      icon: Icons.folder_open_rounded,
                      height: 38,
                      onPressed: _addFromBrowser,
                    ),
                    GlassButton(
                      text: '手动输入',
                      icon: Icons.keyboard_rounded,
                      height: 38,
                      onPressed: _addFromInput,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(
                      Icons.sd_storage_rounded,
                      size: 16,
                      color: JXColors.accentCyan,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '解密缓存：${_formatBytes(_cacheBytes)} · $_cacheCount 个文件',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: textSub),
                      ),
                    ),
                    TextButton(
                      onPressed: _clearCache,
                      child: const Text('清理', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                Text(
                  '支持加密格式：NCM（网易云）/ QMC、MFLAC、MGG（QQ）/ '
                  'KGM、VPR（酷狗）；解密结果只缓存在本机，不上传。',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: textSub,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 手动输入目录对话框（controller 由本 widget 持有，避免退场动画期间被 dispose）。
class _ManualPathInputDialog extends StatefulWidget {
  const _ManualPathInputDialog();

  @override
  State<_ManualPathInputDialog> createState() => _ManualPathInputDialogState();
}

class _ManualPathInputDialogState extends State<_ManualPathInputDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('手动输入目录'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: '例如 /storage/emulated/0/Music 或 D:\\Music',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('添加'),
        ),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = <String>['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final decimals = unitIndex == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
}
