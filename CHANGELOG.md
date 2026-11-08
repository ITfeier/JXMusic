# CHANGELOG

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
