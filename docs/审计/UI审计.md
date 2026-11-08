# JXMusic UI 层审计报告

- 审计人：唐 · tang-ui（CPO / 产品设计师），任务 `task-3`
- 审计日期：2026-11-08
- 审计对象：`D:\Project\yinyue\JXMusic`（Flutter 工程）
- **代码基线：git HEAD `d40525a`（0.9.6+15，2026-11-08 23:24 提交，工作区干净）**
  - 审计开始时 HEAD 为 `f32dac6`（0.9.5+14），期间另一个并行会话提交了 `d40525a`；该提交只含 UI 布局与版本号（`git show --stat d40525a`：`CHANGELOG.md`、`docs/项目状态.md`、`lib/ui/player/player_page.dart`、`lib/ui/search_page.dart`、`lib/ui/settings_page.dart`、`pubspec.yaml`，共 6 文件），**无播放/数据逻辑改动**。
  - 本报告所有行号已按 `d40525a` 重新核对；搜索页/播放页使用该提交后的最新内容。
- 审计方式：逐文件 `read` 全量读完 UI 文件（非 grep 摘句），并交叉阅读 `providers.dart`、`playback.dart`、`player_service.dart`、`library_store.dart`、`local_music.dart`、`download_service.dart`、`tray_service.dart`、`mini_mode.dart`、`models/*` 核对调用点；用 `git show` / `git diff` 核对基线。
- **边界声明**：本任务只读代码、只写本报告；未运行 `flutter analyze` / `flutter test` / `flutter run`，未真机或桌面实际点击。凡标“待实测”的条目为源码级静态推演，已在条目标注。未修改任何代码/配置，未 `git commit`。

---

## 一、结论摘要

### 1.1 分级统计

| 级别 | 条数 | 编号 |
|---|---:|---|
| **阻断** | **1** | UI-01 |
| **高** | **5** | UI-02 ~ UI-06 |
| **中** | **16** | UI-07 ~ UI-22 |
| **低** | **18** | UI-23 ~ UI-40 |
| **合计** | **40** | — |

严重级别定义：**阻断**＝必现且核心功能不可用；**高**＝主流程大概率触发，或用户明显感知、难自愈；**中**＝特定条件可触发、用户可感知、有绕行；**低**＝边界/体验/一致性/代码卫生。

### 1.2 最严重的 5 条（按危害排序）

1. **UI-01（阻断）首页永久加载态**：`home_page.dart:24` 把 `_loading` 初始化为 `true`，`_load()` 首行守卫（`:44`）见 `_loading==true` 直接 `return`，而全文件只有 `:93` 能把它置回 false——形成死锁。首页从冷启动起就一直转圈；手机端“刷新”、榜单“更多”、切回首页的自动刷新（`:108-115` 要求 `!_loading`）全部被同一个守卫挡住，**首页榜单/推荐歌单/热歌榜整块不可用**。
2. **UI-02（高）播放页清空队列后进入空白死路**：`player_page.dart:82-84` 在 `currentSong==null` 时返回没有任何返回按钮的空 `Scaffold`；`_QueueSheet` 的“清空队列”（`:1049-1052`）无确认、且 `clearQueue()`（`player_service.dart:358-363`）不停音频。桌面端自绘标题栏没有系统返回，用户被困在空白页而音乐继续播放。
3. **UI-03（高）全局快捷键在输入框聚焦时仍然拦截按键**：`shortcuts.dart:35-38` 用 `primaryFocus?.context?.widget is EditableText` 判断“正在输入”，但按 Flutter 源码，EditableText 的焦点节点 context.widget 是内部 `Focus` 组件（SDK `editable_text.dart:5903-5906`、`focus_scope.dart:583-587`），该 `is` 恒为 false。于是搜索框输入空格触发播放/暂停、输入 `m/n/p` 触发静音/切歌、方向键调音量/快进。
4. **UI-04（高）播放页在最小窗口/小屏竖屏下 RenderFlex 纵向溢出**：`player_page.dart:102-359` 外层 `Column` 不可滚动，`_AlbumArtView`（`:479-536`）固定 300 封面 + 40 间距 + 标题/副标题 + 32 Chip；控制区固定约 182（进度 28 + 8 + 主键 72 + 14 + 音量 32 + 上下 padding 28）、顶栏 60、音源行 31。Windows 最小窗口 960×640（`main.dart:29-30`）可用高度约 367，内容需 434~461，**溢出约 67~94px；多音源时再加 31px**。
5. **UI-05（高）进度条拖动会回跳且每帧发 seek**：`player_page.dart:214-237`，滑块 `value` 由 `player.position` 流反向计算（`:86-88`），`onChanged`（`:224-231`）每次移动都 `await player.seek(...)`。拖动过程中旧位置回报会把手柄拉回，且高频 seek 造成卡顿/音频断续，松手落点不可预期。

### 1.3 总体判断

- **导航骨架成立**：桌面侧栏 / 手机 5 tab（`shell_page.dart:34-48`）用 `IndexedStack` 保留各页状态；推入的详情页（歌单详情、我的歌单、播放页）均有显式返回按钮。但存在 1 处真正的“断头路”（UI-02）与 1 处功能不可用（本地目录选择，UI-15）。
- **播放器交互是最大风险区**：进度条、切源、队列三处都有“UI 状态与播放引擎不一致”的问题（UI-05/06/11）；歌词三态缺失（UI-17）。
- **响应式只做了“壳 + 首页”两套布局**：`isDesktopLayout` 全仓只有 `shell_page.dart:32`、`home_page.dart:116` 两个使用点（定义在 `layout.dart:8-10`），其余页面是单一布局；播放页在窄宽度已由 0.9.6 修好，但**高度方向没有适配**（UI-04）。
- **视觉一致性不足**：液态玻璃只在 `glass.dart` 与壳里真正用到（`BackdropFilter` 仅 `glass.dart:42`、`shell_page.dart:135/381`），详情/播放/迷你页各写一套渐变；53 处硬编码 `JXColors.primary` 使“5 套主题色”基本无效（UI-20/21）；浅色模式下 9.5px/8px 小字与选中态对比度多处低于 WCAG AA（UI-19）。

---

## 二、问题清单

> 格式：编号、级别、`文件:行号`、触发/复现步骤、用户可见后果、建议。所有行号基于 `d40525a`。

### 阻断

#### UI-01（阻断）首页初始加载死锁，永久转圈

- **位置**：`lib/ui/home_page.dart:24`、`:41-50`、`:93`、`:108-115`、`:131-137`、`:225-231`
- **触发/复现**：冷启动 App → 默认即首页；或任意窗口尺寸冷启动。`initState`（`:36-39`）调用 `_load()`，但 `_loading` 初值为 `true`（`:24`），`_load` 第一段守卫 `else if (_loading) return;`（`:44`）立即返回，没有发起任何请求；此后只有 `_load` 成功走完才会在 `:93` 置 `_loading=false`，而它压根没被执行。
- **用户可见后果**：首页永远显示 `CircularProgressIndicator`（桌面 `:131-137`、手机 `:225-231`），“推荐歌单 / 热门单曲 / 热歌榜”整块不可用。手机端刷新按钮（`:366-370` → `_load`）同样被守卫弹回；切走再切回首页时自动刷新要求 `!_loading`（`:108-115`），也不会触发。唯一能进入其他 tab 绕过，但首页核心内容永久缺失。
- **建议**：`_loading` 初值改 `false`；或在 `initState` 调用 `_fetch()`（不带守卫的内部实现），守卫只用于防“手动重复触发”。补一条 widget test：pump `HomePage` 后断言 `_tops`/歌单行出现、无 `CircularProgressIndicator`。

### 高

#### UI-02（高）播放页“清空队列”后空白死路，音频仍在播

