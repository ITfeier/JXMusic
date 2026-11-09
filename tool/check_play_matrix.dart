// JXMusic 播放矩阵探针（诊断专用，手动运行）
//
// 目的：用实测量化区分「部分音乐无法播放」的两类根因：
//   A 类：登录态缺失导致的 VIP/付费歌不可播（未登录时接口返回空直链 / 权限错误码）
//   B 类：与登录无关的不可播（版权/下架无直链、接口契约变更、CDN 拒绝、播放器状态机）
//
// 运行：
//   dart run tool/check_play_matrix.dart [输出文件] [--fallback]
//   默认输出：docs/projects/播放失败诊断/evidence-matrix.txt（同时打印到控制台）
//
// 设计约束（对应任务要求）：
//   1) 三平台各取 ≥5 首样本，覆盖 vip=true / vip=false；
//   2) 每首记录：标题/平台/id/vip、应用层 getPlayUrl 返回有无、失败时原始接口证据
//      （HTTP 状态、响应 JSON 的 code/msg、purl/url 是否为空、api.lastError）；
//   3) 拿到直链后用 Range 下载前 4KB 验证 CDN 真可播（HTTP 状态、content-type、字节数、
//      音频魔数）——避免把 JSON/HTML 错误页误判成音频；
//   4) **不注入任何登录 cookie**：三平台 API 都是全新实例，从不调用 restoreSession；
//      仅对网易云失败样本做「无效随机 MUSIC_U」对照（随机 32 hex，非真实凭据）。
//
// 注意：本文件只读 lib/ 的公开接口，不修改业务代码。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import 'package:jxmusic/models/song.dart';
import 'package:jxmusic/services/api/http.dart';
import 'package:jxmusic/services/api/kugou_api.dart';
import 'package:jxmusic/services/api/music_api.dart';
import 'package:jxmusic/services/api/netease_api.dart';
import 'package:jxmusic/services/api/netease_crypto.dart';
import 'package:jxmusic/services/api/qq_api.dart';

const Map<int, String> _platformNames = <int, String>{
  0: 'QQ音乐',
  1: '网易云',
  2: '酷狗',
};

const String _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

/// 免费候选里排除「节目/电台/播客」等非普通单曲：这类条目在 QQ 侧常因
/// songtype 不是普通歌曲而拿不到 vkey，会污染「免费曲成功率」统计。
const List<String> _programTitleMarkers = <String>[
  '节目',
  '电台',
  '播客',
  '有声',
  '片段',
  '铃声',
  '收音机',
  '专访',
];

bool _usableFree(Song s) =>
    !_programTitleMarkers.any((m) => s.title.contains(m));

/// 标题相似度（与 lib/services/playback.dart 的 _similarTitle 同规则）：
/// 归一化后互相包含即可，用于让兜底实验与 app 的实际筛选一致。
bool _similarTitle(String a, String b) {
  String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '');
  final na = norm(a);
  final nb = norm(b);
  if (na.isEmpty || nb.isEmpty) return false;
  return na.contains(nb) || nb.contains(na);
}

final DateTime _start = DateTime.now();
late final File _evidence;
bool _evidenceOk = false;
late final DateTime _deadline;
late final Map<int, MusicPlatformApi> _allApis;

int _lineNo = 0;
int _lineOffset = 0; // 专项追加模式：从指定行号起编号（保护已交付的证据行）
bool _fallbackEnabled = false;
/// 第三轮登录后对照：把真实会话 cookie 透传给原始接口证据请求（只用于接口复现，
/// 值不落盘、不打印；证据里只出现 cookie 名与打码后的长度）。
String? _neteaseCookieForRaw;
int _fallbackBudget = 0; // 跨平台兜底实验的总预算（控制请求量）
int _fallbackInitial = 0;
int _fallbackUsed = 0;

void main(List<String> args) async {
  // 编译自检：只验证脚本能编译运行，不联网、不写文件。
  if (args.contains('--selfcheck')) {
    // ignore: avoid_print
    print('[SELFCHECK] check_play_matrix.dart compiled ok; no network performed; '
        'login state: fresh API instances (no cookies)');
    return;
  }
  final positional = args.where((a) => !a.startsWith('--')).toList();
  var outPath = positional.isNotEmpty
      ? positional.first
      : 'docs/projects/播放失败诊断/evidence-matrix.txt';
  // 防误覆盖：默认输出文件已存在且非空时（含第二轮/第三轮追加证据），
  // 无 --force 则改写到一个 rerun 文件，避免一条命令冲掉已交付的 453 行证据。
  if (positional.isEmpty && !args.contains('--force')) {
    final f = File(outPath);
    if (f.existsSync() && f.lengthSync() > 0) {
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      outPath = 'docs/projects/播放失败诊断/evidence-matrix-rerun-$stamp.txt';
      // ignore: avoid_print
      print('[WARN] 默认证据文件已存在（含追加证据），本次改写为 $outPath；'
          '如需覆盖请加 --force');
    }
  }
  _fallbackEnabled = args.contains('--fallback');
  // 每首失败样本最多做 1 次兜底实验（跨平台搜同名免费版本），预算覆盖全部失败样本。
  _fallbackBudget = _fallbackEnabled ? 12 : 0;
  _fallbackInitial = _fallbackBudget;
  _evidence = File(outPath);
  try {
    _evidence.parent.createSync(recursive: true);
    _evidence.writeAsStringSync('');
    _evidenceOk = true;
  } catch (e) {
    // 某些受限环境不允许子进程写文件：退化为仅控制台输出，不中断诊断。
    _evidenceOk = false;
    // ignore: avoid_print
    print('[WARN] 无法写证据文件（$outPath）：$e；本次仅输出到控制台，'
        '请用重定向保存输出');
  }
  // 全局预算 10 分钟：即使网络极慢也保证写出可用的部分证据文件。
  _deadline = _start.add(const Duration(seconds: 600));

  // ---- 第二轮专项模式（用户样本）：只输出追加段，从 L0190 起编号 ----
  final caseArg = args.firstWhere(
    (a) => a.startsWith('--case='),
    orElse: () => '',
  );
  final caseName =
      caseArg.isEmpty ? '' : caseArg.substring('--case='.length).trim();
  if (caseName.isNotEmpty) {
    final offArg = args.firstWhere(
      (a) => a.startsWith('--case-offset='),
      orElse: () => '',
    );
    _lineOffset = offArg.isEmpty
        ? 189
        : (int.tryParse(offArg.substring('--case-offset='.length)) ?? 189);
    final startNo = ((_lineOffset + 1).toString()).padLeft(4, '0');
    _emit('# ===== 专项追加段（case=$caseName；从 L$startNo 起；原有证据行未改动） =====');
    _emit('# case=$caseName');
    _emit('# 运行时间(本地): ${DateTime.now().toIso8601String()}');
    _emit('# 命令(实际): ${Platform.resolvedExecutable} '
        '--packages=.dart_tool/package_config.json '
        'tool/check_play_matrix.dart ${args.join(' ')}');
    if (caseName == 'third-round') {
      _emit('# 登录态: 第三轮注入模拟器 App 的网易云真实会话'
          '（来源 /data/data/com.jxmusic.jxmusic/app_flutter/jx_accounts.hive，'
          '仅内存/系统临时目录使用；证据只记录 cookie 名+长度，不记录任何值片段；'
          '授权与合规见报告 §10.0）');
    } else {
      _emit('# 登录态: 无 —— 三平台 API 均为全新实例（cookie 字段为空），'
          '未调用 restoreSession、未注入任何登录 Cookie');
    }
    _emit('# 判定口径同 L0008；[CASE-*] 为用户样本专项，'
        '[FALLBACK-DETAIL-*] 为 findAlternativeSong 兜底候选明细；'
        '[LOGIN-*] 为登录后对照（仅 third-round）');
    final caseQq = QQMusicApi();
    final caseNe = NeteaseApi();
    final caseKg = KuGouApi();
    _allApis = <int, MusicPlatformApi>{
      0: caseQq,
      1: caseNe,
      2: caseKg,
    };
    if (caseName == '7years') {
      await _runCase7Years();
    } else if (caseName == 'matrix-fallback') {
      await _runCaseMatrixFallback();
    } else if (caseName == 'second-round') {
      await _runCase7Years();
      await _runCaseMatrixFallback();
    } else if (caseName == 'third-round') {
      await _runCaseThirdRound();
    } else {
      _emit('[CASE] unknown case="$caseName"（支持 7years / matrix-fallback / '
          'second-round / third-round）');
    }
    _emit('[DONE] case=$caseName '
        'elapsedMs=${DateTime.now().difference(_start).inMilliseconds} '
        'evidence=$outPath');
    return;
  }

  _emit('# JXMusic 播放矩阵探针 evidence（未登录态）');
  _emit('# 运行时间(本地): ${DateTime.now().toIso8601String()}');
  _emit('# 命令(推荐): dart run tool/check_play_matrix.dart ${args.join(' ')}');
  _emit('# 命令(实际): ${Platform.resolvedExecutable} '
      '--packages=.dart_tool/package_config.json '
      'tool/check_play_matrix.dart ${args.join(' ')}');
  _emit('# 登录态: 无 —— 三平台 API 均为全新实例（cookie 字段为空），'
      '全程未调用 restoreSession、未注入任何登录 Cookie');
  _emit('# 无效会话对照: 只用随机 MUSIC_U=<32 hex>（非真实凭据），'
      '只观测「未登录 vs 无效会话」的接口返回差异，不绕过付费');
  _emit('# 字段说明: [SEARCH] 搜索样本池; [SAMPLE] 单首样本; [APP] 应用层 getPlayUrl 结果; '
      '[RAW-*] 原始接口证据; [CDN] Range 前 4KB 探测; [VERDICT] 判定; [FALLBACK] 跨平台兜底实验');
  _emit('# 判定口径: OK=有直链且 CDN 返回音频字节; '
      'A_LOGIN_DIRECT=接口直接返回登录/权限码（如网易云 -110）; '
      'A_PAID_PERMISSION=接口直接返回付费/会员权限错误（如酷狗「需要付费」/30020）; '
      'A_RESTRICTED_CODE=接口权限受限业务码（如 QQ 104003 缺播放票据）; '
      'A_LIKELY_PERMISSION=vip 曲无直链且同平台免费样本可解析（推断权限墙，非接口明示）; '
      'B_NO_DIRECT_URL=接口 200 但无直链（版权/下架/接口变更）; '
      'B_CDN_REJECT=有直链但 CDN 拒绝/非音频; B_INTERFACE=HTTP/网络/解析错误');
  _emit('');

  final qq = QQMusicApi();
  final ne = NeteaseApi();
  final kg = KuGouApi();
  _allApis = <int, MusicPlatformApi>{0: qq, 1: ne, 2: kg};

  final runners = <_Runner>[
    _Runner(
      api: qq,
      candidateQueries: const <String>['周杰伦', '生日快乐', '卡农', '国际歌'],
    ),
    _Runner(
      api: ne,
      candidateQueries: const <String>['周杰伦', '生日快乐', '卡农', '国际歌'],
      extraQueries: const <String>['森林之心'],
    ),
    _Runner(
      api: kg,
      candidateQueries: const <String>['周杰伦', '生日快乐', '卡农', '国际歌'],
    ),
  ];

  // 三平台并发（彼此独立、单个平台内顺序执行以控制风控风险）。
  await Future.wait(runners.map((r) => r.run()));

  _emit('');
  _emit('===== SUMMARY =====');
  var aDirect = 0;
  var aPaid = 0;
  var aRestricted = 0;
  var aLikely = 0;
  var bOther = 0;
  var okCount = 0;
  var extraOk = 0;
  var extraOther = 0;
  for (final r in runners) {
    final matrixSamples =
        r.outcomes.where((o) => o.idx <= 6).toList();
    final extraSamples =
        r.outcomes.where((o) => o.idx > 6).toList();
    _emit('[SUMMARY] platform=${r.name} '
        'matrixSamples=${matrixSamples.length} '
        'extraSamples=${extraSamples.length} '
        'free=${r.freeOk}/${r.freeTotal} vip=${r.vipOk}/${r.vipTotal}');
    for (final o in r.outcomes) {
      _emit('[SUMMARY-SAMPLE] platform=${r.name} idx=${o.idx} '
          'vip=${o.song.vip} id=${o.song.id} '
          'title="${_sanitize(o.song.title, max: 60)}" '
          'verdict=${o.verdict} hasUrl=${o.hasUrl} cdnOk=${o.cdnOk}');
      final isMatrix = o.idx <= 6;
      if (isMatrix) {
        switch (o.verdict) {
          case 'A_LOGIN_DIRECT':
            aDirect++;
            break;
          case 'A_PAID_PERMISSION':
            aPaid++;
            break;
          case 'A_RESTRICTED_CODE':
            aRestricted++;
            break;
          case 'A_LIKELY_PERMISSION':
            aLikely++;
            break;
          case 'OK':
            okCount++;
            break;
          default:
            bOther++;
        }
      } else {
        if (o.verdict == 'OK') {
          extraOk++;
        } else {
          extraOther++;
        }
      }
    }
  }
  _emit('[SUMMARY] 主矩阵(每平台 3 free + 3 vip): '
      'A_LOGIN_DIRECT=$aDirect A_PAID_PERMISSION=$aPaid '
      'A_RESTRICTED_CODE=$aRestricted A_LIKELY_PERMISSION=$aLikely '
      'A_total=${aDirect + aPaid + aRestricted + aLikely} '
      'B_other=$bOther OK=$okCount total=${aDirect + aPaid + aRestricted + aLikely + bOther + okCount}');
  _emit('[SUMMARY] 额外样本(已知问题曲/节目类，不计入主矩阵成功率): '
      'OK=$extraOk 其他=$extraOther total=${extraOk + extraOther}');
  _emit('[SUMMARY] A_LIKELY_PERMISSION 为推断（同平台免费样本可解析、vip 样本不可解析），'
      '不是接口直接明示；其余 A_* 均有接口 code/msg 直接证据。');
  _emit('[SUMMARY] 跨平台兜底实验: enabled=$_fallbackEnabled '
      'initialBudget=$_fallbackInitial used=$_fallbackUsed');
  _emit('[DONE] elapsedMs=${DateTime.now().difference(_start).inMilliseconds} '
      'evidence=$outPath');
}

