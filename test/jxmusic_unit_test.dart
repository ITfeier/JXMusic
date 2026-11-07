import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/core/constants.dart';
import 'package:jxmusic/models/lyric.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/download_service.dart';

void main() {
  test('AccountSession 可 JSON 往返（登录态持久化依赖）', () {
    const session = AccountSession(
      platform: 1,
      cookies: {'MUSIC_U': 'abc123', '__csrf': 'xyz'},
      nickname: '测试用户',
    );
    final restored = AccountSession.fromJson(session.toJson());
    expect(restored.platform, 1);
    expect(restored.cookies, session.cookies);
    expect(restored.nickname, '测试用户');
    expect(restored.avatarUrl, isNull);
  });

  test('AccountSession.fromJson 对缺字段存档做容错', () {
    final session = AccountSession.fromJson({'platform': 2});
    expect(session.platform, 2);
    expect(session.cookies, isEmpty);
    expect(session.nickname, '');
  });

  test('LRC 歌词解析：毫秒换算正确且按时间排序', () {
    final lines = LyricParser.parseLrc(
      '[00:01.50]第一句\n[00:03.00]第三句\n[00:02.00]第二句',
    );
    expect(lines.length, 3);
    expect(lines[0].time, 1500);
    expect(lines[1].time, 2000);
    expect(lines[2].time, 3000);
    expect(lines[1].text, '第二句');
  });

  test('下载文件名：过滤非法字符并保留扩展名', () {
    const song = Song(
      id: 'x',
      platform: JXPlatform.netease,
      title: '晴天 / 现场版',
      artist: '周杰伦',
    );
    final name = DownloadService.buildFileName(
      song,
      url: 'https://m8.music.126.net/a/b/xyz.mp3?x=1',
    );
    expect(name, '周杰伦 - 晴天 _ 现场版.mp3');
    expect(name.contains('/'), isFalse);
  });

  test('下载文件名：无标题时有兜底且默认 .mp3', () {
    const song = Song(id: 'y', platform: JXPlatform.qq, title: '', artist: '');
    final name = DownloadService.buildFileName(song, url: '');
    expect(name, '未命名.mp3');
  });

  test('各平台下载请求头带正确 Referer', () {
    expect(DownloadService.headersFor(JXPlatform.qq)['Referer'],
        'https://y.qq.com/');
    expect(DownloadService.headersFor(JXPlatform.netease)['Referer'],
        'https://music.163.com/');
    expect(DownloadService.headersFor(JXPlatform.kugou)['Referer'],
        'https://m.kugou.com/');
    expect(DownloadService.headersFor(JXPlatform.local), isEmpty);
  });
}
