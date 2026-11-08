"""从播放页截图里测量「音源」按钮（灰色胶囊）的实际像素/DP 宽度。

用途：E2E 回归证据。task-5 修复前按钮被 Container(alignment) 撑成通栏，
修复后应回到内容宽度的紧凑胶囊（约 64~90dp）。
设备：1080x1920 @480dpi -> dp = px / 3。

用法：
  python measure_source_button.py <screenshot.png> [y_min] [y_max]
默认在进度条上方区域（y 1080~1300）扫描「浅灰、饱和度低、连续」的横向色块，
取最长连续段的包围盒作为按钮胶囊的宽度。
"""
import sys
from PIL import Image


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: python measure_source_button.py <png> [y_min] [y_max]")
        return 2
    path = sys.argv[1]
    y_min = int(sys.argv[2]) if len(sys.argv) > 2 else 1080
    y_max = int(sys.argv[3]) if len(sys.argv) > 3 else 1300
    img = Image.open(path).convert("RGB")
    W, H = img.size
    px = img.load()

    best_rows = []  # (y, start, end, length)
    for y in range(max(0, y_min), min(H, y_max)):
        run_start = None
        longest = (0, 0, 0)  # len, start, end
        for x in range(0, W):
            r, g, b = px[x, y]
            mx, mn = max(r, g, b), min(r, g, b)
            bright = (r + g + b) / 3.0
            # 玻璃胶囊：中灰~浅灰、低饱和；背景是深色渐变
            hit = bright > 90 and (mx - mn) < 45
            if hit and run_start is None:
                run_start = x
            elif not hit and run_start is not None:
                ln = x - run_start
                if ln > longest[0]:
                    longest = (ln, run_start, x - 1)
                run_start = None
        if run_start is not None:
            ln = W - run_start
            if ln > longest[0]:
                longest = (ln, run_start, W - 1)
        if longest[0] > 120:
            best_rows.append((y, longest[1], longest[2], longest[0]))

    if not best_rows:
        print(f"{path}: 未检测到按钮胶囊（检查 y 区间/阈值）")
        return 1

    # 取最长的那几行估计按钮主体（排除文字行造成的碎片）
    best_rows.sort(key=lambda t: t[3], reverse=True)
    top = best_rows[:8]
    x0 = min(t[1] for t in top)
    x1 = max(t[2] for t in top)
    y0 = min(t[0] for t in top)
    y1 = max(t[0] for t in top)
    width_px = x1 - x0 + 1
    height_px = y1 - y0 + 1
    print(f"file: {path}")
    print(f"设备: {W}x{H} @480dpi (1dp = 3px)")
    print(f"按钮胶囊包围盒: x=[{x0},{x1}] y=[{y0},{y1}]")
    print(f"按钮宽度: {width_px}px = {width_px / 3.0:.1f}dp")
    print(f"按钮高度(检测行范围): {height_px}px = {height_px / 3.0:.1f}dp")
    # 结论判定（task-5 要求 64~120dp，紧凑胶囊；通栏约 300dp）
    if width_px / 3.0 <= 120:
        print("判定: PASS（紧凑胶囊，<=120dp）")
        return 0
    print("判定: FAIL（疑似通栏，>120dp）")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
