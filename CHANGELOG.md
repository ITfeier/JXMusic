# CHANGELOG

## 0.11.0+27 — 2026-11-18

### 修复（网易云/酷狗登录账号歌单拉取：两处接口 bug + 错误态透明化）

真机诊断（新增 `tool/probe_playlists.dart`：读设备沙盒 `jx_accounts.hive` 的真实登录态，`dart run -DJX_PROBE=true` 离线复现三平台 userPlaylists 并打印原始响应）定位：
- **网易云「0 个歌单」是两个接口 bug，会话其实一直有效**：① 拿 uid 的端点写错——`/api/user/account` 返回 404「接口未找到」，正确老接口为 `/api/nuser/account/get`；② `/api/user/playlist` 老接口的响应字段是单数 **`playlist`**（`{"more":false,"playlist":[…],"code":200}`），代码读的是 `playlists` → 永远解析出空列表。修复后真机网易云 4 个歌单正常加载（喜欢的音乐/山有木兮…）。
- **酷狗「0 个歌单」是 token 真失效**：`/v7/get_all_list` 网关返回 `{"status":0,"error_code":20017}`，此前被 catch 静默吞掉、UI 误导性显示「0 个歌单」；现在如实显示「登录已过期，请重新登录」并引导重登。
- QQ 正常（4 个歌单），未受影响。

### 改动明细

- **`lib/services/api/netease_api.dart`**：`userPlaylists` 端点修正为 `/api/nuser/account/get`；歌单列表解析兼容 `playlist`/`playlists` 两种字段名；带 MUSIC_U 但 `profile` 为 null 时抛 `SessionExpiredException('登录已过期，请重新登录')`（`on SessionExpiredException { rethrow; }` 不被兜底 catch 吞掉），作为真会话失效时的安全网；`-DJX_PROBE` 探针打印保留（编译期剔除，release 零开销）。
- **`lib/services/api/kugou_api.dart`**：`userPlaylists` 在网关返回非零 `error_code`（20017 过期 / 20028 风控 / 其它）时抛对应 `SessionExpiredException`（琥珀 chip 提示重登），root 为 null 归为「网络错误或登录已过期」；同样 rethrow 不吞。
- **`lib/services/api/music_api.dart`**：新增 `SessionExpiredException`（会话失效异常，携带面向用户的 message）与 `PlatformPlaylists`（单平台歌单拉取结果：`playlists` + `error`）；`userPlaylistsByPlatform()` 返回 `Map<int, PlatformPlaylists>`——会话失效平台带 error 描述，其它异常归为「拉取失败」，单平台失败不影响其它平台。
- **`lib/ui/library_page.dart`**：`_platformErrors`（Set）标记会话失效平台；chip 错误态用琥珀警示色（区别于平台色与灰色「未登录」），文案展示真实原因（如「酷狗音乐 · 登录已过期，请重新登录」），点击跳设置页重登（Tooltip「去设置重新登录」）；空态「去设置登录」按钮条件扩展为「未登录 或 会话失效」。
- 新增 `tool/probe_playlists.dart` 一次性诊断探针（不进 App 产物）。

### 测试与验收

- `test/user_playlists_test.dart`：`_FakePlatformApi` 新增 `sessionError`（抛 `SessionExpiredException` 模拟「已登录但平台拒绝会话」）；新增 hub 层用例（userPlaylistsByPlatform 会话失效平台带 error、不影响其它平台）与 UI 层用例（网易云/酷狗 chip 显示「登录已过期，请重新登录」、点击跳设置页 navIndex==4）。
- 门禁：`flutter analyze` 8 issue 基线不变；`flutter test --reporter json` **438 testDone / 0 failure / 0 error** 全绿（新基线 438）。
- 真机装机自检（uitest dumpLayout）：收藏歌单 tab 实测「QQ音乐 · 4 个歌单」「网易云音乐 · 4 个歌单」「酷狗音乐 · 登录已过期，请重新登录」，QQ/网易云歌单卡片正常渲染。

## 0.11.0+26 — 2026-11-17

### 新增（应用内收藏歌单）

- **本机收藏歌单**（`lib/services/library_store.dart`）：playlistsBox 新增 `c:` 前缀条目——`collectedPlaylists`（getter）、`isCollected(playlist)`（同平台同 id 判重）、`toggleCollectedPlaylist(playlist)`（收藏 insert(0) + Hive 持久化 / 取消删除，返回切换后状态）；重载时按 addedAt 降序恢复。同平台同 id 视为同一歌单。
- **歌单详情收藏按钮**（`lib/ui/playlist_detail_page.dart`）：详情页头部新增星标 IconButton（`star_border_rounded`/`star_rounded`，主色），点击切换本机收藏并以 SnackBar 提示「已收藏「xx」/已取消收藏」。
- **收藏歌单 tab 改造**（`lib/ui/library_page.dart`）：
  - 顶部新增三平台状态 chip（`_PlatformStatusChip`）：未登录显示「平台 · 未登录」不拉取，已登录显示「平台 · N 个歌单」，拉取失败显示错误态——「为什么这个平台是空的」一眼可见；
  - `MusicApiHub.userPlaylistsByPlatform()`（`lib/services/api/music_api.dart`）返回 `Map<int, List<Playlist>>`，单平台失败不影响其它平台；
  - 区块化渲染：「本机收藏 N」区块（store.collectedPlaylists）+「平台账号歌单」区块（平台歌单过滤掉已本机收藏的，去重）；两者皆空显示引导空态。

### 修复（首页点歌只有单曲进队列）

- `lib/ui/home_page.dart`：`_resolveAndPlay(Song song, {List<Song>? queue})` 增加 queue 参数——5 个调用点（桌面猜你喜欢、手机猜你喜欢、手机热歌榜、桌面热歌榜、_playTop）全部传所在列表整单：热歌榜 60 首三平台交错、猜你喜欢 picks、_playTop 用 `_tops[p]`；点任何列表歌曲，队列=所在列表全部歌曲。

### 测试与验收

