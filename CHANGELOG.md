# CHANGELOG

## 0.11.0+46 — 2026-11-20

### 功能（QQ VIP/付费歌曲自动解析官方试听版）

- **需求**：付费音乐和 VIP 音乐都有官方试听版本——需要 VIP/付费的歌曲在完整版无权益时自动解析为试听版播放，而不是直接失败/跳过。
- **调研（探针实测，2026-11，匿名）**：
  - **QQ**：`CgiGetVkey` 同接口显式带 `filename: ['RS02{songmid}.mp3']`（RS02 = QQ 官方试听文件前缀，与官方 web 播放器对未购用户提供的试听同口径）即可签发试听 vkey——VIP（晴天 `0039MnYb0qxYhV`）与付费数字专辑（最伟大的作品 `003w2xz20QlUZt`）均可下载 960887 字节 mp3（帧头 `fffb`，≈60.1s@128kbps）；不带 filename 或 M500/M800 前缀 purl 均为空；
  - **网易云**：`/api/song/enhance/player/url`（含 weapi/v1 三通道）匿名一律 `url=null`（code 404）、无 `freeTrialInfo`——试听由服务端按账号权益决定（已登录非会员若获发试听，现有代码已能直接透传播放），无公开试听端点可主动解析，本次不改；
  - **酷狗**：公开端点全部试尽（getSongInfo 各变体 / `trans_param.hash_offset.clip_hash`（60s 试听片段官方 hash，直查 data not found）/ offset_hash / `gateway.kugou.com/v5/url`（502）/ 公开 salt 签名 `play/songinfo` 与 m3ws `get_play_info`（30020 参数错/No Action））——官方客户端走私有签名接口，试听暂不支持。
- **实现**：
  - `qq_api` `getPlayUrl`：完整版 purl 为空（未登录/权益过期/无版权直链）时，不再直接 return null——改带 RS02 试听 filename 重发同一 musicu 请求，解析出官方 60 秒试听直链（sip+purl，过 `jxUpgradeHttps`）即返回播放；无试听/请求失败维持原有 `lastError` 文案不变；
  - 覆盖全部播放路径（手动点歌 `resolveAndPlay` / 自动切歌 PlayerService `urlResolver` / 播放中切源 `switchSource`）——试听兜底在 `getPlayUrl` 内完成，自动切歌 VIP 歌不再无声跳过；
  - 试听解析全程落 `[JXMusic][QQ播放]` 日志（OK/无试听/异常），真机 hilog 可观测兜底命中情况；
  - 合规口径：试听=平台官方提供给未购用户的预览内容（QQ 官方 web 播放器同款 RS02 文件），完整版仍需会员/购买，不绕过任何付费限制。
- **测试**：`qq_trial_request_test` +6（RS02 试听 filename 构造；请求体 guid/songmid/uin/双请求结构；响应解析 sip+purl 拼接升 https / purl 空返回 null / midurlinfo 缺失返回 null / sip 缺失退化纯 purl）。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：511/511 全绿（505 + 6 新增）。

## 0.11.0+45 — 2026-11-20

### 修复（QQ 播放失败提示误导「需要登录」+ 失败原因诊断）

- **痛点（真机反馈）**：QQ 歌单点歌失败时一律提示「无法播放：该歌曲可能需要先在设置里登录对应平台」——已登录豪华绿钻的用户被严重误导；同时「暂无音源已跳过 / 播放失败 / 已切换其他音源」等失败没有任何可定位的原因。
- **实现**：
  - `playlist_detail_page`：点歌/播放全部失败不再写死「需要先登录」——快照法（`freshApiError`）取平台本次新增的 `lastError` 作为具体原因展示；只有「未登录且是 VIP 歌」才提示「需要先登录XX才能播放 VIP 音源」；已登录用户兜底文案为「该歌曲在XX及跨平台均无可用音源」；
  - `qq_api` `getPlayUrl`：新增 `[JXMusic][QQ播放]` 诊断日志（print，与既有 `_log` 同口径，不引入 Flutter 依赖保证 `dart run tool/*` 可执行）——每次解析输出 songmid/vip/uin（打码）/已带 cookie；purl 为空、midurlinfo 缺失、解析异常均落日志，真机 hilog 可区分「未带登录态 / 登录态过期 / 服务端无音源」；
  - `qq_api` purl 为空时按登录态细分 `lastError`：带登录态 + VIP 歌 → 「若长时间未登录请尝试重新登录」（指向 musickey 过期）；带登录态 + 非 VIP → 「版权受限」；未登录 → 维持 +43 文案。
- **测试**：`playlist_detail_page_test` +2（未登录点 VIP 歌提示「需要先登录XX」；点歌失败展示平台具体原因且不再出现「需要先在设置里登录」误导文案）。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：504/504 全绿（502 + 2 新增）。

## 0.11.0+44 — 2026-11-20

### 调整（全部歌单：随机更新 + 三平台同时刷新）

- **痛点**：「更多歌单」聚合页每次刷新固定拉 `page=1`，而三平台推荐位第一页内容长期不变——用户每次点更新/进页看到的永远是同一批旧歌单。
- **实现**：
  - `playlist_list_page`：首屏起始页默认 **1~10 随机**（`randomStartPage` 可注入固定值供测试），滑到底从起始页顺序续拉下一页；随机页越界（服务端已无更多、返回空）自动回退 page=1，不误报「暂无歌单」；State 改公开 `PlaylistListPageState`，新增 `refresh()`（回顶 + 重新随机起始页加载）；内嵌聚合页时（`showBack=false`）隐藏页内刷新按钮，由聚合页头部统一触发；
  - `playlist_hub_page`：头部新增「更新」按钮——一次点击通过 per-platform `GlobalKey` 同时触发三平台子页 `refresh()`（各自随机起始页、并行请求），满足「所有歌单同步更新、同时更新、随机更新」；
  - 三平台分页口径不变（QQ sin/ein、网易云 offset、酷狗 page），随机区间 1~10 各平台均有稳定数据。