String _elapsedTag() {
  final ms = DateTime.now().difference(_start).inMilliseconds;
  return '[+${(ms / 1000).toStringAsFixed(1)}s]';
}

void _emit(String line) {
  _lineNo++;
  final no = (_lineNo + _lineOffset).toString().padLeft(4, '0');
  final text = 'L$no ${_elapsedTag()} $line';
  // ignore: avoid_print
  print(text);
  if (_evidenceOk) {
    try {
      _evidence.writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
    } catch (_) {
      _evidenceOk = false;
    }
  }
}

bool get _overDeadline => DateTime.now().isAfter(_deadline);

String _sanitize(Object? value, {int max = 200}) {
  final s = '${value ?? ''}'.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
  if (s.length <= max) return s;
  return '${s.substring(0, max)}…(len=${s.length})';
}

String _err(Object e) {
  if (e is TimeoutException) return 'timeout';
  if (e is DioException) {
    final sc = e.response?.statusCode;
    return 'DioException(${e.type.name}'
        '${sc == null ? '' : ', http=$sc'}): ${_sanitize(e.message, max: 120)}';
  }
  return _sanitize(e, max: 160);
}

String _host(String? url) {
  if (url == null || url.isEmpty) return '-';
  try {
    final u = Uri.parse(url);
    return u.host.isEmpty ? '-' : u.host;
  } catch (_) {
    return '-';
  }
}

bool _audioMagic(List<int> b) {
  if (b.length < 4) return false;
  if (b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) return true; // ID3v2
  if (b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43) {
    return true; // fLaC
  }
  if (b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53) {
    return true; // OggS
  }
  if (b.length >= 8 &&
      b[4] == 0x66 &&
      b[5] == 0x74 &&
      b[6] == 0x79 &&
      b[7] == 0x70) {
    return true; // ....ftyp (m4a/mp4)
  }
  if (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) return true; // MPEG/AAC 帧同步
  return false;
}

String _randomHex32() {
  final r = Random.secure();
  return List<String>.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
}

class _Outcome {
  _Outcome({required this.idx, required this.song});

  final int idx;
  final Song song;
  bool hasUrl = false;
  bool cdnOk = false;
  String verdict = 'UNKNOWN';
  String detail = '';
  Map<String, Object?> raw = const <String, Object?>{};
}

class _CdnResult {
  int status = 0;
  String ct = '';
  int bytes = 0;
  String magic = '';
  bool audioMagic = false;
  bool ok = false;
  int ms = 0;
  String? err;
}

class _Runner {
  _Runner({
    required this.api,
    required this.candidateQueries,
    this.extraQueries = const <String>[],
  });

  final MusicPlatformApi api;
  final List<String> candidateQueries;
  final List<String> extraQueries;

  final List<_Outcome> outcomes = <_Outcome>[];
  int freeOk = 0;
  int freeTotal = 0;
  int vipOk = 0;
  int vipTotal = 0;
  bool _controlDone = false;
  int _invalidCookieCtrl = 0;
  int _qqVariantCtrl = 0;

  String get name => _platformNames[api.platform]!;

