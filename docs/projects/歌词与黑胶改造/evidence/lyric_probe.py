# -*- coding: utf-8 -*-
"""T3 QA 独立接口探测脚本（2026-11-10，清·QA）

目的：用与 App 完全一致的请求头（UA + JXHttp 全局 Referer https://music.163.com/）
复现并验证「QQ 歌词接口缺平台 Referer → retcode=-1310 空歌词」的根因，以及修复口径：
QQ 带 `Referer: https://y.qq.com/` 后 retcode=0 且 LRC 非空；网易云/酷狗完整链路歌词非空。

用法：
  python lyric_probe.py [输出文件路径]

说明：shell 中 curl/.NET TLS 被沙箱拦截，Python 自带 OpenSSL 可联网（见 环境说明.md）。
"""
import base64
import json
import re
import sys
import time
import urllib.parse
import urllib.request

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")
GLOBAL_REFERER = "https://music.163.com/"   # 与 lib/services/api/http.dart 一致
QQ_REFERER = "https://y.qq.com/"
KG_REFERER = "https://m.kugou.com/"         # T1 加固口径

checks = []   # (name, passed, detail)


def check(name, passed, detail=""):
    checks.append((name, bool(passed), detail))
    print("[%s] %s%s" % ("PASS" if passed else "FAIL", name,
                         ("  | " + detail) if detail else ""))


def get(url, params=None, referer=GLOBAL_REFERER, timeout=25):
    if params:
        url = url + "?" + urllib.parse.urlencode(params)
    headers = {"User-Agent": UA, "Referer": referer}
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, raw.decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001 - 探测脚本需要记录任何异常
        return None, "EXC: %r" % (e,)


def body_head(body, n=180):
    return (body or "").strip().replace("\n", "\\n")[:n]


def parse_json(body):
    try:
        return json.loads(body)
    except Exception:
        return None


def looks_like_b64(s):
    return bool(s) and "[" not in s and len(s) > 32 and re.fullmatch(r"[A-Za-z0-9+/=\s]+", s or "")


def norm_lrc(lyric):
    """兼容服务端忽略 nobase64=1 时返回 base64 的情况。"""
    if not lyric:
        return ""
    if looks_like_b64(lyric):
        try:
            return base64.b64decode(lyric).decode("utf-8", "replace")
        except Exception:
            return lyric
    return lyric