- **测试**：`playlist_list_page_test` +2（随机起始页=3 首屏渲染第 3 页/续拉第 4 页；随机页越界回退第 1 页不误报空态）；`home_aggregate_test` +1（聚合页「更新」一次点击三平台 `recommendCalls` 各 +1，刷新按钮唯一）。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：502/502 全绿（499 基线 + 3 新增）。

## 0.11.0+43 — 2026-11-19

### 修复（真机在线歌曲播放失败：completed=false 级联切歌 + 直链 https 升级 + 静默失败提示）

- **真根因（+43 第二轮 hilog 取证 + mpv warn 级日志）**：media_kit 在 mpv `START_FILE`（开始加载新文件）时会向 `completed` 流发 `false`，应用订阅回调不判值直接 `_onTrackComplete()`——**每次 open 新歌都立刻被误切到下一首**，级联中止所有进行中的加载（产生大量「Failed to open」假错误，且错误归属错位触发错误重试交叉干扰）、一路跳到队尾才停。表现即真机反馈：网易云歌单「点了没反应」（队尾歌 http 直链也打不开 → 全程无声）、QQ 歌单「大量跳过」。
- **实现**：
  - `player_service`：`completed` 流回调改为只对 `completed=true`（eof-reached 真播完）触发 `_onTrackComplete`；新增 `@visibleForTesting onCompletedEvent` 供回归测试注入；`queue_auto_advance_test` 新增 START_FILE 回归（completed=false 不切歌 / true 正常切）；
  - `http.dart` 新增 `jxUpgradeHttps`：音频直链 `http://` 统一升级 `https://`（三家 CDN 实测均支持：m80x.music.126.net / aqqmusic.tc.qq.com / sharefs.kugou.com 同文件明文与 https 均 200）——修复队尾歌 http 直链真打不开的问题；
  - `netease_api`/`qq_api`/`kugou_api` 的 `getPlayUrl` 返回直链全部过 `jxUpgradeHttps`；
  - `player_service` `_onPlayerError`：重试一次后仍打开失败不再静默停止——提示「播放失败，已跳过」并按死链 autoAdvance 语义跳下一首（队尾则提示后停下），消除「点了没反应」的无声路径；
  - `player_service` 新增 mpv warn/error 细节日志订阅（`logLevel: warn`），ffmpeg/lavf 层错误转 debugPrint 进 hilog（本轮正是靠它定位到「Failed to create file cache」与级联时序）；
  - `qq_api` `getPlayUrl` purl 为空（VIP/付费无权益或无版权）时写 `lastError`（「暂无可用音源（VIP/付费歌曲或版权受限）」），死链提示不再无原因。
- **测试**：`residual_fixes_test` 酷狗免费歌直链断言更新为 https 升级后值；`queue_auto_advance_test` +1 条 START_FILE 级联回归；删除 4 个临时诊断脚本（diag_play / diag_netease_pl / diag_netease_cdn / diag_https_upgrade）。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：499/499 全绿（4 跳过为需联网用例；+1 START_FILE 级联回归）。

## 0.11.0+42 — 2026-11-19

### 调整（底部提示条：悬浮玻璃胶囊通知）

- **痛点**：全 app 底部弹出的提示（版权/换源/导入/登录/收藏/建歌单等）原先走 Material 默认 SnackBar——贴边扁平暗色条，与全 app 液态玻璃语言割裂。
- **实现**：
  - `glass.dart` 新增统一入口 `jxShowNotice(context, message, {duration?})`：`floating` 行为 + 透明外壳（`backgroundColor: transparent` + `elevation: 0` + `padding: zero`），本体 `_GlassNotice` 自绘玻璃胶囊——阴影 → `ClipRRect` → `BackdropFilter`(blur 18) → 渐变玻璃容器 + 1px 描边 + Row（info 图标 + 文案），左右 16 / 底 12 margin 悬浮于屏幕底部边缘；
  - 替换全部 21 处调用点：home、search、library、local、media_songs、my_playlist、playlist_detail、player（×2）、settings（×4）、shell（×2）；
  - `theme.dart` 增加 `snackBarTheme` 兜底（未来裸 SnackBar 也呈悬浮玻璃观感，`jxShowNotice` 自带完整胶囊逐项覆盖主题值）。
- **回退**：+41「底部悬浮坞」经确认为需求理解偏差（本需求实为「通知条悬浮」而非「底栏悬浮」），全部回退——`shell_page` 还原 `Column`、`layout.dart` 删 `kJxMobileDockHeight`/`jxDockBottomReserve`、`player_bar` 边距还原、五页滚动 padding 还原、删除 `bottom_dock_test`。
- **测试**：新增 `notice_test`（2 条）：悬浮玻璃胶囊（脱离左右/底边缘 + `BackdropFilter` 模糊本体 + floating/透明/零投影外壳 + 默认 4s 自动消失）、自定义时长到时自动消失；既有测试提示断言均为 `find.text(...)`，内容不变全部通过。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：**498/498 全绿**（4 跳过为需联网用例；+3）。

