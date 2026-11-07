import '../../models/song.dart';
import '../../models/playlist.dart';
import 'http.dart';

/// 平台接口抽象
abstract class MusicPlatformApi {
  int get platform;

  /// 搜索歌曲
  Future<List<Song>> searchSongs(String keyword, {int page = 1, int size = 30});

  /// 获取歌曲播放 URL（可能返回 null 表示需要登录）
  Future<String?> getPlayUrl(Song song);

  /// 获取歌词（LRC 文本）
  Future<String> getLyrics(Song song);

  /// 获取歌单列表（推荐/分类）
  Future<List<Playlist>> recommendPlaylists({int page = 1, int size = 20});

  /// 获取歌单详情
  Future<List<Song>> playlistSongs(Playlist playlist, {int page = 1, int size = 100});

  /// 获取排行榜
  Future<List<Song>> topSongs({int page = 1, int size = 30});

  /// 扫码登录：返回二维码 URL 与唯一 key
  Future<({String qrUrl, String key})> createQrLogin();

  /// 轮询扫码状态，返回 session（未完成返回 null）
  Future<AccountSession?> pollQrLogin(String key);

  /// 恢复持久化的登录态（应用启动时调用，把 cookie 灌回平台客户端）
  void restoreSession(AccountSession? session);
}

/// 多平台聚合入口
class MusicApiHub {
  final Map<int, MusicPlatformApi> _apis = {};

  void register(MusicPlatformApi api) {
    _apis[api.platform] = api;
  }

  MusicPlatformApi? api(int platform) => _apis[platform];

  /// 聚合搜索：按平台并行，合并结果
  Future<List<Song>> aggregateSearch(String keyword,
      {int page = 1, int size = 30}) async {
    final results = await Future.wait(
      _apis.values
          .map((api) => api.searchSongs(keyword, page: page, size: size)
              .catchError((_) => <Song>[])),
    );
    return results.expand((e) => e).toList();
  }
}