- 新增 `test/home_queue_test.dart`：热歌榜点歌 60 首整单进队列 + 切行只换索引不换队列。
- 新增/更新 `test/user_playlists_test.dart`：pumpLibrary 支持 `loggedIn` 平台集合（AccountNotifier override）；未登录/部分登录状态 chip 断言；「歌单详情收藏：本机收藏展示+平台去重+取消恢复」端到端。
- 新增 `test/library_store_test.dart` 本机收藏歌单用例：收藏/取消/同平台同 id 去重/持久化/重载排序。
- 补齐 `playlist_detail_page_test` / `playlist_list_page_test` / `search_modules_test` 的 Hive 初始化（详情页 watch libraryProvider 后需要 box）。
- 门禁：`flutter analyze` 8 issue 基线不变；`flutter test --reporter json` **436 testDone / 0 failure / 0 error** 全绿（新基线 436）。

## 0.11.0+25 — 2026-11-17

### 新增（ohos AVSession 系统媒体会话 + 后台播放长时任务）

- **原生侧**（ohos/entry）：
  - 新建 `ets/avsession/JxAvSessionManager.ets`：`createAVSession('audio')` + `activate()`（锁屏/播控中心/耳机线控可控）；注册 play/pause/playNext/playPrevious/seek 命令监听并经 `jxmusic/avsession` MethodChannel 转发给 Flutter；接收 Flutter 推送的 `updateMetadata`（标题/歌手/封面 URL/时长 → setAVMetadata，mediaImage 失败静默兜底）/`updatePlaybackState`（播放态/进度/时长/倍速 → setAVPlaybackState，进度含 updateTime）/`startBackground`/`stopBackground`（`backgroundTaskManager` AUDIO_PLAYBACK 长时任务 + wantAgent 通知回跳，幂等）；
  - `EntryAbility.ets`：`configureFlutterEngine` 里 setup（Dart 启动前通道就绪），`onDestroy` 里 destroy（停任务/注销命令/销毁会话）；
  - `module.json5`：EntryAbility 加 `backgroundModes: ["audioPlayback"]`；`requestPermissions` 加 `ohos.permission.KEEP_BACKGROUND_RUNNING`（reason/usedScene 三语齐全）。
- **Flutter 侧**：
  - 新建 `lib/services/avsession_service.dart`：监听 PlayerService——换歌推元数据、播放态变化即推、进度按 ~1s 节流推；首次播放申请后台长时任务、清空队列释放；接收系统命令转发回 PlayerService（seek 解析 positionMs）；通道异常一律静默降级，不影响播放本体；仅 ohos 生效（`supported`）；
  - `app.dart`：`AvSessionService.supported` 时随播放器服务一起初始化。
- **验收**：锁屏/控制中心应出现媒体卡片（标题/歌手/进度），退后台播放不被冻结；后续真机验证后台播放与 READ_MEDIA 授权。

### 测试与验收

- 新增 `test/avsession_service_test.dart` 8 项 4 组全绿：A 系统命令转发（含未知命令静默）/ B 元数据与后台任务推送（换歌只推一次、清队列释放）/ C 状态推送与 ~1s 进度节流 / D 初始化幂等 + supported 平台判定。
- 门禁：`flutter analyze` 8 issue 基线不变；`flutter test --reporter json` **425 testDone / 0 failure / 0 error** 全绿（新基线 425）；ArkTS 静态检查 0 错误；signed HAP 构建成功。

## 0.11.0+24 — 2026-11-17

### 改进（播放器 UI 改版：沉浸式封面背景，保红线契约）

- **沉浸式封面背景**：播放页背景升级为「渐变底色 + 封面模糊放大铺满 + 压暗渐变」三层结构——有封面时全屏模糊封面（`_BackdropArt`：复用 `JXCoverImage` 的网络/本地/UA/网易云变体重试逻辑，`cacheWidth:180` 小尺寸解码省内存，`Transform.scale(1.25)` 出血避免 blur 边缘暗角），叠加深浅色各自的可读性渐变（`_BackdropScrim`）；切歌时封面背景 700ms 交叉淡化；封面加载中/失败回落纯渐变，空 coverUrl（列表占位/无封面歌曲）整层不渲染。key：`playerBackdropArt` / `playerBackdropScrim`。
- **顶部栏精简**：两行「正在播放 + 应用名」精简为单行「正在播放」（letterSpacing 2），更简洁。
- **进度条精致化**：进度 Slider 套 `SliderTheme`（trackHeight 3.5、小 thumb 6、overlay 14），拖动/seek 逻辑不变。
- **播放/暂停图标动画**：主播放键图标用 `AnimatedSwitcher` 缩放淡入切换（180ms），动画连贯。
- **红线契约全部保持**：`jxPlayerCoverSize/CoverGap/Compact` 纯函数与文案块预算未动；音源按钮（`sourceSwitchButton` 64~120dp 紧凑胶囊/右对齐/26dp 高）未动；黑胶唱片 `JXVinylDisc` 与歌词三态（loading/empty/error+重试、AnimatedSwitcher 300ms）未动；音量条平台化逻辑未动。

### 测试与验收

- 新增 `test/player_backdrop_test.dart` 3 项：有封面背景两层渲染且带 blur 滤镜、无封面两层都不渲染（退回纯渐变）、顶部栏单行且无应用名副标题。
- 门禁：`flutter analyze` 8 issue 基线不变；`flutter test --reporter json` **417 testDone / 0 failure / 0 error** 全绿（新基线 417）。

## 0.11.0+23 — 2026-11-17

### 新增（音效设置）

- **播放器音效预设**：新增 `lib/services/audio_effect.dart` 预设目录（`JXAudioEffects`），6 档预设——原声 / 重低音（`lavfi=[bass=g=6]`）/ 人声（`lavfi=[equalizer=f=1200:t=q:w=1.4:g=5]`）/ 3D环绕（`extrastereo`）/ 演唱会（`lavfi=[aecho=0.8:0.9:60:0.35]`）/ 响度均衡（`lavfi=[loudnorm=I=-16:TP=-1.5:LRA=11]`）。
- **实时下发 mpv 滤镜链**：`PlayerService.setAudioEffect(id)` 校验未知 id、重复设置跳过，经 `NativePlayer.setProperty('af', chain)` 整链替换（`''` 清空滤镜链恢复原声），播放中实时生效、不中断当前曲目；下发异常 try/catch 静默降级不影响播放。
- **持久化与恢复**：预设 id 经 `onSettingChanged('audioEffect', id)` 落 Hive（`jx_settings`），启动时 `initialAudioEffect` 恢复（`_readSettingsString` 新增，非法/漂移存档兜底原声）。
- **设置页「音效」区块**：外观与桌面之间新增独立 section，6 预设胶囊单选（复用外观胶囊视觉：选中主题色填充、未选中液态玻璃），底部一行说明文案；key `audioEffectPill_{id}`。