- **位置**：`lib/ui/player/player_page.dart:82-84`、`:1049-1052`；`lib/services/player_service.dart:358-363`
- **触发/复现**：播放任意歌曲 → 点播放条进入播放页 → 右上“⋯” → “播放队列” → “清空队列”。
- **用户可见后果**：`clearQueue()` 把 `_currentIndex` 置 -1 并 `notifyListeners`，`PlayerPage.build` 命中 `song == null` 分支返回 `Scaffold(body: SizedBox())`——整页变空白且**没有任何返回/退出控件**。桌面端标题栏是自绘隐藏式（`main.dart:34-35`），没有系统返回按钮，用户只能把窗口关进托盘（再打开仍是空白页）或强退。同时 `clearQueue()` 不暂停/停止播放，音乐继续响，与“未在播放”的播放条空态矛盾。
- **建议**：`song == null` 时渲染“回到主界面”空态（复用 `GlassButton`），或直接 `Navigator.pop`；清空队列前 `pop` 队列弹层并给二次确认；`clearQueue()` 内先 `_player.stop()` 再清状态；更稳妥：播放页禁止清空队列，只允许从底栏/队列里操作。

#### UI-03（高）全局快捷键在搜索框/命名弹窗输入时仍拦截按键

- **位置**：`lib/ui/shortcuts.dart:35-38`（判断）、`:40-84`（处理）；判定依据（Flutter SDK）：`editable_text.dart:5903-5906`、`focus_scope.dart:583-587`
- **触发/复现**：搜索页点输入框 → 输入含空格的词（如 `周杰伦 稻香`）或含 `m/n/p` 的英文；或在新建歌单弹窗（`dialogs.dart:16-22`）输入名称。**待实测确认**（静态判定：`_isEditingText()` 恒 false）。
- **用户可见后果**：空格 = 播放/暂停、`M` = 静音、`N/P` = 上/下一首、`←→` = 快进/快退、`↑↓` = 音量——输入过程中同时触发播放器操作，搜索词/歌单名被破坏（桌面端可能表现为“边打字边切歌”）。这是搜索与命名两条主流程的输入体验问题。
- **建议**：改用 `FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null`，或改为在 `Shortcuts/Actions` 层声明快捷键（这样输入控件默认优先）；对 `m/n/p/space` 这类无修饰键增加“仅当无 TextField 聚焦”的条件。修复后补 widget test：聚焦 TextField 后发送空格 KeyEvent，断言 `player.playing` 不变。
- **备注**：`shortcuts.dart:41` 也未过滤 `event.repeat`，见 UI-31。

#### UI-04（高）播放页纵向内容超出可用高度，最小窗口/小屏溢出

- **位置**：`lib/ui/player/player_page.dart:102-359`（不可滚动 Column）、`:479-536`（`_AlbumArtView` 固定尺寸内容）、`:208-398`（控制区固定高）；相关：`lib/main.dart:29-30`（窗口 `minimumSize: Size(960, 640)`）
- **触发/复现**：Windows 把窗口拖到最小 960×640；或在 360×640/320×568 的小屏手机竖屏打开播放页；或系统字体缩放 ≥1.2。
- **用户可见后果**：`Column` 固定部分 ≈ 顶栏 60 + 音源行 31（多音源时）+ 控制区 182 = 273；960×640 下 `Expanded` 只剩约 367，而 `_AlbumArtView` 需要 300(封面)+40(间距)+26~52(标题 1~2 行)+8+16(副标题)+12+32(Chip) ≈ **434~461**，**溢出 67~94px；带音源行时 98~125px**。表现为黄黑 Overflow 条（debug）/内容被裁（release），播放/暂停键可能被挤出安全区。手机小屏同理；宽度方向 0.9.6 已修（见第五节）。
- **建议**：把封面区放进 `LayoutBuilder`，按 `maxHeight - 固定区` 计算封面尺寸（下限 140）并 `FittedBox`；或把“封面/歌词 + 控制区”整体放入 `SingleChildScrollView`（播放键吸底）；给标题/Chip 限高。补 960×640、360×640、320×568 三档 widget 截图测试。

#### UI-05（高）进度条拖动回跳、每帧 seek，落点不可控

- **位置**：`lib/ui/player/player_page.dart:86-88`（value 来源）、`:219-232`（`Slider` + `onChanged` 内 `await player.seek`）
- **触发/复现**：播放中拖动播放页进度条（尤其歌曲较长时）。
- **用户可见后果**：滑块位置来自 `player.position` 流（`:86-88`），拖动时流的旧值会把手柄拉回手指之外；每个 pointer move 都触发一次异步 `seek`（无 `onChangeStart/onChangeEnd`，无本地拖动值），高频 seek 导致卡顿和音频断续，松手位置与手指位置不一致。这是用户最常做的播放器操作之一。
- **建议**：拖动期间维护本地 `_dragValue`（`onChangeStart` 置位、`value` 用本地值、`onChangeEnd` 一次性 seek 并复位），期间忽略 position 流；`seek` 加节流/防抖。

#### UI-06（高）切换音源污染队列 + 进度回退 + 无防重入

- **位置**：`lib/services/playback.dart:114-128`（`switchSource`）；`lib/services/player_service.dart:175-198`（`playSong` 在 `queue==null` 且队列无该曲时 append）、`:277-302`（next/previous）；入口 `lib/ui/player/player_page.dart:159-181`（`:167` 调 `switchSource`）
- **触发/复现**：搜索页点播一首有 QQ+网易云双音源的歌（队列只有 1 首）→ 播放页点“网易云”切源 → 打开“⋯ → 播放队列”→ 按“下一首”。
- **用户可见后果**：
  1. 新音源 `globalId` 不在队列中，`playSong(queue:null)` 走 `:187-196` 的 append，队列变成 `[QQ 版, 网易云版]`，同一首歌出现两条，`next/previous` 在两条之间跳、循环模式下还会跳回刚切走的旧平台版本；
  2. `switchSource` 在**解析前**记录 `position`（`:116`），网络解析常需 1~5 秒，成功后 `seek` 回旧位置（`:124-126`），用户听感为“切换后倒回几秒”；
  3. 切换期间按钮无 loading、无防重入，连点两个平台会并发 `resolveAndPlay`，后完成者覆盖，实际音源与高亮可能不一致。
- **建议**：`switchSource` 用“替换当前队列项”语义（当前 `globalId` 替换为新音源的 `queue[currentIndex]`，长度不变）；进度用 `player.position` 实时值或“解析后位置+”补偿；切换中禁用音源按钮并显示 loading；补回归测试：切源后 `queue.length` 不变、`currentIndex` 不变、`currentSong` 为新音源（与架构审计 P1-1 同一问题，本报告给出 UI 侧可感知后果）。

### 中

#### UI-07（中）搜索请求竞态：结果与顶部关键词错配

- **位置**：`lib/ui/search_page.dart:36-74`（`_search`）、`:64-73`（`await Future.wait` 后无条件覆盖）
- **触发/复现**：网络慢时先搜“周杰伦”再立刻搜“陈奕迅”（或点两个搜索建议）。两个请求并发，先发的可能后返回；`:68-73` 用返回结果覆盖 `_groups/_rawCount/_searching/_error`，而 `_keyword` 已在 `:40` 改成最新词。
- **用户可见后果**：列表是 A 的结果、顶部写「B」·去重后 N 首；`_searching` 被旧请求提前置 false，spinner 消失后列表又跳变；`_error` 也可能被旧请求覆盖。
- **建议**：为每次搜索分配自增 `requestId`，仅当 `id == _latestId` 时才 `setState`；或保存 `CancelableOperation` 取消旧请求。