## 0.11.0+41 — 2026-11-19（已回退，见 +42）

### 调整（手机端底部悬浮坞：真·悬浮）

- **痛点**：手机端底部迷你播放条 + 底部 Tab 原先是 `Column` 布局——底栏占据布局空间、内容在它们上方结束，玻璃卡后面没有滚过的内容，「悬浮」只是视觉近似。
- **实现**：
  - `MobileShellBody` 改为 `Stack`：五个 tab 页内容全屏铺满、延伸到屏幕底部，迷你播放条 + 底部玻璃 Tab 以悬浮坞方式覆盖其上——内容在毛玻璃后滚动，与全 app 玻璃卡片语言一致；
  - 新增 `kJxMobileDockHeight`（156dp）/ `jxDockBottomReserve`（layout.dart）：各 tab 页滚动底部预留悬浮坞高度 + 系统手势区 + 呼吸间距，最后一项能滚出悬浮坞（桌面布局无悬浮坞，返回各页原值，桌面零变化）；
  - 首页/搜索/音乐库/本地/设置五个 tab 页的滚动底部留白全部接入 `jxDockBottomReserve`；
  - 迷你播放条外边距对称化 `(12, 6, 16, 12)` → `(12, 6, 12, 8)`，与底部 Tab 衔接更紧凑（含歌单详情页自带播放条）；
  - 顶部安全区仍在壳层统一避让一次（`MobilePageSafeArea` 不变），整页路由（歌单详情/搜索结果等全屏页）不受影响。
- **测试**：新增 `bottom_dock_test`（3 条）：内容铺满全屏到底部且悬浮坞覆盖其上、悬浮坞避让系统底部手势区、滚动预留含悬浮坞高度；既有 `top_safe_area`（壳层接线）与 `top_safe_area_acceptance`（G1~G4 验收矩阵）全部通过。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：**499/499 全绿**（4 跳过为需联网用例；+4）。

## 0.11.0+40 — 2026-11-19

### 修复（首页聚合卡：整行可点播放）

- **痛点**：手机版首页「三平台热歌聚合」/「猜你喜欢」卡片的歌曲行，点击行内空白区域（文字右侧留白、间隙、上下 padding）无响应，体感上「只能点行尾播放图标」。
- **根因**：行 `GestureDetector` 默认 `deferToDefault` 命中行为，child 为 `Padding`/`Row`（自身不可命中），只有文字、图标等实际渲染处可点。
- **修复**：`_AggRankCard` 行 `GestureDetector` 加 `behavior: HitTestBehavior.opaque`，整行任意位置点击均触发播放；全 app 其余歌曲行（搜索/歌单/本地/收藏/历史/下载/队列/音源面板）已是 `ListTile`/`GlassCard`(InkWell)/`SongRow`(带 decoration 容器) 整行可点，无需改动。
- **测试**：`home_queue_test` 新增「行内空白区域点击也能播放」回归用例（点标题右侧留白处，旧行为点击无效、新行为正常播放且整单进队列）。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：**495/495 全绿**（4 跳过为需联网用例；+1）。

## 0.11.0+39 — 2026-11-19

### 调整（本地页：移除「扫描目录」按钮）

- **痛点**：「扫描目录」按钮 + 目录管理弹层路径过深，实际使用中几乎不碰（打开页面已自动扫描）；鸿蒙端系统目录不可扫，按钮更是无用。
- **实现**（全平台移除）：
  - 本地页右上角「扫描目录」按钮删除，鸿蒙端只保留「导入」，Android/桌面端头部不再有按钮；
  - 目录管理底部弹层（`_DirectoryManagerSheet`）、手动输入目录对话框、`dir_browser.dart` 目录浏览器整体删除（死代码）；
  - 扫描行为不变：打开页面时 `autoScan` 自动扫描已配置目录；`LocalPathsStore.load` 首次使用仍会自动 seed 默认候选目录（Android 常用目录 / 桌面 Music、Downloads），此前已配置的目录继续生效，仅不再提供手动增删入口；
  - 空态/页头文案同步去掉「点扫描目录添加」引导（改为「打开页面自动扫描已配置目录」）。
- **测试**：`local_page_test` 删除目录弹层用例，其余用例改走 `autoScan: true` 自动扫描路径；新增「扫描目录按钮不存在」回归断言。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：**494/494 全绿**（4 跳过为需联网用例；-1）。

## 0.11.0+38 — 2026-11-19

### 新增（鸿蒙本地页「导入系统音乐」）

- **痛点**：鸿蒙系统目录（`/storage/Users/.../Music` 等）不允许应用直接扫描，此前鸿蒙端本地页始终无歌可听，只能靠应用沙盒目录。
- **实现**（DocumentViewPicker 方案，AudioViewPicker/文件夹选择因 API 版本或持久化限制弃用）：
  - 原生端新增 `JxFileAccessPlugin.ets`（`jxmusic/file_access` 通道）：`pickAudio`（DocumentViewPicker 多选、`fileSuffixFilters` 过滤 mp3/flac 等）→ `persistUris`/`activateUris`/`revokeUris`（`fileShare` 授权持久化/激活/撤销）→ `openFd`/`closeFd`（URI 转 fd）；`module.json5` 声明 `ohos.permission.FILE_ACCESS_PERSIST`。
  - Dart 端新增 `OhosFileAccess`（通道客户端；`openFdUrl` 打开失败先激活持久化授权再重试一次自愈；`readMetadataByUri` 经 `/proc/self/fd/<fd>` 直接读标签+封面，不复制进沙盒）与 `OhosSystemMusicService`（导入记录持久化到 Hive `jx_settings` 的 `ohos_system_tracks`：导入=多选→持久化授权→逐个解析标签（失败回退「歌手 - 歌名」文件名，复用 `mergeFileNameFallback`）→落盘；`loadSongs` 重启后激活授权；`removeSong` 撤销授权+删记录）。
  - 本地页：右上角「导入」按钮（仅鸿蒙显示）+ 空态导入引导文案；系统导入歌曲排在扫描结果之前合并展示，导入进度实时显示在页头摘要；长按系统歌曲弹「移除导入歌曲」确认（只移除记录与授权，不动系统原文件）。
  - 播放：系统歌曲 `audioUrl` 存系统 URI 本身，providers 的 urlResolver 经 `openFdUrl` 转 `fd://<fd>` 交给 libmpv（media_kit 的 fd:// 为一等 scheme，fd 所有权移交 mpv）；授权持久化失败不阻断导入（本次会话临时授权仍可播）。