  Future<void> run() async {
    _emit('');
    _emit('========== $name（platform=${api.platform}）==========');
    final pool = <Song>[];

    // 自适应搜索：按候选关键词顺序搜索，直到覆盖「免费 ≥3 且 vip ≥3」。
    for (final q in candidateQueries) {
      if (_overDeadline) {
        _emit('[SKIP] platform=$name query="$q" reason=global_deadline');
        break;
      }
      pool.addAll(await _search(q));
      final cov = _coverage(pool);
      if (cov.$1 >= 3 && cov.$2 >= 3) break;
    }
    // 已知问题曲额外搜索（不占样本配额，单独编号 90）。
    for (final q in extraQueries) {
      if (_overDeadline) break;
      pool.addAll(await _search(q));
    }

    final chosen = _pick(pool);
    final coverage = _coverage(pool);
    _emit('[POOL] platform=$name searched=${pool.length} '
        'freeAvailable=${coverage.$1} vipAvailable=${coverage.$2} '
        'chosen=${chosen.length}（目标每类 3 首）');

    var idx = 0;
    for (final song in chosen) {
      idx++;
      await _sample(song, idx);
    }

    // 已知问题曲：网易云《森林之心》若搜到就纳入（额外样本，idx=90）。
    for (final q in extraQueries) {
      final hit = pool.firstWhere(
        (s) => s.title.contains('森林之心'),
        orElse: () =>
            const Song(id: '', platform: -1, title: '', artist: ''),
      );
      if (hit.id.isEmpty) {
        _emit('[EXTRA] platform=$name titleContains="森林之心" found=false');
        break;
      }
      final already = chosen.any((s) => s.id == hit.id);
      _emit('[EXTRA] platform=$name titleContains="森林之心" found=true '
          'id=${hit.id} vip=${hit.vip} alreadyInMatrix=$already '
          'title="${_sanitize(hit.title, max: 80)}"');
      if (!already) await _sample(hit, 90);
      break;
    }

    // 额外样本（QQ）：「节目/电台」类免费条目——用于验证 B 类（与登录无关的内容
    // 限制：vip=false 但接口仍无 vkey，业务码 104003）。不算入 free/vip 成功率统计，
    // 单独编号 91/92，以区分「VIP 权限墙」与「内容本身不可播」。
    if (api.platform == 0) {
      final programs = pool
          .where((s) =>
              s.title.contains('节目') && !chosen.any((c) => c.id == s.id))
          .take(2)
          .toList();
      var pIdx = 91;
      for (final p in programs) {
        if (_overDeadline) break;
        _emit('[EXTRA] platform=$name reason=programSample idx=$pIdx '
            'id=${p.id} vip=${p.vip} title="${_sanitize(p.title, max: 80)}"');
        await _sample(p, pIdx);
        pIdx++;
      }
    }
  }

  (int, int) _coverage(List<Song> pool) {
    final freeIds = <String>{};
    final vipIds = <String>{};
    for (final s in pool) {
      if (s.id.isEmpty) continue;
      if (s.vip) {
        vipIds.add(s.id);
      } else if (_usableFree(s)) {
        freeIds.add(s.id);
      }
    }
    return (freeIds.length, vipIds.length);
  }

  List<Song> _pick(List<Song> pool) {
    final free = <Song>[];
    final vip = <Song>[];
    final seen = <String>{};
    for (final s in pool) {
      if (s.id.isEmpty || !seen.add(s.id)) continue;
      if (s.vip) {
        if (vip.length < 3) vip.add(s);
      } else if (_usableFree(s)) {
        if (free.length < 3) free.add(s);
      }
      if (free.length >= 3 && vip.length >= 3) break;
    }
    // 免费样本先跑完，vip 失败时 freeOk 已确定，便于区分「登录墙」与「版权/接口」。
    return <Song>[...free, ...vip];
  }

  Future<List<Song>> _search(String q) async {
    final sw = Stopwatch()..start();
    try {
      final songs = await api
          .searchSongs(q, size: 30)
          .timeout(const Duration(seconds: 30));
      sw.stop();
      final vip = songs.where((s) => s.vip).length;
      final usableFree =
          songs.where((s) => !s.vip && _usableFree(s)).length;
      _emit('[SEARCH] platform=$name query="$q" count=${songs.length} '
          'vipCount=$vip freeCount=${songs.length - vip} '
          'usableFreeCount=$usableFree elapsedMs=${sw.elapsedMilliseconds}');
      if (songs.isNotEmpty) {
        final s = songs.first;
        _emit('[SEARCH-SAMPLE] platform=$name query="$q" '
            'firstId=${s.id} vip=${s.vip} '
            'title="${_sanitize(s.title, max: 60)}"');
      }
      return songs;
    } catch (e) {
      sw.stop();
      _emit('[SEARCH-FAIL] platform=$name query="$q" '
          'elapsedMs=${sw.elapsedMilliseconds} error="${_err(e)}"');
      return const <Song>[];
    }
  }

  Future<void> _sample(Song song, int idx) async {
    if (_overDeadline) {
      _emit('[SKIP] platform=$name idx=$idx id=${song.id} '
          'reason=global_deadline');
      return;
    }
    _emit('[SAMPLE] platform=$name idx=$idx id=${song.id} vip=${song.vip} '
        'title="${_sanitize(song.title, max: 80)}" '
        'artist="${_sanitize(song.artist, max: 60)}" duration=${song.duration}s');
    if (song.vip) {
      if (idx <= 6) vipTotal++;
    } else {
      if (idx <= 6) freeTotal++;
    }

    var mainRaw = <String, Object?>{};
    final sw = Stopwatch()..start();
    String? url;
    String? thrown;
    try {
      url = await api
          .getPlayUrl(song)
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      thrown = _err(e);
    }
    sw.stop();
    final hasUrl = url != null && url.isNotEmpty;
    _emit('[APP] platform=$name idx=$idx getPlayUrl hasUrl=$hasUrl '
        'urlLen=${url?.length ?? 0} urlHost=${hasUrl ? _host(url) : '-'} '
        'elapsedMs=${sw.elapsedMilliseconds} '
        'api.lastError="${_sanitize(api.lastError, max: 120)}"'
        '${thrown == null ? '' : ' thrown="$thrown"'}');

    final outcome = _Outcome(idx: idx, song: song)..hasUrl = hasUrl;

    if (hasUrl) {
      final cdn = await _probeCdn(url!, api.platform);
      outcome.cdnOk = cdn.ok;
      _emit('[CDN] platform=$name idx=$idx http=${cdn.status} '
          'ct="${cdn.ct}" bytes=${cdn.bytes} magic="${cdn.magic}" '
          'audioMagic=${cdn.audioMagic} elapsedMs=${cdn.ms} ok=${cdn.ok}'
          '${cdn.err == null ? '' : ' err="${cdn.err}"'}');
    } else {
      mainRaw = await _rawEvidence(song, idx);
      // 成功样本（首个免费成功）也留一条原始接口对照，证明"同接口免费曲有 url"。
      if (!_controlDone && freeOk > 0) {
        // 已有免费成功样本时，控制证据已在它成功时采集，无需重复。
        _controlDone = true;
      }
    }

    if (hasUrl && !song.vip && !_controlDone) {
      _controlDone = true;
      await _rawEvidence(song, idx, deep: false, suffix: '-CONTROL');
    }

    outcome.raw = mainRaw;
    outcome.verdict = _verdict(outcome);
    if (outcome.verdict == 'OK' && idx <= 6) {
      if (song.vip) {
        vipOk++;
      } else {
        freeOk++;
      }
    }
    _emit('[VERDICT] platform=$name idx=$idx vip=${song.vip} '
        'result=${outcome.verdict}'
        '${outcome.detail.isEmpty ? '' : ' note="${outcome.detail}"'}');
    outcomes.add(outcome);

    // 网易云失败 VIP 样本：无效随机 MUSIC_U 对照（最多 2 例，非真实凭据）。
    if (!hasUrl &&
        api.platform == 1 &&
        song.vip &&
        _invalidCookieCtrl < 2 &&
        !_overDeadline) {
      _invalidCookieCtrl++;
      final hex = _randomHex32();
      _emit('[CTRL-INVALID-MUSIC_U] platform=网易云 idx=$idx '
          'purpose=无效会话对照 cookie="MUSIC_U=${hex.substring(0, 4)}…'
          '(len=${hex.length})"');
      final invalid = await _rawNetease(
        song,
        idx,
        'CTRL-INVALID-MUSIC_U',
        cookie: 'MUSIC_U=$hex',
      );
      _emit('[CTRL-INVALID-MUSIC_U] platform=网易云 idx=$idx '
          'compare=no_cookie(code=${mainRaw['code']}/itemCode=${mainRaw['itemCode']}) '
          'vs invalid(code=${invalid['code']}/itemCode=${invalid['itemCode']}) '
          'invalidUrlEmpty=${invalid['urlEmpty']}');
    }

    // QQ 失败样本：loginflag=0 变体对照（最多 2 例），判断固定 loginflag=1 + uin=0
    // 是否是 purl 为空的直接原因（只做诊断对照，不改业务代码）。
    if (!hasUrl &&
        api.platform == 0 &&
        _qqVariantCtrl < 2 &&
        !_overDeadline) {
      _qqVariantCtrl++;
      await _rawQq(
        song,
        idx,
        'CTRL-QQ-LOGINFLAG0',
        loginflag: 0,
      );
    }

    // 跨平台兜底实验（可选，总预算 2 例，控制请求量）。
    if (!hasUrl &&
        _fallbackEnabled &&
        _fallbackBudget > 0 &&
        !_overDeadline) {
      _fallbackBudget--;
      _fallbackUsed++;
      await _fallbackProbe(song, idx);
    }
  }