### 测试与验收

- 新增 `test/audio_effect_test.dart` 10 项：预设映射纯逻辑（afFor/labelFor/isValid、未知 id 兜底）、PlayerService 契约（非法初始值兜底、重复/非法设置不回调、切回原声）、设置页结构与交互（6 胶囊齐全、点击切换 bass→none）、持久化往返（onSettingChanged 落 Hive → initialAudioEffect 重启恢复，plain test 真实写 Hive）。
- `test/theme_settings_test.dart`、`test/top_safe_area_test.dart` 补 `playerServiceProvider.overrideWith((ref) => PlayerService(initPlayer: false))`——设置页音效区开始 watch playerServiceProvider，pump 设置页的既有用例需隔离 media_kit。
- 门禁：`flutter analyze` 8 issue 基线不变；`flutter test --reporter json` **413 testDone / 0 failure / 0 error** 全绿（新基线 413）。

## 0.11.0+22 — 2026-11-17

### 改进（音量系统接管 + 主题自定义扩展）

- **手机端移除应用内音量条**：播放页音量图标/滑块仅在桌面（Windows/macOS/Linux）保留，手机端（Android/ohos/iOS）音量由系统音量键接管；软件音量不再恢复历史应用内值、固定 100，避免「两套音量」叠加衰减。倍速按钮全平台保留（手机端右对齐）。
- **外观模式三选一**：设置页「深色模式」开关升级为「跟随系统 / 浅色 / 深色」胶囊（`followSystemThemeProvider` 新增，`ThemeMode.system` 交给 MaterialApp 自动随系统切换；手动模式保留原 darkMode 值，关掉跟随时回到该值）。
- **主题色扩展到 10 色**：色板由 5 色扩为 10 色（湖蓝/晴空/青碧/翠绿/琥珀/绯红/樱粉/紫罗兰/酷青/石墨，`JXThemePalette` 统一维护），Wrap 布局窄屏自动换行；仍作为 `buildJXTheme` 种子色动态生成整套配色。

### 测试与验收

- 新增 `test/player_volume_test.dart` 6 项（TargetPlatformVariant 驱动 android/ohos/iOS × 音量条隐藏 + windows/macOS/linux × 音量条保留）；注意 `_verifyInvariants` 在 tearDown 前校验 foundation debug 变量，平台覆写必须用 `variant:` 而非手动改 `debugDefaultTargetPlatformOverride`。
- 新增 `test/theme_settings_test.dart` 2 项：外观结构（三胶囊 + 10 色板 360dp 窄屏齐全）、外观交互（浅色/跟随系统/深色切换与 darkMode/followSystemTheme/themeColor 持久化；写 Hive 用例最后声明）。
- 门禁：`flutter analyze` 8 issue 基线不变；`flutter test --reporter json` **403 testDone / 0 failure / 0 error** 全绿。

## 0.11.0+21 — 2026-11-17

### 新增（首页猜你喜欢 + 鸿蒙本地常用目录）

- **首页「猜你喜欢」**：基于播放历史与收藏统计口味歌手（历史 1 分/次、收藏 2 分/首、同分按名字升序，取前 6），按口味歌手轮换 QQ/网易/酷狗搜索候选池（排除已听、globalId 去重、每歌手 size:15），Fisher-Yates 洗牌后按「日期种子 + 批次」取 9 首展示；同日同批刷新结果稳定，「换一批」批次 +1 不重新搜索；无播放历史时区块整体隐藏；推荐加载失败静默降级，不影响首页主内容。纯逻辑收敛在 `lib/services/guess_you_like.dart`（`dailySeed` / `splitArtists` / `tasteArtists` / `dailyShuffle` / `picks`）。
- **鸿蒙本地音乐常用目录**：`LocalPathsStore` 默认候选新增 ohos 分支——用户公共目录 `/storage/Users/currentUser/{Music,Download}`、媒体库公共目录 `/storage/media/100/local/files/{Music,Download}`，不存在的自动过滤（沙盒场景退化为仅应用目录）；`isOhos` 可注入便于桌面单测。ohos `module.json5` 声明 `ohos.permission.READ_MEDIA`（reason + usedScene，三语言 string 资源），公共目录直读依赖该授权。

### 测试与验收

- 新增 `test/guess_you_like_test.dart` 8 项：纯逻辑 5 项（日期种子、歌手拆分、口味评分排序、洗牌不改原列表、picks 稳定去重）+ widget 3 项（排除已听+平台轮换搜索、换一批批次复算、无历史隐藏）。
- 新增 `test/local_paths_test.dart` ohos 分支 2 项：候选目录存在性过滤、宿主平台判定。
- 门禁：`flutter analyze` 8 issue 基线不变；`flutter test --reporter json` **391 testDone / 0 failure / 0 error** 全绿；`flutter build hap --debug` 签名包构建成功。
- 工具链修复：flutter_ohos 工具源码的插件 symlink junction 兜底补丁存在 `ProcessResult` 编译错误（快照未重建、补丁从未生效），修复后重建 `flutter_tools.snapshot`，Windows 无开发者模式也能正常构建。

## 0.11.0+20 — 2026-11-17

### 新增（音乐库：平台收藏歌单聚合 + 导入歌单）

- **平台收藏歌单 tab**：音乐库新增「收藏歌单」页签，聚合展示当前登录账号在 QQ 音乐 / 网易云 / 酷狗创建和收藏的歌单（三平台并行拉取，轮询交错合并 A1,B1,C1,A2…），点卡片直接进歌单详情；每次切入自动重新拉取（登录态变更即时生效），右上角支持手动刷新；未登录任何平台时给出登录引导文案。
- **三平台账号歌单接口**：
  - 网易云：`/api/user/account`（Cookie MUSIC_U）取 uid → `/api/user/playlist` 列歌单
  - QQ：musicu `PlaylistBaseRead.GetPlaylistByUin`（创建）+ `PlaylistFavRead.CgiGetPlaylistFavInfo`（收藏，euin 加密 best-effort），字段别名兼容（tid/dissid、dissname/title、picurl/logo）
  - 酷狗：gateway `/v7/get_all_list`（android 签名 + x-router cloudlist），tolerant 多别名解析（specialid/specialname/img/count 等）