- **测试**：新增 `ohos_system_music_test` 12 条（记录序列化/URI 文件名解析；导入标签解析、文件名回退、重复跳过、持久化失败不阻断、取消、移除撤销；本地页 ohos 导入入口/长按移除/非 ohos 隐藏入口）。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：**495/495 全绿**（4 跳过为需联网用例；+12）。

## 0.11.0+37 — 2026-11-19

### 调整（播放页控制行：歌词按钮换成播放队列按钮）

- **痛点**：播放队列此前藏在右上角「更多（⋯）」菜单二级路径里，切队列要多点两步；而歌词/封面切换已有「点击主体」这一更直接的入口，控制行右下角的歌词按钮显得冗余。
- **实现**：
  - 控制行最右槽位的「歌词切换」按钮移除（点击主体/歌词区切换封面 ↔ 歌词成为唯一切换入口，交互不变）；
  - 播放队列按钮（`Icons.queue_music_rounded`）放进该槽位，与循环/上下曲等按钮同一水平行、等宽均分对齐，点击直接打开队列弹层（`_QueueSheet`）；
  - 控制行布局维持 5 槽位（循环 / 上一曲 / 播放 / 下一曲 / 队列），主播放键保持水平居中；
  - 「更多」菜单里的「播放队列」项保留，内部复用同一 `_showQueueSheet` 入口。
- **测试**：`player_page_layout_test` 队列按钮回归更新（与循环按钮垂直对齐、位于主播放键右侧、点击弹层）；`vinyl_disc_test` 歌词面板切换改走点击黑胶封面；全量 480 用例。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：**480/480 全绿**（4 跳过为需联网用例）。

## 0.11.0+36 — 2026-11-19

### 调整（播放页：移除倍速按钮，点击主体切换歌词/封面）

- **倍速按钮移除**：控制区音量行右侧的「播放速度」弹层按钮（`_SpeedButton`）按需求删除，手机/桌面均不再渲染；手机端该行整体不再出现（原本只剩一个倍速按钮），桌面端保留应用内音量条。服务层 `PlayerService.setSpeed` 与速度持久化不受影响（AVSession/桌面端仍可用）。
- **点击切换歌词/封面**：播放页主体（黑胶封面区/歌词区）整块可点，点击在封面 ↔ 歌词间切换（300ms AnimatedSwitcher 过渡），与右下角歌词按钮等效；歌词区内部拖动滚动不受影响，歌词加载失败态的「重试」按钮自身吸收点击不触发切换。
- **测试**：`player_volume_test` 断言更新（手机/桌面倍速入口均 `findsNothing`）；`player_page_layout_test` 新增「点击主体在封面/歌词间切换」回归 1 条。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：**479/479 全绿**（4 跳过为需联网用例；+1）。

## 0.11.0+35 — 2026-11-19

### 修复（酷狗「登录已过期」— 账号歌单 20017）

- **痛点**：酷狗扫码登录成功后，账号歌单页仍报「登录已过期，请重新登录」；用户重扫码无效，`/v7/get_all_list` 始终返回 `error_code=20017`。
- **根因**（对照 MakcRe/KuGouMusicApi main 定案）：旧扫码链路是 H5 网页型二维码（取码/轮询 `appid=1014`、`clientver=8131`），拿到的 token 是 **H5（1014）型**；而账号歌单走 cloudlist（`x-router: cloudlist.service.kugou.com`，Android 签名 `appid=1005`），只认 **Android（1005）型 token**——H5 型被拒 20017（与此前实测 v5/login_by_token 等 Android 域接口拒 1014 token 的结论同源）。
- **修复**：扫码链路整体切到 Android 客户端型（`login_qr_key.js`/`login_qr_check.js` 默认分支）：
  - 取码 `/v2/qrcode`：`appid=1001`（Android 型二维码）、`qrcode_txt` 内嵌 `appid=1005`、`clientver=20489`、`srcappid=2919`（实测返回同结构 `data.qrcode/qrcode_img`）；
  - 轮询 `/v2/get_userinfo_qrcode`：`appid=1005`、`clientver=20489`、`srcappid=2919` → status=4 返回 Android 型 token；
  - 设备 mid（十进制）首次生成后以 `kg_mid` 持久化进会话 cookie，取码/轮询/`get_all_list`（`_gatewaySignedPost` 新增 `mid` 参数）共用，密码/验证码登录同样复用与持久化；
  - 登录成功后**需重新扫码**获取 Android 型 token（旧 H5 型 token 无法升级）。
