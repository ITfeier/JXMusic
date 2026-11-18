import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/avsession_service.dart';
import 'package:jxmusic/services/player_service.dart';

/// ohos AVSession 桥（AvSessionService + JxAvSessionManager.ets）回归测试。
///
/// 通道 'jxmusic/avsession' 双向 mock：
/// - Dart -> 原生：用 setMockMethodCallHandler 捕获 updateMetadata /
///   updatePlaybackState / startBackground / stopBackground；
/// - 原生 -> Dart：用 handlePlatformMessage 注入 play/pause/playNext/
///   playPrevious/seek，验证命令转发到 PlayerService。
///
/// Fake 播放器继承 PlayerService（initPlayer: false，不创建 mpv），覆写
/// playing/position/duration/speed getter 便于驱动状态推送，并记录
/// play/pause/next/previous/seek 调用；playSong 走真路径（非 local 且带
/// audioUrl 时不触网，mpv 为 null 直接跳过 open）。
class _FakePlayer extends PlayerService {
  _FakePlayer() : super(initPlayer: false);

  final List<String> commands = <String>[];

  bool fakePlaying = false;
  Duration fakePosition = Duration.zero;
  Duration fakeDuration = const Duration(minutes: 3);
  double fakeSpeed = 1.0;

  @override
  bool get playing => fakePlaying;

  @override
  Duration get position => fakePosition;

  @override
  Duration get duration => fakeDuration;

  @override
  double get speed => fakeSpeed;

  /// 子类内触发 notifyListeners（外部直调会有 protected 告警）。
  void emitChange() => notifyListeners();

  @override
  Future<void> play() async => commands.add('play');

  @override
  Future<void> pause() async => commands.add('pause');

  @override
  Future<void> next() async => commands.add('next');

  @override
  Future<void> previous() async => commands.add('previous');

  @override
  Future<void> seek(Duration d) async => commands.add('seek:${d.inMilliseconds}');
}

Song _song({String id = '1', String coverUrl = 'https://example.com/c.jpg'}) =>
    Song(
      id: id,
      platform: JXPlatform.qq,
      title: '桥接测试曲',
      artist: '测试歌手',
      coverUrl: coverUrl,
      audioUrl: 'https://example.com/a.mp3',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannel channel;
  late List<MethodCall> nativeCalls;

  setUp(() {
    channel = const MethodChannel('jxmusic/avsession');
    nativeCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 模拟原生侧（JxAvSessionManager）向 Flutter 下发媒体命令。
  Future<void> sendNative(MethodCall call) {
    final data = const StandardMethodCodec().encodeMethodCall(call);
    return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, data, (ByteData? _) {});
  }

  int countCalls(String method) =>
      nativeCalls.where((c) => c.method == method).length;

  group('A. 系统媒体命令转发', () {
    testWidgets('play/pause/playNext/playPrevious/seek 转发到 PlayerService',
        (tester) async {
      final player = _FakePlayer();
      final service = AvSessionService(channel);
      await service.init(player);

      await sendNative(const MethodCall('play'));
      await sendNative(const MethodCall('pause'));
      await sendNative(const MethodCall('playNext'));
      await sendNative(const MethodCall('playPrevious'));
      await sendNative(const MethodCall('seek', {'positionMs': 4200}));

      expect(player.commands,
          ['play', 'pause', 'next', 'previous', 'seek:4200']);
    });

    testWidgets('未知命令静默忽略（原生升级/降级兼容）', (tester) async {
      final player = _FakePlayer();
      final service = AvSessionService(channel);
      await service.init(player);

      await sendNative(const MethodCall('setSpeed'));
      await sendNative(const MethodCall('toggleFavorite'));

      expect(player.commands, isEmpty);
    });
  });

  group('B. 元数据与后台任务推送', () {
    testWidgets('开始播放：推送 updateMetadata + startBackground，且只推一次',
        (tester) async {
      final player = _FakePlayer();
      final service = AvSessionService(channel);
      await service.init(player);

      await player.playSong(_song());
      await tester.pump();

      expect(countCalls('updateMetadata'), 1, reason: '换歌时元数据只推一次');
      final meta = nativeCalls
          .firstWhere((c) => c.method == 'updateMetadata')
          .arguments as Map<Object?, Object?>;
      expect(meta['assetId'], '0:1');
      expect(meta['title'], '桥接测试曲');
      expect(meta['artist'], '测试歌手');
      expect(meta['durationMs'], 180000);
      expect(meta['coverUrl'], 'https://example.com/c.jpg');

      expect(countCalls('startBackground'), 1, reason: '首次播放申请后台长时任务');
      expect(player.commands, isEmpty, reason: 'AVSession 只读状态，不回打命令');
    });

    testWidgets('同一首歌重复通知不重复推元数据；清空队列释放后台任务',
        (tester) async {
      final player = _FakePlayer();
      final service = AvSessionService(channel);
      await service.init(player);

      await player.playSong(_song());
      await tester.pump();
      player.emitChange(); // 同歌重复通知（如进度 tick）
      await tester.pump();

      expect(countCalls('updateMetadata'), 1);
      expect(countCalls('startBackground'), 1);

      player.clearQueue();
      await tester.pump();

      expect(countCalls('stopBackground'), 1, reason: '清空队列时释放后台长时任务');
      expect(player.commands, isEmpty);
    });
  });

  group('C. 播放状态推送与节流', () {
    testWidgets('播放状态变化立即推；进度 tick 按约 1s 节流', (tester) async {
      final player = _FakePlayer();
      final service = AvSessionService(channel);
      await service.init(player);
      await player.playSong(_song());
      await tester.pump();
      // playSong 后已推一次 playing=false 的状态
      expect(countCalls('updatePlaybackState'), 1);

      // 开始播放：playing 变化 → 立即推
      player.fakePlaying = true;
      player.fakePosition = const Duration(milliseconds: 1000);
      player.emitChange();
      expect(countCalls('updatePlaybackState'), 2);

      // 进度 tick +200ms：节流窗口内不推
      player.fakePosition = const Duration(milliseconds: 1200);
      player.emitChange();
      expect(countCalls('updatePlaybackState'), 2);

      // 进度 tick +1000ms：达到节流阈值 → 推
      player.fakePosition = const Duration(milliseconds: 2000);
      player.emitChange();
      expect(countCalls('updatePlaybackState'), 3);

      final states = nativeCalls
          .where((c) => c.method == 'updatePlaybackState')
          .toList();
      final last = states.last.arguments as Map<Object?, Object?>;
      expect(last['playing'], true);
      expect(last['positionMs'], 2000);
      expect(last['durationMs'], 180000);
      expect(last['speed'], 1.0);
    });
  });

  group('D. 初始化幂等', () {
    testWidgets('重复 init 不重复监听（同一次播放只推一份元数据）',
        (tester) async {
      final player = _FakePlayer();
      final service = AvSessionService(channel);
      await service.init(player);
      await service.init(player);

      await player.playSong(_song());
      await tester.pump();

      expect(countCalls('updateMetadata'), 1);
      expect(countCalls('startBackground'), 1);
    });
  });

  test('supported 在非 ohos 宿主上为 false（flutter test 宿主为桌面系统）', () {
    expect(AvSessionService.supported, isFalse,
        reason: '宿主是 Windows 桌面，AVSession 仅 ohos 生效');
  });
}