- **导入歌单**：「歌单」页签新增「导入歌单」——粘贴网易云 / QQ / 酷狗歌单分享链接或纯数字歌单 ID（`parseJXPlaylistLink`：网易云 fragment 链接、QQ ryqq 路径、酷狗 specialid 全识别），拉取歌单全部歌曲后命名存为本地自建歌单；空歌单 / 无效链接给出失败提示。
- **窄屏适配**：音乐库头部在窄屏（<380dp）下「导入歌单 / 新建歌单」文字按钮换图标按钮（Tooltip 保留语义），修复 360dp 级屏幕 RenderFlex 溢出 15px。

### 测试与验收

- 新增 `test/user_playlists_test.dart` 12 项：链接解析 6 项（fragment/m 页/ryqq/specialid/纯数字/垃圾输入）、Hub 轮询交错 2 项（不等长补位 + 全未登录）、音乐库页 4 项（五 tab 齐全 + 聚合交错 + 点卡片进详情、未登录引导、导入成功全链路、导入失败提示）。
- 测试基建要点：testWidgets fake async 里发起的 Hive 磁盘写入其管线由 Timer/IO 事件驱动、测试结束后不再推进，Hive 写队列会卡住——之后任何 `await` 该 box（clear/close）都永不返回；因此**写入 Hive 的用例必须最后声明**，且 `tearDownAll` 不能 `await Hive.close()`。SnackBar 的 4s 超时计时器在入场动画完成后才创建，断言 toast 可见需先 pump 过入场动画再跳 4s，结束后用 `ScaffoldMessengerState.clearSnackBars/removeCurrentSnackBar` 确定性清队列。
- 门禁：`flutter analyze` 8 issue 基线不变；`flutter test --reporter json` **378 testDone / 0 failure / 0 error** 全绿。

## 0.10.0+19 — 2026-11-09

### 新增（本地音乐：自定义路径 + 三大平台加密格式 + 常用格式）

- **自定义音乐路径**：本地音乐页「扫描目录」打开目录管理弹层——可添加/删除多个扫描目录（目录浏览器或手动输入）、多目录合并去重扫描、Hive 持久化（`jx_settings.local_scan_paths`）、重启自动扫描；首次使用预填默认候选（应用外部目录、Download、Music、QQ音乐/酷狗/网易云常见下载目录）。
- **加密格式解密播放**（纯 Dart，Windows/Android 同一实现）：
  - 网易云 `.ncm`：AES-ECB 密钥盒 + 元数据解析（扫描即显示标题/歌手/专辑/封面）
  - QQ 音乐 QMC v1/v2：`.qmc0/.qmc2/.qmc3/.qmcflac/.qmcogg/.mflac/.mflac0/.mgg/.mgg1/.bkcmp3/.bkcflac/.tkm`（v2 尾部密钥 TEA 派生；musicex/STag/无密钥尾部明确提示暂不支持）
  - 酷狗 `.kgm/.kgma/.vpr`：8 MiB 公钥表随包（覆盖 128 MiB 音频）；`.kgg` 识别后明确提示「需要客户端密钥，暂不支持离线解密」
  - 解密结果缓存到应用支持目录 `<key>/data.<ext>`（同一文件并发单飞、`.part` 原子写、1.5 GB/400 文件 LRU 淘汰、可清理），二次播放直接命中
  - 解密失败给中文原因（不静默、不崩溃）；队列/播放全部自动下一首时懒解密，失败通过 SnackBar 提示
- **常用格式**：mp3/flac/m4a/aac/ogg/opus/wav/wma/ape/aiff/aif/dsf/dff/mka 直接扫描播放；元数据读不到时回退「歌手 - 歌名」文件名解析。
- **Android 权限**：声明 `MANAGE_EXTERNAL_STORAGE`，本地页未授权时显示横幅并可跳转「所有文件访问」授权页（API 30+）；授权返回后自动复核刷新。

### 架构与实现

- ADR-004（Accepted）：vendored MIT 包 `packages/music_decoder`（NCM/QMC，未改上游源码）+ 按 MIT 参考实现移植的酷狗 KGM 解码器；统一 `EncryptedAudioDecoder` 契约、解码后音频容器自检、底层异常中文化。公钥表/算法来源与 MIT 许可见 `THIRD-PARTY-NOTICES.md`。
- 播放链路：本地曲目播放前由 `LocalFormatService` 解密（普通格式原样），解析结果**只用于打开播放器**；队列/播放历史/收藏保留源文件路径（避免缓存清理后历史无法回放）。

### 测试与验收

- 新增测试：`test/local_formats/ncm_qmc_test.dart`（27）、`kgm_test.dart`（23）、`test/local_format_service_test.dart`（24）、`test/local_paths_test.dart`（7）、`test/local_page_test.dart`（6）、`test/local_playback_integration_test.dart`（6）——含跨语言黄金向量、合成样本回环、异常中文断言、R-1/R-11 回归。
- 评审修复（架构阶段二 R-18/R-19/R-22/R-23/R-26）：文件名回退只填补缺失标签字段（不再覆盖标签标题）；Android 10 及以下补 `Permission.storage` 权限退路；QMC 输出格式以容器嗅探为准；NCM 元数据长度上限防御 + 无元数据块（metaLength=0）合法样本放行。
- 门禁：`flutter analyze --no-pub lib` 0 issue；`flutter test --no-pub` **222 passed / 4 skipped 全绿**（详见 QA 测试报告 `docs/projects/本地音乐与加密格式/测试报告.md`）。
- 覆盖边界：不随包分发真实版权加密样本（合规），E2E 用合成样本；真实 NCM/QMC/KGM 文件需用户人工验收（步骤见测试报告）。

### 修复（酷狗扫码登录误报「登录态不完整 20006」）

