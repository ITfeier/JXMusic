import 'package:flutter_test/flutter_test.dart';
import 'package:jxmusic/services/api/qq_api.dart';

/// 回归（+46 官方试听版）：QQ 完整版无权益（VIP/付费/登录态过期）时，
/// getPlayUrl 会改请求官方 60 秒试听文件（RS02 前缀）。这里把可测的
/// 「请求体构造」与「响应解析」锁进单测，防止日后清理参数时弄丢试听兜底。
/// 探针实测口径（2026-11，匿名）：
/// - VIP（晴天 0039MnYb0qxYhV）与付费数字专辑（最伟大的作品 003w2xz20QlUZt）
///   带 filename=RS02 均返回 purl（190 字符）+ sip，可下 960887B mp3 ≈ 60s。
/// - 不带 filename 或带 M500/M800 前缀，purl 均为空。
void main() {
  group('QQ 官方试听请求体（trialUrlRequest）', () {
    test('CgiGetVkey 必须带 RS02 试听 filename', () {
      final req = QQMusicApi.trialUrlRequest(
          '123456789012', '0039MnYb0qxYhV', '10001');
      final param = req['req_0']['param'] as Map<String, dynamic>;
      final filename = param['filename'] as List;
      expect(filename, ['RS020039MnYb0qxYhV.mp3']);
    });

    test('guid/songmid/uin 正确映射，双请求结构完整', () {
      final req = QQMusicApi.trialUrlRequest('g1', '003w2xz20QlUZt', 'u9');
      expect(req['req']['module'], 'CDN.SrfCdnMusicSvr');
      expect(req['req']['method'], 'GetCdnDispatch');
      expect(req['req']['param']['guid'], 'g1');
      expect(req['req']['param']['songmid'], '003w2xz20QlUZt');
      final param = req['req_0']['param'] as Map<String, dynamic>;
      expect(req['req_0']['module'], 'vkey.GetVkeyServer');
      expect(req['req_0']['method'], 'CgiGetVkey');
      expect(param['guid'], 'g1');
      expect(param['songmid'], ['003w2xz20QlUZt']);
      expect(param['songtype'], [1]);
      expect(param['uin'], 'u9');
      expect(param['loginflag'], 1);
      expect(param['platform'], '20');
    });
  });

  group('QQ 官方试听响应解析（trialUrlFromResponse）', () {
    test('sip[0]+purl 拼接并升级 https', () {
      final data = {
        'req_0': {
          'code': 0,
          'data': {
            'sip': ['http://aqqmusic.tc.qq.com/', 'http://b.example.com/'],
            'midurlinfo': [
              {
                'purl':
                    'RS020039MnYb0qxYhV.mp3?guid=1&vkey=ABCDEF',
              }
            ],
          },
        },
      };
      final url = QQMusicApi.trialUrlFromResponse(data);
      expect(url,
          'https://aqqmusic.tc.qq.com/RS020039MnYb0qxYhV.mp3?guid=1&vkey=ABCDEF');
    });

    test('purl 为空（无试听权益/接口口径变化）返回 null', () {
      final data = {
        'req_0': {
          'data': {
            'sip': ['http://aqqmusic.tc.qq.com/'],
            'midurlinfo': [
              {'purl': ''},
            ],
          },
        },
      };
      expect(QQMusicApi.trialUrlFromResponse(data), isNull);
    });

    test('midurlinfo 缺失返回 null', () {
      expect(QQMusicApi.trialUrlFromResponse({'req_0': {'data': {}}}), isNull);
      expect(QQMusicApi.trialUrlFromResponse(const {}), isNull);
      expect(QQMusicApi.trialUrlFromResponse(null), isNull);
    });

    test('sip 缺失时退化为纯 purl（与主路径口径一致）', () {
      final data = {
        'req_0': {
          'data': {
            'midurlinfo': [
              {'purl': 'RS020039MnYb0qxYhV.mp3?guid=1&vkey=ABC'},
            ],
          },
        },
      };
      expect(QQMusicApi.trialUrlFromResponse(data),
          'RS020039MnYb0qxYhV.mp3?guid=1&vkey=ABC');
    });
  });
}
