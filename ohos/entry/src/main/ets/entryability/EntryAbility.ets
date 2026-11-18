
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { JxAvSessionManager } from '../avsession/JxAvSessionManager';

export default class EntryAbility extends FlutterAbility {
  private avSessionManager: JxAvSessionManager = new JxAvSessionManager();

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // 系统媒体会话（锁屏/播控中心/耳机线控）+ 后台播放长时任务
    this.avSessionManager.setup(this.context, flutterEngine.dartExecutor.getBinaryMessenger())
  }

  onDestroy() {
    this.avSessionManager.destroy()
    super.onDestroy()
  }
}
