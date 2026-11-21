# JXMusic app icon generator (vinyl record, dark theme).
# Renders 1024x1024 master, downscales to 512x512 icon.png.
# Usage: powershell -File tool/gen_icon.ps1
param(
    [string]$OutPath = "$PSScriptRoot\..\ohos\entry\src\main\resources\base\media\icon.png",
    [string]$MasterPath = "$PSScriptRoot\..\build\icon_master.png"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$size = 1024
$c = $size / 2.0
$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

function Color-A($a, $r, $gn, $b) {
    [System.Drawing.Color]::FromArgb($a, $r, $gn, $b)
}

# 1) background: deep night blue -> dark violet, diagonal
$rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $rect, (Color-A 255 11 15 38), (Color-A 255 40 22 78), 115.0)
$g.FillRectangle($bg, $rect)

# 2) soft radial glow behind the disc (theme primary #5B8DEF)
$gr = 430
$gp = New-Object System.Drawing.Drawing2D.GraphicsPath
$gp.AddEllipse(($c - $gr), ($c - $gr), (2 * $gr), (2 * $gr))
$glow = New-Object System.Drawing.Drawing2D.PathGradientBrush($gp)
$glow.CenterColor = (Color-A 72 91 141 239)
$glow.SurroundColors = @((Color-A 0 91 141 239))
$glow.SetSigmaBellShape(0.45)
$g.FillEllipse($glow, ($c - $gr), ($c - $gr), (2 * $gr), (2 * $gr))

# 3) vinyl disc base: slightly lighter center, near-black rim
$vr = 350
$vp = New-Object System.Drawing.Drawing2D.GraphicsPath
$vp.AddEllipse(($c - $vr), ($c - $vr), (2 * $vr), (2 * $vr))
$vb = New-Object System.Drawing.Drawing2D.PathGradientBrush($vp)
$vb.CenterColor = (Color-A 255 45 45 54)
$vb.SurroundColors = @((Color-A 255 10 10 14))
$g.FillEllipse($vb, ($c - $vr), ($c - $vr), (2 * $vr), (2 * $vr))

# subtle rim light on the disc edge
$rimPen = New-Object System.Drawing.Pen((Color-A 46 255 255 255), 3.0)
$g.DrawEllipse($rimPen, ($c - $vr), ($c - $vr), (2 * $vr), (2 * $vr))

# 4) grooves: concentric rings, alternating light/dark strokes
$ring = 0
for ($r = 336; $r -ge 150; $r -= 13) {
    $col = if ($ring % 2 -eq 0) { (Color-A 14 255 255 255) } else { (Color-A 105 0 0 0) }
    $pen = New-Object System.Drawing.Pen($col, 2.4)
    $g.DrawEllipse($pen, ($c - $r), ($c - $r), (2 * $r), (2 * $r))
    $pen.Dispose()
    $ring++
}

# 5) sheen: two glossy arcs on the upper-left of the disc
$pen1 = New-Object System.Drawing.Pen((Color-A 20 255 255 255), 46.0)
$g.DrawArc($pen1, ($c - 292), ($c - 292), 584, 584, 186, 58)
$pen1.Dispose()
$pen2 = New-Object System.Drawing.Pen((Color-A 34 255 255 255), 15.0)
$g.DrawArc($pen2, ($c - 312), ($c - 312), 624, 624, 196, 34)
$pen2.Dispose()

# 6) center label: theme gradient primary -> accent cyan, with dark separator
$lr = 118
$labelRect = New-Object System.Drawing.Rectangle(($c - $lr), ($c - $lr), (2 * $lr), (2 * $lr))
$sepPen = New-Object System.Drawing.Pen((Color-A 255 8 8 12), 9.0)
$g.DrawEllipse($sepPen, ($c - $lr - 5), ($c - $lr - 5), (2 * $lr + 10), (2 * $lr + 10))
$sepPen.Dispose()
$lb = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $labelRect, (Color-A 255 91 141 239), (Color-A 255 79 216 245), 45.0)
$g.FillEllipse($lb, $labelRect)
# glass edge highlight on the label
$labelRing = New-Object System.Drawing.Pen((Color-A 95 255 255 255), 3.0)
$g.DrawEllipse($labelRing, ($c - $lr), ($c - $lr), (2 * $lr), (2 * $lr))
$labelRing.Dispose()

# 7) music note glyph on the label
$font = New-Object System.Drawing.Font('Segoe UI Symbol', 104.0, [System.Drawing.FontStyle]::Bold)
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center
$sf.LineAlignment = [System.Drawing.StringAlignment]::Center
$g.DrawString([string][char]0x266A, $font, [System.Drawing.Brushes]::White, $c, ($c - 4), $sf)
$font.Dispose()

# save master + downscaled 512 icon
New-Item -ItemType Directory -Path (Split-Path $MasterPath -Parent) -Force | Out-Null
$bmp.Save($MasterPath, [System.Drawing.Imaging.ImageFormat]::Png)
$small = New-Object System.Drawing.Bitmap(512, 512)
$sg = [System.Drawing.Graphics]::FromImage($small)
$sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$sg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$sg.DrawImage($bmp, 0, 0, 512, 512)
$sg.Dispose()
New-Item -ItemType Directory -Path (Split-Path $OutPath -Parent) -Force | Out-Null
$small.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
$small.Dispose()
$g.Dispose(); $bmp.Dispose()
Write-Output "icon written: $OutPath (512x512), master: $MasterPath (1024x1024)"
