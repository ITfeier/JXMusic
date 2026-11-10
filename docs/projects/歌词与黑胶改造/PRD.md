# PRD · 歌词展示修复 + 播放页黑胶圆盘（0.10.1+20）

- 版本：v1.0（2026-11-10，监国起草）
- 上游：`立项单.md`
- 原则：每条需求都可验收（单测 / widget 测试 / 真实接口探测 / 真实运行截图）

## 0. 根因结论（已实证，2026-11-10）

用与 App **完全一致**的请求头（UA + 全局 `Referer: https://music.163.com/`）实测：

| 平台 | 请求 | 结果 |
|---|---|---|
| QQ | `c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=0039MnYb0qxYhV&format=json&nobase64=1` | **`{"retcode":-1310}`，歌词为空** |
| QQ | 同上 + `Referer: https://y.qq.com/` | `retcode:0` + 完整 LRC |
| 网易云 | `music.163.com/api/song/lyric?id=186016&lv=-1&kv=-1&tv=-1` | `code:200` + 完整 LRC |
| 酷狗 | `krcs.kugou.com/search` → `lyrics.kugou.com/download` | `status:200` + base64 LRC |

→ **主因：`qq_api.dart` 的 `getLyrics` 未带平台 Referer，QQ 歌词 100% 为空**；
首页/榜单默认都是 QQ 曲库，所以用户看到的就是「歌词永远展示不出来」。
次因：歌词只有空/有两态、无加载/失败提示（审计 UI-17），且 `player_page` 还有一条
1.2s 延迟直连歌词请求（与服务层重复，审计 BUG-07）。

## 1. 需求一：歌词可展示（数据层）

### R1.1 QQ 歌词请求带平台 Referer（P0）
- `QQMusicApi.getLyrics` 请求必须带 `Referer: https://y.qq.com/`（与 `getPlayUrl`/搜索同口径）。
- 若响应 `lyric` 字段是 base64（`nobase64=1` 被服务端忽略时），自动 base64 解码为 UTF-8 LRC。
- 若 `retcode != 0` 或 `lyric` 为空 → 返回空串并 `debugPrint` 一次原因（不抛出）。
- 验收：单测用 Dio 假适配器断言请求头含 `https://y.qq.com/`；夹具含 LRC 时能解析；base64 夹具能解码。

### R1.2 网易云 / 酷狗歌词链路保持并加固（P1）
- 网易云：公开 GET 主路径不变；已登录时附加 `MUSIC_U` Cookie（只发 163.com 域）。
- 酷狗：`krcs`/`lyrics` 请求补 `Referer: https://m.kugou.com/`（无 Referer 依赖，属加固）。
- 验收：既有单测（`check_api_test` 等）不回归；真实接口探测脚本三平台均返回非空歌词。

### R1.3 歌词状态机 + 与音频解耦（P0）
`PlayerService` 新增（**T2 依赖的接口契约，签名不得改**）：

```dart
enum LyricsStatus { idle, loading, ready, empty, error }

class PlayerService extends ChangeNotifier {
  LyricsStatus get lyricsStatus;   // 初始 idle
  List<LyricLine> get lyrics;      // 保持既有
  void retryLyrics();              // 重新请求当前曲目歌词；无曲目/加载中时安全 no-op
}
```

语义：
- 切歌（`_playAt`）时：清空歌词 → `loading` → **立即**异步请求（不依赖 `_player.open` 成功；无直链也要能出歌词）。
- 成功且解析出歌词行 → `ready`；成功但为空 → `empty`；异常/超时 → `error`。
- 同一首歌重复 `playSong`（如切音源）不重复请求；`retryLyrics()` 强制重试。
- 切歌后旧请求返回必须丢弃（沿用 `globalId` 守卫）。
- `dispose()` 后异步返回不得 `notifyListeners`（避免 debug 断言）。
- `setLyrics()` 保留，同步置 `ready`/`empty`（兼容既有调用与测试）。
- 验收：`test/player_lyrics_state_test.dart` 覆盖 loading→ready / empty / error / retry / 过期响应 / 同曲不重复请求 / dispose 安全。