print("=" * 72)
print("T3 QA 接口探测  %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
print("UA: %s" % UA)
print("JXHttp 全局 Referer: %s" % GLOBAL_REFERER)
print("=" * 72)

# ---------------------------------------------------------------- QQ
print("\n--- QQ 搜索（全局 Referer，与 App 搜索一致）---")
qq_search_url = "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
st, body = get(qq_search_url, {
    "p": 1, "n": 3, "w": "晴天", "format": "json",
    "inCharset": "utf-8", "outCharset": "utf-8",
})
j = parse_json(body)
qqmid = None
try:
    item = j["data"]["song"]["list"][0]
    qqmid = item["songmid"]
    print("search status=%s songmid=%s name=%s" % (st, qqmid, item.get("songname")))
except Exception as e:  # noqa: BLE001
    print("search parse fail: %r head=%s" % (e, body_head(body)))
check("QQ 搜索链路可用（取到 songmid）", bool(qqmid), "songmid=%s" % qqmid)

lyric_url = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg"
if qqmid:
    # 1) 复现 App 现状：不覆盖 Referer → 使用全局 music.163.com
    print("\n--- QQ 歌词：不覆盖 Referer（App 修复前现状，Referer=music.163.com）---")
    st, body = get(lyric_url, {"songmid": qqmid, "format": "json", "nobase64": 1})
    j = parse_json(body)
    retcode = (j or {}).get("retcode")
    lyric = norm_lrc((j or {}).get("lyric") or "")
    print("status=%s retcode=%s lyric_len=%s head=%s"
          % (st, retcode, len(lyric), body_head(body)))
    check("QQ 无平台 Referer → retcode=-1310 且 lyrics 为空（根因复现）",
          retcode == -1310 and not lyric,
          "retcode=%s lyric_len=%s" % (retcode, len(lyric)))

    # 2) 修复口径：带 Referer https://y.qq.com/
    print("\n--- QQ 歌词：带 Referer https://y.qq.com/（修复口径）---")
    st, body = get(lyric_url, {"songmid": qqmid, "format": "json", "nobase64": 1},
                   referer=QQ_REFERER)
    j = parse_json(body)
    retcode = (j or {}).get("retcode")
    lyric = norm_lrc((j or {}).get("lyric") or "")
    print("status=%s retcode=%s lyric_len=%s head=%s"
          % (st, retcode, len(lyric), body_head(body)))
    print("LRC head: %s" % lyric[:120].replace("\n", "\\n"))
    check("QQ 带 Referer y.qq.com → retcode=0 且 LRC 非空（修复口径）",
          retcode == 0 and len(lyric) > 0,
          "retcode=%s lyric_len=%s" % (retcode, len(lyric)))
    check("QQ LRC 含时间标签（可被 LyricParser 解析）", "[" in lyric,
          "contains '[' = %s" % ("[" in lyric))

    # 3) 服务端忽略 nobase64=1 时返回 base64 → 验证解码口径
    print("\n--- QQ 歌词：不传 nobase64（base64 响应）带 Referer y.qq.com ---")
    st, body = get(lyric_url, {"songmid": qqmid, "format": "json"}, referer=QQ_REFERER)
    j = parse_json(body)
    raw_lyric = (j or {}).get("lyric") or ""
    decoded = norm_lrc(raw_lyric)
    is_b64 = looks_like_b64(raw_lyric)
    print("retcode=%s raw_len=%s looks_base64=%s decoded_len=%s"
          % ((j or {}).get("retcode"), len(raw_lyric), is_b64, len(decoded)))
    check("QQ base64 响应可解码为 UTF-8 LRC（修复需自动解码）",
          (not is_b64) or ("[" in decoded and len(decoded) > 0),
          "looks_base64=%s decoded_len=%s" % (is_b64, len(decoded)))

# ---------------------------------------------------------------- 网易云
print("\n--- 网易云完整链路 ---")
st, body = get("https://music.163.com/api/search/get/web",
               {"s": "晴天", "type": 1, "limit": 3, "offset": 0})
j = parse_json(body)
ne_id = None
try:
    ne_id = j["result"]["songs"][0]["id"]
    print("search status=%s id=%s name=%s" % (st, ne_id, j["result"]["songs"][0].get("name")))
except Exception as e:  # noqa: BLE001
    print("search parse fail: %r head=%s" % (e, body_head(body)))
check("网易云搜索链路可用（取到 song id）", bool(ne_id), "id=%s" % ne_id)
if ne_id:
    st, body = get("https://music.163.com/api/song/lyric",
                   {"id": ne_id, "lv": -1, "kv": -1, "tv": -1})
    j = parse_json(body) or {}
    ly = ((j.get("lrc") or {}).get("lyric") or "")
    print("lyric status=%s code=%s lyric_len=%s head=%s"
          % (st, j.get("code"), len(ly), ly[:100].replace("\n", "\\n")))
    check("网易云歌词链路 → code=200 且歌词非空", j.get("code") == 200 and len(ly) > 0,
          "code=%s lyric_len=%s" % (j.get("code"), len(ly)))

# ---------------------------------------------------------------- 酷狗
print("\n--- 酷狗完整链路 ---")
# 与 kugou_api.dart 的 _search 一致（mobilecdn.kugou.com 当前证书主机名不匹配，改走 songsearch）
st, body = get("https://songsearch.kugou.com/song_search_v2",
               {"keyword": "晴天", "page": 1, "pagesize": 3,
                "platform": "PCFilter", "tag": "em", "filter": "2"})
j = parse_json(body)
kg_hash, kg_dur = None, 0
try:
    item = j["data"]["lists"][0]
    kg_hash = item["FileHash"]
    kg_dur = int(item.get("TimeLength") or 0)
    print("search status=%s hash=%s name=%s" % (st, kg_hash, item.get("SongName")))
except Exception as e:  # noqa: BLE001
    print("search parse fail: %r head=%s" % (e, body_head(body)))
check("酷狗搜索链路可用（取到 FileHash）", bool(kg_hash), "hash=%s" % kg_hash)
if kg_hash:
    st, body = get("https://krcs.kugou.com/search",
                   {"ver": 1, "man": "yes", "client": "mobi", "keyword": "",
                    "duration": kg_dur * 1000, "hash": kg_hash, "album_audio_id": ""},
                   referer=KG_REFERER)
    j = parse_json(body) or {}
    cands = j.get("candidates") or []
    print("krcs status=%s status_field=%s candidates=%s"
          % (st, j.get("status"), len(cands)))
    check("酷狗 krcs 找到歌词候选", bool(cands), "candidates=%s" % len(cands))
    if cands:
        cid, akey = cands[0].get("id"), cands[0].get("accesskey")
        st, body = get("https://lyrics.kugou.com/download",
                       {"ver": 1, "client": "pc", "id": cid,
                        "accesskey": akey, "fmt": "lrc", "charset": "utf8"},
                       referer=KG_REFERER)
        j = parse_json(body) or {}
        content = j.get("content") or ""
        decoded = ""
        try:
            decoded = base64.b64decode(content).decode("utf-8", "replace")
        except Exception:
            decoded = content
        print("download status=%s len=%s decoded_len=%s head=%s"
              % (st, len(content), len(decoded), decoded[:100].replace("\n", "\\n")))
        check("酷狗歌词下载 → 解码后非空", len(decoded) > 0,
              "decoded_len=%s" % len(decoded))

# ---------------------------------------------------------------- 汇总
print("\n" + "=" * 72)
failed = [c for c in checks if not c[1]]
print("汇总：%s 项检查，%s 通过，%s 失败"
      % (len(checks), len(checks) - len(failed), len(failed)))
for name, passed, detail in checks:
    print("  [%s] %s" % ("PASS" if passed else "FAIL", name))
print("=" * 72)
sys.exit(1 if failed else 0)
