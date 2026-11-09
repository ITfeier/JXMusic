# 第三方组件与许可声明（JXMusic）

本项目的本地音乐加密格式解密能力参考/使用了以下开源实现。所有实现均以 MIT 等宽松许可分发，
未包含任何音乐平台私有代码、账号凭据、设备指纹或用户数据。

## 1. music_decoder（vendored，MIT）

- 位置：`packages/music_decoder/`（以 path 依赖方式接入，未修改源码）
- 版本：0.1.0（vendored 自 https://github.com/djbird2046/music_decoder）
- 用途：网易云 `.ncm`、QQ 音乐 QMC v1/v2（`.qmc0/.qmc3/.qmcflac/.qmcogg/.mflac/.mgg` 等）解密
- 许可：MIT，Copyright (c) 2025 djbird2046（全文见 `packages/music_decoder/LICENSE` 与应用附录）

## 2. 酷狗 KGM/KGMA/VPR 公钥表 `assets/kugou_key.bin`

- 用途：酷狗 KGM 格式解密所需的公开公钥表（每 1 字节覆盖 16 字节音频）。
  随包的是**截断版前 8 MiB（8,388,608 字节）**，覆盖 134,217,728 字节（128 MiB）音频。
- 直接来源：`dsh-audio-converter`（MIT，Copyright (c) 2026 yousj666，
  https://github.com/yousj666/dsh-audio-converter）的
  `lib/crypto/assets/kugou_key.bin`，本项目按字节复制，未修改。
  该文件 SHA-256 = `FE2AE000E3EBCFD0602A1DC87DEC65EEAE1BAA3FAE7A32D34E38C6D0600F72A4`。
- 上游来源：由 `HRuiCcc/music-geshizhuanhuan`（MIT）的 `assets/kugou_key.xz`
  解压后截取前 8 MiB 得到；完整表解压 69.77 MB（覆盖约 1.1 GB 音频）。
- 性质：公开技术常量表，不含账号、设备、用户信息；多个开源解密项目包含同一份数据。
- 若认为该数据不应分发：删除 `assets/kugou_key.bin` 后程序其余功能正常，`.kgm` 会明确报
  「酷狗公钥表缺失」而不是静默失败。

## 3. KGM/VPR 解密算法参考

- 参考：`dsh-audio-converter`（MIT，Copyright (c) 2026 yousj666）
  `lib/crypto/kgm.js` 的算法说明与公开常量。
- 本项目 Dart 实现为**按上述 MIT 参考实现的算法移植**（公式、索引规则、MEND_TABLE、
  KGM/VPR magic 均与该 MIT 项目一致），代码由本项目编写；移植等价性经跨语言黄金向量复算
  （见 `docs/projects/本地音乐与加密格式/评审记录.md` §三）。
- QMC v1 静态密钥常量来自 unlock-music 项目公开资料（仅算法事实）。

## 4. 免责声明

本功能仅用于播放用户**自己合法拥有**的本地音乐文件；解密结果只写入本机应用缓存，
不提供下载、导出或再分发能力。请遵守各音乐平台的服务条款与当地版权法律。

---

## 附录：MIT 许可全文（dsh-audio-converter，Copyright (c) 2026 yousj666）

```
MIT License

Copyright (c) 2026 yousj666

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 附录：MIT 许可全文（music_decoder，Copyright (c) 2025 djbird2046）

```
MIT License

Copyright (c) 2025 djbird2046

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