#### UI-08（中）“首选·XX”音源标签命中区过小、无按压反馈、点当前音源会从头重播

- **位置**：`lib/ui/search_page.dart:297-308`（`Wrap` 内标签）、`:325-400`（`_SourceChip`：`:355` `GestureDetector`、`:357-366` 内边距 6/2、`:380` `fontSize: 9.5`、`:385-394` VIP 8px）；播放入口 `:77-98`
- **触发/复现**：桌面鼠标点「首选·QQ」/「网易云」小标签；或播放中再点一次当前音源标签。
- **用户可见后果**：标签实际点击区域约 17px 高、40~55px 宽，远小于 48×48 触控标准，桌面/手机上经常点不中或误触整行播放；`GestureDetector` 无 InkWell/水波纹/hover，点中也没有反馈；点当前正在播放的首选音源会走 `_play` 重新 `playSong`，导致**从头重播**当前歌曲。
- **建议**：改用 `InkWell`（或 `Material+InkResponse`）并加 `MouseRegion(cursor: click)`；`padding` 提升到至少 6/6 并用 `ConstrainedBox(minHeight: 32)`；点击当前音源时改为“忽略/切换暂停”；标签上加“正在播放”状态点（与 UI-20 的主题一致）。

#### UI-09（中）播放失败文案与内部逻辑矛盾；标签点击未保证“点谁播谁”

- **位置**：`lib/ui/search_page.dart:87-98`（失败文案 `可点其它平台标签再试`）、`:77-98`（`_play` 全部走 `playTrackGroup`）；`lib/services/playback.dart:74-97`（`playTrackGroup` 本身会把**所有**音源按序试完）；`playback.dart:100-111`（`playSingleSource` 存在但全仓 0 调用）
- **触发/复现**：多音源曲目全部音源不可用（VIP/版权），点整行播放。
- **用户可见后果**：内部已经把其它平台都试过并全部失败，提示却让用户“点其它平台标签再试”，用户重复点击仍失败；同时点具体标签时 `playTrackGroup(preferred:)` 在首选失败后仍会自动落到其它平台（只靠事后 SnackBar 告知），与 0.9.5「不再由系统暗中挑选」的产品意图有落差。
- **建议**：点具体标签时调用现成的 `playSingleSource`（只试该音源，失败直接提示“XX 音源不可用”）；整行播放保留内部兜底，但失败文案改为“已尝试全部 N 个音源，均不可用”；成功兜底提示保留。

#### UI-10（中）搜索信息行无弹性，长关键词横向溢出

- **位置**：`lib/ui/search_page.dart:153-171`（`Row` 内两个裸 `Text`，无 `Expanded/Flexible`、无 ellipsis）
- **触发/复现**：输入较长关键词（如 20+ 全角字符/中文长句）并搜出结果，手机 360dp 或桌面小窗。
- **用户可见后果**：`RenderFlex overflowed`（debug 黄黑条）/ 右侧“（合并 N 条音源）”被裁；关键词本身也没有截断策略。
- **建议**：第一个 `Text` 包 `Flexible`+`overflow: ellipsis`，或整行改为两行布局（关键词一行、统计一行）。

#### UI-11（中）从队列移除“正在播放”项后，UI 与音频错位

- **位置**：`lib/ui/player/player_page.dart:1038-1042`（移除按钮）、`:1016-1044`（队列行高亮 `active = i == player.currentIndex`）；`lib/services/player_service.dart:351-356`（`removeFromQueue`）
- **触发/复现**：播放页 → “⋯ → 播放队列” → 点当前高亮（正在播放）那一行的 ✕。
- **用户可见后果**：`removeAt(currentIndex)` 后 `_currentIndex` 不变，于是 `currentSong` 变成原队列的下一首——播放页标题/封面/歌词立即切换，但音频仍在放被删除的那首；进度、时长、音源高亮全部错位，直到下一次切歌才自愈。
- **建议**：移除当前项时要么先 `stop` 并 `_playAt` 下一首，要么禁止移除当前项（按钮置灰 + tooltip）；`removeFromQueue` 返回是否影响当前曲，由 UI 给提示。

#### UI-12（中）进出迷你模式会整体销毁 ShellPage，页面状态全部丢失

- **位置**：`lib/app.dart:37`、`:45-47`（`miniMode` 三元切换 `ShellPage` / `MiniPlayerPage`）；页面局部状态：`home_page.dart:24-33`、`search_page.dart:22-28`、`library_page.dart:26-30`、`local_page.dart:18-21`
- **触发/复现**：搜索出结果（或本地页已扫描、音乐库停在下载 tab）→ 播放条点“迷你窗口”按钮（`player_bar.dart:156-166`）→ 迷你窗里点“恢复主界面”（`mini_player_page.dart:126-132`）。
- **用户可见后果**：`home` 的 widget 类型变化导致整个 `ShellPage` 子树被 dispose 重建：搜索结果清空回到“试试搜索”、首页重新进入加载态（叠加 UI-01 就是永久转圈）、本地页重新扫描、音乐库 tab 复位、列表滚动位置丢失。用户感知为“恢复主界面后所有东西都没了”。
- **建议**：不要在 `home` 层替换；改成 `Stack/Offstage` 保留 `ShellPage`，迷你模式时叠加 `MiniPlayerPage`（`IndexedStack` 或 `Visibility` 保状态）；或把搜索词/结果等关键状态提升到 provider。

#### UI-13（中）播放条空态里的“播放/下一首”是死按钮

- **位置**：`lib/ui/player/player_bar.dart:19-84`（空态）、`:68-79`（两个 `GlassIconButton` 的 `onPressed: () {}`，`:72`、`:78`）
- **触发/复现**：未播放任何歌曲时点底栏的播放键/下一首键。
- **用户可见后果**：按钮外观正常（主色高亮）、点击无任何反应，用户以为卡死；与旁边文案“点击导航栏切换曲库开始播放”也矛盾。
- **建议**：`onPressed: null` 置灰（`GlassIconButton` 需要支持禁用态），或点击时提示“先从曲库选择歌曲”。

#### UI-14（中）迷你窗口“未在播放”时没有恢复主界面的入口

- **位置**：`lib/ui/mini_player_page.dart:49-53`（`song == null` 只渲染“未在播放”）、`:126-132`（“恢复主界面”按钮只在有歌的 Row 内）
- **触发/复现**：迷你模式下队列被清空（或状态异常导致 `currentSong==null`），例如在播放页清空队列后再进入/已处于迷你模式。
- **用户可见后果**：420×150 的迷你窗里只剩关闭按钮（收进托盘），没有“恢复主界面”，用户只能托盘右键退出或再想办法播放一首歌；属于局部断头路。
- **建议**：空态也显示“恢复主界面”图标按钮；空态文案加“打开主界面选择歌曲”。

#### UI-15（中）本地页“扫描目录”无法选择目录，只能重扫默认路径

- **位置**：`lib/ui/local_page.dart:55-63`（`_pickDir` 只 `defaultScanPaths().first` 重新扫描）、`:102`（按钮文案“扫描目录”）；`lib/services/local_music.dart:27-57`（默认目录仅 Downloads / `%USERPROFILE%\Music` / 应用目录）；`pubspec.yaml`（无 `file_picker` 等目录选择依赖）
- **触发/复现**：本地音乐 tab → 点“扫描目录”；或把音乐放在 `D:\Music`、移动硬盘等非默认目录。
- **用户可见后果**：按钮不会弹目录选择器，只是把同一个默认目录再扫一遍；非默认目录的音乐永远无法加入本地曲库，“本地音乐”功能对多数用户不可用（Windows 下默认首选还是 Downloads，不是 Music）。
- **建议**：接入 `file_picker` 的 `getDirectoryPath`（或 `file_selector`）选择目录后 `_scan(dir)`；若暂不做，按钮文案改为“重新扫描”并注明当前扫描范围；`_scan` 支持多目录合并。