- **测试**：更新签名固定向量（新参数 PowerShell 独立算得）+ 取码/轮询参数断言；新增 `get_all_list` 使用会话 `kg_mid` 回归（20017 诱因之一：旧实现用无关的匿名搜索 mid）。测试 481/488 全绿（新增 1 条）。

## 0.11.0+34 — 2026-11-19

### 增强（导入歌单带出源歌单名称与封面）

- **痛点**：导入分享链接后歌单名默认「导入歌单」需手填、封面是渐变占位——源歌单的名称和封面没有带过来。
- **接口层新增 `MusicPlatformApi.playlistInfo`**（默认 null，失败不阻塞导入）：
  - QQ：`uniform_get_Dissinfo` 的 `dirinfo.title/picurl` + `total_song_num`（探针实测字段）。
  - 网易云：`v3/playlist/detail` 的 `playlist.name/coverImgUrl/trackCount`。
  - 酷狗：仅 gcid 形态——m.kugou.com 歌单页内嵌 `listinfo` JSON（`name/pic/count/list_create_username`），复用 `playlistSongs` 的移动 UA 约束（桌面 UA 被 301 到 www 站无数据）；数字 specialid 无公开元数据接口，返回 null 走手填兜底。
- **`UserPlaylist` 新增 `coverUrl` 字段**（Hive 持久化，旧存档无该字段重载兜底空串）：`createPlaylist(name, {coverUrl})`、重命名保留封面、`_LocalPlaylistCard` 封面非空显示网络图（空串仍渐变占位）。
- **导入流程**：先取 `playlistInfo` 再拉歌曲，命名弹窗默认填源歌单名称（拉不到回落「导入歌单」），创建本地歌单时写入源封面。
- 实网验证：用户链接（gcid `3zivrucnzoz01f`）带出「最好听的英文歌，包你上瘾！」+ `c1.kgimg.com/custom/240/...` 封面 + 创建者「大Ner」+ 400 首。
- 新增测试 5 条：playlistInfo 三平台字段映射 4 条（含酷狗数字 specialid 返回 null）+ 封面创建/重命名保留/持久化重载/旧存档兜底 1 条。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：**477/477 全绿**（+5）。

## 0.11.0+33 — 2026-11-19

### 修复（酷狗 gcid 歌单分享链接导入「无法识别」）

- **根因**：酷狗 App/网页的歌单分享链接是 `https://m.kugou.com/songlist/gcid_XXX/?src_cid=XXX` 形态——gcid（全球集合 ID，字母数字混合）在**路径**里，而 `parseJXPlaylistLink` 只认 `?specialid=`/`?global_collection_id=`/`?id=` 三个数字参数形态，全部命中不了 → 提示「无法识别歌单链接」。
- **链接解析**：kugou 分支新增 `/songlist/gcid_([A-Za-z0-9]+)` 路径形态与字母数字版 `global_collection_id` 参数；原有数字 specialid 链接不受影响。
- **gcid → specialid 映射**（KuGouApi.playlistSongs）：gcid 不能直查 `special/song`（实测返回「参数不合法」）；非数字 id 先经 `m.kugou.com/songlist/gcid_XXX/` 歌单页映射成数字 specialid（页面内嵌 `"specialid":2509422`），再走原有接口。**必须带移动浏览器 UA**——桌面 UA 会被 301 到 `www.kugou.com`，该页面不内嵌映射（实网调试定位）。
- 实网验证：用户提供的链接（gcid `3zivrucnzoz01f`，400 首歌单）实链拉回 **325 首**（下架/不可见曲目不计），分页聚合正常。
- 新增离线回归 4 条：parseJXPlaylistLink gcid 路径/参数两形态；playlistSongs gcid 映射链路（歌单页→special/song 参数断言）与无效 gcid 返回空不抛异常。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：**472/472 全绿**（+4）。

## 0.11.0+32 — 2026-11-19

### 修复（QQ 音乐用户歌单封面/曲目数不显示）

- **根因**：`musicu` `GetPlaylistByUin` 的 `v_playlist` 字段为**驼峰**（探针实测）：`picUrl`/`bigpicUrl`/`dirName`/`songNum`，而 `_playlistFromUserItem` 旧映射链只认 `picurl`/`logo`/`cover`/`songnum`/`song_cnt`，全部未命中 → 封面空、曲目数 0。
- `_playlistFromUserItem` 扩映射：coverUrl 链加 `picUrl`/`bigpicUrl`，songCount 加 `songNum`，title 链 `dirName` 提前（旧字段保留兼容收藏列表 `v_list` 形态）。
- **http→https 规范化**：v_playlist 的封面部分是 `http://`（如「我喜欢」的 `y.gtimg.cn/cover_love_300.jpg`），且映射后统一过 `jxNormalizeImageUrl` 升 https——移动端明文被禁，不升 https 封面仍加载不出。
- 新增离线回归：`residual_fixes_test.dart` 「QQ 用户歌单封面映射」——v_playlist 驼峰字段映射、http 升 https、v_list 旧形态（dissname/logo/songnum）不回归。
- 酷狗「登录已过期」歌单不显示：非代码 bug，酷狗会话被服务端拒（20017），需在设置页重新扫码登录。

### 门禁

- `flutter analyze`：8 issue 基线不变。
- `flutter test` 全量：**468/468 全绿**（含新增 QQ 封面映射回归 1 条）。

## 0.11.0+31 — 2026-11-19

### 音乐库信息架构重排