  String _verdict(_Outcome o) {
    if (o.hasUrl && o.cdnOk) return 'OK';
    if (o.hasUrl && !o.cdnOk) {
      o.detail = '直链存在但 CDN Range 探测不可播（见 [CDN] 行）';
      return 'B_CDN_REJECT';
    }
    final raw = o.raw;
    switch (api.platform) {
      case 1:
        final codes = <String>[
          '${raw['code']}',
          '${raw['itemCode']}',
          '${raw['weapiCode']}',
          '${raw['weapiItemCode']}',
        ];
        final msgs = '${raw['msg']} ${raw['weapiMsg']}';
        final direct = codes.any((c) => c == '-110' || c == '110') ||
            msgs.contains('登录') ||
            msgs.contains('VIP') ||
            msgs.contains('vip');
        if (direct) {
          o.detail = '接口返回登录/权限码：code=${raw['code']} '
              'itemCode=${raw['itemCode']} msg="${_sanitize(raw['msg'], max: 60)}"';
          return 'A_LOGIN_DIRECT';
        }
        final httpOk = raw['http'] == 200 || raw['weapiHttp'] == 200;
        if (!httpOk) {
          o.detail = '接口 HTTP 非 200/网络异常：http=${raw['http']} '
              'weapiHttp=${raw['weapiHttp']} error="${_sanitize(raw['error'], max: 60)}"';
          return 'B_INTERFACE';
        }
        o.detail = '接口 200 但 url 为空（无版权/下架/接口变更）';
        return 'B_NO_DIRECT_URL';
      case 0:
        final http = raw['http'];
        if (http != 200) {
          o.detail = '接口 HTTP 非 200/网络异常：http=$http '
              'error="${_sanitize(raw['error'], max: 60)}"';
          return 'B_INTERFACE';
        }
        final result = '${raw['result']}';
        final resultNonZero =
            result.isNotEmpty && result != '0' && result != 'null';
        if (resultNonZero) {
          // 104003：QQ 播放票据缺失/受限（第三方公开接口文档记载：缺
          // qqCookiePlaybackKey 时命中 104003；未登录 uin=0 必然没有该票据）。
          if (result == '104003' && o.song.vip) {
            o.detail = 'QQ 业务码 result=104003（缺播放票据/受限，'
                '未登录无 qqCookiePlaybackKey），purl 为空';
            return 'A_RESTRICTED_CODE';
          }
          o.detail = '接口业务码 result=$result（版权/下架等），purl 为空';
          return 'B_NO_DIRECT_URL';
        }
        if (o.song.vip && freeOk > 0) {
          o.detail = 'vip 曲 purl 为空，同平台免费样本可解析（uin=0 未登录）';
          return 'A_LIKELY_PERMISSION';
        }
        o.detail = '接口 200 但 purl 为空（无版权/下架/接口变更）';
        return 'B_NO_DIRECT_URL';
      case 2:
        final http = raw['http'];
        if (http != 200) {
          o.detail = '接口 HTTP 非 200/网络异常：http=$http '
              'error="${_sanitize(raw['error'], max: 60)}"';
          return 'B_INTERFACE';
        }
        final errCode = '${raw['errCode']}';
        final fbErrCode = '${raw['fbErrCode']}';
        final errorText = '${raw['error']}';
        // 酷狗付/会员权限墙：主路径 error="需要付费"，或兜底接口 err_code=30020。
        final payWall = errorText.contains('付费') ||
            errorText.contains('会员') ||
            errorText.contains('VIP') ||
            errorText.contains('vip') ||
            fbErrCode == '30020';
        if (payWall) {
          o.detail = '接口返回付费/会员权限错误：'
              'error="${_sanitize(errorText, max: 60)}" fbErrCode=$fbErrCode';
          return 'A_PAID_PERMISSION';
        }
        final bizErr =
            errCode.isNotEmpty && errCode != '0' && errCode != 'null';
        if (bizErr) {
          o.detail = '接口业务错误 err_code=$errCode '
              'error="${_sanitize(raw['error'], max: 60)}"';
          return 'B_NO_DIRECT_URL';
        }
        if (o.song.vip && freeOk > 0) {
          o.detail = 'vip 曲 url 为空，同平台免费样本可解析（未登录）';
          return 'A_LIKELY_PERMISSION';
        }
        o.detail = '接口 200 但 url 为空（无版权/下架/接口变更）';
        return 'B_NO_DIRECT_URL';
      default:
        o.detail = '未知平台';
        return 'B_NO_DIRECT_URL';
    }
  }

  Future<Map<String, Object?>> _rawEvidence(
    Song song,
    int idx, {
    bool deep = true,
    String suffix = '',
  }) async {
    switch (api.platform) {
      case 0:
        return _rawQq(song, idx, 'RAW-QQ$suffix');
      case 1:
        final main = await _rawNetease(song, idx, 'RAW-NE$suffix');
        if (!deep) return main;
        final weapi = await _rawNeteaseWeapi(song, idx, 'RAW-NE-WEAPI$suffix');
        return <String, Object?>{...main, ...weapi};
      case 2:
        final main = await _rawKugou(song, idx, 'RAW-KUGOU$suffix');
        if (!deep) return main;
        final fallback =
            await _rawKugouFallback(song, idx, 'RAW-KUGOU-FALLBACK$suffix');
        return <String, Object?>{...main, ...fallback};
      default:
        return const <String, Object?>{};
    }
  }

  /// 网易云公开 GET 接口原始证据（与 lib getPlayUrl 第 1 步完全同参）。
  Future<Map<String, Object?>> _rawNetease(
    Song song,
    int idx,
    String tag, {
    String? cookie,
  }) async {
    final sid = int.tryParse(song.id);
    var http = 0;
    var code = '';
    var msg = '';
    var itemCode = '';
    var urlEmpty = true;
    var fee = '';
    var payed = '';
    var level = '';
    var hasFreeTrial = false;
    var errText = '';
    if (sid == null) {
      _emit('[$tag] platform=网易云 idx=$idx error="id 非数字"');
      return <String, Object?>{'idInvalid': true};
    }
    try {
      final effectiveCookie = cookie ?? _neteaseCookieForRaw;
      final resp = await JXHttp.dio
          .get(
            'https://music.163.com/api/song/enhance/player/url',
            queryParameters: <String, dynamic>{'ids': '[$sid]', 'br': 128000},
            options: Options(
              validateStatus: (_) => true,
              headers: <String, String>{
                'Referer': 'https://music.163.com/',
                if (effectiveCookie != null && effectiveCookie.isNotEmpty)
                  'Cookie': effectiveCookie,
              },
            ),
          )
          .timeout(const Duration(seconds: 30));
      http = resp.statusCode ?? 0;
      final data = resp.data;
      final map = data is Map ? data : const <String, dynamic>{};
      code = '${map['code'] ?? ''}';
      msg = '${map['message'] ?? map['msg'] ?? ''}';
      final list = map['data'];
      if (list is List && list.isNotEmpty && list.first is Map) {
        final first = list.first as Map;
        itemCode = '${first['code'] ?? ''}';
        urlEmpty = (first['url'] as String? ?? '').isEmpty;
        fee = '${first['fee'] ?? ''}';
        payed = '${first['payed'] ?? ''}';
        level = '${first['level'] ?? ''}';
        hasFreeTrial = first['freeTrialInfo'] != null;
      }
    } catch (e) {
      errText = _err(e);
    }
    _emit('[$tag] platform=网易云 idx=$idx '
        'endpoint=GET:music.163.com/api/song/enhance/player/url(br=128000) '
        'http=$http topCode="$code" topMsg="${_sanitize(msg, max: 120)}" '
        'itemCode="$itemCode" urlEmpty=$urlEmpty fee=$fee payed=$payed '
        'level="$level" hasFreeTrialInfo=$hasFreeTrial'
        '${errText.isEmpty ? '' : ' error="$errText"'}');
    return <String, Object?>{
      'http': http,
      'code': code,
      'msg': msg,
      'itemCode': itemCode,
      'urlEmpty': urlEmpty,
      'fee': fee,
      'error': errText,
    };
  }

  /// 网易云 weapi 兜底接口原始证据（与 lib getPlayUrl 第 2 步同参数同加密）。
  Future<Map<String, Object?>> _rawNeteaseWeapi(
    Song song,
    int idx,
    String tag,
  ) async {
    final sid = int.tryParse(song.id);
    var http = 0;
    var code = '';
    var msg = '';
    var itemCode = '';
    var urlEmpty = true;
    var errText = '';
    if (sid == null) return const <String, Object?>{};
    try {
      final enc = NeteaseCrypto.weapi(<String, dynamic>{
        'ids': jsonEncode(<int>[sid]),
        'level': 'standard',
        'encodeType': 'aac',
      });
      final resp = await JXHttp.dio
          .post(
            'https://music.163.com/weapi/api/song/enhance/player/url/v1',
            data: <String, String>{
              'params': enc['params']!,
              'encSecKey': enc['encSecKey']!,
            },
            options: Options(
              contentType: 'application/x-www-form-urlencoded',
              validateStatus: (_) => true,
              headers: const <String, String>{
                'Referer': 'https://music.163.com/',
              },
            ),
          )
          .timeout(const Duration(seconds: 30));
      http = resp.statusCode ?? 0;
      final data = resp.data;
      final map = data is Map ? data : const <String, dynamic>{};
      code = '${map['code'] ?? ''}';
      msg = '${map['message'] ?? map['msg'] ?? ''}';
      final list = map['data'];
      if (list is List && list.isNotEmpty && list.first is Map) {
        final first = list.first as Map;
        itemCode = '${first['code'] ?? ''}';
        urlEmpty = (first['url'] as String? ?? '').isEmpty;
      }
    } catch (e) {
      errText = _err(e);
    }
    _emit('[$tag] platform=网易云 idx=$idx '
        'endpoint=POST:music.163.com/weapi/api/song/enhance/player/url/v1 '
        'http=$http topCode="$code" topMsg="${_sanitize(msg, max: 120)}" '
        'itemCode="$itemCode" urlEmpty=$urlEmpty'
        '${errText.isEmpty ? '' : ' error="$errText"'}');
    return <String, Object?>{
      'weapiHttp': http,
      'weapiCode': code,
      'weapiMsg': msg,
      'weapiItemCode': itemCode,
    };
  }

