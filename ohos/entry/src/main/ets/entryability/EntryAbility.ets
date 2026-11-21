
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { JxAvSessionManager } from '../avsession/JxAvSessionManager';
import { JxFileAccessPlugin } from '../fileaccess/JxFileAccessPlugin';

export default class EntryAbility extends FlutterAbility {
  private avSessionManager: JxAvSessionManager = new JxAvSessionManager();
  private fileAccessPlugin: JxFileAccessPlugin = new JxFileAccessPlugin();

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // 系统媒体会话（锁屏/播控中心/耳机线控）+ 后台播放长时任务
    this.avSessionManager.setup(this.context, flutterEngine.dartExecutor.getBinaryMessenger())
    // 系统文件选择器/授权持久化（本地音乐导入系统文件夹）
    this.fileAccessPlugin.setup(this.context, flutterEngine.dartExecutor.getBinaryMessenger())
  }

  onDestroy() {
    this.avSessionManager.destroy()
    super.onDestroy()
  }
}