- 根因：扫码成功（`v2/get_userinfo_qrcode` → `data.status=4`，直接返回 `token`+`userid`）后，旧代码又调**已被服务端废弃**的 `loginservice.kugou.com/v1/login_by_token_get` 换登录态，返回 `20006`（业务失败）→ 被误报为「登录成功但登录态不完整（VIP 权益可能不可用）」。
- 修复：`status=4` 直接以 `token`+`userid` 建立会话（`lastError=null`）；**整段删除** legacy 换登录态调用、三套候选与误导文案；取码/轮询/取链主路径保持不变。真实 token 本机实测：带 `Cookie: token/userid` 取免费歌直链正常（`getSongInfo` → status=1 + sharefs URL）。
- 测试：新增 `test/kugou_login_state_test.dart` 8 项（Web 签名、设备 MID、云歌单 AES 固定向量由 Node/OpenSSL 独立算得；`status=4` 不调 legacy 的回归守卫；过期/错误码/取链带 Cookie）；酷狗范围 `dart analyze` 0 issue、定向单测 +25 全绿。
- 已知边界：web 型 token（appid=1014）在酷狗 Android 网关域受限（实测 20006/20018/20017），VIP 高音质/云歌单需后续迁 Android 型 token（appid=1001 + 真实 dfid + Android 签名）；实扫复验待用户窗口（验收标准：无警告 / 已登录 / 普通歌可播 / 重启保持）。
- 报告：`docs/projects/酷狗登录态修复/修复报告.md`、`测试报告-验收.md`。

## 0.9.9+18（扫码登录修复，同日续）— 2026-11-09

### 修复（扫码登录：QQ / 网易云端到端可用）

- **QQ 扫码登录（真机实扫通过）**：根因是 `check_sig` 响应里服务端**先下发有效 `p_skey`（44 字符）、随后又下发同名空值行**（删除父域旧 cookie）；旧 Cookie 合并是 last-wins，被空值覆盖 → `authorize` 的 `g_tk` 退化为 `hash33('')=5381` → 拿不到授权 code。修复：Set-Cookie 合并**忽略空值行**（`qq_api.dart` / `netease_api.dart` 两处）；扫码确认后停止轮询，不再对同一二维码反复兑换；失败文案给出具体阶段。
  - 实测（MuMu 模拟器实扫）：`check_sig → p_skey=true(len=44)` → `authorize 302 → code(len=32)` → `QQLogin 外层code=0/业务code=0` → 登录成功「ゞ李先森」cookies=4；重启 App 后仍「已登录」。
- **网易云扫码登录（真机实扫通过）**：旧 `/api/login/qrcode/*` + `type=1` 是「网页模拟」协议，2026 服务端在手机确认后返回 `8821 请切换其他登录方式或升级新版本再试`。迁移官方 **eapi**：`/eapi/login/qrcode/unikey`、`/eapi/login/qrcode/client/login`，请求体 AES-128-ECB（key `e82ckenh8dichen8`，明文 `apiPath-36cd479b6b5-json-36cd479b6b5-md5`）+ 官方客户端 UA / 设备指纹 Cookie + `type:"3"`；801/802/800/8821/803 分状态提示；803 从响应体与 Set-Cookie 双通道取 `MUSIC_U`，缺则明确失败；`getPlayUrl` 补登录 Cookie（仅发 163.com 域）。
  - 实测：`801 → 802 授权中 → 803 授权登陆成功`，`MUSIC_U(len=802)`、cookies=7；重启后仍「已登录：网易云用户」。
- **日志隐私红线**：登录全链路日志统一打码（URL/Location 走 `_maskUrl`、Set-Cookie 只打名字+值长度+前后4位、body 只打长度与特征位、code/musickey/p_skey/MUSIC_U 打码），release 包 logcat 可用且不泄露完整凭证。

### 测试 / 验收

- 新增 `test/qr_login_diagnostic_test.dart` 15 项离线用例：eapi 固定向量（与参考实现独立比对）、空 Set-Cookie 不覆盖有效 `p_skey`、无 `p_skey` 时 OAuth 链取 code、QQLogin 成功/失败分支、8821 文案等。
- QA 独立验收：`docs/projects/扫码登录修复/测试报告-实扫验收.md`（结论：**通过**——实扫 + 重启持久化 + 隐私红线）；`flutter analyze lib` 零问题；`flutter test --no-pub` **121 passed / 4 skipped**。
- 实扫证据（脱敏）：`docs/projects/扫码登录修复/证据-logcat-QQ登录成功.txt`、`证据-logcat-网易云登录成功.txt`、`screenshots/06~08`；修复报告：`修复报告-实扫.md`。
- 已知残留（不阻断）：QQ VIP 点播未验证；网易云 8821/800 终态仍轮询至 2 分钟；QQ 兑换链 30s 总超时小于最坏路径且超时不取消底层请求；QQ `#code=` fragment 未识别。

## 0.9.9+18 — 2026-11-09

### 修复（真机反馈：QQ 歌单详情 / 歌单迷你播放器 / 热歌榜「更多」）

- **QQ 歌单详情「0 首 + 列表空白」**：`QQMusicApi.playlistSongs()` 请求 `u.y.qq.com/cgi-bin/musicu.fcg` 时未带 Referer，而 JXHttp 全局默认 `Referer: https://music.163.com/` 被 QQ 判定为站外来源 → 返回空 `songlist`（`total_song_num=0`）。补 `Referer: https://y.qq.com/`（实测同一 disstid：默认 Referer 0 首 → 修复后 66 首）。详情页头部改按实际加载首数展示（加载中…/加载失败/暂无歌曲/N 首），不再用 QQ 歌单广场恒为 0 的 `playlist.songCount`；错误态补「重试」，空歌单显示「该歌单暂无歌曲」+ 重试；空列表时「播放全部」禁用。
- **歌单详情页看不到底部迷你播放器**：`PlayerBar` 只挂在 ShellPage，歌单详情 / 我的歌单是 `Navigator.push` 的整页路由，会把底部条盖住。两个详情页底部各嵌入 `const PlayerBar()`（未播放时占位，播放后显示曲目/歌手/进度、点击进播放页）；补 360x640dp 布局回归。
- **首页热歌榜「更多」无法展开**：`onMore` 原来绑 `_load`（重载首页、闪 loading、内容不变）。改为内联展开/收起：手机热歌榜与桌面「热门单曲」直接用 `_tops` 已缓存数据展开全部榜单，按钮「更多 ›/收起 ›」，不触发网络请求、不闪 loading。

### 测试

