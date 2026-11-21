import { picker, fileShare, fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  BinaryMessenger,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';

const DOMAIN = 0x04A1;
const TAG = 'JxFileAccess';
const CHANNEL_NAME = 'jxmusic/file_access';

/** 文件选择器后缀过滤：常见可直播音轨格式（与 Dart 侧 LocalAudioFormats 对应）。 */
const AUDIO_SUFFIX_FILTER = '音乐|.mp3,.flac,.m4a,.aac,.ogg,.opus,.wav,.wma,.ape,.aiff,.aif,.dsf,.dff,.mka';

/** 单次最多可选文件数（API 20 及以下上限 500）。 */
const MAX_SELECT_NUMBER = 500;

/**
 * 鸿蒙系统用户文件访问插件（DocumentViewPicker + 授权持久化 + fd 打开）。
 *
 * 与 Flutter 侧 lib/services/ohos_file_access.dart 通过 'jxmusic/file_access'
 * 的 MethodChannel 通信：
 * - pickAudio：拉起系统文件选择器（多选音频文件，返回临时授权 URI 列表）；
 * - persistUris / activateUris / revokeUris：fileShare 授权持久化/激活/撤销
 *   （重启后凭持久化授权继续访问已导入文件）；
 * - openFd / closeFd：按 URI 打开文件返回 fd（供 mpv fd:// 播放与元数据读取）。
 *
 * Picker 本身无需权限；授权持久化需 ohos.permission.FILE_ACCESS_PERSIST
 * （module.json5 已声明）。
 */
export class JxFileAccessPlugin implements MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;

  /** 挂接 Flutter 通道。须在 UIAbility 上下文调用（Picker 必须在 UIAbility 中拉起）。 */
  setup(context: common.UIAbilityContext, messenger: BinaryMessenger): void {
    this.context = context;
    this.channel = new MethodChannel(messenger, CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    hilog.info(DOMAIN, TAG, 'JxFileAccessPlugin setup');
  }

  /** Flutter -> 原生方法入口。 */
  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'pickAudio':
        this.pickAudio(result);
        break;
      case 'persistUris':
        this.sharePermission(call, result, 'persist');
        break;
      case 'activateUris':
        this.sharePermission(call, result, 'activate');
        break;
      case 'revokeUris':
        this.sharePermission(call, result, 'revoke');
        break;
      case 'openFd':
        this.openFd(call, result);
        break;
      case 'closeFd':
        this.closeFd(call, result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /** 拉起系统文件选择器多选音频文件（无需权限，URI 仅有临时读写授权）。 */
  private pickAudio(result: MethodResult): void {
    const context = this.context;
    if (context == null) {
      result.error('NO_CONTEXT', 'UIAbility context is null', null);
      return;
    }
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = MAX_SELECT_NUMBER;
      options.fileSuffixFilters = [AUDIO_SUFFIX_FILTER];
      const documentPicker = new picker.DocumentViewPicker(context);
      documentPicker
        .select(options)
        .then((uris: Array<string>) => {
          hilog.info(DOMAIN, TAG, 'pickAudio success: %{public}d uris', uris.length);
          result.success(uris);
        })
        .catch((err: BusinessError) => {
          // 用户取消也走这里（13900042 等）：原样回传，由 Flutter 侧静默处理
          hilog.warn(DOMAIN, TAG, 'pickAudio failed: %{public}d', err.code);
          result.error(`${err.code}`, err.message ?? 'picker error', null);
        });
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'pickAudio throw: %{public}d', err.code);
      result.error(`${err.code}`, err.message ?? 'picker throw', null);
    }
  }

  /** 授权持久化/激活/撤销统一入口（均为 READ_MODE + Promise<void>）。 */
  private sharePermission(call: MethodCall, result: MethodResult, action: string): void {
    const uris = JxFileAccessPlugin.readStringArray(call.argument('uris'));
    if (uris.length === 0) {
      result.success(false);
      return;
    }
    const policies: Array<fileShare.PolicyInfo> = [];
    for (const uri of uris) {
      const info: fileShare.PolicyInfo = {
        uri: uri,
        operationMode: fileShare.OperationMode.READ_MODE,
      };
      policies.push(info);
    }
    const task = action === 'persist'
      ? fileShare.persistPermission(policies)
      : action === 'activate'
        ? fileShare.activatePermission(policies)
        : fileShare.revokePermission(policies);
    task
      .then(() => {
        hilog.info(DOMAIN, TAG, '%{public}s success: %{public}d uris', action, uris.length);
        result.success(true);
      })
      .catch((err: BusinessError<Array<fileShare.PolicyErrorResult>>) => {
        // 授权持久化能力缺失（FILE_ACCESS_PERSIST 未授予 / 设备不支持）不阻断导入：
        // 本次会话临时授权仍可用，回传 false 由 Flutter 侧记录警告
        hilog.warn(DOMAIN, TAG, '%{public}s failed: %{public}d', action, err.code);
        result.success(false);
      });
  }

  /** 按 URI 打开文件返回 {fd, size}（URI 需已授权；fd 供 mpv fd:// 播放）。 */
  private openFd(call: MethodCall, result: MethodResult): void {
    const uri = JxFileAccessPlugin.readString(call.argument('uri'));
    if (uri.length === 0) {
      result.error('BAD_ARGS', 'uri is required', null);
      return;
    }
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      const res: Record<string, number> = { 'fd': file.fd, 'size': stat.size };
      result.success(res);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'openFd failed: %{public}d', err.code);
      result.error(`${err.code}`, err.message ?? 'open failed', null);
    }
  }

  /** 关闭 fd（元数据读取完成后释放；交给 mpv 的 fd 由 mpv 自行关闭，不走这里）。 */
  private closeFd(call: MethodCall, result: MethodResult): void {
    const fd = JxFileAccessPlugin.readFd(call.argument('fd'));
    if (fd < 0) {
      result.error('BAD_ARGS', 'fd is required', null);
      return;
    }
    try {
      fileIo.closeSync(fd);
      result.success(null);
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'closeFd failed: %{public}d', err.code);
      result.success(null);
    }
  }

  /** 参数容错读取：uris 可能是 Array<string>（也可能类型漂移），异常返回空数组。 */
  private static readStringArray(raw: ESObject | null): Array<string> {
    if (raw == null || typeof raw !== 'object') {
      return [];
    }
    const out: Array<string> = [];
    try {
      const arr = raw as Array<string>;
      for (const item of arr) {
        if (typeof item === 'string' && item.length > 0) {
          out.push(item);
        }
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'readStringArray failed');
    }
    return out;
  }

  private static readString(value: ESObject): string {
    return typeof value === 'string' ? value : '';
  }

  /** fd 容错读取：非法值返回 -1（fd 合法取值为非负整数）。 */
  private static readFd(value: ESObject): number {
    return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : -1;
  }
}