  /// QQ 音乐 CgiGetVkey 原始证据（与 lib getPlayUrl 同参：uin=0、loginflag=1，未登录）。
  /// [loginflag] 可传 0 做对照实验（诊断用，不代表 app 行为）。
  Future<Map<String, Object?>> _rawQq(
    Song song,
    int idx,
    String tag, {
    int loginflag = 1,
  }) async {
    var http = 0;
    var req0Code = '';
    var midCount = 0;
    var purlLen = 0;
    var result = '';
    var errtype = '';
    var sipCount = 0;
    var errText = '';
    try {
      final guid = List<String>.generate(
        12,
        (_) => Random().nextInt(10).toString(),
      ).join();
      final reqObj = <String, dynamic>{
        'req': <String, dynamic>{
          'module': 'CDN.SrfCdnMusicSvr',
          'method': 'GetCdnDispatch',
          'param': <String, dynamic>{
            'guid': guid,
            'songmid': song.id,
            'songtype': 1,
          },
        },
        'req_0': <String, dynamic>{
          'module': 'vkey.GetVkeyServer',
          'method': 'CgiGetVkey',
          'param': <String, dynamic>{
            'guid': guid,
            'songmid': <String>[song.id],
            'songtype': <int>[1],
            'uin': '0',
            'loginflag': loginflag,
            'platform': '20',
          },
        },
      };
      final resp = await JXHttp.dio
          .get(
            'https://u.y.qq.com/cgi-bin/musicu.fcg',
            queryParameters: <String, dynamic>{
              'format': 'json',
              'data': jsonEncode(reqObj),
              'loginUin': '0',
              'hostUin': '0',
              'needNewCode': 0,
            },
            options: Options(
              validateStatus: (_) => true,
              headers: const <String, String>{
                'Referer': 'https://y.qq.com/',
              },
            ),
          )
          .timeout(const Duration(seconds: 30));
      http = resp.statusCode ?? 0;
      final data = resp.data;
      final map = data is Map ? data : const <String, dynamic>{};
      final req0 = map['req_0'];
      final req0Map = req0 is Map ? req0 : const <String, dynamic>{};
      req0Code = '${req0Map['code'] ?? ''}';
      final d0 = req0Map['data'];
      final d0Map = d0 is Map ? d0 : const <String, dynamic>{};
      final mi = d0Map['midurlinfo'];
      if (mi is List) {
        midCount = mi.length;
        if (mi.isNotEmpty && mi.first is Map) {
          final first = mi.first as Map;
          purlLen = (first['purl'] as String? ?? '').length;
          result = '${first['result'] ?? ''}';
          errtype = '${first['errtype'] ?? ''}';
        }
      }
      final sip = d0Map['sip'];
      if (sip is List) sipCount = sip.length;
    } catch (e) {
      errText = _err(e);
    }
    _emit('[$tag] platform=QQ音乐 idx=$idx '
        'endpoint=GET:u.y.qq.com/cgi-bin/musicu.fcg'
        '(CgiGetVkey,uin=0,loginflag=$loginflag) '
        'http=$http req0Code="$req0Code" midurlinfoCount=$midCount '
        'purlLen=$purlLen result="$result" '
        'errtype="${_sanitize(errtype, max: 40)}" sipCount=$sipCount'
        '${errText.isEmpty ? '' : ' error="$errText"'}');
    return <String, Object?>{
      'http': http,
      'req0Code': req0Code,
      'midCount': midCount,
      'purlLen': purlLen,
      'result': result,
      'errtype': errtype,
      'error': errText,
    };
  }

  /// 酷狗 m.kugou 主路径原始证据（与 lib getPlayUrl 第 1 步同参）。
  Future<Map<String, Object?>> _rawKugou(Song song, int idx, String tag) async {
    var http = 0;
    var urlEmpty = true;
    var status = '';
    var errCode = '';
    var error = '';
    var fileName = '';
    var errText = '';
    try {
      final resp = await JXHttp.dio
          .get(
            'https://m.kugou.com/app/i/getSongInfo.php',
            queryParameters: <String, dynamic>{
              'cmd': 'playInfo',
              'hash': song.id,
              'platid': 4,
            },
            options: Options(validateStatus: (_) => true),
          )
          .timeout(const Duration(seconds: 30));
      http = resp.statusCode ?? 0;
      final data = resp.data;
      final map = data is Map ? data : const <String, dynamic>{};
      urlEmpty = (map['url'] as String? ?? '').isEmpty;
      status = '${map['status'] ?? ''}';
      errCode = '${map['err_code'] ?? ''}';
      error = '${map['error'] ?? ''}';
      fileName = '${map['fileName'] ?? ''}';
    } catch (e) {
      errText = _err(e);
    }
    _emit('[$tag] platform=酷狗 idx=$idx '
        'endpoint=GET:m.kugou.com/app/i/getSongInfo.php(cmd=playInfo) '
        'http=$http urlEmpty=$urlEmpty status="$status" err_code="$errCode" '
        'error="${_sanitize(error, max: 80)}" '
        'fileName="${_sanitize(fileName, max: 80)}"'
        '${errText.isEmpty ? '' : ' error="$errText"'}');
    return <String, Object?>{
      'http': http,
      'urlEmpty': urlEmpty,
      'status': status,
      'errCode': errCode,
      'error': errText.isEmpty ? error : errText,
    };
  }

  /// 酷狗 wwwapi getdata 兜底原始证据（与 lib getPlayUrl 第 2 步同参）。
  Future<Map<String, Object?>> _rawKugouFallback(
    Song song,
    int idx,
    String tag,
  ) async {
    var http = 0;
    var playUrlEmpty = true;
    var status = '';
    var errCode = '';
    var error = '';
    var errText = '';
    try {
      final resp = await JXHttp.dio
          .get(
            'https://wwwapi.kugou.com/yy/index.php',
            queryParameters: <String, dynamic>{
              'r': 'play/getdata',
              'hash': song.id,
              'album_id': '',
              'dfid': '3K9V4B4Z3I9y0M5M0n2T0',
              'mid': 'JXMusic',
              'platid': 4,
            },
            options: Options(validateStatus: (_) => true),
          )
          .timeout(const Duration(seconds: 30));
      http = resp.statusCode ?? 0;
      final data = resp.data;
      final map = data is Map ? data : const <String, dynamic>{};
      status = '${map['status'] ?? ''}';
      errCode = '${map['err_code'] ?? ''}';
      error = '${map['error'] ?? ''}';
      final d = map['data'];
      final dMap = d is Map ? d : const <String, dynamic>{};
      playUrlEmpty = (dMap['play_url'] as String? ?? '').isEmpty;
    } catch (e) {
      errText = _err(e);
    }
    _emit('[$tag] platform=酷狗 idx=$idx '
        'endpoint=GET:wwwapi.kugou.com/yy/index.php(r=play/getdata) '
        'http=$http play_urlEmpty=$playUrlEmpty status="$status" '
        'err_code="$errCode" error="${_sanitize(error, max: 80)}"'
        '${errText.isEmpty ? '' : ' error="$errText"'}');
    return <String, Object?>{
      'fbHttp': http,
      'fbPlayUrlEmpty': playUrlEmpty,
      'fbErrCode': errCode,
    };
  }

  /// 跨平台兜底实验：其它平台搜同名免费版本 + getPlayUrl（镜像 lib playback.dart
  /// findAlternativeSong 的策略，但用独立实现避免引入 Flutter 依赖）。
  Future<void> _fallbackProbe(Song song, int idx) async {
    final title = song.title
        .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
        .trim();
    final artist = song.artist.split('、').first.trim();
    final query = '${title.isEmpty ? song.title : title} $artist';
    for (final platform in const <int>[0, 1, 2]) {
      if (platform == api.platform) continue;
      final other = _allApis[platform];
      if (other == null) continue;
      final otherName = _platformNames[platform]!;
      if (_overDeadline) {
        _emit('[FALLBACK] platform=$name idx=$idx try=$otherName '
            'result=SKIP_GLOBAL_DEADLINE');
        return;
      }
      _emit('[FALLBACK] platform=$name idx=$idx try=$otherName '
          'query="${_sanitize(query, max: 80)}"');
      List<Song> candidates;
      try {
        candidates = await other
            .searchSongs(query, size: 5)
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        _emit('[FALLBACK] platform=$name idx=$idx try=$otherName '
            'searchError="${_err(e)}"');
        continue;
      }
      var tried = 0;
      // 与 app 的 findAlternativeSong 一致：只接受标题相似的免费候选。
      for (final candidate in candidates
          .where((s) => !s.vip && _similarTitle(s.title, song.title))
          .take(3)) {
        tried++;
        try {
          final altUrl = await other
              .getPlayUrl(candidate)
              .timeout(const Duration(seconds: 10));
          final altHas = altUrl != null && altUrl.isNotEmpty;
          _emit('[FALLBACK] platform=$name idx=$idx try=$otherName '
              'candidate="${_sanitize(candidate.title, max: 60)}" '
              'candidateId=${candidate.id} getPlayUrl=$altHas');
          if (altHas) return;
        } catch (e) {
          _emit('[FALLBACK] platform=$name idx=$idx try=$otherName '
              'candidate="${_sanitize(candidate.title, max: 60)}" '
              'error="${_err(e)}"');
        }
      }
      _emit('[FALLBACK] platform=$name idx=$idx try=$otherName '
          'candidatesTried=$tried result=NO_FREE_URL');
    }
    _emit('[FALLBACK] platform=$name idx=$idx result=ALL_PLATFORMS_NO_FREE_URL');
  }
}

