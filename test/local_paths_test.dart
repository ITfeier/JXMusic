import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import 'package:jxmusic/services/local_paths.dart';

/// LocalPathsStore 单测（ADR-004 D5 / PRD REQ-1）：
/// - 首次使用 seed 默认候选并持久化；
/// - add/remove 持久化、重启保留、去重与规范化；
/// - 用户清空后不再自动 seed；
/// - 默认候选按平台探测 + 存在性过滤 + 兜底。
void main() {
  late Directory tempDir;
  late Box<dynamic> box;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('jx_paths_hive_');
    Hive.init(tempDir.path);
    box = await Hive.openBox<dynamic>('jx_settings');
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    await box.clear();
  });

  List<String> seeded() => <String>[
    p.join(tempDir.path, 'Music'),
    p.join(tempDir.path, 'Download'),
  ];

  test('首次使用：load 探测默认候选并写入 Hive；第二次 load 不再探测', () async {
    final candidates = seeded();
    final store = LocalPathsStore(
      box: box,
      defaultCandidatesProvider: () async => candidates,
    );

    expect(await store.load(), candidates, reason: '首次使用应 seed 默认候选目录');
    expect(
      box.get(LocalPathsStore.storageKey),
      candidates,
      reason: '默认候选应持久化到 jx_settings.local_scan_paths',
    );

    // 第二次 load 应直接读 Hive（若再探测会抛错）
    final store2 = LocalPathsStore(
      box: box,
      defaultCandidatesProvider: () async => throw StateError('已有配置时不应再探测默认候选'),
    );
    expect(await store2.load(), candidates);
  });

  test('add/remove：持久化、去重、路径规范化、重启后保留', () async {
    final musicDir = p.join(tempDir.path, 'Music');
    final downloadDir = p.join(tempDir.path, 'QQMusic');
    final store = LocalPathsStore(
      box: box,
      defaultCandidatesProvider: () async => <String>[musicDir],
    );

    expect(await store.load(), <String>[musicDir]);

    // 重复添加同一路径不产生重复项；带空白/结尾分隔符的路径会被规范化
    await store.add('  $musicDir  ');
    final afterAdd = await store.add('$downloadDir${Platform.pathSeparator}');
    expect(afterAdd, <String>[
      musicDir,
      downloadDir,
    ], reason: '重复目录应去重，结尾分隔符应被规范化');
    expect(await store.contains(downloadDir), isTrue);

    // 模拟重启：用同一个 Hive box 新建 store 直接读取
    final restarted = LocalPathsStore(box: box);
    expect(await restarted.load(), <String>[
      musicDir,
      downloadDir,
    ], reason: '配置应持久化，重启（新实例）后仍保留');

    // 删除一个目录后持久化
    final afterRemove = await restarted.remove(musicDir);
    expect(afterRemove, <String>[downloadDir]);
    expect(await LocalPathsStore(box: box).load(), <String>[downloadDir]);
  });

  test('用户把目录全删光后：键存在但为空，不再自动 seed', () async {
    await box.put(LocalPathsStore.storageKey, <String>[]);
    final store = LocalPathsStore(
      box: box,
      defaultCandidatesProvider: () async => throw StateError('用户清空后不应自动 seed'),
    );
    expect(await store.load(), isEmpty);
  });

  test('Hive 里是脏数据（非 List）时：回退默认候选并覆盖写回', () async {
    await box.put(LocalPathsStore.storageKey, 'not-a-list');
    final candidates = seeded();
    final store = LocalPathsStore(
      box: box,
      defaultCandidatesProvider: () async => candidates,
    );
    expect(await store.load(), candidates);
    expect(box.get(LocalPathsStore.storageKey), candidates);
  });

  test('默认候选（Android 分支）：外部目录 + 硬编码候选，只保留存在的', () async {
    final store = LocalPathsStore(
      box: box,
      isAndroid: true,
      externalStorageDirs: () async => <String>[
        '/storage/emulated/0/Android/data/com.jxmusic.jxmusic/files',
      ],
      downloadsDirectory: () async => null,
      directoryExists: (path) => !path.endsWith('QQMusic'),
    );

    final candidates = await store.defaultCandidates();
    String n(String path) => p.normalize(path);
    expect(
      candidates.first,
      n('/storage/emulated/0/Android/data/com.jxmusic.jxmusic/files'),
      reason: '应用外部目录应排在最前',
    );
    expect(candidates, contains(n('/storage/emulated/0/Music')));
    expect(candidates, contains(n('/storage/emulated/0/Download')));
    expect(candidates, contains(n('/storage/emulated/0/kgmusic/download')));
    expect(
      candidates,
      contains(n('/storage/emulated/0/netease/cloudmusic/Music')),
    );
    expect(
      candidates,
      isNot(contains(n('/storage/emulated/0/QQMusic'))),
      reason: '不存在的候选目录不应加入',
    );
  });

  test('默认候选（Windows 分支）：%USERPROFILE%\\Music 与 Downloads（存在才加）', () async {
    final home = Directory(p.join(tempDir.path, 'user_home'));
    Directory(p.join(home.path, 'Music')).createSync(recursive: true);
    Directory(p.join(home.path, 'Downloads')).createSync(recursive: true);

    final store = LocalPathsStore(
      box: box,
      isAndroid: false,
      homePath: home.path,
      externalStorageDirs: () async => const <String>[],
      downloadsDirectory: () async => null,
      applicationDocumentsDirectory: () async => null,
    );

    final candidates = await store.defaultCandidates();
    expect(candidates, <String>[
      p.join(home.path, 'Music'),
      p.join(home.path, 'Downloads'),
    ]);
  });

  test('默认候选全部不存在时：兜底应用文档目录', () async {
    final store = LocalPathsStore(
      box: box,
      isAndroid: false,
      homePath: '',
      externalStorageDirs: () async => const <String>[],
      downloadsDirectory: () async => null,
      applicationDocumentsDirectory: () async =>
          p.join(tempDir.path, 'app_documents'),
    );

    expect(await store.defaultCandidates(), <String>[
      p.join(tempDir.path, 'app_documents'),
    ]);
  });
}