- 新增 3 个 widget 用例：`test/playlist_detail_page_test.dart`（实际首数/无「0 首」/空态重试/PlayerBar 嵌入/360x640 无溢出）、`test/home_rank_expand_test.dart`（展开收起/零网络请求/不闪 loading）；旧 `test/playlist_list_page_test.dart` 补 `PlayerService(initPlayer:false)` 注入（详情页新增常驻播放条后必须，否则旧用例读未初始化 Hive）。
- 门禁（提交 `57c0624` 干净树）：`flutter analyze lib` 零问题；`flutter test` **116 passed / 4 skipped**（工作副本另含并行会话未提交用例时为 119，不计入本次提交）。
- 模拟器 E2E（emulator-5554，360x640dp）：D1 QQ 歌单 66 首、D2 酷狗详情「播放全部」→迷你条→播放页（进度真实推进 + logcat AudioTrack）、D2b 自建歌单详情条、D3 热歌榜展开/收起（收起后截图与展开前逐字节一致）全 PASS；首页/搜索/播放页/Shell 迷你条回归 PASS。详细报告：`docs/projects/播放链路修复/测试报告.md`。

### 交付与构建教训

- 最终 APK：`jxmusic-0.9.9-final.apk`（SHA256 `E1A645EE…AAB9`，106,674,209 B，versionName 0.9.9 / versionCode 18，模拟器冷启动冒烟通过）。
- **干净 worktree 构建前必须先 `flutter pub get --offline`**，生成被 gitignore 的 `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`；缺它会产生「装机后启动白屏 + ClassNotFoundException: GeneratedPluginRegistrant」（本次曾产出坏包 `445BE3A0`，已废弃留证）。交付前自检：解包 APK 的 classes.dex 必须含该注册类，并模拟器冒烟启动到首页。
- 本次提交 `57c0624` 只含本修复 8 个文件；工作副本中并行会话的扫码登录未提交改动未纳入本提交。
- 遗留：网易云《森林之心》播放页停在 00:00 为**既有问题**（干净包复现，与本次修复无关），另立专项。

## 0.9.8+17 — 2026-11-09

### 修复（真机反馈：首页歌单 / 播放页）
- **首页 QQ 推荐歌单标题乱码**：QQ 歌单广场接口 `fcg_get_diss_by_tag.fcg` 默认按 GB2312/GBK 返回（响应头 `charset=gb2312`），Dio 按 UTF-8 解码成 `�` 替换字符。请求显式带 `inCharset/outCharset=utf-8`（URI 构造抽成 `dissByTagUri` 并加回归单测），中文标题恢复正常。
- **首页「更多」无法查看更多歌单**：原逻辑只是 `_load(nextBatch: true)` 换一批，用户看不到更多歌单。新增「<平台> · 全部歌单」分页页（`lib/ui/playlist_list_page.dart`）：网格卡片（复用 `JXPlaylistCard` 视觉）、三平台分页（QQ sin/ein、网易云 offset、酷狗 page）、滚动触底自动加载、加载中/没有更多/空态/失败重试，点卡片进歌单详情；首页桌面/手机两处「更多」改为进入该页。
- **播放页音源按钮**：按用户要求只显示「音源」二字（去掉 swap 图标、平台名、展开箭头），保留点击弹「选择音源」面板；按钮为右侧紧凑胶囊 64×26dp（修复「`Container(alignment)` 在 bounded 约束下撑满成整行通栏」的回归，补按钮宽度/右对齐/不压平台 Chip 的 widget 回归用例）。
- **播放页 360x640dp 布局重叠**：`_AlbumArtView` 改 LayoutBuilder 按可用高度自适应封面尺寸（`jxPlayerCoverSize`，140~300dp、矮屏收紧间距、显式行高），修复 Expanded 内容溢出导致平台 Chip 被音源按钮压住。
- **播放器不显示封面**：
  - 网易云搜索接口 `album` 只有 `picId` 没有 `picUrl` → 搜索后批量调 `/api/song/detail` 按 id 只回填空封面（纯函数 + 单测），失败不影响搜索；
  - **网易云封面全部 403 的真根因**：Flutter `Image.network(headers:)` 内部用 `request.headers.add()`，与 dart:io 默认 UA 组合成 `Dart/3.13 (dart:io), Mozilla/5.0 ...` 两段 UA，网易云 CDN 直接 403。改用自定义 `JXNetworkImage`（共享 HttpClient 以 `userAgent` 属性设单值 Chrome UA，请求头只 `set` Referer；带 403 诊断日志、失败清 ImageCache、网易云优先 `?param=500y500` 缩略图提速）。实测：add 组合 UA → 403，set/单值 UA → 200。
  - 首页/搜索/播放页/迷你条封面统一走新链路；新增 `tool/check_cover_image.dart` 联网探针。
- 同批合入并行工作进行中的「扫码登录链路诊断增强」（设置页/QQ 接口的脱敏诊断日志、`qr_login_diagnostic_test.dart`、`tool/check_netease_qr.dart` 等），便于真机实扫排障；不改变扫码协议本身。

### 测试
- `flutter analyze lib` 零问题；`flutter test` **113 passed / 4 skipped**（本轮新增 44 个用例：全部歌单页分页/空态/失败/详情、QQ GBK 回归、网易云封面回填、封面 UA/重试/日志、播放页 360x640 布局与音源按钮尺寸等）
- Android 15 模拟器（1080x1920@480 → 360x640dp）端到端 **25 项全 PASS**：QQ 标题中文、三平台「更多」→ 全部歌单分页、播放页音源按钮/布局/封面、搜索与播放回归；封面失败日志 0 条
- 详细报告与截图证据：`docs/审计/2026-11-09-缺陷修复测试报告.md`、`docs/审计/screenshots/2026-11-09/`

## 0.9.7+16 — 2026-11-09

### 修复 / 调整（真机反馈：播放页音源切换）
- **音源选择移到二级按钮**：删除播放页标题下方的横向音源条，改为进度条上方右侧「音源 · 当前平台」按钮，点击弹出「选择音源」面板；面板标注当前音源 / VIP / 需登录，切换中禁用并显示进度条
- **切换音源改为替换当前队列项**（不再 append 污染队列），成功后保留播放进度；失败不再静默跨平台换歌，而是区分「未登录 VIP → 需先登录」「接口错误」「通用不可用（可能需登录或受版权限制）」
- **修复切换音源会清空队列的缺陷**（`_queue..clear()..addAll(f(_queue))` 级联求值顺序问题），并补 14 个纯逻辑/队列回归用例
- **搜索页播放失败文案**改为「已尝试全部 N 个音源，均不可用（可能需要登录或受版权限制）」，删除误导性的「可点其它平台标签再试」
- **修复首页永久加载态**（0.9.3 引入的回归）：`_loading` 初值从 `true` 改为 `false`，首次 `_load()` 不再被自身守卫拦截；补首页 widget 回归测试