// ============================================================================
// 第二轮专项（用户样本）：7 Years 网易云 + 兜底版本错乱 + 搜索页“全部音源失败”复现
// 结果追加到 evidence-matrix.txt 末尾（L0190 起），不重写主矩阵证据（L0001–L0189）。
// ============================================================================

class _GroupSim {
  _GroupSim({required this.key});

  final String key;
  String title = '';
  String artist = '';
  int duration = 0;
  final List<Song> sources = <Song>[];
}

String _normKey(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll(
        RegExp(r'[\\/:*?"<>|,，.。!！?？·・、_\-—–~()（）\[\]【】]'), '')
    .trim();

String _fmtSongBrief(Song s) =>
    'id=${s.id} vip=${s.vip} title="${_sanitize(s.title, max: 70)}" '
    'artist="${_sanitize(s.artist, max: 50)}" duration=${s.duration}s';

/// 判断候选相对原曲是什么版本（回答“会不会播成别的版本”）。
String _versionOf(Song original, Song candidate) {
  final t = candidate.title.toLowerCase();
  final ot = original.title.toLowerCase();
  bool hit(List<String> markers, String text) =>
      markers.any((m) => text.contains(m));
  final rules = <String, List<String>>{
    'LIVE': <String>['live', '现场', '演唱会', 'unplugged'],
    'DEMO': <String>['demo', '小样', '试听版'],
    'COVER': <String>[
      'cover',
      '翻唱',
      '女声',
      '男声',
      '童声',
      '钢琴版',
      '吉他版',
      '纯音乐',
      '钢琴曲',
    ],
    'REMIX_DJ': <String>['remix', 'dj', '伴奏', '混音', '加快', '慢速'],
    'MEDLEY': <String>['medley', '串烧', '＋'],
  };
  for (final entry in rules.entries) {
    if (hit(entry.value, t) && !hit(entry.value, ot)) {
      return entry.key;
    }
  }
  if (_normKey(candidate.title) != _normKey(original.title)) {
    return 'DIFFERENT_TITLE';
  }
  if (original.duration > 0 &&
      candidate.duration > 0 &&
      (candidate.duration - original.duration).abs() > 15) {
    return 'DURATION_MISMATCH';
  }
  final oa = _normKey(original.artist.split('、').first);
  final ca = _normKey(candidate.artist.split('、').first);
  if (oa.isNotEmpty && ca.isNotEmpty && !ca.contains(oa) && !oa.contains(ca)) {
    return 'DIFFERENT_ARTIST';
  }
  return 'SAME_TITLE';
}

/// 明细版跨平台兜底：复刻 lib/services/playback.dart findAlternativeSong 的选择顺序
/// （平台 0→1→2、跳过源平台、search size=5、跳过 VIP、标题相似、取前 3 个候选、
/// 第一个有直链即返回），逐条打印候选标题/歌手/时长/vip/版本。
/// 返回：SWITCH:<版本类型> / SAME_TITLE_OTHER_PLATFORM / NO_ALTERNATIVE。
Future<String> _detailedFallback(Song original) async {
  final baseTitle =
      original.title.replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '').trim();
  final artist = original.artist.split('、').first.trim();
  final query = '${baseTitle.isEmpty ? original.title : baseTitle} $artist';
  _emit('[FALLBACK-DETAIL] sourcePlatform='
      '${_platformNames[original.platform]} original=${_fmtSongBrief(original)} '
      'query="${_sanitize(query, max: 80)}"');
  for (final platform in const <int>[0, 1, 2]) {
    if (platform == original.platform) continue;
    final other = _allApis[platform];
    if (other == null) continue;
    final otherName = _platformNames[platform]!;
    if (_overDeadline) {
      _emit('[FALLBACK-DETAIL] try=$otherName result=SKIP_GLOBAL_DEADLINE');
      break;
    }
    List<Song> candidates;
    try {
      candidates = await other
          .searchSongs(query, size: 5)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      _emit('[FALLBACK-DETAIL] try=$otherName searchError="${_err(e)}"');
      continue;
    }
    _emit('[FALLBACK-DETAIL] try=$otherName searchCount=${candidates.length}');
    var accepted = 0;
    Song? chosen;
    for (var i = 0; i < candidates.length; i++) {
      final c = candidates[i];
      final similar = _similarTitle(c.title, original.title);
      final wouldAccept = !c.vip && similar;
      final ver = _versionOf(original, c);
      // 专项输出保持紧凑：只打「前 2 个候选（可见 VIP 原版被跳过）+ 会被接受的候选」。
      if (wouldAccept || i < 2) {
        _emit('[FALLBACK-DETAIL-CANDIDATE] try=$otherName rank=${i + 1} '
            '${_fmtSongBrief(c)} similarTitle=$similar '
            'wouldAccept=$wouldAccept version=$ver');
      }
      if (!wouldAccept || accepted >= 3) continue;
      accepted++;
      try {
        final u =
            await other.getPlayUrl(c).timeout(const Duration(seconds: 10));
        final has = u != null && u.isNotEmpty;
        _emit('[FALLBACK-DETAIL-URL] try=$otherName rank=${i + 1} '
            'id=${c.id} getPlayUrl=$has');
        if (has && chosen == null) chosen = c;
      } catch (e) {
        _emit('[FALLBACK-DETAIL-URL] try=$otherName rank=${i + 1} '
            'id=${c.id} error="${_err(e)}"');
      }
    }
    if (chosen != null) {
      final ver = _versionOf(original, chosen);
      _emit('[FALLBACK-DETAIL-CHOSEN] try=$otherName '
          '${_fmtSongBrief(chosen)} version=$ver');
      final decision =
          ver == 'SAME_TITLE' ? 'SAME_TITLE_OTHER_PLATFORM' : 'SWITCH:$ver';
      _emit('[FALLBACK-DETAIL-DECISION] originalPlatform='
          '${_platformNames[original.platform]} '
          'original="${_sanitize(original.title, max: 60)}" '
          'chosenPlatform=$otherName '
          'chosen="${_sanitize(chosen.title, max: 60)}" '
          'chosenArtist="${_sanitize(chosen.artist, max: 40)}" '
          'version=$ver outcome=$decision');
      return decision;
    }
    _emit('[FALLBACK-DETAIL-CHOSEN] try=$otherName result=NO_FREE_URL');
  }
  _emit('[FALLBACK-DETAIL-DECISION] originalPlatform='
      '${_platformNames[original.platform]} '
      'original="${_sanitize(original.title, max: 60)}" '
      'chosenPlatform=- outcome=NO_ALTERNATIVE（app 侧会走失败提示）');
  return 'NO_ALTERNATIVE';
}

List<_GroupSim> _buildGroupSims(List<Song> songs) {
  final map = <String, _GroupSim>{};
  final order = <String>[];
  for (final s in songs) {
    final title = s.title.trim();
    if (title.isEmpty) continue;
    final key = '${_normKey(title)}|${_normKey(s.artist.trim())}';
    final existing = map[key];
    if (existing == null) {
      final g = _GroupSim(key: key)
        ..title = title
        ..artist = s.artist.trim()
        ..duration = s.duration
        ..sources.add(s);
      map[key] = g;
      order.add(key);
    } else {
      existing.sources.removeWhere((x) => x.platform == s.platform);
      existing.sources.add(s);
      if (existing.duration <= 0) existing.duration = s.duration;
    }
  }
  return [for (final k in order) map[k]!];
}

Song _groupPrimary(_GroupSim g) {
  final free = g.sources.where((s) => !s.vip).toList();
  final pool = free.isEmpty ? <Song>[...g.sources] : free;
  pool.sort((a, b) {
    final ca = a.coverUrl.isNotEmpty ? 1 : 0;
    final cb = b.coverUrl.isNotEmpty ? 1 : 0;
    if (ca != cb) return cb - ca;
    return b.duration - a.duration;
  });
  return pool.first;
}

