import 'dart:io';

import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';

/// 本地音乐扫描目录配置的持久化封装（ADR-004 D5）。
///
/// 配置存在 Hive `jx_settings` 的 [storageKey]（`List<String>`）：
/// - [load]：读取配置；该键从未写过（首次使用）时探测默认候选目录并落盘；
/// - [add] / [remove] / [save]：增删并立即持久化，返回最新列表；
/// - [defaultCandidates]：按平台给默认候选（存在的目录才加入）。
///
/// 为便于单测，Box、目录存在判断、平台判定、主目录与 path_provider 目录来源
/// 均可注入；不注入时使用真实实现（Hive + dart:io + path_provider）。
class LocalPathsStore {
  LocalPathsStore({
    this.box,
    this.directoryExists,
    this.isAndroid,
    this.homePath,
    this.externalStorageDirs,
    this.downloadsDirectory,
    this.applicationDocumentsDirectory,
    this.defaultCandidatesProvider,
  });

  /// Hive 里存扫描目录列表的键。
  static const String storageKey = 'local_scan_paths';

  /// 可注入的 Hive Box（默认 `JXConstants.hiveBoxSettings` 的 jx_settings）。
  final Box<dynamic>? box;

  /// 目录存在性判断（默认 `Directory(path).existsSync()`）。
  final bool Function(String path)? directoryExists;

  /// 平台判定注入（默认 `Platform.isAndroid`），便于在桌面跑 Android 分支单测。
  final bool? isAndroid;

  /// 用户主目录注入（默认 `%USERPROFILE%` / `$HOME`）。
  final String? homePath;

  /// 应用外部存储目录来源注入（默认 `getExternalStorageDirectories()`）。
  final Future<List<String>> Function()? externalStorageDirs;

  /// 下载目录来源注入（默认 `getDownloadsDirectory()`）。
  final Future<String?> Function()? downloadsDirectory;

  /// 兜底的应用文档目录来源注入（默认 `getApplicationDocumentsDirectory()`）。
  final Future<String?> Function()? applicationDocumentsDirectory;

  /// 默认候选整体覆盖注入（单测/自定义场景）。
  final Future<List<String>> Function()? defaultCandidatesProvider;

  Box<dynamic> get _settingsBox =>
      box ?? Hive.box<dynamic>(JXConstants.hiveBoxSettings);