- 一级 tab 从 5 个（收藏/历史/收藏歌单/歌单/下载）收敛为**一排三个等宽**：「音乐」「歌单」「下载」。
- 「音乐」内二级小标签：**收藏 / 历史**（原两个一级 tab 合并，带计数）。
- 「歌单」内二级小标签：**收藏 / 创建**（原「收藏歌单」「歌单」两个一级 tab 合并）：收藏=本机收藏+各平台账号歌单聚合；创建=自建歌单。
- 歌单卡片手机端**一排 3 个**（原自适应约 2 列）；桌面宽内容区（≥840dp）维持自适应多列不变。
- 自建歌单从列表行改为与收藏歌单同视觉的**卡片网格**（渐变占位封面 + 曲目数角标），长按弹「重命名 / 删除歌单」底部菜单（原行内 PopupMenu 的降级入口）。
- 头部操作按钮随 tab/二级联动：音乐·历史→清空历史；歌单·收藏→刷新；歌单·创建→导入/新建歌单；下载→刷新。
- 测试：`user_playlists_test` 适配新结构（一级三 tab、二级切换、平台聚合、导入歌单路径走「歌单→创建」）；全量 **467/467 全绿**；`flutter analyze` 8 条基线不变。

## 0.11.0+30 — 2026-11-18

### 修复（QA 遗留清单：兜底校验/换平台提示/死链文案化/酷狗分页/扫码终态）

对照历史回溯清单（QA 实扫验收残留 D-03/D-05/D-06/D-11 + 播放失败诊断 P1 遗留项）集中修复，全部离线单测锁住：

- **跨平台兜底校验（播放失败诊断 P1）**：`findAlternativeSong` 候选链从「非 VIP + 标题相似」扩为「非 VIP → 标题相似 → 同歌手（`similarArtist`：归一化双向包含，未知歌手/群星不过滤）→ 时长接近（`durationClose`：±8 秒或 15% 容差，防 30 秒片段/超长 Live）→ 原曲非特殊版本时排除 Live/伴奏/DJ/翻唱等候选（`isOddVersion`，英文词用词边界防误伤 Discover/Believe）」。历史问题：兜底会把 VIP 曲换成同名不同歌手的歌或 Live/片段。
- **换平台不再静默**：兜底成功换歌时 `resolveAndPlay` 调 `PlayerService.reportSourceSwitch`，ShellPage 监听 `lastSourceSwitchNotice` 弹 SnackBar「「歌名」在XX不可播，已切换XX版本」后清除。
- **死链原因文案化（#3/#6）**：三平台 `getPlayUrl` 失败的**已知特定原因**写入 `lastError`（网易云 code=-110 → 「该歌曲为网易云 VIP 歌曲，需登录会员账号播放」；QQ 104003 → 「该内容为节目/电台类，暂不支持播放（QQ音乐）」；酷狗 status=0 error（如「需要付费」）→ 「酷狗：…（该歌曲可能需要会员或付费）」）。`PlayerService` 新增 `onlineResolutionErrorHint`，providers.resolveUrl 用快照把本次解析新增的 lastError 接入 `_playAt` 死链提示（消息追加具体原因），成功解析时清空防陈旧误报。
- **酷狗歌单分页（#5）**：`playlistSongs` 与 QQ 语义对齐——page=1 聚合整单（>100 首按 100 条/页内部翻页，上限 10 页；接口忽略 page 参数时首元素 hash 防重守卫，不堆叠重复页），page>1 本地切片。历史问题：大歌单只有前 100 首。
- **扫码终态提前停轮询（QA D-05）**：`MusicPlatformApi` 新增 `qrTerminal`（默认 false）；网易云 800/8821、QQ 65、酷狗 status=0 置终态，等待态复位，重新取码重置；设置页 `_poll` 检测终态即停定时器并展示 lastError，不再空转到 2 分钟。
- **QQ 兑换链超时取消（QA D-06）**：pollQrLogin 的 `.timeout` onTimeout 里 `CancelToken.cancel()` 取消底层请求，CancelToken 贯穿 check_sig/authorize/OAuth 链/QQLogin 全链；取消异常不覆盖已写好的超时提示（防一次性 code 被晚到响应消费、迟到失败覆盖提示）。
- **QQ `#code=` fragment（QA D-11）**：`_extractCodeFromText` 提为顶层公开 `extractOAuthCode`，正则扩为 `[#?&]code=`——授权方用 fragment 形态回跳（`wx_redirect.html#code=xxx`）也能取到 code。
- 新增 `test/residual_fixes_test.dart`：23 条离线回归（三平台 qrTerminal 三态与重置、-110/104003/酷狗付费文案、extractOAuthCode 五形态、酷狗分页聚合/防重/切片、兜底三纯函数、reportSourceSwitch），不联网。

### 门禁

- `flutter analyze`：8 issue 基线不变（tray_service dead_code + check_api_test avoid_print×6 + home_rank_expand unused_import，均为存量）。
- `flutter test` 全量：**467/467 全绿**（含新增 residual_fixes_test 23 条）。

### 真机回归（Mate 80 Pro，arm64 +30 签名包）

- 安装/启动冒烟：首屏正常渲染，无白屏/崩溃/弹窗。
- **#4 栀子花开**：搜索→播放何炅版成功，进度正常前进（PASS）。
- **#8 深色模式**：跟随系统深色，背景/文字/播放栏/导航对比度正常，无渲染异常（PASS）。
- **D-05 扫码终态**（酷狗，不扫码等待）：约 150 秒后出现「二维码已过期，请关闭后重新获取」，时机与二维码有效期一致而非 2 分钟客户端超时，终态停轮询生效（PASS）。副作用：验证过程退出了酷狗登录，需重新扫码恢复。