#### UI-16（中）歌单详情/本地页错误态无重试入口

- **位置**：`lib/ui/playlist_detail_page.dart:152-164`（`:156-163` 仅居中红字，无按钮）、`lib/ui/local_page.dart:110-113`（红字，无重试）
- **触发/复现**：网络异常时从首页打开歌单详情；或本地扫描抛异常（权限/路径失效）。
- **用户可见后果**：错误后页面只剩一行红字；歌单详情没有刷新/重试，用户只能返回上一页再重新点歌单（且详情页是 push 路由，返回后首页数据也在加载）；本地页只能点“扫描目录”重来。
- **建议**：统一错误组件（`_EmptyHint` 风格：图标 + 文案 + `GlassButton('重试', onPressed: _load)`）；`playlist_detail_page.dart` 的 `_load` 已有，直接挂按钮即可。

#### UI-17（中）播放页歌词没有 loading/错误态，空态误导；歌词请求异常未捕获

- **位置**：`lib/ui/player/player_page.dart:47-65`（`:49` 1.2s 定时后才请求、`:59` `getLyrics` 无 try/catch）、`:658-670`（`lyrics.isEmpty` 直接渲染“暂无歌词”）
- **触发/复现**：进入播放页的 1.2 秒内、或歌词接口返回空/抛异常时切到歌词页。
- **用户可见后果**：三态被压成一种：加载期间显示“暂无歌词”（用户以为这首歌没歌词，切回封面）；接口异常时 `:59` 的 `await api.getLyrics` 抛出未捕获异步异常（FlutterError 日志），提示永远停在“暂无歌词”且无重试。服务层 `player_service.dart:255-267` 对歌词异常有 `catchError`，所以大多数异常会静默为空，进一步强化“没歌词”的错觉。
- **建议**：歌词加载区分 loading（骨架/小 spinner）/ empty（“暂无歌词”）/ error（“歌词加载失败，点此重试”）；给 `:59` 包 try/catch 并落到 error 态。

#### UI-18（中）歌词行固定 44 高 + 两行省略号，长歌词被截断；滚动定位依赖固定行高

- **位置**：`lib/ui/player/player_page.dart:640`（`_lineHeight = 44`）、`:725-735`（`SizedBox(height: 44)` + `Text(maxLines: 2, overflow: ellipsis)`，选中行 17px）、`:671-693`（居中滚动公式按 44 固定行高）
- **触发/复现**：歌曲含较长中文歌词行（两行），或系统字体放大。
- **用户可见后果**：17px 选中行两行约 46px > 44px，第二行被裁或出现省略号（歌词出现省略号体验很差）；字体缩放后行高不匹配，`:677-682` 的居中计算偏移，当前行不在视口中央。
- **建议**：`itemBuilder` 行高自适应（`ConstrainedBox(minHeight:44)` + 按行数测量，或 `Text` 不设 maxLines 并让列表自然增高），滚动居中改用 `Scrollable.ensureVisible` / item 实际 offset；歌词不建议 ellipsis。

#### UI-19（中）浅色模式下小字/选中态对比度不足（9.5px、8px、accentPink、主题蓝）