### 测试
- `flutter analyze lib` 零问题；`flutter test` 69 passed / 4 skipped / 0 failed（新增 15 个用例：音源切换 14 + 首页回归 1）

## 0.9.6+15 — 2026-11-08

### 修复（UI 对齐）
- **播放器控制按钮不对齐**：控制行改为左右两侧 `Expanded` 等分 + 主播放键固定 84 宽居中，保证播放/上一首/下一首/循环/歌词五个按钮水平均匀、垂直居中对齐；窄屏不再因固定间距溢出
- **音量行对齐**：喇叭图标定宽 24 居中，滑块统一 `trackHeight/thumb/overlay` 尺寸，倍速按钮固定 28 高并居中文字，整行垂直对齐
- **搜索框文字未垂直居中**：输入框固定高 46、`isDense + contentPadding 0 + textAlignVertical.center`，前后图标约束统一为 34×34，输入文字与搜索图标同一中线

## 0.9.5+14 — 2026-11-08

### 修复
- **搜索结果"显示的平台"与"实际播放的平台"不一致**：
  - 结果行里把即将播放的音源标为「首选·XX」（加粗高亮），用户一眼能看出点行会播哪个平台
  - 每个平台标签都可**直接点击**播放该平台音源（不再由系统暗中挑选）
  - 取消"找不到就静默换平台找另一首同名歌"的替代：用户明确点歌/点音源时只尝试该曲目自己的音源，失败即提示，保证播的就是点的那首
  - 首选音源失败、自动落到本曲目其它平台音源时，弹提示「已改用 XX 音源播放」

## 0.9.4+13 — 2026-11-08

### 新增 / 调整
- **搜索页改为合并去重列表**：不再按 QQ/网易云/酷狗分三块重复展示；三平台各取 100 条（共 300 条来源），按「歌名+歌手」归一化去重后展示**最多 100 首**，每行标注该曲目在哪些平台有音源
- **多音源切换**：播放页新增「音源」横向切换条（QQ / 网易云 / 酷狗），点击即切到该平台音源播放并**保持当前播放进度**
- 播放聚合曲目时自动优先尝试非 VIP 音源；全部音源不可用时给出明确提示
- QQ 搜索接口单页上限约 60 条（传 100 会返回空）→ 改为内部分页累加，保证 100 首搜索时 QQ 也有结果

### 测试
- 新增 `test/track_group_test.dart`（8 项：三平台合并、版本区分、标点/大小写归一、同平台去重、首选音源优先级、全 VIP、空标题、顺序）
- 新增 `tool/check_search_merge.dart` 搜索聚合诊断（实测：300 条来源 → 100 首，27 首多音源）
- 门禁：`flutter analyze lib` 零问题；`flutter test` 54 passed / 4 skipped / 0 failed

## 0.9.3+12 — 2026-11-08

### 修复（首页歌单/榜单）
- **首页只有几个歌单且不更新**：
  - QQ 推荐歌单此前是空实现 → 接入公开「歌单广场」接口（`fcg_get_diss_by_tag`，按最热排序，支持翻页）
  - 酷狗榜单接口失效（`www.kugou.com/yy/index.php?r=rank/list` 返回 Access Deny，榜单 0 首）→ 改用 `m.kugou.com/rank/info?rankid=8888`
  - 网易云榜单返回 100 首不裁剪 → 按请求数量裁剪
- 首页改为**分平台展示**：QQ / 网易云 / 酷狗 各自一行「推荐歌单」（横滑卡片，带平台标签与数量），空列表有明确提示
- 首页支持**换一批**（点每行右侧「更多」翻页）与**自动刷新**（回到首页且距上次加载超过 1 分钟时自动重拉）
- 播放失败提示改为"三个平台都没有可用免费版本"，与跨平台替代播放逻辑对齐

### 测试
- 新增 `tool/check_home_data.dart` 首页数据诊断（三平台推荐歌单/榜单返回数量）
- 门禁：`flutter analyze lib` 零问题；`flutter test` 47 passed / 4 skipped / 0 failed

## 0.9.2+11 — 2026-11-08

### 修复（基础播放，优先）
- **网易云搜索完全失效**：官方 `weapi/cloudsearch/pc/search/get` 已 404（搜索返回 0 首），改用当前可用的公开接口 `GET /api/search/get/web`，并保留 weapi 兜底；解析抽成 `neteaseSongFromSearchJson`（兼容 `artists/album/duration` 与 `ar/al/dt` 两套字段）
- **网易云播放直链**：新增公开 `GET /api/song/enhance/player/url?ids=[id]&br=128000/320000`（免费与 fee=8 歌曲实测可拿到直链），weapi 作为兜底
- **网易云歌词**：新增公开 `GET /api/song/lyric`，weapi 兜底
- **跨平台自动替代播放**：本平台解析不出直链（VIP/版权限制）时，自动到其它平台搜索同名/同歌手免费版本并播放（实测：QQ 上 VIP 的《卡农》→ 网易云免费版可播）
- QQ 扫码后 `check_sig` 改为手动跟随最多 3 跳并逐跳合并 Set-Cookie（p_skey 可能在跳转后才下发），失败提示带跳转次数

### 测试
- 新增 `test/netease_parse_test.dart`（4 项解析回归）、`test/playback_fallback_test.dart`（联网替代播放检查，默认 skip）
- 新增 `tool/check_play_urls.dart` 播放链路诊断脚本
- 门禁：`flutter analyze lib` 零问题；`flutter test` 47 passed / 2 skipped / 0 failed

## 0.9.1+10 — 2026-11-08

### 修复
- **QQ 扫码轮询误报"轮询返回异常内容"**：真实响应 `ptuiCB('66','0','','0','二维码未失效。', '')` 最后一项前带空格，旧实现的固定分组正则匹配失败，导致正常等待态被当成接口异常（用户截图复现）。改为容错解析 `parsePtuiCb`（先截取 `ptuiCB(...)` 函数体，再按序抓取所有单引号字符串），兼容字段增减/空格/引号转义。
- 参数错误（code 7）时把服务端原文带进提示；等待态（66/67）不再写 `lastError`。