## 0.11.0+29 — 2026-11-18

### 修复（队列死链曲目卡死整条播放队列：自动跳过 + 提示）

真机（Mate 80 Pro）实测网易云隐私歌单「山有木兮」20 首整单播放时发现：非 VIP 账号下部分曲目解析不出直链（VIP/版权限制），自动下一首撞上这种「死链曲目」时**整个队列停在 00:00 不再前进**（实测卡在「立夏」），且不写 `lastResolutionError`——用户看不到任何提示，表现为「应用卡了」。

- **`lib/services/player_service.dart`**：`_playAt` 增加 `autoAdvance` 参数——自动前进场景（自然播完的下一首、播放器报错后的重解析重试、用户按「下一首」）撞上死链曲目时，提示「「歌名」暂无播放链接，已跳过」后自动跳到队列下一首，队列不中断；队尾无下一首可跳则停下并给出可行动提示（「可尝试切换其它平台音源」）。用户主动点播（队列面板/歌单点击）保持原有「停下并提示」语义不变；本地加密曲目失败提示（评审 R-11）行为不变。
- 死链曲目从此不再静默：所有「无可播放链接」路径都写 `lastResolutionError`，复用 shell_page 的 SnackBar 链路。
- 新增 `test/queue_auto_advance_test.dart`：用户点播死链提示、自动前进跳过继续播、队尾死链不越界不误导、连续多首死链逐首跳过，共 4 条回归。

### 验证（真机 Mate 80 Pro，HarmonyOS API 26，arm64 +29，uitest）

- 网易云山有木兮整单播放：告白之夜/唐人实际出声播放（进度推进、音频渲染数据流、状态栏网速 53-82KB/s）。
- 播放队列 (20) 完整展示；队列内点歌切换正常。
- 死链曲目自动跳过链路见上（+29 修复后复验）。

### 排查记录（+29 期间「本机收藏」条目一度消失：非应用 bug，结案）

- 现象：+28 复验时「本机收藏 1 · 山有木兮」正常，+29 装机后区块消失。取证 `jx_playlists.hive`：收藏键 `c:1:2902307374` 共 4 帧 = put/delete/put/delete（+27 的 收藏→取消→重收 + 末尾多出一帧 delete），且全部自动化 tap 均已对照 dumpLayout 复核、无一落在星标上；代码侧唯一删除路径是星标按钮 `toggleCollectedPlaylist`。
- 真机重收复验（+29）：收藏 → 区块恢复 → 冷重启 → 导航 → 播放全部 → 播放器页 → 队列面板 → 返回，逐步拉取盒文件比对，**零异常写入**（期间一次误收藏为测试脚本时序问题——mini player 未就绪时坐标落到详情页星标，随即取消恢复；这反而证实了「坐标落在过期页面状态会误触星标」是唯一可复现的删除机制）。真机为用户日常使用设备，+28→+29 窗口内的删除帧最可能来自窗口期的人为操作，非应用自动行为。
- 结论：收藏持久化链路（Hive 写入/重载/去重/冷重启）经盒级帧取证与逐步复验稳定，无需代码改动。

## 0.11.0+28 — 2026-11-18

### 修复（无 libmpv 环境启动白屏：播放引擎初始化失败优雅降级）

模拟器（x86_64）安装后启动只显示状态栏、主体全白。根因：media_kit 的 OHOS 原生库只发布了 arm64-v8a/armeabi-v7a 两个 ABI（`media_kit_libs_ohos_video/libs/`），x86_64 模拟器上 `DynamicLibrary.open('libmpv.so.2')` 必然失败；而 `MediaKit.ensureInitialized()` 失败时 `rethrow`，`main()` 未捕获 → `runApp()` 永不执行 → 白屏（进程活着、无崩溃日志，极易误诊）。

- **`lib/main.dart`**：`MediaKit.ensureInitialized()` 包 try/catch——引擎缺失只 `debugPrint`，UI 照常启动；播放能力由 PlayerService 降级处理。
- **`lib/services/player_service.dart`**：`_init()` 里 `Player()` 创建包 try/catch，失败置空 `_player`；新增 `_playerCreationRequested` 标记（构造器初始化列表）区分「测试 initPlayer:false」（保持原静默 no-op 语义，不提示）与「真机请求了引擎但创建失败」（点播时置 `lastResolutionError='播放引擎初始化失败，播放功能暂不可用'`，复用 shell_page 的 SnackBar 链路给出明确提示，不再静默无反应）。
- 不影响真机（arm64 libmpv 正常加载，行为不变）；测试契约保持（`initPlayer:false` 的 onSongStarted 回调语义未动）。

### 验证（Pura 80 Pro 模拟器，HarmonyOS 6.1.1，x86_64，uitest）

- 启动白屏修复：应用完整 UI 正常渲染（首页三平台热门聚合/底部五 tab）。
- 账号盒从真机沙盒恢复（`jx_accounts.hive` 推入 `app_flutter/`）：收藏歌单 tab「QQ音乐 · 4 个歌单」「网易云音乐 · 4 个歌单」「酷狗音乐 · 登录已过期，请重新登录」三态正确。
- 隐私歌单「山有木兮」详情：`lD李先森 · 20 首` 全量列表（1-7 号曲目渲染正常）。
- 星标收藏：「本机收藏 1 · 山有木兮」区块出现，平台区同歌单去重。
- 酷狗错误 chip 点击跳设置页：账号与登录三行（QQ/网易云/酷狗登录态）正常。
- 无引擎点歌：SnackBar「播放引擎初始化失败，播放功能暂不可用」，进程不崩。
- 门禁：`flutter analyze` 8 issue 基线不变；`flutter test` **438/438 全绿**。

