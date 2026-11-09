# CHANGELOG

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