/// 模拟搜索页 buildTrackGroups + playTrackGroup（lib/models/track_group.dart、
/// lib/ui/search_page.dart:_play）：解释「已尝试全部 N 个音源，均不可用」与
/// 「用的不是当前平台音源」。
Future<void> _caseGroupSim(String keyword, {String? pickedNeteaseId}) async {
  _emit('[CASE-GROUP] 模拟搜索页聚合组：query="$keyword"');
  final all = <Song>[];
  for (final p in const <int>[0, 1, 2]) {
    final api = _allApis[p];
    if (api == null) continue;
    try {
      final list = await api
          .searchSongs(keyword, size: 30)
          .timeout(const Duration(seconds: 15));
      _emit('[CASE-GROUP-SEARCH] platform=${_platformNames[p]} '
          'count=${list.length} vipCount=${list.where((s) => s.vip).length}');
      all.addAll(list);
    } catch (e) {
      _emit('[CASE-GROUP-SEARCH] platform=${_platformNames[p]} '
          'error="${_err(e)}"');
    }
  }
  final groups = _buildGroupSims(all);
  final matched = groups
      .where((g) =>
          g.title.toLowerCase().contains('7 years') ||
          g.title.toLowerCase().contains('seven years'))
      .toList();
  _emit('[CASE-GROUP] totalSongs=${all.length} totalGroups=${groups.length} '
      'titleMatches=${matched.length}');
  // 只输出：Lukas Graham 原版聚合组 + 最多 3 个「全部音源是 VIP」的失败组（对应
  // 搜索页「已尝试全部 N 个音源，均不可用」），避免几十个同名翻唱组刷屏。
  final canonical = matched
      .where((g) =>
          _normKey(g.title) == '7years' &&
          g.artist.toLowerCase().contains('lukas'))
      .toList();
  final failing = matched
      .where((g) => g.sources.every((s) => s.vip) && g.sources.length >= 2)
      .take(3)
      .toList();
  final selected = <_GroupSim>[...canonical, ...failing];
  _emit('[CASE-GROUP] selected=${selected.length} '
      'canonicalGroups=${canonical.length} allVipFailingGroups=${failing.length}');
  for (final g in selected) {
    _emit('[CASE-GROUP] title="${_sanitize(g.title, max: 70)}" '
        'artist="${_sanitize(g.artist, max: 50)}" sources=${g.sources.length} '
        'allVip=${g.sources.every((s) => s.vip)}');
    for (final s in g.sources) {
      _emit('[CASE-GROUP-SOURCE] platform=${_platformNames[s.platform]} '
          '${_fmtSongBrief(s)}');
    }
    final primary = _groupPrimary(g);
    _emit('[CASE-GROUP-PRIMARY] platform=${_platformNames[primary.platform]} '
        'id=${primary.id} title="${_sanitize(primary.title, max: 60)}" '
        'vip=${primary.vip}（非 VIP 优先，再按封面/时长排序）');
    final ordered = <Song>[
      primary,
      for (final s in g.sources)
        if (s.globalId != primary.globalId) s,
    ];
    var tried = 0;
    Song? okSource;
    for (final s in ordered) {
      tried++;
      final api = _allApis[s.platform];
      String? u = s.audioUrl;
      if (u == null || u.isEmpty) {
        if (api == null) {
          u = null;
        } else {
          try {
            u = await api.getPlayUrl(s).timeout(const Duration(seconds: 15));
          } catch (e) {
            _emit('[CASE-GROUP-PLAY] platform=${_platformNames[s.platform]} '
                'id=${s.id} error="${_err(e)}"');
          }
        }
      }
      final has = u != null && u.isNotEmpty;
      _emit('[CASE-GROUP-PLAY] attempt=$tried/${ordered.length} '
          'platform=${_platformNames[s.platform]} id=${s.id} vip=${s.vip} '
          'getPlayUrl=$has');
      if (has) {
        okSource = s;
        break;
      }
    }
    if (okSource != null) {
      _emit('[CASE-GROUP-RESULT] ok=true tried=$tried/${ordered.length} '
          'playedPlatform=${_platformNames[okSource.platform]} '
          'id=${okSource.id}（若与用户点选平台不同，搜索页会提示'
          '“已改用 X 音源播放”）');
    } else {
      _emit('[CASE-GROUP-RESULT] ok=false tried=$tried/${ordered.length} '
          'snackbar="「${_sanitize(g.title, max: 40)}」已尝试全部 $tried 个音源，'
          '均不可用（可能需要登录或受版权限制）"');
    }
    if (canonical.contains(g) && pickedNeteaseId != null) {
      final samePlatform =
          g.sources.where((s) => s.platform == 1).toList();
      _emit('[CASE-GROUP-NOTE] 用户点的网易云版本 id=$pickedNeteaseId；'
          '该聚合组的网易云音源='
          '${samePlatform.map((s) => '${s.id}(vip=${s.vip})').join(',')} '
          '→ 同一首歌在同一平台可能有多条目/版本，搜索页优先选非 VIP 版本，'
          '与用户点选的条目可能不是同一条');
    }
  }
}

Future<void> _runCase7Years() async {
  _emit('[CASE] ===== 7 Years（网易云）专项 =====');
  final ne = _allApis[1]!;
  final runner = _Runner(api: ne, candidateQueries: const <String>[]);
  final results = await runner._search('7 Years');
  final matches = results.where((s) {
    final t = s.title.toLowerCase();
    return t.contains('7 years') || t.contains('seven years');
  }).toList();
  _emit('[CASE-CANDIDATES] platform=网易云 query="7 Years" '
      'total=${results.length} titleMatches=${matches.length}');
  for (var i = 0; i < matches.length && i < 10; i++) {
    _emit('[CASE-CANDIDATE] rank=${i + 1} ${_fmtSongBrief(matches[i])}');
  }
  Song? pick;
  for (final s in matches) {
    if (s.artist.toLowerCase().contains('lukas')) {
      pick = s;
      break;
    }
  }
  pick ??= matches.isNotEmpty ? matches.first : null;
  if (pick == null) {
    _emit('[CASE-PICK] found=false');
    return;
  }
  _emit('[CASE-PICK] ${_fmtSongBrief(pick)}（优先歌手含 Lukas Graham）');
  await runner._sample(pick, 1);
  final verdict =
      runner.outcomes.isEmpty ? 'UNKNOWN' : runner.outcomes.last.verdict;
  _emit('[CASE-VERDICT] song="7 Years" platform=网易云 '
      'vip=${pick.vip} result=$verdict');
  final decision = await _detailedFallback(pick);
  _emit('[CASE-FALLBACK-7YEARS] decision=$decision');
  await _caseGroupSim('7 Years', pickedNeteaseId: pick.id);
}

Future<void> _runCaseMatrixFallback() async {
  _emit('[CASE] ===== 主矩阵 9 首 A 类 VIP 歌：走 app resolveAndPlay 兜底后的实际去向 =====');
  // 来自 evidence-matrix.txt L0082/L0099/L0127/L0062/L0101/L0125/L0051/L0088/L0116 的样本，
  // 用当时的 id/title/artist/duration 重建（vip=true、未登录）。
  final items = <List<Object>>[
    <Object>[1, '509781655', '想你就写信 (Live)', '周杰伦、李硕、张鑫', 238],
    <Object>[1, '210049', '布拉格广场', '蔡依林、周杰伦', 294],
    <Object>[1, '1888354230', '默 (Live)', '李荣浩、周杰伦', 133],
    <Object>[2, '1F7E7659B9FFF4FB6F71562A61BBC25F', '发如雪', '周杰伦', 0],
    <Object>[2, 'B3A52A7A958BF0AED0EBFBA2E9A818B7', '晴天', '周杰伦', 0],
    <Object>[2, '8909E1809908CD8E3BF6CF85D98B93F0', '稻香', '周杰伦', 0],
    <Object>[0, '0027oMO61wWi55', '发如雪', '周杰伦', 299],
    <Object>[0, '0039MnYb0qxYhV', '晴天', '周杰伦', 269],
    <Object>[0, '00128N3r2SYKMF', '兰亭序', '周杰伦', 253],
  ];
  var switchCount = 0;
  var sameTitle = 0;
  var none = 0;
  for (var i = 0; i < items.length; i++) {
    final m = items[i];
    final song = Song(
      id: m[1] as String,
      platform: m[0] as int,
      title: m[2] as String,
      artist: m[3] as String,
      duration: m[4] as int,
      vip: true,
    );
    _emit('[CASE-A] idx=${i + 1}/9 '
        'platform=${_platformNames[song.platform]} ${_fmtSongBrief(song)}');
    final d = await _detailedFallback(song);
    _emit('[CASE-A-RESULT] idx=${i + 1}/9 decision=$d');
    if (d == 'NO_ALTERNATIVE') {
      none++;
    } else if (d == 'SAME_TITLE_OTHER_PLATFORM') {
      sameTitle++;
    } else {
      switchCount++;
    }
  }
  _emit('[CASE-SUMMARY] total=9 SWITCH_DIFFERENT_VERSION=$switchCount '
      'SAME_TITLE_OTHER_PLATFORM=$sameTitle NO_ALTERNATIVE=$none');
  _emit('[CASE-NOTE] 本实验只模拟 findAlternativeSong 的候选选择（不含 UI 包装）；'
      'app 在首页/歌单/音乐库走 resolveAndPlay 静默兜底（成功后无提示），'
      '搜索页 playTrackGroup 兜底成功会提示“已改用 X 音源播放”。');
}

// ============================================================================
// 第三轮：登录后对照（从模拟器已登录 App 的 Hive 取出真实网易云会话注入探针）
// 敏感约束：cookie 只在内存/系统临时目录使用，证据只输出 cookie 名与打码长度。
// ============================================================================

/// 敏感值只输出长度：不输出任何值片段（首尾片段同样属于可识别信息，审计要求不展示）。
String _secretLen(String s) => 'len=${s.length}';