  bool get _android {
    final override = isAndroid;
    if (override != null) return override;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  String get _home {
    final override = homePath;
    if (override != null) return override;
    try {
      return Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';
    } catch (_) {
      return '';
    }
  }

  /// 读取已配置目录。
  ///
  /// 首次使用（Hive 里没有该键）时探测默认候选并持久化；用户把目录全删光
  /// （键存在但为空）时尊重用户选择，不再自动 seed。
  /// Hive 未初始化/读失败时退回默认候选，保证页面仍可展示。
  Future<List<String>> load() async {
    List<String>? stored;
    try {
      final raw = _settingsBox.get(storageKey);
      stored = _asPathList(raw);
    } catch (_) {
      stored = null;
    }
    if (stored != null) return stored;

    final candidates = await defaultCandidates();
    if (candidates.isEmpty) return const <String>[];
    try {
      await save(candidates);
    } catch (_) {
      // Hive 不可用时仍返回候选，只是不持久化
    }
    return candidates;
  }

  /// 覆盖保存目录列表（自动规范化、去重、去空）。
  Future<void> save(List<String> paths) async {
    final normalized = <String>[];
    for (final raw in paths) {
      final path = _normalize(raw);
      if (path.isEmpty || normalized.contains(path)) continue;
      normalized.add(path);
    }
    await _settingsBox.put(storageKey, normalized);
  }

  /// 添加一个目录（已存在则忽略），返回最新列表。
  Future<List<String>> add(String path) async {
    final target = _normalize(path);
    final paths = await load();
    if (target.isEmpty) return paths;
    if (!paths.contains(target)) {
      paths.add(target);
      await save(paths);
    }
    return paths;
  }

  /// 删除一个目录，返回最新列表。
  Future<List<String>> remove(String path) async {
    final target = _normalize(path);
    final paths = await load();
    final before = paths.length;
    paths.removeWhere((e) => e == target || e == path.trim());
    if (paths.length != before) {
      await save(paths);
    }
    return paths;
  }

  /// 是否已配置某个目录。
  Future<bool> contains(String path) async {
    final target = _normalize(path);
    if (target.isEmpty) return false;
    final paths = await load();
    return paths.any((e) => _normalize(e) == target);
  }

  /// 默认候选目录（按平台探测；只保留真实存在的目录）。
  ///
  /// - Android：应用外部目录 + `/storage/emulated/0/{Music,Download,QQMusic,kgmusic/download,netease/cloudmusic/Music}`；
  /// - Windows/桌面：`%USERPROFILE%\\Music`、`%USERPROFILE%\\Downloads`；
  /// - 再补 path_provider 的下载目录；全部候选都不存在时兜底应用文档目录。
  Future<List<String>> defaultCandidates() async {
    final override = defaultCandidatesProvider;
    if (override != null) return _dedupe(await override());

    final raw = <String>[];

    // 1) 应用外部存储目录（Android 上通常是 Android/data/<pkg>/files）
    final externalDirsProvider = externalStorageDirs;
    try {
      final dirs = externalDirsProvider != null
          ? await externalDirsProvider()
          : (await getExternalStorageDirectories())
                    ?.map((d) => d.path)
                    .toList() ??
                const <String>[];
      raw.addAll(dirs);
    } catch (_) {}

    // 2) 平台常用目录
    if (_android) {
      raw.addAll(const <String>[
        '/storage/emulated/0/Music',
        '/storage/emulated/0/Download',
        '/storage/emulated/0/QQMusic',
        '/storage/emulated/0/kgmusic/download',
        '/storage/emulated/0/netease/cloudmusic/Music',
      ]);
    } else {
      final home = _home;
      if (home.isNotEmpty) {
        raw.add(p.join(home, 'Music'));
        raw.add(p.join(home, 'Downloads'));
      }
    }

    // 3) path_provider 下载目录
    final downloadsProvider = downloadsDirectory;
    try {
      final downloads = downloadsProvider != null
          ? await downloadsProvider()
          : (await getDownloadsDirectory())?.path;
      if (downloads != null && downloads.isNotEmpty) raw.add(downloads);
    } catch (_) {}

    // 4) 存在性过滤 + 去重（保持顺序）
    final existing = <String>[];
    for (final candidate in raw) {
      final path = _normalize(candidate);
      if (path.isEmpty || existing.contains(path)) continue;
      bool exists = false;
      try {
        exists = (directoryExists ?? _existsDirectory)(path);
      } catch (_) {
        exists = false;
      }
      if (exists) existing.add(path);
    }
    if (existing.isNotEmpty) return existing;

    // 5) 兜底：应用文档目录
    final docsProvider = applicationDocumentsDirectory;
    try {
      final docs = docsProvider != null
          ? await docsProvider()
          : (await getApplicationDocumentsDirectory()).path;
      final path = _normalize(docs ?? '');
      if (path.isNotEmpty) return <String>[path];
    } catch (_) {}
    return const <String>[];
  }

  static bool _existsDirectory(String path) {
    try {
      return Directory(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  static String _normalize(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    try {
      return p.normalize(trimmed);
    } catch (_) {
      return trimmed;
    }
  }

  static List<String> _dedupe(List<String> paths) {
    final out = <String>[];
    for (final raw in paths) {
      final path = _normalize(raw);
      if (path.isEmpty || out.contains(path)) continue;
      out.add(path);
    }
    return out;
  }

  /// Hive 返回值可能是 `List<dynamic>`（也可能被写成其它类型），统一转成路径列表；
  /// 类型不对返回 null，让调用方走默认候选。
  static List<String>? _asPathList(Object? raw) {
    if (raw is! List) return null;
    final out = <String>[];
    for (final item in raw) {
      if (item is! String) continue;
      final path = _normalize(item);
      if (path.isEmpty || out.contains(path)) continue;
      out.add(path);
    }
    return out;
  }
}
