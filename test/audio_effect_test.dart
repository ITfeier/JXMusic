import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/providers.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/audio_effect.dart';
import 'package:jxmusic/services/player_service.dart';
import 'package:jxmusic/ui/settings_page.dart';

/// 音效设置（todo#7）：
/// - A. 预设目录映射：afFor / labelFor / isValid（纯逻辑）；
/// - B. PlayerService.setAudioEffect：未知 id 忽略、重复设置跳过、
///      onSettingChanged 回调契约（initPlayer:false 不加载原生库）；
/// - C. 设置页音效区：6 预设胶囊渲染 + 点击切换（override playerServiceProvider，
///      不接 onSettingChanged → 不写 Hive，可在 testWidgets 里安全跑）；
/// - D. 持久化往返：onSettingChanged 落 Hive → 重启以 initialAudioEffect 恢复
///      （plain test 真实 async，写 Hive 安全；testWidgets 内才禁止写 Hive）。
void main() {
  late Directory tempDir;
  late Box<dynamic> settingsBox;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('jx_audio_effect_hive_');
    Hive.init(tempDir.path);
    settingsBox = await Hive.openBox<dynamic>(JXConstants.hiveBoxSettings);
    await Hive.openBox<Map>(JXConstants.hiveBoxAccounts);
  });

  tearDownAll(() async {
    // 不 await Hive.close()（theme_settings_test 实测：testWidgets 结束后
    // await 该 box 的操作会卡死），残留临时目录留给系统清理。
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('A. 预设目录映射（纯逻辑）', () {
    test('afFor：6 预设 → mpv af 滤镜链；原声/未知 → 空串', () {
      expect(JXAudioEffects.afFor('none'), '');
      expect(JXAudioEffects.afFor('bass'), 'lavfi=[bass=g=6]');
      expect(JXAudioEffects.afFor('vocal'),
          'lavfi=[equalizer=f=1200:t=q:w=1.4:g=5]');
      expect(JXAudioEffects.afFor('surround'), 'extrastereo');
      expect(JXAudioEffects.afFor('reverb'), 'lavfi=[aecho=0.8:0.9:60:0.35]');
      expect(JXAudioEffects.afFor('loud'),
          'lavfi=[loudnorm=I=-16:TP=-1.5:LRA=11]');
      // 未知 id / 旧版本存档漂移 → 空串（按原声处理，不崩溃）
      expect(JXAudioEffects.afFor('unknown'), '');
      expect(JXAudioEffects.afFor(''), '');
    });

    test('labelFor / isValid：目录完整，未知 id 兜底原声', () {
      expect(JXAudioEffects.presets.length, 6, reason: '音效应为 6 个预设');
      for (final preset in JXAudioEffects.presets) {
        expect(JXAudioEffects.isValid(preset.id), isTrue,
            reason: '${preset.id} 应为合法预设');
        expect(preset.label, isNotEmpty);
      }
      expect(JXAudioEffects.labelFor('none'), '原声');
      expect(JXAudioEffects.labelFor('bass'), '重低音');
      expect(JXAudioEffects.labelFor('unknown'), '原声',
          reason: '未知 id 展示名兜底原声');
      expect(JXAudioEffects.isValid('unknown'), isFalse);
      // 预设 id 不重复（持久化键唯一性）
      final ids = JXAudioEffects.presets.map((p) => p.id).toSet();
      expect(ids.length, JXAudioEffects.presets.length);
    });
  });

  group('B. PlayerService.setAudioEffect（initPlayer:false）', () {
    test('构造：合法 initialAudioEffect 采纳，非法兜底原声', () {
      final ok = PlayerService(initialAudioEffect: 'bass', initPlayer: false);
      expect(ok.audioEffect, 'bass');
      final bad = PlayerService(initialAudioEffect: 'garbage', initPlayer: false);
      expect(bad.audioEffect, JXAudioEffects.noneId,
          reason: '非法初始值应兜底原声');
    });

    test('切换：更新状态并回调 onSettingChanged；重复/非法设置不回调', () async {
      final changes = <(String, dynamic)>[];
      final player = PlayerService(
        onSettingChanged: (key, value) => changes.add((key, value)),
        initPlayer: false,
      );
      expect(player.audioEffect, JXAudioEffects.noneId);

      await player.setAudioEffect('bass');
      expect(player.audioEffect, 'bass');
      expect(changes, [('audioEffect', 'bass')]);

      // 同一预设再点：跳过，不产生第二次回调
      await player.setAudioEffect('bass');
      expect(changes.length, 1);

      // 非法 id：忽略，状态与回调都不变
      await player.setAudioEffect('garbage');
      expect(player.audioEffect, 'bass');
      expect(changes.length, 1);

      // 切回原声：同样走回调（'' 清空 mpv 滤镜链）
      await player.setAudioEffect('none');
      expect(player.audioEffect, JXAudioEffects.noneId);
      expect(changes, [('audioEffect', 'bass'), ('audioEffect', 'none')]);
    });
  });

  group('C. 设置页音效区（testWidgets，不写 Hive）', () {
    Future<ProviderContainer> pumpSettings(WidgetTester tester) async {
      final container = ProviderContainer(overrides: [
        musicHubProvider.overrideWithValue(MusicApiHub()),
        playerServiceProvider.overrideWith(
            (ref) => PlayerService(initPlayer: false)),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(brightness: Brightness.dark),
            home: const Scaffold(body: SettingsPage()),
          ),
        ),
      );
      await tester.pump();
      return container;
    }

    testWidgets('结构：6 预设胶囊齐全，默认原声选中', (tester) async {
      tester.view.physicalSize = const Size(1080, 3600); // 360×1200dp 全量可见
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await pumpSettings(tester);

      expect(find.text('音效'), findsWidgets,
          reason: '音效 section 标题应渲染');
      for (final preset in JXAudioEffects.presets) {
        expect(
          find.byKey(ValueKey('audioEffectPill_${preset.id}')),
          findsOneWidget,
          reason: '预设 ${preset.id}（${preset.label}）胶囊应渲染',
        );
      }
      expect(find.text('重低音'), findsOneWidget);
      expect(find.text('响度均衡'), findsOneWidget);
    });

    testWidgets('交互：点重低音 → audioEffect=bass；点原声 → 恢复 none', (tester) async {
      tester.view.physicalSize = const Size(1080, 3600);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final container = await pumpSettings(tester);
      expect(container.read(playerServiceProvider).audioEffect,
          JXAudioEffects.noneId);

      await tester.tap(find.byKey(const ValueKey('audioEffectPill_bass')));
      await tester.pump();
      expect(container.read(playerServiceProvider).audioEffect, 'bass');

      await tester.tap(find.byKey(const ValueKey('audioEffectPill_none')));
      await tester.pump();
      expect(container.read(playerServiceProvider).audioEffect,
          JXAudioEffects.noneId);
    });
  });

  group('D. 持久化往返（plain test 真实写 Hive）', () {
    test('onSettingChanged 落 Hive → initialAudioEffect 重启恢复', () async {
      await settingsBox.clear();

      // 模拟 providers.dart 的 onSettingChanged: saveSetting 接线
      Future<void> saveSetting(String key, dynamic value) async {
        await settingsBox.put(key, value);
      }

      final first = PlayerService(
        onSettingChanged: (key, value) => saveSetting(key, value),
        initPlayer: false,
      );
      await first.setAudioEffect('reverb');
      expect(settingsBox.get('audioEffect'), 'reverb',
          reason: '音效预设应持久化到 jx_settings');

      // 重启：按存档恢复（providers.dart initialAudioEffect 接线）
      final saved = settingsBox.get('audioEffect');
      final restored = PlayerService(
        initialAudioEffect:
            saved is String ? saved : JXAudioEffects.noneId,
        initPlayer: false,
      );
      expect(restored.audioEffect, 'reverb');
    });
  });
}