/// 与 lib playback.findAlternativeSong 完全一致的选择逻辑，返回 app 会实际选中的
/// 候选（用于确认“兜底选中的那个 QQ 音乐同名版本”到底是什么）。
Future<({Song song, String url})?> _appFallbackPick(Song original) async {
  final baseTitle =
      original.title.replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '').trim();
  final artist = original.artist.split('、').first.trim();
  final query = '${baseTitle.isEmpty ? original.title : baseTitle} $artist';
  for (final platform in const <int>[0, 1, 2]) {
    if (platform == original.platform) continue;
    final other = _allApis[platform];
    if (other == null) continue;
    List<Song> candidates;
    try {
      candidates = await other
          .searchSongs(query, size: 5)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      continue;
    }
    var accepted = 0;
    for (final c in candidates) {
      if (c.vip || !_similarTitle(c.title, original.title)) continue;
      if (accepted >= 3) break;
      accepted++;
      try {
        final u =
            await other.getPlayUrl(c).timeout(const Duration(seconds: 10));
        if (u != null && u.isNotEmpty) {
          return (song: c, url: u);
        }
      } catch (_) {}
    }
  }
  return null;
}

Future<void> _runCaseThirdRound() async {
  _emit('[CASE] ===== 第三轮：登录后对照（网易云真实会话注入）=====');

  // ---- 1) 读取 Hive 提取的会话（系统临时目录；不写入仓库、不打印值） ----
  final cookiePath = Platform.environment['JX_COOKIE_FILE'] ?? '';
  if (cookiePath.isEmpty) {
    _emit('[LOGIN-SESSION] result=MISSING_ENV JX_COOKIE_FILE 未设置，未验证登录后行为');
    return;
  }
  Map<String, dynamic> data;
  try {
    data = jsonDecode(File(cookiePath).readAsStringSync())
        as Map<String, dynamic>;
  } catch (e) {
    _emit('[LOGIN-SESSION] result=READ_FAIL error="${_err(e)}"');
    return;
  }
  final cookies = <String, String>{};
  final rawCookies = data['cookies'];
  if (rawCookies is Map) {
    rawCookies.forEach((k, v) => cookies['$k'] = '$v');
  }
  final names = cookies.keys.toList()..sort();
  final cookieHeader =
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  _emit('[LOGIN-SESSION] source=模拟器 App Hive(jx_accounts.hive) '
      'cookieNames=${names.join(',')} count=${cookies.length} '
      'MUSIC_U(${_secretLen(cookies['MUSIC_U'] ?? '')}) '
      '__csrf(${_secretLen(cookies['__csrf'] ?? '')}) '
      '（仅记录 cookie 名+长度，不输出任何值片段；cookie 只存内存/系统临时目录）');
  _neteaseCookieForRaw = cookieHeader;

  final ne = NeteaseApi();
  ne.restoreSession(AccountSession(
    platform: 1,
    cookies: cookies,
    nickname: '${data['nickname'] ?? '网易云用户'}',
  ));

  // ---- 2) 会话有效性 / 会员状态校验（直接问网易云账号接口） ----
  try {
    final resp = await JXHttp.dio
        .get(
          'https://music.163.com/api/nuser/account/get',
          options: Options(
            validateStatus: (_) => true,
            headers: <String, String>{
              'Cookie': cookieHeader,
              'Referer': 'https://music.163.com/',
            },
          ),
        )
        .timeout(const Duration(seconds: 20));
    final m = resp.data is Map ? resp.data as Map : const {};
    final profile = m['profile'];
    final account = m['account'];
    final vipType = profile is Map ? '${profile['vipType'] ?? ''}' : '';
    final nick = profile is Map ? '${profile['nickname'] ?? ''}' : '';
    final accountType = account is Map ? '${account['type'] ?? ''}' : '';
    _emit('[LOGIN-ACCOUNT] http=${resp.statusCode} code=${m['code']} '
        'hasProfile=${profile is Map} hasAccount=${account is Map} '
        'vipType=$vipType accountType=$accountType '
        'nicknameMasked=${nick.isEmpty ? '-' : 'len=${nick.length}'}');
  } catch (e) {
    _emit('[LOGIN-ACCOUNT] error="${_err(e)}"');
  }

  // ---- 3) 同一批样本：登录后重测（含用户样本 7 Years 与免费对照） ----
  final runner = _Runner(api: ne, candidateQueries: const <String>[]);
  const samples = <Song>[
    Song(
        id: '405599119',
        platform: 1,
        title: '7 Years',
        artist: 'Lukas Graham',
        duration: 237,
        vip: true),
    Song(
        id: '509781655',
        platform: 1,
        title: '想你就写信 (Live)',
        artist: '周杰伦、李硕、张鑫',
        duration: 238,
        vip: true),
    Song(
        id: '210049',
        platform: 1,
        title: '布拉格广场',
        artist: '蔡依林、周杰伦',
        duration: 294,
        vip: true),
    Song(
        id: '1888354230',
        platform: 1,
        title: '默 (Live)',
        artist: '李荣浩、周杰伦',
        duration: 133,
        vip: true),
    Song(
        id: '5257138',
        platform: 1,
        title: '屋顶',
        artist: '周杰伦、温岚、吴宗宪',
        duration: 319,
        vip: false),
  ];
  var idx = 0;
  for (final s in samples) {
    idx++;
    _emit('[LOGIN-TARGET] idx=$idx target=${s.vip ? 'VIP' : 'FREE_CONTROL'} '
        '${_fmtSongBrief(s)}');
    await runner._sample(s, idx);
  }

  // ---- 4) 未登录 vs 已登录 对照（未登录行号来自本轮之前的证据） ----
  const unloggedRef = <int, String>{
    1: 'L0213 itemCode=-110 fee=1（7 Years 未登录）',
    2: 'L0075 itemCode=-110 fee=1（想你就写信 未登录）',
    3: 'L0106 itemCode=-110 fee=1（布拉格广场 未登录）',
    4: 'L0129 itemCode=-110 fee=1（默 未登录）',
    5: 'L0045 itemCode=200 url（屋顶 未登录免费对照）',
  };
  for (final o in runner.outcomes) {
    final raw = o.raw;
    _emit('[LOGIN-COMPARE] idx=${o.idx} vip=${o.song.vip} '
        'title="${_sanitize(o.song.title, max: 60)}" '
        'loggedInHttp=${raw['http']} loggedInTopCode="${raw['code']}" '
        'loggedInItemCode="${raw['itemCode']}" '
        'hasUrl=${o.hasUrl} cdnOk=${o.cdnOk} verdict=${o.verdict} '
        '|| 未登录对照: ${unloggedRef[o.idx] ?? '-'}');
  }
  _emit('[LOGIN-COMPARE-SUMMARY] vipSamples=4 '
      'vipOkLoggedIn=${runner.outcomes.where((o) => o.song.vip && o.hasUrl).length} '
      'freeControlOk=${runner.outcomes.where((o) => !o.song.vip && o.hasUrl).length}');

  // ---- 5) 用户样本 7 Years：app 兜底会选中的 QQ 音乐版本到底是什么 ----
  final seven = samples.first;
  final alt = await _appFallbackPick(seven);
  if (alt == null) {
    _emit('[FALLBACK-CHECK] song="7 Years" result=NO_FALLBACK_CANDIDATE');
  } else {
    final cdn = await _probeCdn(alt.url, alt.song.platform);
    _emit('[FALLBACK-CHECK] song="7 Years" chosenPlatform='
        '${_platformNames[alt.song.platform]} '
        '${_fmtSongBrief(alt.song)} '
        'version=${_versionOf(seven, alt.song)} getPlayUrl=true');
    _emit('[FALLBACK-CHECK-CDN] http=${cdn.status} ct="${cdn.ct}" '
        'bytes=${cdn.bytes} magic="${cdn.magic}" audioMagic=${cdn.audioMagic} '
        'ok=${cdn.ok}${cdn.err == null ? '' : ' err="${cdn.err}"'}');
    _emit('[FALLBACK-CHECK-VERDICT] 该候选 vip=${alt.song.vip} '
        '（false=非 VIP，排除“兜底选到 VIP/无版权版本”假设；'
        '失败发生在播放层而非解析层，见报告 §9）');
  }
}

/// CDN Range 探测（顶层函数，供主流程与专项共用）：
/// 取前 4KB，判定 200/206 + 音频魔数 + content-type 非 html/json。
Future<_CdnResult> _probeCdn(String url, int platform) async {
  final result = _CdnResult();
  final sw = Stopwatch()..start();
  try {
    final resp = await JXHttp.dio
        .get<List<int>>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            headers: <String, String>{
              'User-Agent': _ua,
              'Range': 'bytes=0-4095',
              if (platform == 0) 'Referer': 'https://y.qq.com/',
              if (platform == 1) 'Referer': 'https://music.163.com/',
              if (platform == 2) 'Referer': 'https://m.kugou.com/',
            },
            validateStatus: (_) => true,
            followRedirects: true,
            receiveTimeout: const Duration(seconds: 20),
          ),
        )
        .timeout(const Duration(seconds: 25));
    sw.stop();
    final data = resp.data;
    final bytes = data is List<int> ? data : <int>[];
    result
      ..status = resp.statusCode ?? 0
      ..ct = (resp.headers.value('content-type') ?? '').toLowerCase()
      ..bytes = bytes.length
      ..magic = bytes
          .take(8)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
      ..audioMagic = _audioMagic(bytes);
    result.ok = (result.status == 200 || result.status == 206) &&
        result.bytes > 512 &&
        result.audioMagic &&
        !result.ct.contains('html') &&
        !result.ct.contains('json');
  } catch (e) {
    sw.stop();
    result.err = _err(e);
  }
  result.ms = sw.elapsedMilliseconds;
  return result;
}
