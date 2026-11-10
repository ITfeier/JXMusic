import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/qq_api.dart';

/// R1.1 QQ 歌词请求回归：
/// 根因是 `getLyrics` 未带 `Referer: https://y.qq.com/`，JXHttp 全局默认
/// Referer 是 music.163.com → QQ 接口返回 `{"retcode":-1310}`，歌词恒为空。
/// 这里用 Dio 假适配器锁死请求头与响应处理（真实形态 JSON 夹具）。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonBody(Object payload) => ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

Song _song(String id) =>
    Song(id: id, platform: 0, title: '测试歌曲', artist: '测试歌手');

void main() {
  final api = QQMusicApi();
  late HttpClientAdapter originalAdapter;

  setUp(() {
    originalAdapter = JXHttp.dio.httpClientAdapter;
  });

  tearDown(() {
    // 恢复真实适配器，避免污染其它测试
    JXHttp.dio.httpClientAdapter = originalAdapter;
  });

  group('请求头与参数', () {
    test('必须带 Referer: https://y.qq.com/（根因回归）', () async {
      final fake = _FakeAdapter((_) async => _jsonBody({
            'retcode': 0,
            'lyric': '[00:01.00]第一句\r\n[00:02.00]第二句',
          }));
      JXHttp.dio.httpClientAdapter = fake;

      final text = await api.getLyrics(_song('0039MnYb0qxYhV'));

      expect(fake.requests, hasLength(1));
      final request = fake.requests.single;
      final referer = '${request.headers['Referer'] ?? ''}';
      expect(referer, contains('y.qq.com'),
          reason: '缺 y.qq.com Referer 时 QQ 返回 retcode=-1310，歌词为空');
      expect(referer, isNot(contains('music.163.com')));
      // 接口路径与核心参数
      expect(request.uri.host, 'c.y.qq.com');
      expect(request.uri.path, '/lyric/fcgi-bin/fcg_query_lyric_new.fcg');
      expect('${request.queryParameters['songmid']}', '0039MnYb0qxYhV');
      expect('${request.queryParameters['format']}', 'json');
      // 返回非空 LRC，可被解析器消费
      expect(text, contains('[00:01.00]第一句'));
    });
  });

  group('响应兜底', () {
    test('lyric 为 base64 时自动解码为 UTF-8 LRC', () async {
      const lrc = '[00:02.50]世界';
      final fake = _FakeAdapter((_) async => _jsonBody({
            'retcode': 0,
            'lyric': base64Encode(utf8.encode(lrc)),
          }));
      JXHttp.dio.httpClientAdapter = fake;

      final text = await api.getLyrics(_song('x'));
      expect(text, lrc, reason: '服务端忽略 nobase64=1 时返回 base64，必须解码');
    });

    test('base64 带换行（MIME 形态）也能解码', () async {
      const lrc = '[00:03.00]换行 base64';
      final encoded = base64Encode(utf8.encode(lrc));
      final wrapped =
          '${encoded.substring(0, 8)}\n${encoded.substring(8)}';
      final fake = _FakeAdapter((_) async => _jsonBody({
            'retcode': 0,
            'lyric': wrapped,
          }));
      JXHttp.dio.httpClientAdapter = fake;

      expect(await api.getLyrics(_song('x')), lrc);
    });

    test('retcode=-1310（无 Referer 时的错误形态）→ 返回空串、不抛', () async {
      final fake = _FakeAdapter(
          (_) async => _jsonBody({'retcode': -1310, 'subcode': -1310}));
      JXHttp.dio.httpClientAdapter = fake;

      expect(await api.getLyrics(_song('x')), '');
    });

    test('lyric 字段缺失/为空 → 返回空串、不抛', () async {
      final fake = _FakeAdapter((_) async => _jsonBody({'retcode': 0}));
      JXHttp.dio.httpClientAdapter = fake;
      expect(await api.getLyrics(_song('x')), '');

      final empty = _FakeAdapter(
          (_) async => _jsonBody({'retcode': 0, 'lyric': ''}));
      JXHttp.dio.httpClientAdapter = empty;
      expect(await api.getLyrics(_song('x')), '');
    });

    test('网络异常 → 返回空串、不抛（播放链路不能被歌词打断）', () async {
      final fake = _FakeAdapter((options) async => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ));
      JXHttp.dio.httpClientAdapter = fake;

      expect(await api.getLyrics(_song('x')), '');
    });

    test('非 JSON/结构异常响应 → 返回空串、不抛', () async {
      final fake = _FakeAdapter((_) async => ResponseBody.fromString(
            '<html>gateway error</html>',
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.textPlainContentType],
            },
          ));
      JXHttp.dio.httpClientAdapter = fake;

      expect(await api.getLyrics(_song('x')), '');
    });
  });
}
