import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { WantAgent, common, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  BinaryMessenger,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';

const DOMAIN = 0x04A0;
const TAG = 'JxAvSession';
const CHANNEL_NAME = 'jxmusic/avsession';

/**
 * ohos 系统媒体会话（AVSession）+ 后台长时任务（AUDIO_PLAYBACK）管理器。
 *
 * 与 Flutter 侧 lib/services/avsession_service.dart 通过名为
 * 'jxmusic/avsession' 的 MethodChannel 通信：
 * - Flutter -> 原生：updateMetadata / updatePlaybackState / startBackground /
 *   stopBackground（onMethodCall 处理）；
 * - 原生 -> Flutter：play / pause / playNext / playPrevious / seek
 *   （系统媒体控制命令转发，seek 携带 {'positionMs': number}）。
 *
 * AVSession 由 EntryAbility 在 configureFlutterEngine 时创建并 activate，
 * 使锁屏 / 播控中心 / 耳机线控的播放暂停、上下曲、进度拖动都能控制 App；
 * 长时任务在 Flutter 侧首次开始播放时经 startBackground 申请，保证退后台
 * 播放不被冻结。
 */
export class JxAvSessionManager implements MethodCallHandler {
  private channel: MethodChannel | null = null;
  private session: avSession.AVSession | null = null;
  private context: common.UIAbilityContext | null = null;
  private bgRunning: boolean = false;

  /**
   * 创建媒体会话并挂接 Flutter 通道。须在 UIAbility 上下文调用（Dart 侧
   * 代码尚未运行前完成注册，保证首条 updateMetadata 不丢失）。
   */
  setup(context: common.UIAbilityContext, messenger: BinaryMessenger): void {
    this.context = context;
    this.channel = new MethodChannel(messenger, CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    avSession.createAVSession(context, 'jxmusic', 'audio')
      .then((session: avSession.AVSession) => {
        this.session = session;
        this.registerCommands(session);
        session.activate().catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'activate failed: %{public}d', err.code);
        });
        hilog.info(DOMAIN, TAG, 'AVSession created');
      })
      .catch((err: BusinessError) => {
        // 无 AVSession 也能播，只是失去系统媒体控制；不阻断启动
        hilog.warn(DOMAIN, TAG, 'createAVSession failed: %{public}d', err.code);
      });
  }

  /** 注册系统媒体控制命令并转发给 Flutter。 */
  private registerCommands(session: avSession.AVSession): void {
    session.on('play', () => {
      this.channel?.invokeMethod('play', null);
    });
    session.on('pause', () => {
      this.channel?.invokeMethod('pause', null);
    });
    session.on('playNext', () => {
      this.channel?.invokeMethod('playNext', null);
    });
    session.on('playPrevious', () => {
      this.channel?.invokeMethod('playPrevious', null);
    });
    session.on('seek', (time: number) => {
      const args: Map<string, number> = new Map<string, number>();
      args.set('positionMs', time);
      this.channel?.invokeMethod('seek', args);
    });
  }

  /** Flutter -> 原生方法入口。 */
  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'updateMetadata':
        this.updateMetadata(call);
        result.success(null);
        break;
      case 'updatePlaybackState':
        this.updatePlaybackState(call);
        result.success(null);
        break;
      case 'startBackground':
        this.startBackground();
        result.success(null);
        break;
      case 'stopBackground':
        this.stopBackground();
        result.success(null);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  /** 把 Flutter 推送的歌曲元数据写入 AVSession（锁屏/播控中心展示）。 */
  private updateMetadata(call: MethodCall): void {
    const session = this.session;
    if (session == null) {
      return;
    }
    const metadata: avSession.AVMetadata = {
      assetId: JxAvSessionManager.readString(call.argument('assetId')),
      title: JxAvSessionManager.readString(call.argument('title')),
      artist: JxAvSessionManager.readString(call.argument('artist')),
      duration: JxAvSessionManager.readNumber(call.argument('durationMs')),
    };
    const cover = JxAvSessionManager.readString(call.argument('coverUrl'));
    if (cover.length > 0) {
      // 封面 URL 交给系统侧解析展示；个别版本对网络封面支持不佳时
      // setAVMetadata 可能失败，由 catch 兜底不影响播放本体。
      metadata.mediaImage = cover;
    }
    session.setAVMetadata(metadata).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'setAVMetadata failed: %{public}d', err.code);
    });
  }

  /** 把 Flutter 推送的播放状态写入 AVSession（播控中心进度条/按钮态）。 */
  private updatePlaybackState(call: MethodCall): void {
    const session = this.session;
    if (session == null) {
      return;
    }
    const playing = JxAvSessionManager.readBool(call.argument('playing'));
    const position: avSession.PlaybackPosition = {
      elapsedTime: JxAvSessionManager.readNumber(call.argument('positionMs')),
      updateTime: Date.now(),
    };
    const speed = JxAvSessionManager.readNumber(call.argument('speed'));
    const state: avSession.AVPlaybackState = {
      state: playing
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      position: position,
      duration: JxAvSessionManager.readNumber(call.argument('durationMs')),
      speed: speed > 0 ? speed : 1.0,
    };
    session.setAVPlaybackState(state).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'setAVPlaybackState failed: %{public}d', err.code);
    });
  }

  /** 申请 AUDIO_PLAYBACK 后台长时任务（幂等）。 */
  private startBackground(): void {
    const context = this.context;
    if (context == null || this.bgRunning) {
      return;
    }
    this.bgRunning = true;
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name,
        },
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
    };
    wantAgent.getWantAgent(wantAgentInfo)
      .then((agent: WantAgent) => {
        backgroundTaskManager
          .startBackgroundRunning(
            context,
            backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
            agent)
          .then(() => {
            hilog.info(DOMAIN, TAG, 'background running started');
          })
          .catch((err: BusinessError) => {
            this.bgRunning = false;
            hilog.warn(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}d',
              err.code);
          });
      })
      .catch((err: BusinessError) => {
        this.bgRunning = false;
        hilog.warn(DOMAIN, TAG, 'getWantAgent failed: %{public}d', err.code);
      });
  }

  /** 释放后台长时任务（幂等）。 */
  private stopBackground(): void {
    const context = this.context;
    if (context == null || !this.bgRunning) {
      return;
    }
    this.bgRunning = false;
    backgroundTaskManager.stopBackgroundRunning(context).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}d', err.code);
    });
  }

  /** UIAbility 销毁时清理：停长时任务、注销命令、销毁会话。 */
  destroy(): void {
    this.stopBackground();
    const session = this.session;
    this.session = null;
    if (session != null) {
      session.off('play');
      session.off('pause');
      session.off('playNext');
      session.off('playPrevious');
      session.off('seek');
      session.destroy().catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'session destroy failed: %{public}d', err.code);
      });
    }
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  private static readString(value: ESObject): string {
    return typeof value === 'string' ? value : '';
  }

  private static readNumber(value: ESObject): number {
    return typeof value === 'number' ? value : 0;
  }

  private static readBool(value: ESObject): boolean {
    return typeof value === 'boolean' ? value : false;
  }
}