### 测试
- 新增 `test/qq_ptui_parse_test.dart`（4 项：66 带空格、67/65/7、成功态取 URL 与昵称、异常输入返回 null）
- 新增 `tool/check_qq_parse_live.dart` 实网检查：真实响应解析 code=66、`pollQrLogin` 返回 null 且 `lastError` 为空
- 门禁：`flutter analyze lib` 零问题；`flutter test` 43 passed / 2 skipped / 0 failed

## 0.9.0+9 — 2026-11-08

### 新增
- **酷狗登录态补全**：扫码确认后接入官方 `loginservice.kugou.com/v1/login_by_token_get`（AES-CBC/PKCS7 + textbook RSA），换取完整登录 cookie（vip_type/vip_token 等）；三套密钥/参数约定候选按序尝试（官网 web-js → 本项目参数 → makcre md5+PEM），失败降级为 userid+token 会话并提示"登录态不完整"
- 酷狗补全后的登录 cookie 接入播放链接解析（只发往 kugou.com 官方域）
- **QQ 兑换链路加固**：check_sig / authorize / QQLogin 候选化（QQLogin 备 `u6.y.qq.com`）、authorize POST→GET 降级、Set-Cookie 多值合并、逐级 lastError、20s 总超时；授权 code 只在最后一步重试，不重复请求 authorize
- **接口清单与失效替换指引**：新增 `docs/接口清单.md`，记录各平台接口位置、候选与替换流程
- 登录降级提示落到 UI（设置页登录成功时会提示"登录态不完整"）
- 扫码轮询增加 in-flight 互斥，避免 10~20 秒兑换期间 2 秒定时器并发重复兑换同一 token/授权码

### 测试
- 新增 `test/kugou_login_crypto_test.dart`（17 项离线单测：两套 AES 固定向量、PEM DER 解析、textbook RSA 零左填充、hex 工具、secu_params 解密、离线降级）
- 新增 `test/setcookie_multi_probe.dart`（Dio/IO Set-Cookie 多值合并验证）
- 新增 `tool/check_kg_token_get.dart`；QA 用 Node/OpenSSL 交叉复核全部加密向量
- 门禁：`flutter analyze lib` 零问题；`flutter test` 39 passed / 2 skipped / 0 failed

### 已知
- 仍未真机扫码：酷狗 token_get 成功态、QQ 真实 p_skey→code→musicid 未端到端验证
- 酷狗三候选存在 token 一次性消费的幂等风险（已降级兜底）

## 0.8.0+8 — 2026-11-08

### 修复
- **QQ 音乐扫码无法生成二维码**：`ptqrshow` 不再带 `u1`（带 u1+daid 会被网关 403），恢复为 200 + 真二维码 PNG（111×111）+ qrsig；轮询改用 `u1=graph.qq.com/oauth2.0/login_jump` + 完整浏览器参数，稳定返回 `ptuiCB('66')` 等待态
- **QQ 换登录态链路重写**：旧 `wxa_redirect.html` 已 404，改为 `check_sig` → `graph.qq.com/oauth2.0/authorize` → `musicu QQConnectLogin.LoginServer.QQLogin` 取 musicid/musickey
- **酷狗音乐扫码无法生成二维码**：旧 `gateway.kugou.com` openapi 协议整体下线（502），改用官方 Web 登录协议 `login-user.kugou.com/v2/qrcode` + `/v2/get_userinfo_qrcode`，签名改为官方 `getInterFaceKguser` 算法（MD5_UPPER(salt+排序"k=v"无分隔符+salt)，含 srcappid=2919）
- 扫码失败提示改为接口层回报（新增 `MusicPlatformApi.lastError`），不再写死「403/502」；二维码过期/接口变更会展示具体原因
- 修复打开登录弹窗即清空已持久化登录态的问题

### 新增
- `tool/check_qq_qr.dart`、`tool/check_kg_qr_probe.dart` 两个联网手动检查脚本（取码 + 轮询等待态）

### 已知
- 扫码成功后的完整登录链路未真机端到端验证；酷狗未复刻官方 `login_by_token_get`（VIP 鉴权可能不完整）

## 0.7.0+7 — 2026-11-08

### 新增
- 系统托盘：左键显示/隐藏窗口；右键菜单支持显示窗口、播放/暂停、上一首、下一首、退出
- 关闭主窗口改为收进托盘（仅托盘初始化成功后生效）
- 迷你播放窗口：420×150、置顶、可拖动、播放控制、恢复主界面、收进托盘
- 设置页新增「退出应用」入口
- 生成 JXMusic 专属图标，替换 Windows 应用图标与托盘图标

## 0.6.0+6 — 2026-11-08

### 新增
- 0.5x–2.0x 倍速播放
- 静音切换（记住静音前音量）
- 全局快捷键：空格/媒体键播放暂停、←→ 快退快进 5s、↑↓ 音量、M 静音、N/P 切歌
- 窗口置顶开关（Windows，启动恢复）
- 音量/倍速/循环模式持久化

## 0.5.0+5 — 2026-11-08

### 新增
- 下载管理：音乐库「下载」页支持播放、定位文件、删除、打开下载目录、总占用统计
- 无标签音频按「歌手 - 歌名」文件名回退解析

## 0.4.0+4 — 2026-11-08

### 新增
- 音乐库：收藏、播放历史、自建歌单（新建/重命名/删除/加歌/移除/播放全部）
- 播放页菜单：收藏/取消收藏、添加到歌单
- 统一播放入口 `resolveAndPlay`，首页/搜索/歌单/本地复用

### 修复
- 「播放全部/自动下一首」因队列歌曲无直链而卡住；现在按需解析直链并可自动加载歌词
- Hive `box.clear()` 异步落盘导致的清空不一致

## 0.3.0+3 — 2026-11-08

### 新增
- 酷狗推荐歌单与歌单详情
- 歌曲下载（带进度、按平台 Referer、文件名安全化、重名加序号）
- 首页推荐歌单改为网易云 + 酷狗聚合

### 修复
- 酷狗歌词接口（原实现永远返回空），改为官方 search + download 链路
- 酷狗 VIP 判定改为 `privilege >= 10`，修正全部误标 VIP

## 0.2.0+2 — 2026-11-07

### 新增
- Android release 权限（INTERNET、媒体读取）与 release 签名配置
- 登录态持久化（Hive）+ 退出登录
- 封面加载修复（浏览器 UA，解决 403）、本地音乐内嵌封面
- 歌词当前行自动滚动居中
- README、单元测试

### 清理
- 删除 39 个调试产物；初始化 git 仓库