### 已知限制

- 播放功能在 x86_64 模拟器不可用（上游 media_kit OHOS 库无 x86_64 libmpv 预编译产物）；真机 arm64 不受影响。
- 酷狗 token 已过期（error_code 20017），需在设置页扫码重新登录。

## 0.11.0+27 — 2026-11-18

### 修复（网易云/酷狗登录账号歌单拉取：两处接口 bug + 错误态透明化）

真机诊断（新增 `tool/probe_playlists.dart`：读设备沙盒 `jx_accounts.hive` 的真实登录态，`dart run -DJX_PROBE=true` 离线复现三平台 userPlaylists 并打印原始响应）定位：
- **网易云「0 个歌单」是两个接口 bug，会话其实一直有效**：① 拿 uid 的端点写错——`/api/user/account` 返回 404「接口未找到」，正确老接口为 `/api/nuser/account/get`；② `/api/user/playlist` 老接口的响应字段是单数 **`playlist`**（`{"more":false,"playlist":[…],"code":200}`），代码读的是 `playlists` → 永远解析出空列表。修复后真机网易云 4 个歌单正常加载（喜欢的音乐/山有木兮…）。
- **酷狗「0 个歌单」是 token 真失效**：`/v7/get_all_list` 网关返回 `{"status":0,"error_code":20017}`，此前被 catch 静默吞掉、UI 误导性显示「0 个歌单」；现在如实显示「登录已过期，请重新登录」并引导重登。
- QQ 正常（4 个歌单），未受影响。

### 改动明细

- **`lib/services/api/netease_api.dart`**：`userPlaylists` 端点修正为 `/api/nuser/account/get`；歌单列表解析兼容 `playlist`/`playlists` 两种字段名；带 MUSIC_U 但 `profile` 为 null 时抛 `SessionExpiredException('登录已过期，请重新登录')`（`on SessionExpiredException { rethrow; }` 不被兜底 catch 吞掉），作为真会话失效时的安全网；`-DJX_PROBE` 探针打印保留（编译期剔除，release 零开销）。
- **`lib/services/api/kugou_api.dart`**：`userPlaylists` 在网关返回非零 `error_code`（20017 过期 / 20028 风控 / 其它）时抛对应 `SessionExpiredException`（琥珀 chip 提示重登），root 为 null 归为「网络错误或登录已过期」；同样 rethrow 不吞。
- **`lib/services/api/netease_api.dart`（playlistSongs 补充修复）**：歌单详情请求 `/api/v3/playlist/detail` 此前不带登录 Cookie——隐私歌单（privacy>0）会被 401「该歌单已被创建者设置为隐私」拒绝（探针实测：本人会话 + Cookie 请求 200 全量），补 `Cookie`/`Referer` 头；加 `n=1000` 参数取全量曲目（v3 默认只回 10 首，实测 20 首歌单修复后从 10 → 20、81 首榜单从 10 → 81）。真机验证：「山有木兮」隐私歌单详情从「暂无歌曲」修复为 20 首完整加载。
- **`lib/services/api/music_api.dart`**：新增 `SessionExpiredException`（会话失效异常，携带面向用户的 message）与 `PlatformPlaylists`（单平台歌单拉取结果：`playlists` + `error`）；`userPlaylistsByPlatform()` 返回 `Map<int, PlatformPlaylists>`——会话失效平台带 error 描述，其它异常归为「拉取失败」，单平台失败不影响其它平台。
- **`lib/ui/library_page.dart`**：`_platformErrors`（Set）标记会话失效平台；chip 错误态用琥珀警示色（区别于平台色与灰色「未登录」），文案展示真实原因（如「酷狗音乐 · 登录已过期，请重新登录」），点击跳设置页重登（Tooltip「去设置重新登录」）；空态「去设置登录」按钮条件扩展为「未登录 或 会话失效」。
- 新增 `tool/probe_playlists.dart` 一次性诊断探针（不进 App 产物）。

### 测试与验收

- `test/user_playlists_test.dart`：`_FakePlatformApi` 新增 `sessionError`（抛 `SessionExpiredException` 模拟「已登录但平台拒绝会话」）；新增 hub 层用例（userPlaylistsByPlatform 会话失效平台带 error、不影响其它平台）与 UI 层用例（网易云/酷狗 chip 显示「登录已过期，请重新登录」、点击跳设置页 navIndex==4）。
- 门禁：`flutter analyze` 8 issue 基线不变；`flutter test --reporter json` **438 testDone / 0 failure / 0 error** 全绿（新基线 438）。
- 真机装机自检（uitest dumpLayout，全链路）：
  - 收藏歌单 tab：「QQ音乐 · 4 个歌单」「网易云音乐 · 4 个歌单」「酷狗音乐 · 登录已过期，请重新登录」；
  - 隐私歌单「山有木兮」详情 20 首全量加载（修复前「暂无歌曲」）；QQ 大歌单（しんちゃん 155 首）正常；
  - 星标收藏/取消：toast「已收藏「xx」」/「已取消收藏」，返回 tab 后「本机收藏 1」区块出现且平台歌单区同歌单去重；
  - 首页点歌：mini player 起播（进度推进），播放器页「更多 → 播放队列」显示**播放队列 (9)** 整单在队；
  - 酷狗错误 chip 点击跳设置页重登。

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
