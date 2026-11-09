# JXMusic

聚合音乐播放器（Windows / Android），基于 Flutter + libmpv（media_kit）。

支持 **QQ音乐 / 网易云音乐 / 酷狗音乐 / 本地文件** 四个音源，统一搜索、榜单、歌单、播放与歌词。

## 功能

- **聚合搜索**：一次搜索同时命中 QQ音乐 / 网易云 / 酷狗，结果按平台分块展示
- **榜单与歌单**：首页三平台热榜、网易云 + 酷狗推荐歌单、歌单详情与整单播放
- **播放器**：media_kit（libmpv）内核，支持队列、顺序/单曲/列表循环/随机、拖动进度、音量/静音、0.5x–2.0x 倍速、播放队列弹层；队列内歌曲会自动解析直链，所以"播放全部 + 自动下一首"可连续播放
- **桌面增强**：全局键盘快捷键（空格播放暂停、←→ 快退快进、↑↓ 音量、M 静音、N/P 切歌）、窗口置顶、**系统托盘**（关闭收进托盘、托盘菜单可控播放/退出）、**迷你播放窗口**（一键缩成小播放条并置顶），音量/倍速/循环模式等偏好持久化
- **歌词**：LRC 解析、当前行高亮并自动滚动居中
- **音乐库**：收藏、播放历史（同一首歌去重、上限 200 条）、自建歌单（新建/重命名/删除/加歌/移除），全部本地持久化
- **下载**：播放页菜单可把当前歌曲下载到 `下载/JXMusic`（Android 为应用外部存储目录），带进度提示
- **下载管理**：音乐库「下载」页集中管理已下载歌曲：直接播放（离线可听）、定位文件、删除，显示总占用大小
- **扫码登录**：三个平台均走各自官方扫码流程（ptlogin2 / Netease QR / 酷狗 gateway），登录态持久化到本地，重启后仍保持
- **本地音乐**：自定义多个扫描目录（持久化、重启自动扫描）；支持常见音频格式，以及网易云 `.ncm`、QQ 音乐 QMC 系（`.qmc0/.qmc3/.qmcflac/.qmcogg/.mflac/.mgg` 等）、酷狗 `.kgm/.kgma/.vpr` 加密格式解密播放（解密缓存到应用目录，可清理）；`.kgg` 及 QQ `musicex` 尾部需要客户端密钥/暂不支持，会给出明确提示
- **界面**：iOS26 风格液态玻璃，深浅色主题 + 5 种主题色，桌面/手机两套响应式布局

## 运行与构建

```bash
flutter pub get
flutter run -d windows          # 桌面调试
flutter build windows --release # 桌面发布包
flutter build apk --release     # Android 发布包
```

Flutter SDK：>= 3.44（Dart >= 3.13.7）。

### Android release 签名

`android/key.properties` 保存 release 签名配置（已被 `.gitignore` 忽略，**不要提交**）：

```properties
storePassword=...
keyPassword=...
keyAlias=jxmusic
storeFile=jxmusic-release.jks
```

密钥库文件为 `android/jxmusic-release.jks`，**请自行备份**：丢失后无法对已发布的 App 做覆盖升级。
文件缺失时构建会自动回退到 debug 签名，方便本机调试。

## 测试与开发辅助

```bash
flutter test                                        # 单元测试（联网用例默认跳过）
flutter test test/download_integration_test.dart --run-skipped  # 真实下载链路检查
dart run tool/check_kugou_playlist.dart             # 酷狗歌单/播放/歌词接口检查
flutter test test/check_api_test.dart --run-skipped  # 扫码登录接口连通性检查
```

## 目录结构

```
lib/
├── main.dart            # 入口：Hive、media_kit、window_manager 初始化
├── app.dart             # MaterialApp + 主题 + 全局渐变背景
├── providers.dart       # Riverpod：播放器 / 平台 API 聚合 / 登录态 / 设置
├── theme.dart           # 主题构建
├── core/constants.dart  # 颜色、平台常量
├── models/              # Song / Playlist / Lyric
├── services/
│   ├── api/             # QQ、网易云、酷狗接口 + 网易云加密 + HTTP 封装
│   ├── player_service.dart
│   ├── local_music.dart      # 本地多目录扫描 + 加密格式识别
│   ├── local_format_service.dart # 加密格式解密缓存调度（NCM/QMC/KGM）
│   ├── local_paths.dart      # 自定义扫描路径持久化
│   └── local_formats/        # 各平台加密格式解码器（EncryptedAudioDecoder）
└── ui/                  # 页面与液态玻璃组件
```

## 已知限制

- **版权与接口**：播放走各平台公开接口，VIP/付费歌曲需要登录对应平台账号且最终以平台权益为准；接口随时可能调整或风控（QQ 扫码在部分网络下会返回 403）。
- **本地音乐（Android）**：自定义目录依赖「所有文件访问」权限（`MANAGE_EXTERNAL_STORAGE`，侧载分发；上架 Play 商店需改用 SAF）；未授权时本地页会显示授权横幅。`.kgg`、QQ `musicex/STag` 尾部加密暂不支持离线解密，会明确提示而不是静默失败。
- **未实现**：均衡器、桌面歌词、跨端同步（占位）。