- **位置与估算**（按 sRGB 相对亮度估算，浅色模式，背景取玻璃白叠加后约 `#FBFCFD`）：
  | 元素 | 位置 | 前景/背景 | 估算对比度 | 结论 |
  |---|---|---|---|---|
  | 手机底栏未选中文字 9.5px | `shell_page.dart:418-431` | `textSecondary`(#1A1F29 60%) / 玻璃白 | ≈4.3:1 | 低于 AA 4.5 |
  | 手机底栏选中文字 9.5px | `shell_page.dart:402-430` | `primary`(#5B8DEF) / 16% 主题色底 | ≈2.7:1 | 不合格 |
  | 桌面侧栏选中白字 10px | `shell_page.dart:188-224` | 白 / `primary` 0.6~0.9 渐变 | ≈2.7:1 | 不合格 |
  | 音乐库选中 Tab 12.5px | `library_page.dart:453-478` | `primary` / 16% primary 底 | ≈2.7:1 | 不合格 |
  | VIP 9.5px / 8px 标签 | `search_page.dart:270-284`、`:385-394` | `accentPink`(#F26B8A) / 白玻璃 | ≈2.8:1 | 不合格 |
  | 播放页音源 VIP 8.5px | `player_page.dart:1115-1124` | accentPink / 玻璃白 | ≈2.8:1 | 不合格 |
  | “预览版”11px | `settings_page.dart:208-209` | `Colors.grey`(#9E9E9E) / 玻璃白 | ≈2.6:1 | 不合格 |
  | 播放页“JXMusic”11px | `player_page.dart:123-128` | `Colors.grey` / 深/浅背景 | 浅色 ≈2.6:1 | 不合格 |
- **用户可见后果**：浅色模式下底栏文字、选中项、VIP 标签在手机上偏淡难辨；桌面 9.5px/10px 字号本身已低于可读下限，叠加上低对比度基本“看不清”。
- **建议**：小字下限提到 11px；选中态改用深色文字/加深底色或加 1px 描边；`accentPink` 只用于大字号或加深到 `#C94562` 级别；`Colors.grey` 换成主题派生色；用 WCAG AA（4.5:1，小字）逐项校验，深浅两套都要过。

#### UI-20（中）5 套主题色实际几乎不生效（53 处硬编码主题色）

- **位置**：`lib/theme.dart:5-11`（只把 `seedColor` 传给 `ColorScheme.fromSeed`）；`lib/providers.dart:129-133`（主题色持久化）；`lib/ui/settings_page.dart:69-97`（5 色选择器）。硬编码 `JXColors.primary` 统计（`lib/ui` 下共 53 处）：`player_page.dart` 14、`shell_page.dart` 8、`library_page.dart` 5、`settings_page.dart` 5、`home_page.dart` 4、`player_bar.dart` 4、`search_page.dart` 3、`glass.dart` 2、`local_page.dart` 2、`mini_player_page.dart` 2、`my_playlist_page.dart` 2、`playlist_detail_page.dart` 2。
- **触发/复现**：设置 → 主题色，切换 5 个色块。
- **用户可见后果**：只有 `ColorScheme` 派生的 Material 控件（部分 TextButton、Switch 轨道、文本选择等）变色；图标、进度条、选中态、玻璃高光、播放键渐变、封面占位等主视觉全部保持蓝色，用户感知“选了个颜色但界面没变”；5 套主题仅在设置页色块本身可见。
- **建议**：用 `ThemeExtension<JXBrandColors>` 或统一读 `Theme.of(context).colorScheme.primary`；至少把选中态、主按钮、进度条、玻璃高光改为主题派生；品牌色 `accentCyan/accentPink` 作为扩展色显式定义。

#### UI-21（中）液态玻璃用法不统一：只有壳和 GlassCard 有真模糊，其余页面各写一套

- **位置**：
  - 真玻璃：`glass.dart:40-43`（`ClipRRect+BackdropFilter`）、`shell_page.dart:133-139`、`:379-386`；
  - 无模糊的自绘“仿玻璃”：播放页整页纯渐变 `player_page.dart:90-101`、歌单详情 `playlist_detail_page.dart:75-87`、我的歌单 `my_playlist_page.dart:46-57`、迷你播放 `mini_player_page.dart:34-48`；
  - 标签/输入框类直接普通 `Container`：`search_page.dart:355-366`、`library_page.dart:453-469`、`home_page.dart:376-388`、`shell_page.dart:287-313`；
  - 背景渐变两套：`app.dart:60-69`（`#0B0E16/#121826/#0F1320`）与推入页 `player_page.dart:97-99`、`playlist_detail_page.dart:82-84`、`my_playlist_page.dart:53-55`（`#151B29/#0B0E16`），导航时背景轻微跳色；
  - 重复组件：`layout.dart:41-111` 的 `JXCover` 与 `glass.dart:243-311` 的 `GlassCover` 两份实现，回落渐变不同（多彩色板 vs 品牌蓝青）。
- **触发/复现**：在首页/搜索（玻璃卡片）与播放页/歌单详情（纯渐变）之间来回切换；或对比封面占位图。
- **用户可见后果**：同一 App 的“iOS26 液态玻璃”质感时有时无；页面切换有背景色差；同一类封面占位颜色不一致。视觉一致性打折，也让“玻璃”组件库形同虚设。
- **建议**：统一一个 `GlassSurface`（可配 blur/透明度/描边），详情页/播放页/迷你窗复用；抽出统一背景 token（`JXBackdrop`）；合并 `JXCover`/`GlassCover` 为一个组件 + 统一的 fallback 策略。

#### UI-22（中）卡片/按钮缺少按压与 hover 反馈，桌面端没有可点击光标

- **位置**：`lib/ui/glass.dart:71-77`（`GlassCard.onTap` 用 `InkWell`，但位于 `ClipRRect+BackdropFilter+渐变 Container` 之下的 Material 上，水波纹被不透明玻璃盖住）、`:119-121`/`:200-201`（`GlassButton`/`GlassIconButton` 用 `GestureDetector`）；全 UI 大量 `GestureDetector`（`shell_page.dart` 4 处、`player_page.dart` 4 处、`home_page.dart` 3 处、`search_page.dart` 2 处等），均无 `MouseRegion` 光标、无 hover/按下态。
- **触发/复现**：桌面鼠标悬停到侧栏、封面卡片、音源标签、标题行；点击卡片。
- **用户可见后果**：悬停时鼠标不变手型，用户无法判断哪些区域可点；点击整张歌曲卡/音源标签没有任何视觉反馈，容易重复点击（叠加 UI-30 的 SnackBar 排队）。
- **建议**：统一 `InkWell` + `Material(type: transparency)`/自绘 pressed 态；`MouseRegion(cursor: SystemMouseCursors.click)` 包所有可点区域；列表行加 hover 高亮（桌面）。

### 低

#### UI-23（低）设置页“跨端同步”开关永远打不开

- **位置**：`lib/ui/settings_page.dart:166-177`（`:170` `value: false` 恒定；`:171-176` `onChanged` 只弹 SnackBar“开发中”）
- **复现**：设置 → 拨动“跨端同步”开关。后果：开关回弹，用户以为控件坏了（文案说开发中，但控件装成可用）。建议：`SwitchListTile.onChanged: null` 置灰 + “开发中”徽标，或改成说明行。

#### UI-24（低）桌面端壳顶栏与页内 H1 重复

- **位置**：`shell_page.dart:66-71`（顶栏标题）、`:20`（`_pageTitles`）；`library_page.dart:132-135`（“音乐库”24px）、`local_page.dart:87-91`（“本地音乐”24px）、`settings_page.dart:31-37`（“设置”26px）
- **复现**：桌面切到音乐库/本地/设置。后果：同屏出现两个同级标题（顶栏 22px + 页内 24/26px），层级混乱、浪费垂直空间。建议：桌面端页内 H1 用 `isDesktopLayout` 隐藏，或顶栏改面包屑（“音乐库 / 收藏”）。

#### UI-25（低）首页“更多”是重新加载；榜单空态缺失；自动刷新整页闪空

- **位置**：`home_page.dart:171`（热门单曲 `onMore: _load`）、`:273`（热歌榜 `onMore: _load`）、`:170-196`（桌面榜单空 → 无任何文案）、`:278-280`（手机 `plats.isEmpty` 只给 `SizedBox(height:40)`）；`app.dart` 无关；刷新闪空 `home_page.dart:47-50`、`:131-137`、`:225-231`
- **复现**：点“热门单曲 · 更多›”；平台榜单接口返回空；停留首页 >1 分钟后切回（`:108-115` 触发 `_load`）。
- **后果**：“更多”不展示更多内容而是重载（列表回到第一批）；空榜一片空白；自动刷新时整页内容被 spinner 替换，视觉跳动、滚动位置丢失。建议：更多做分页/跳列表；空态文案+重试；刷新用 `RefreshIndicator`/保留旧数据增量更新。

#### UI-26（低）暂停时封面仍持续旋转

- **位置**：`player_page.dart:33-36`（`AnimationController.repeat()` 无条件）、`:501-504`（`RotationTransition`）
- **复现**：播放中暂停。后果：暂停时封面继续转（30 秒/圈），与“已暂停”状态矛盾。建议：`ref.listen` 播放状态，`playing ? _spin.repeat() : _spin.stop()`。

#### UI-27（低）扫码登录失败无重试入口；登录弹窗固定尺寸不可滚动

- **位置**：`settings_page.dart:423-441`（`_create` 失败只改 `_hint`）、`:373-377`（`barrierDismissible: false`）、`:522-569`（Dialog：`:528` 固定宽 320，`:539-566` 固定 Column，`:561-564` 只有“取消”）
- **复现**：QQ/酷狗取码失败（403/风控）；或窗口高度很矮（分屏/横屏）时打开扫码弹窗。
- **后果**：失败后只能关弹窗再点登录行重来；矮窗口下 QR 200 + 文案 + 按钮的 Column 溢出、取消按钮被裁。建议：失败态显示“重试”（重跑 `_create`）；Dialog 内容套 `SingleChildScrollView`，二维码按可用高度收缩。

#### UI-28（低）单曲播放不建队列，“下一首”变成重播当前歌

- **位置**：`home_page.dart:327-334`（`resolveAndPlay(ref, song)` 不传 queue）、`search_page.dart:77-98`（同上）；`lib/services/player_service.dart:277-287`（队列长度 1 时 `next` 命中循环 `_playAt(0)`）
- **复现**：首页/搜索点一首歌 → 播放条点“下一首”。后果：没有下一首可切，直接从头重播本曲，用户以为切歌失败；队列弹层里也只有 1 首。建议：单曲播放时把所在列表作为队列传入（首页榜单/搜索结果组），或单曲时禁用 next/prev 并提示“单曲播放”。

#### UI-29（低）设置页版本号硬编码，需与 `pubspec.yaml` 双写

- **位置**：`settings_page.dart:205`（`'v0.9.6 · 聚合 ...'`）；`pubspec.yaml:4`（`version: 0.9.6+15`）；`CHANGELOG.md:3-11`、`docs/项目状态.md:7`
- **复现**：下次发版只改 pubspec 时设置页仍显示旧版本。后果：关于页版本可能落后（本次 0.9.5→0.9.6 就需要同时改 UI、pubspec、CHANGELOG、项目状态四处，易漏）；且不含 build 号、release 包仍标“预览版”。建议：接 `package_info_plus` 读运行时版本，或由构建脚本注入；去掉/条件化“预览版”。

#### UI-30（低）SnackBar 不替换，连续操作时提示排队

- **位置**：`search_page.dart:87-97`；`home_page.dart:330-333`；`library_page.dart:104-107`；`player_page.dart:506-510`；`my_playlist_page.dart:249-253`
- **复现**：快速连续点多个不可播放的歌曲/连续点音源。后果：`ScaffoldMessenger` 默认排队，每条 4 秒，提示严重滞后于操作（第 5 条时用户早已忘记点过什么）。建议：统一 `..hideCurrentSnackBar()` 或 `clearSnackBars()` 再 show，播放失败类提示可合并计数。

#### UI-31（低）全局快捷键不过滤按键 repeat

- **位置**：`shortcuts.dart:41`（只判断 `event is! KeyDownEvent`，未看 `event.repeat`）
- **复现**：长按空格/方向键。后果：播放/暂停随键盘连发抖动；音量/seek 连发过快；`N/P` 连续切歌。建议：对 `space/M/N/P` 忽略 `event.repeat`，方向键保留连发但加节流。

#### UI-32（低）播放页音量行左右两个喇叭都执行“切换静音”

- **位置**：`player_page.dart:337-352`（左 `volume_down` 图标 `onTap: player.toggleMute`）、`:372-387`（右 `volume_up` 同样 `toggleMute`）
- **复现**：点左侧喇叭。后果：语义重复且反直觉（“音量-”却触发静音）；建议：左图标仅展示状态/或改成“音量-”，只保留一个静音开关，并在图标上加 tooltip。

#### UI-33（低）迷你窗口封面点击空实现

- **位置**：`mini_player_page.dart:56-63`（`GestureDetector(onTap: () {})`）
- **复现**：迷你窗点封面。后果：无反应。建议：恢复主界面或打开播放页。

#### UI-34（低）下载进度弹窗不可取消、不能关闭

- **位置**：`player_page.dart:461-504`（`:476-481` `showDialog(barrierDismissible: false)` 且无取消按钮；`:490-493` `DownloadService.download` 无 `CancelToken`）
- **复现**：下载一首大文件/网络慢时点下载。后果：用户只能等或强退；无法取消误点的下载。建议：给 Dio `CancelToken` + 弹窗“取消”按钮，取消时删除半成品文件。

#### UI-35（低）搜索框不收起键盘、清除按钮常驻

- **位置**：`search_page.dart:110-151`（`:118` `onSubmitted: _search` 后未 `unfocus`；`:130-147` `suffixIcon` 无论是否有文字都显示）
- **复现**：手机提交搜索；清空输入后再看输入框。后果：键盘挡住结果列表；空输入时“清除”图标点了没反应。建议：提交后 `FocusScope.of(context).unfocus()`；`suffixIcon` 按 `_controller.text.isNotEmpty` 条件显示。

#### UI-36（低）桌面顶栏“搜索框”点击只切 tab，不聚焦输入

- **位置**：`shell_page.dart:287-313`（`GestureDetector` 假搜索框）、`:69`（`onSearch: () => switchTab(1)`）
- **复现**：桌面点顶栏搜索框。后果：跳到搜索页但不聚焦，用户还要再点一次输入框（且首次点击无任何输入反馈）。建议：切 tab 后通过 provider/FocusNode 聚焦搜索框，或把顶栏搜索框做成真实输入。

#### UI-37（低）本地页在 App 启动时即扫描磁盘（IndexedStack 全量构建）

- **位置**：`local_page.dart:24-27`（`initState → _scanDefault`）；`shell_page.dart:34-40`（5 个页面同时构建，`IndexedStack` 会实例化所有子页）；`local_music.dart:60-92`（递归 `listSync` + 逐文件读元数据）
- **复现**：冷启动 App。后果：即使不进本地页也会启动磁盘扫描/读标签，Windows 音乐目录大时增加启动 I/O 与首帧卡顿；Android 可能触发权限弹窗。建议：首次进入本地 tab 时再扫描（`navIndex` 监听或懒加载），或改 `IndexedStack`+懒构建。

#### UI-38（低）`app.dart` 中 `AnimatedBuilder(Listenable.merge(const []))` 是死代码

- **位置**：`app.dart:50-52`
- **后果**：空 listenable 永不通知，包一层 `AnimatedBuilder` 无任何作用，还让背景层多一次 builder 回调。建议：删掉，直接返回 `Container`。

#### UI-39（低）少量颜色写死，绕过深浅主题

- **位置**：`local_page.dart:112-113`（`Colors.redAccent` 错误文字）、`playlist_detail_page.dart:161-162`（同）、`player_page.dart:127`/`settings_page.dart:209`（`Colors.grey`）、`player_page.dart:223/333`（`Colors.grey.withValues` 轨道）、`shell_page.dart:316-339`（头像渐变写死 accentPink+accent）
- **后果**：与主题色/深浅模式不联动；浅色下灰字对比度偏低（见 UI-19）。建议：错误/次要文字色走主题（`colorScheme.error`/`onSurfaceVariant`）。

#### UI-40（低）双端布局只覆盖“壳 + 首页”，其余页面无桌面适配

- **位置**：`layout.dart:8-10`（`isDesktopLayout` 定义）、唯一使用点 `shell_page.dart:32`、`home_page.dart:116`
- **复现**：桌面 1280 宽切到搜索/音乐库/设置/播放页。后果：搜索页单列结果铺满 ~1100px（信息密度低、视线跨度大）；设置页卡片全宽拉伸；播放页/详情页无最大宽度约束。建议：抽 `JXResponsive(maxContentWidth)`，桌面给列表/设置加最大宽度与多列；播放页桌面做左右分栏（封面 + 歌词/队列）。

---

## 三、页面 × 状态矩阵

> ✓＝该状态有明确覆盖/无溢出风险；✗＝缺失或有风险；—＝不适用。行号基于 `d40525a`。

### 3.1 状态覆盖矩阵

| 页面（文件） | 加载态 | 空态 | 错误态 | 小窗口/窄屏溢出 | 备注 |
|---|---|---|---|---|---|
| 壳/导航 `shell_page.dart` | — | — | — | ✓ | 桌面侧栏 92+24 gutter；手机 5 tab 高 60 内 22 图标+9.5 字不溢出；`IndexedStack` 保留页面状态 |
| 首页 `home_page.dart` | ✗ **永久 spinner**（UI-01） | ✗ 热门单曲/热歌榜空→空白（UI-25） | ✓ 错误卡片+重试（`:139-153`/`:233-247`） | ✓ 可滚动 | 手机/桌面两套布局；空歌单行有文案（`playlist_row.dart:39-47`） |
| 搜索 `search_page.dart` | ✓（`:172-180`） | ✓ 未搜索建议（`:402-465`）；全空→错误文案 | ✓ 有失败文案；✗ 无重试按钮 | ✗ 信息行横向溢出（UI-10）；结果行 ✓（Wrap+Flexible） | 取消/清空按钮常驻（UI-35） |
| 音乐库 `library_page.dart` | ✓（仅下载 tab `:273-276`） | ✓ 4 个 tab 均有 `_EmptyHint`（`:202-290`、`:350-357`） | ✓ 下载错误文案（`:277-283`）+ 刷新按钮 | ✓ | 收藏/历史/歌单本地数据无加载态（合理） |
| 本地 `local_page.dart` | ✓（`:107-109`） | ✓“未发现音乐文件”（`:114-118`） | ✓ 红字（`:110-113`）；✗ 无重试（UI-16） | ✓ | 目录选择缺失（UI-15） |
| 我的歌单 `my_playlist_page.dart` | — | ✓（`:163-174`） | ✓“歌单不存在”+返回（`:21-38`） | ✓ | 顶部栏与歌单详情/播放页重复实现 |
| 歌单详情 `playlist_detail_page.dart` | ✓（`:152-155`） | ✗ 0 首时空白（无文案） | ✗ 红字无重试（UI-16） | ✓ | 头部固定 ~188，短屏仍有余量 |
| 设置 `settings_page.dart` | — | — | 扫码弹窗有失败文案；✗ 无重试（UI-27） | ✓ ListView；✗ 扫码 Dialog 固定高（UI-27） | 桌面端页内标题与壳顶栏重复（UI-24） |
| 播放页 `player_page.dart` | ✗ 歌词无 loading；封面无占位（UI-17） | ✗ 清空队列→空白死路（UI-02）；“暂无歌词”误导（UI-17） | ✗ 音源失败仅 SnackBar，无失败态/重试 | ✗ 高度溢出（UI-04）；宽度 320 ✓（0.9.6 已修） | 播放队列弹层无空态文案 |
| 迷你播放 `mini_player_page.dart` | — | ✓“未在播放”（`:49-53`）；✗ 无恢复主界面（UI-14） | — | ✓ 420×150 固定布局（固定 238px + Expanded） | |
| 播放条 `player_bar.dart` | — | ✓ 占位（`:19-84`）；✗ 死按钮（UI-13） | ✗ 解析失败仍显示标题、无错误（服务审计 BUG-02） | ✓ 窄屏 Expanded+ellipsis | 点击任意处打开播放页 |

### 3.2 状态一致性核对

| 场景 | 期望 | 代码事实 | 结论 |
|---|---|---|---|
| 搜索行「首选·XX」高亮 vs 实际播放平台 | 高亮应反映“点整行会播谁”，最好再标“正在播放” | `search_page.dart:288-293` 恒按 `group.primary` 高亮，不随播放/切源变化 | ⚠ 语义成立但无“正在播放”标记（UI-08） |
| 播放页切音源后的队列/当前曲/高亮 | 队列长度不变、当前项替换、高亮跟随 | `playback.dart:114-128` + `player_service.dart:187-196`：新音源 **append**，队列变长 | ✗ UI-06 |
| 清空队列后的当前曲/播放状态 | 停止播放 + 可继续操作 | `player_service.dart:358-363` 不停音频；`player_page.dart:82-84` 空白 | ✗ UI-02 |
| 退出迷你后的页面状态 | 搜索/本地/库状态保留 | `app.dart:45-47` 切换 home widget → ShellPage 重建 | ✗ UI-12 |
| 收藏/历史/歌单（单一 `LibraryStore`） | 各页读写一致 | 全部 `ref.watch(libraryProvider)`，Hive 单写入口 | ✓ |
| 深浅模式 / 主题色持久化 | 重启保持 | `providers.dart:123-133,136-139` + `settings_page.dart:50-53,77-80` | ✓ 持久化；✗ 主题色视觉不生效（UI-20） |
| 音量/倍速/循环持久化 | 重启保持 | `providers.dart:110-113` + `player_service.dart:304-340` | ✓（静音状态不持久，可接受） |
| tab 切换 / 返回路径 | 各 tab 状态保留、详情页可返回 | `IndexedStack`（`shell_page.dart:75/87`）+ 推入页均有返回按钮 | ✓（唯一死路 UI-02） |

---

## 四、视觉一致性清单

### 4.1 主题与色板

| 检查项 | 现状 | 问题 |
|---|---|---|
| 主题构建 | `theme.dart:5-11` 只把 seed 传给 `ColorScheme.fromSeed`；`textTheme/iconTheme/appBarTheme/sliderTheme` | 主视觉不受主题色控制（UI-20） |
| 品牌色 | `constants.dart:6-9`：primary `#5B8DEF`、accent `#7C6FF0`、cyan `#4FD8F5`、pink `#F26B8A` | 固定色，无深浅两套明度；accentPink 用于小字对比度不足（UI-19） |
| 5 套主题色 | `settings_page.dart:69-75` 提供蓝/红/绿/粉/紫 | 只有 Material 派生控件变色；`lib/ui` 53 处硬编码 `JXColors.primary` |
| 平台色 | `constants.dart:50-63` QQ 绿/网易云红/酷狗蓝/本地青 | 与主题色体系独立，标签用色合理；但浅色下 9.5px 平台色文字对比度不足 |
| 错误/次要色 | `Colors.redAccent`、`Colors.grey` 写死（UI-39） | 不随主题/深浅联动 |

### 4.2 字号阶梯（实际使用）

| 用途 | 字号 | 位置举例 | 评价 |
|---|---|---|---|
| 页面 H1 | 22~26 | `shell_page.dart:274`、`library_page.dart:133`、`settings_page.dart:35` | ✓ |
| 歌曲标题 | 13~14（`layout.dart:303`、`search_page.dart:265`） | ✓ |
| 标题（播放页） | 22（`player_page.dart:548`） | ✓ |
| 正文/辅助 | 11~13 | 大量 | ✓ 但 11px 偏小 |
| 标签/角标 | 9.5~10 | `shell_page.dart:421`（9.5）、`search_page.dart:380`（9.5）、`search_page.dart:390`（8）、`player_page.dart:1120`（8.5）、`playlist_row.dart:88`（9.5）、`layout.dart:327`（10） | ✗ 小于 11px，桌面几乎不可读；建议 11px 下限 |

### 4.3 玻璃/容器使用清单

| 页面 | 玻璃实现 | 一致性 |
|---|---|---|
| 壳（侧栏/底栏） | `BackdropFilter` + 描边（`shell_page.dart:133-139,379-386`） | ✓ 标准 |
| 首页/搜索/设置/排名卡 | `GlassCard`（`glass.dart:10-94`） | ✓ 标准 |
| 播放页 | 纯线性渐变（`player_page.dart:90-101`），按钮用 `GlassIconButton` | ✗ 无模糊 |
| 歌单详情/我的歌单 | 纯线性渐变 + 自绘顶部栏（`playlist_detail_page.dart:75-87`、`my_playlist_page.dart:46-57`） | ✗ 无模糊、背景色与壳不一致 |
| 迷你播放 | 纯渐变（`mini_player_page.dart:34-48`） | ✗ |
| 本地页 | `ListTile` + `Divider`（`local_page.dart:119-158`） | ✗ 与玻璃卡片风格脱节 |
| 音乐库/搜索标签、桌面搜索框 | 普通 `Container` 半透明（`library_page.dart:453-469`、`search_page.dart:344-353`、`shell_page.dart:287-313`） | ✗ 无描边高光 |
| 封面组件 | `JXCover`（`layout.dart:41-111`）与 `GlassCover`（`glass.dart:243-311`）两份 | ✗ 重复、fallback 不同 |
| 背景 | `app.dart:60-69` vs 推入页 `#151B29/#0B0E16` | ✗ 导航跳色 |

### 4.4 交互反馈

- `InkWell` 仅在 `GlassCard.onTap`（`glass.dart:72-76`）使用，且水波纹被玻璃层遮住 → 无可见点击反馈（UI-22）。
- 全 UI 以 `GestureDetector` 为主（无 hover/无光标/无禁用态）；`GlassIconButton` 没有 `onPressed == null` 的禁用视觉（`glass.dart:183-239`）。
- 选中态仅靠颜色/透明度表达（侧栏渐变、TabChip 底色、音源 chip 22% 底色），浅色下对比不足（UI-19）。
- 弹层统一为 `showModalBottomSheet` + `GlassCard`（`player_page.dart:410-413,753-800`），风格基本一致 ✓。

### 4.5 重复实现（维护性/一致性）

- 顶部“返回 + 标题 + ⋯”三处重复：`my_playlist_page.dart:61-108`、`playlist_detail_page.dart:91-108`、`player_page.dart:106-140`。
- 封面组件两份（见 4.3）；平台短名映射两份：`playlist_row.dart:20-31` 与 `search_page.dart:337-348`。
- 搜索结果行/歌曲行两套样式：`layout.dart:241-342`（SongRow）与 `search_page.dart:218-323`（_TrackGroupRow）。

---

## 五、最近改动评审结论

### 5.1 基线与 diff 事实

- 任务下发时 HEAD 为 `f32dac6`（0.9.5+14），期间并行会话提交 `d40525a`（0.9.6+15）。本轮审计**以 `d40525a` 为准**。
- `git diff --stat f32dac6..d40525a`：`CHANGELOG.md`(+7)、`docs/项目状态.md`(2 改 1)、`lib/ui/player/player_page.dart`(245 行改动)、`lib/ui/search_page.dart`(57 行改动)、`lib/ui/settings_page.dart`(2 行)、`pubspec.yaml`(2 行)。
- 当前 `git status`：工作区干净；本报告新增 `docs/审计/UI审计.md`（未跟踪）。**无其他未提交 UI 代码改动**——任务原要求的 `git diff -- lib/ui/search_page.dart lib/ui/settings_page.dart` 在当前 HEAD 下为空（相关改动已分别进入 `f32dac6` 与 `d40525a`），故按 HEAD 代码评审，结论见下。

### 5.2 逐项结论

1. **`player_page.dart` 控制按钮行重排（0.9.6）**：✓ 方向正确，窄宽度已修复。数学复核：控制行 = `SizedBox(width:84)` + 4×`Expanded`，左右 padding 24×2；在 360dp 下每格 `(360-48-84)/4=57`、320dp 下 `(320-48-84)/4=47`，均 ≥ `GlassIconButton` 最大 46，`Center` 内不再溢出（旧版固定 24 间距 + 48/40 按钮在 <392dp 时会溢出）。**但高度方向未改**：固定区仍约 182（进度 28 + 8 + 主键 72 + 14 + 音量 32 + padding 28），`_AlbumArtView` 仍固定 300+40+文字+Chip，960×640 最小窗口下溢出问题仍在 → 见 **UI-04**（建议补 320×640/960×640 两档布局测试）。
2. **`player_page.dart` 音量行对齐（0.9.6）**：✓ 图标 `SizedBox(width:24)`、倍速按钮 `height:28 + alignment.center`、滑块 `SliderTheme` 统一尺寸，垂直对齐成立；Row 被 `SizedBox(height:32)` 约束后滑块实际高度 32（无约束时约 28），无溢出。⚠ 但左右两个喇叭都执行 `toggleMute` 的语义问题未改（UI-32）。
3. **`search_page.dart` 搜索框 46 高/垂直居中（0.9.6）**：✓ `isDense + contentPadding: 0 + textAlignVertical.center + 34×34 图标约束` 能让文字与图标同中线；`GlassCard` 只有水平 padding，故整体高度即 46。⚠ 触摸热区 46 < 48 推荐值；系统字体放大 >1.3 时可能偏紧，建议 48。
4. **`settings_page.dart` 版本号 v0.9.5→v0.9.6**：✓ 与 `pubspec.yaml:4` 的 0.9.6 一致；⚠ 仍是硬编码双写、不含 build 号、release 仍标“预览版”（UI-29）。
5. **`CHANGELOG.md` 0.9.6 表述**：“窄屏不再因固定间距溢出”——**只对宽度成立**，播放页高度溢出未修（UI-04）；建议改措辞或补修后保留。
6. **原任务点名的 search_page 未提交改动（已提交为 `f32dac6`）评审**：
   - `_play(group, {preferred})`（`search_page.dart:77-98`）：`playTrackGroup(preferred:)` 在首选失败后仍会尝试同曲目所有音源，与「点标签直接播放该平台」的措辞有落差；已存在的 `playSingleSource`（`playback.dart:100-111`）0 调用，建议标签点击改用它 → **UI-09**。
   - SnackBar 条件（`:81-91`）：`actual != target && platform != target.platform` 判定“已改用 XX 音源”逻辑成立（同平台音源在 `buildTrackGroups` 去重，`track_group.dart:83-87`），无假阳性；但提示不替换、连续点击会排队 → **UI-30**。
   - 「首选·XX」标签点击区（`:297-308,325-400`）：`GestureDetector` + 9.5px + padding 6/2，命中区约 17px 高、无按压反馈、点当前音源会重播 → **UI-08**。
   - `Wrap` 换行（`:297-308`）：✓ 本身无溢出风险（5px 间距 + 自动换行，窄屏会把多平台标签折行），问题在点击区而非换行。
   - `settings_page.dart` 版本号：见第 4 条。

### 5.3 与其他审计的交叉

- 架构审计已提“切源/搜索点歌 append 队列”（P1-1），本报告从 UI 可感知面补充了队列重复、进度回退与无 loading（UI-06）。
- 服务层审计已提“播放失败静默/无错误态”（BUG-02），本报告对应 UI 面为播放条/播放页无失败提示（UI-16、UI-17 与 3.1 矩阵）。
- **UI-01（首页死锁）与 UI-03（快捷键输入冲突）目前未见于其他报告，建议优先修复并回归测试。**

---

## 六、审计覆盖（页面文件清单）

### 6.1 逐文件全量阅读（21 个 UI 核心文件，约 5.9k 行）

| 文件 | 行数 | 状态 |
|---|---:|---|
| `lib/ui/shell_page.dart` | 451 | ✅ 全读 |
| `lib/ui/home_page.dart` | 515 | ✅ 全读 |
| `lib/ui/search_page.dart` | 465 | ✅ 全读（`d40525a`） |
| `lib/ui/library_page.dart` | 542 | ✅ 全读 |
| `lib/ui/local_page.dart` | 163 | ✅ 全读 |
| `lib/ui/my_playlist_page.dart` | 266 | ✅ 全读 |
| `lib/ui/playlist_detail_page.dart` | 244 | ✅ 全读 |
| `lib/ui/settings_page.dart` | 570 | ✅ 全读 |
| `lib/ui/mini_player_page.dart` | 144 | ✅ 全读 |
| `lib/ui/player/player_page.dart` | 1130 | ✅ 分 3 段全读（`d40525a`） |
| `lib/ui/player/player_bar.dart` | 187 | ✅ 全读 |
| `lib/ui/playlist_row.dart` | 111 | ✅ 全读 |
| `lib/ui/glass.dart` | 311 | ✅ 全读 |
| `lib/ui/layout.dart` | 342 | ✅ 全读 |
| `lib/ui/cover.dart` | 61 | ✅ 全读 |
| `lib/ui/dialogs.dart` | 66 | ✅ 全读 |
| `lib/ui/shortcuts.dart` | 88 | ✅ 全读 |
| `lib/main.dart` | 49 | ✅ 全读 |
| `lib/app.dart` | 79 | ✅ 全读 |
| `lib/theme.dart` | 61 | ✅ 全读 |
| `lib/core/constants.dart` | 77 | ✅ 全读 |

### 6.2 交叉核对文件（11 个，约 1.8k 行）

`lib/providers.dart`(171)、`lib/services/playback.dart`(186)、`lib/services/player_service.dart`(375)、`lib/services/library_store.dart`(280)、`lib/services/local_music.dart`(177)、`lib/services/download_service.dart`(172)、`lib/services/tray_service.dart`(152)、`lib/services/mini_mode.dart`(61)、`lib/models/track_group.dart`(102)、`lib/models/song.dart`(96)、`lib/models/lyric.dart`(37)

### 6.3 覆盖范围说明

- 页面/组件：壳导航、首页、搜索、音乐库（收藏/历史/歌单/下载 4 tab）、本地、我的歌单、歌单详情、设置、播放页、播放条、迷你播放、玻璃组件库、响应式工具、封面、弹窗、快捷键——覆盖任务清单全部条目。
- 验证命令：仅只读 `git status/log/show/diff`、`Select-String`/行号核对、Flutter SDK 源码核对（`editable_text.dart`、`focus_scope.dart`、`slider.dart`）；**未运行任何 `flutter` 命令**。
- 未覆盖：真机/桌面实际点击、性能实测、无障碍（Semantics）专项、Android 真机布局；相关结论已在条目中标“待实测/静态推演”。
