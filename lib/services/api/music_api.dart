import '../../models/song.dart';
import '../../models/playlist.dart';
import '../../models/artist.dart';
import '../../models/album.dart';
import '../../models/lyric_hit.dart';
import 'http.dart';

/// 登录态失效（会话过期 / 平台风控 / token 被拒）。
///
/// 平台 API 在「已登录但平台拒绝该会话」时抛出，区别于「真的 0 个歌单」，
/// UI 据此提示用户去设置页重新登录，而不是误导性地展示 0 个歌单。
class SessionExpiredException implements Exception {
  const SessionExpiredException(this.message);

  /// 面向用户的错误描述（如「登录已过期，请重新登录」）。
  final String message;

  @override
  String toString() => message;
}

/// 单平台登录账号歌单的拉取结果。
class PlatformPlaylists {
  const PlatformPlaylists(this.playlists, {this.error});

  /// 该平台拉到的歌单；出错时为空列表。
  final List<Playlist> playlists;

  /// 平台侧错误信息（[SessionExpiredException.message] 等）；null 表示正常。
  final String? error;

  bool get hasError => error != null;
}

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

  /// 歌单元数据（名称/封面/曲目数）。只在「仅凭 id 拿不到元数据」的场景用
  /// （导入歌单分享链接）：把源歌单的名称和封面带过来。
  /// 失败或不支持返回 null，调用方走手填名称兜底，不阻塞歌曲拉取。
  Future<Playlist?> playlistInfo(Playlist playlist) async => null;

  /// 获取排行榜
  Future<List<Song>> topSongs({int page = 1, int size = 30});

  /// 搜索歌单。不支持的平台保持默认空结果。
  Future<List<Playlist>> searchPlaylists(String keyword,
          {int page = 1, int size = 30}) async =>
      const [];

  /// 搜索歌手。不支持的平台保持默认空结果。
  Future<List<Artist>> searchArtists(String keyword,
          {int page = 1, int size = 30}) async =>
      const [];

  /// 搜索专辑。不支持的平台保持默认空结果。
  Future<List<Album>> searchAlbums(String keyword,
          {int page = 1, int size = 30}) async =>
      const [];

  /// 搜索歌词（命中歌曲 + 片段）。不支持的平台保持默认空结果。
  Future<List<LyricHit>> searchLyrics(String keyword,
          {int page = 1, int size = 30}) async =>
      const [];

  /// 歌手热门歌曲。不支持的平台保持默认空结果。
  Future<List<Song>> artistSongs(Artist artist,
          {int page = 1, int size = 30}) async =>
      const [];

  /// 专辑歌曲。不支持的平台保持默认空结果。
  Future<List<Song>> albumSongs(Album album,
          {int page = 1, int size = 30}) async =>
      const [];

  /// 当前登录账号在平台上的歌单（创建 + 收藏）。
  /// 未登录或不支持的平台保持默认空结果。
  Future<List<Playlist>> userPlaylists(
          {int page = 1, int size = 30}) async =>
      const [];


  /// 扫码登录：返回二维码 URL 与唯一 key
  Future<({String qrUrl, String key})> createQrLogin();

  /// 轮询扫码状态，返回 session（未完成返回 null）
  Future<AccountSession?> pollQrLogin(String key);

  /// 账号密码登录（网易云手机号/邮箱、酷狗账号）。
  /// 不支持账密登录的平台（QQ）保持默认实现返回 null。
  /// 失败返回 null，具体原因见 [lastError]。
  Future<AccountSession?> loginByPassword(String username, String password) async => null;

  /// 发送短信验证码（酷狗手机验证码登录第一步）。
  /// 不支持的平台保持默认返回 false，原因见 [lastError]。
  Future<bool> sendSmsCode(String mobile) async {
    return false;
  }

  /// 短信验证码登录（酷狗）。失败返回 null，原因见 [lastError]。
  Future<AccountSession?> loginBySmsCode(String mobile, String code) async => null;

  /// 恢复持久化的登录态（应用启动时调用，把 cookie 灌回平台客户端）
  void restoreSession(AccountSession? session);

  /// 最近一次扫码相关操作的失败原因（成功/等待时为 null）。
  /// UI 用它展示准确原因；默认无错误，平台实现可覆盖。
  String? get lastError => null;

  /// 最近一次扫码轮询是否为终态（如二维码已过期，QA D-05）。
  /// 终态再轮询无意义，设置页据此提前停止轮询；默认非终态，平台实现可覆盖。
  bool get qrTerminal => false;
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

  /// 聚合搜索歌单：按平台并行，合并结果
  Future<List<Playlist>> aggregateSearchPlaylists(String keyword,
      {int page = 1, int size = 30}) async {
    final results = await Future.wait(
      _apis.values
          .map((api) => api.searchPlaylists(keyword, page: page, size: size)
              .catchError((_) => <Playlist>[])),
    );
    return results.expand((e) => e).toList();
  }

  /// 聚合搜索歌手：按平台并行，合并结果
  Future<List<Artist>> aggregateSearchArtists(String keyword,
      {int page = 1, int size = 30}) async {
    final results = await Future.wait(
      _apis.values
          .map((api) => api.searchArtists(keyword, page: page, size: size)
              .catchError((_) => <Artist>[])),
    );
    return results.expand((e) => e).toList();
  }

  /// 聚合搜索专辑：按平台并行，合并结果
  Future<List<Album>> aggregateSearchAlbums(String keyword,
      {int page = 1, int size = 30}) async {
    final results = await Future.wait(
      _apis.values
          .map((api) => api.searchAlbums(keyword, page: page, size: size)
              .catchError((_) => <Album>[])),
    );
    return results.expand((e) => e).toList();
  }

  /// 聚合搜索歌词：按平台并行，合并结果
  Future<List<LyricHit>> aggregateSearchLyrics(String keyword,
      {int page = 1, int size = 30}) async {
    final results = await Future.wait(
      _apis.values
          .map((api) => api.searchLyrics(keyword, page: page, size: size)
              .catchError((_) => <LyricHit>[])),
    );
    return results.expand((e) => e).toList();
  }

  /// 聚合登录账号歌单：各平台并行拉取，轮询交错合并（QQ/网易/酷狗 A1,B1,C1,A2…）
  Future<List<Playlist>> userPlaylists({int page = 1, int size = 30}) async {
    final results = await Future.wait(
      _apis.values
          .map((api) => api.userPlaylists(page: page, size: size)
              .catchError((_) => <Playlist>[])),
    );
    final lists = [for (final l in results) l.toList()];
    final merged = <Playlist>[];
    var hasMore = true;
    while (hasMore) {
      hasMore = false;
      for (final list in lists) {
        if (list.isNotEmpty) {
          merged.add(list.removeAt(0));
          hasMore = true;
        }
      }
    }
    return merged;
  }

  /// 按平台分组拉取登录账号歌单：key 为 platform，单平台失败不影响其它平台。
  /// 「收藏歌单」页用它展示每个平台的歌单数与登录态错误（未登录的平台
  /// 由 UI 侧根据 accountProvider 判断；登录但会话失效的平台带 error 描述）。
  Future<Map<int, PlatformPlaylists>> userPlaylistsByPlatform(
      {int page = 1, int size = 30}) async {
    final out = <int, PlatformPlaylists>{};
    await Future.wait(_apis.values.map((api) async {
      try {
        out[api.platform] = PlatformPlaylists(
            await api.userPlaylists(page: page, size: size));
      } on SessionExpiredException catch (e) {
        out[api.platform] = PlatformPlaylists(const [], error: e.message);
      } catch (_) {
        out[api.platform] =
            const PlatformPlaylists([], error: '拉取失败，请稍后重试');
      }
    }));
    return out;
  }
}
