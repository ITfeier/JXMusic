# 修复前基线复现记录（0.9.8+17）

- 执行人：清（QA，独立验收方）
- 执行时间：2026-11-09 08:53–08:57（Asia/Shanghai）
- 设备：emulator-5554（1080x1920 @480dpi = 360x640dp）
- 被测包：已安装的修复前 APK `com.jxmusic.jxmusic` versionName=0.9.8 / versionCode=17（lastUpdateTime 2026-11-09 08:42:05）
- 结论：**三处缺陷全部复现成功**

## 操作前置

1. 首次抓屏时应用停在设置页 + 「网易云音乐扫码登录」弹窗（`code=8821` 失败态）。
2. 尝试 `input tap 取消` 无效，改用 `adb shell input keyevent KEYCODE_BACK` 关闭弹窗（成功）。
3. `adb shell input tap 139 1800` 切到「首页」标签。

截图获取方式（全程）：`adb shell screencap -p /sdcard/<n>.png && adb pull /sdcard/<n>.png <本地路径>`（未用重定向，避免 PNG 损坏）。
坐标读取方式：`adb shell uiautomator dump /sdcard/ui.xml && adb pull /sdcard/ui.xml`。注意：本包 Flutter 未开 accessibility semantics，dump 中无文本节点，实际坐标靠截图按 1080/961 ≈ 1.124 比例换算。

## D3（立项单 D3）热歌榜「更多」不能展开 —— 复现成功

路径：首页 → 上滑 2 次到「热歌榜」区域 → 点该区域右侧「更多 ›」（real 980,720）。

- 点前：热歌榜两张卡片（QQ音乐 / 网易云音乐）各只显示 3 首歌，右侧为「更多 ›」 → `screenshots/baseline-a1-hotlist-before-more.png`
- 点后：页面**整体回到顶部并重新加载**，没有内联展开，也没有「收起」按钮 → `screenshots/baseline-a2-hotlist-after-more-jumps-top.png`
- 再上滑 2 次回到热歌榜：仍各 3 首，未展开 → `screenshots/baseline-a3-hotlist-after-more-still-3rows.png`

结论：与 D3 描述一致（点「更多」= 重新加载首页，不展开）。

## D1（立项单 D1）QQ 歌单详情「0 首」、列表空白 —— 复现成功

路径：首页 → QQ音乐·推荐歌单 第 1 张卡片「甜度爆表 | 旋律说唱狙击少女心」（real 196,450）→ 歌单详情。

- 详情页头部：「我想要两颗西柚 · **0 首**」；歌曲列表区域完全空白，无空态文案、无重试 → `screenshots/baseline-b1-qq-playlist-detail-0songs.png`
- 同页有「播放全部」按钮（点击无歌曲可播）。

结论：与 D1 描述一致。根因待修复后用同一歌单复核（期望 66 首）。

## D2（立项单 D2）歌单详情页播放后无迷你播放条 —— 复现成功

路径：首页 → 上滑到「酷狗音乐·推荐歌单」→ 点该区域「更多 ›」（real 980,1004）→ 全部歌单页（已加载 30 个）→ 点第 1 张「2026店铺播放最佳，气氛拿捏了！」（real 320,560）→ 详情页点「播放全部」（real 610,580）。

- 播放全部后：详情页底部**没有任何迷你播放条**（页面直接到底部歌曲行） → `screenshots/baseline-c1-kugou-playlist-playall-no-minibar.png`
- 播放是否真的开始：点后 logcat 出现 `PlayerBase::PlayerBase()` / `AF::TrackHandle: OpPlayAudio ... not muted` → 证据 `screenshots/baseline-logcat-playback.txt`
- 按 BACK 退回首页后：Shell 全局迷你播放条出现且显示正在播放（「令狐襄儿、龟娘、樱九…」，暂停键 + 进度条） → `screenshots/baseline-c2-shell-mini-bar-playing-evidence.png`

结论：与 D2 描述一致：播放已开始，但歌单详情页没有 PlayerBar，返回 Shell 才有。

## 截图清单

| 文件 | 内容 |
|:--|:--|
| `screenshots/baseline-a1-hotlist-before-more.png` | 热歌榜展开前：每卡 3 首 + 「更多 ›」 |
| `screenshots/baseline-a2-hotlist-after-more-jumps-top.png` | 点更多后：回到首页顶部（重载） |
| `screenshots/baseline-a3-hotlist-after-more-still-3rows.png` | 回滑到热歌榜：仍 3 首未展开 |
| `screenshots/baseline-b1-qq-playlist-detail-0songs.png` | QQ「甜度爆表」详情：0 首、列表空白 |
| `screenshots/baseline-c1-kugou-playlist-playall-no-minibar.png` | 酷狗歌单点「播放全部」后：底部无迷你条 |
| `screenshots/baseline-c2-shell-mini-bar-playing-evidence.png` | 返回首页后 Shell 条显示正在播放（反证播放已开始） |
| `screenshots/baseline-logcat-playback.txt` | 播放引擎启动日志摘录 |
