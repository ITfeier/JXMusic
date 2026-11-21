import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 鸿蒙系统用户文件访问的 Dart 侧通道客户端。
///
/// 与原生 `JxFileAccessPlugin.ets` 通过 `jxmusic/file_access` 通信：
/// - [pickAudioFiles]：拉起系统文件选择器多选音频文件（返回临时授权 URI）；
/// - [persistUris] / [activateUris] / [revokeUris]：授权持久化（重启后可继续访问）；
/// - [openFdUrl]：URI -> `fd://<fd>`（供 media_kit/libmpv 播放）；
/// - [readMetadataByUri]：URI -> [AudioMetadata]（标签+封面，经 `/proc/self/fd`）。
///
/// 元数据读取原理：原生 `openFd` 返回同进程 fd 后，用
/// `File('/proc/self/fd/<fd>')` 重新打开（Linux 对 /proc/self/fd 的 open 等价于
/// dup，不受沙盒路径可见性限制），即可直接交给 audio_metadata_reader 解析，
/// 无需把文件复制进沙盒。
class OhosFileAccess {
  /// [channel] 仅供测试注入；生产环境用默认全局 [instance]。
  OhosFileAccess({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('jxmusic/file_access');

  final MethodChannel _channel;

  /// 全局默认实例（依赖注入的缺省值）。
  static final OhosFileAccess instance = OhosFileAccess();

  /// 当前平台是否支持系统文件导入（仅鸿蒙）。
  bool get isSupported {
    try {
      return Platform.operatingSystem == 'ohos';
    } catch (_) {
      return false;
    }
  }

  /// 拉起系统文件选择器多选音频文件，返回 URI 列表。
  ///
  /// 用户取消（或原生报错）返回空列表：取消是正常路径，不向上抛异常。
  Future<List<String>> pickAudioFiles() async {
    if (!isSupported) return const <String>[];
    try {
      final uris = await _channel.invokeListMethod<String>('pickAudio');
      return uris ?? const <String>[];
    } on PlatformException catch (e) {
      debugPrint('[JXMusic] 系统文件选择取消/失败: ${e.code} ${e.message}');
      return const <String>[];
    } catch (e) {
      debugPrint('[JXMusic] 系统文件选择异常: $e');
      return const <String>[];
    }
  }

  /// 把已获临时授权的 URI 持久化（重启后仍可访问）。
  ///
  /// 返回 false 表示持久化失败（能力缺失/权限未授予）：本次会话临时授权仍可用，
  /// 由调用方决定是否提示「重启后需重新导入」。
  Future<bool> persistUris(List<String> uris) async {
    if (uris.isEmpty) return false;
    return _invokeBool('persistUris', uris);
  }

  /// 激活已持久化的授权（应用/设备重启后访问前必须激活）。
  Future<bool> activateUris(List<String> uris) async {
    if (uris.isEmpty) return false;
    return _invokeBool('activateUris', uris);
  }

  /// 撤销 URI 的持久化授权（从导入列表移除时调用，失败忽略）。
  Future<bool> revokeUris(List<String> uris) async {
    if (uris.isEmpty) return false;
    return _invokeBool('revokeUris', uris);
  }

  Future<bool> _invokeBool(String method, List<String> uris) async {
    try {
      return await _channel.invokeMethod<bool>(
            method,
            <String, Object>{'uris': uris},
          ) ??
          false;
    } catch (e) {
      debugPrint('[JXMusic] $method 失败: $e');
      return false;
    }
  }

  /// 播放解析：URI -> `fd://<fd>`。
  ///
  /// fd 的所有权移交给 libmpv（fd:// 流由 mpv 关闭），调用方不需要也不能再 close。
  /// 打开失败（授权未激活/文件被删）先激活持久化授权再重试一次；仍失败返回 null，
  /// 由播放链路走「无法播放」提示。
  Future<String?> openFdUrl(String uri) async {
    if (uri.isEmpty) return null;
    final direct = await _tryOpenFd(uri);
    if (direct != null) return direct;
    // 重启后持久化授权需激活才生效：激活后重试一次（幂等，未持久化时激活失败直接放弃）
    final activated = await activateUris(<String>[uri]);
    if (!activated) return null;
    return _tryOpenFd(uri);
  }

  Future<String?> _tryOpenFd(String uri) async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'openFd',
        <String, Object>{'uri': uri},
      );
      final fd = map?['fd'];
      if (fd is int && fd >= 0) return 'fd://$fd';
      return null;
    } catch (e) {
      debugPrint('[JXMusic] 打开系统文件失败: $e');
      return null;
    }
  }

  /// 读取 URI 对应音频文件的标签与封面（含图片，导入时使用）。
  ///
  /// 失败返回 null（文件不可读/格式不识别），调用方回退文件名解析。
  Future<AudioMetadata?> readMetadataByUri(String uri) async {
    if (uri.isEmpty) return null;
    int? fd;
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'openFd',
        <String, Object>{'uri': uri},
      );
      fd = map?['fd'];
      if (fd is! int || fd < 0) return null;
      // /proc/self/fd/<fd> 的 open 等价 dup：readMetadata 内部自开自关该副本，
      // 不影响 fd 本身；finally 里统一释放 fd。
      final file = File('/proc/self/fd/$fd');
      return readMetadata(file, getImage: true);
    } catch (e) {
      debugPrint('[JXMusic] 读取系统文件标签失败: $e');
      return null;
    } finally {
      final opened = fd;
      if (opened != null) {
        try {
          await _channel.invokeMethod<void>(
            'closeFd',
            <String, Object>{'fd': opened},
          );
        } catch (_) {
          // close 失败不阻塞导入流程
        }
      }
    }
  }
}