### R1.4 LRC 解析修正（P1）
- 小数位换算：1 位 ×100、2 位 ×10、3 位 ×1（现 1 位按 ×1，实际慢 0.4s）。
- 过滤标签行/纯空白行（`[02:21.989]` 无文本不生成歌词行）。
- 支持 CRLF；保留一行多时间标签。
- 支持 `[offset:±ms]` 整体偏移。
- 验收：`test/lyric_parser_test.dart` 逐项断言。

### R1.5 去掉重复歌词请求（P1）
- 删除 `player_page.dart` 的 1.2s 延迟直连 `getLyrics` 路径，统一由 `PlayerService` 负责。
- 验收：`player_page.dart` 不再引用 `getLyrics`/`LyricParser`。

## 2. 需求二：播放页歌词三态 UI

- `_LyricsView` 按 `lyricsStatus` 渲染：
  - `loading`：居中 `CircularProgressIndicator`（`Key('lyricsLoading')`）+「歌词加载中…」
  - `empty`：既有图标 +「暂无歌词」（`Key('lyricsEmpty')`）
  - `error`：图标 +「歌词加载失败」+ 重试按钮（`Key('lyricsRetryButton')`，点击调 `player.retryLyrics()`）
  - `ready`：既有滚动列表 + 当前行高亮居中（保持现有行为）
- 切换按钮的图标/高亮逻辑不变；歌词加载中不得显示「暂无歌词」。
- 验收：widget 测试注入可控 `lyricsResolver`（Completer / 抛错 / 空 / 正常）断言三态与重试。

## 3. 需求三：播放页黑胶圆盘（视觉）

### R3.1 外观
- 播放页大封面由「方形圆角图」改为**圆形黑胶唱片**（新组件 `lib/ui/player/vinyl_disc.dart`）：

```dart
class JXVinylDisc extends StatelessWidget {
  const JXVinylDisc({
    super.key,
    required this.coverUrl,
    required this.size,
    this.spinning = false,
  });
}
```

- 视觉要素（自外向内）：
  1. 圆形盘体：近黑径向渐变（#0A0A0D → #26262E → #0D0D12），1px 外缘高光；
  2. 沟槽：`CustomPaint` 画 12~16 圈同心细环（白色 4%~10% alpha）+ 135° 反光弧；
  3. 中心标签：**圆形裁剪的专辑封面**，直径 ≈ 0.52×size，外圈 1px 浅色描边；
  4. 轴孔：直径 ≈ 0.05×size 的深色圆孔（`Key('vinylHole')`）；
  5. 盘体下方保留柔和投影/光晕（原 `_GlowCover` 的观感）。
- 封面加载失败/为空：中心标签用「深色渐变 + 音符图标」兜底，盘体仍完整。
- Key：根 `Key('playerVinylDisc')`、沟槽 `Key('vinylGrooves')`、标签 `Key('vinylLabel')`。

### R3.2 旋转
- 播放中匀速旋转（30s/圈）；暂停时**停在当前角度**，恢复播放继续转。
- 切歌不重置角度（保持连续，避免跳帧）。
- 验收：widget 测试 —— spinning 时连续两帧 `Transform` 不同；不 spinning 时相同。

### R3.3 布局不变
- 尺寸继续走 `jxPlayerCoverSize`（360x640dp 不溢出、≥140 下限、极端字体可缩小）。
- 列表/搜索结果/播放条迷你封面**保持方形圆角**（不在本次范围）。
- 验收：更新 `test/player_page_layout_test.dart` 的封面断言为 `JXVinylDisc`；360x640dp 两个用例仍不溢出。

## 4. 质量门禁（QA 必跑）

```powershell
cd D:\Project\yinyue\JXMusic
flutter analyze --no-pub lib test     # 期望 No issues found
flutter test --no-pub                 # 期望全绿（基线 221 passed / 4 skipped + 新增用例）
flutter build windows --release       # 期望 Successfully built
```
（本会话沙箱下 flutter 需以 danger-full-access 运行，见 `环境说明.md`）

## 5. 交付物

1. 代码：上述改动 + 新增测试。
2. 文档：`立项单.md`、`PRD.md`（本文件）、`环境说明.md`、`测试报告.md`（QA）、项目状态/CHANGELOG 更新。
3. 证据：接口探测输出、门禁输出、Windows 运行截图（能完成则附）。
