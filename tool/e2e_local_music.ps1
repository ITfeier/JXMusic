# E2E 自动化：本地音乐自定义路径 + 加密格式解密播放（QA 验收，task-6）
#
# 前置：
#   1) 已连上 Android 设备（模拟器 API 32 / Android 12L），adb devices 可见；
#   2) build/app/outputs/flutter-apk/app-release.apk 已构建（0.10.0+19）；
#   3) build/e2e_music/ 已由 tool/gen_e2e_fixtures.dart 生成。
#
# 用法（在 JXMusic 仓库根目录）：
#   pwsh -File tool/e2e_local_music.ps1
#   pwsh -File tool/e2e_local_music.ps1 -Serial 127.0.0.1:16384 -SkipInstall
#
# 产出：
#   docs/projects/本地音乐与加密格式/evidence/e2e-run.log           运行日志（含 PASS/FAIL 汇总）
#   docs/projects/本地音乐与加密格式/evidence/e2e-summary.txt       PASS/FAIL 明细
#   docs/projects/本地音乐与加密格式/evidence/e2e-*.png             各步骤截图
#   docs/projects/本地音乐与加密格式/evidence/e2e-*.xml             uiautomator 层级快照
#   docs/projects/本地音乐与加密格式/evidence/e2e-logcat*.txt       logcat 证据
#
# 退出码：0 = 全部断言 PASS；1 = 有 FAIL（明细见 e2e-summary.txt）。

[CmdletBinding()]
param(
    [string]$Serial = '',
    [string]$Apk = 'build/app/outputs/flutter-apk/app-release.apk',
    [string]$MusicDir = 'build/e2e_music',
    [string]$EvidenceDir = 'docs/projects/本地音乐与加密格式/evidence',
    [string]$DeviceMusicDir = '/sdcard/Download/jxmusic_e2e',
    [switch]$SkipInstall,
    [switch]$SkipPush
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$script:Package = 'com.jxmusic.jxmusic'
$script:Root = Split-Path -Parent $PSScriptRoot
$script:Adb = 'adb'
$script:Pass = 0
$script:Fail = 0
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Timings = New-Object System.Collections.Generic.List[object]
Set-Location $script:Root

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
}

function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AdbArgs)
    $output = & $script:Adb -s $script:Serial @AdbArgs 2>&1 | Out-String
    return $output.Trim()
}

function Add-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++ } else { $script:Fail++ }
    $entry = [pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail }
    $script:Results.Add($entry)
    if ($Ok) {
        Write-Log ('PASS  ' + $Name + $(if ($Detail) { "（$Detail）" } else { '' })) 'Green'
    } else {
        Write-Log ('FAIL  ' + $Name + $(if ($Detail) { "（$Detail）" } else { '' })) 'Red'
    }
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    Add-Result $Name $Condition $Detail
}

function Add-Timing {
    param([string]$Name, [double]$Seconds, [string]$Detail = '')
    $script:Timings.Add([pscustomobject]@{ Name = $Name; Seconds = $Seconds; Detail = $Detail })
    Write-Log ('TIME  {0}：{1:N2}s {2}' -f $Name, $Seconds, $Detail) 'Cyan'
}

# --- UI 层级 ---------------------------------------------------------------

function Get-UiDump {
    param([string]$EvidenceName = '')
    $remote = '/sdcard/e2e_ui.xml'
    $local = Join-Path $script:TempDir 'ui.xml'
    $ok = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $null = Invoke-Adb shell uiautomator dump $remote
        Start-Sleep -Milliseconds 150
        Remove-Item $local -ErrorAction SilentlyContinue
        $null = Invoke-Adb pull $remote $local
        if ((Test-Path $local) -and ((Get-Item $local).Length -gt 100)) { $ok = $true; break }
        Start-Sleep -Milliseconds 400
    }
    if (-not $ok) { throw 'uiautomator dump 失败（设备无响应？）' }
    if ($EvidenceName) {
        Copy-Item $local (Join-Path $script:EvidenceDir "$EvidenceName.xml") -Force
    }
    return [xml](Get-Content $local -Encoding UTF8 -Raw)
}

function Get-NodeDesc {
    param($Node)
    return [string]$Node.GetAttribute('content-desc')
}

function Get-NodeText {
    param($Node)
    return [string]$Node.GetAttribute('text')
}

function Find-Nodes {
    param($Doc, [string]$Pattern, [switch]$Exact)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($node in @($Doc.SelectNodes('//node'))) {
        foreach ($label in @((Get-NodeDesc $node), (Get-NodeText $node))) {
            if ([string]::IsNullOrEmpty($label)) { continue }
            if ($Exact) {
                if ($label -eq $Pattern) { $out.Add($node); break }
            }
            elseif ($label -like "*$Pattern*") { $out.Add($node); break }
        }
    }
    return $out
}

function Find-Node {
    param($Doc, [string]$Pattern, [switch]$Exact)
    $nodes = @(Find-Nodes $Doc $Pattern -Exact:$Exact)
    if ($nodes.Count -gt 0) { return $nodes[0] }
    return $null
}

function Get-Bounds {
    param($Node)
    $raw = [string]$Node.GetAttribute('bounds')
    $m = [regex]::Match($raw, '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
    if (-not $m.Success) { return $null }
    $x1 = [int]$m.Groups[1].Value
    $y1 = [int]$m.Groups[2].Value
    $x2 = [int]$m.Groups[3].Value
    $y2 = [int]$m.Groups[4].Value
    return [pscustomobject]@{
        X1 = $x1; Y1 = $y1; X2 = $x2; Y2 = $y2
        CX = [int](($x1 + $x2) / 2); CY = [int](($y1 + $y2) / 2)
    }
}

function Invoke-Tap {
    param([int]$X, [int]$Y)
    $null = Invoke-Adb shell input tap $X $Y
}

function Tap-Node {
    param($Node)
    $b = Get-Bounds $Node
    if (-not $b) { return $false }
    Invoke-Tap $b.CX $b.CY
    return $true
}

function Tap-Text {
    param([string]$Text, [switch]$Exact, [int]$TimeoutSec = 20)
    $found = Wait-Text $Text -Exact:$Exact -TimeoutSec $TimeoutSec
    if (-not $found) { return $false }
    return (Tap-Node $found.Node)
}

function Wait-Until {
    param([scriptblock]$Predicate, [int]$TimeoutSec = 30, [int]$PollMs = 700)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $doc = Get-UiDump
            if (& $Predicate $doc) { return $doc }
        }
        catch {
            Write-Log "（等待中 dump 失败，重试）$($_.Exception.Message)" 'DarkYellow'
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return $null
}

function Wait-Text {
    param([string]$Text, [switch]$Exact, [int]$TimeoutSec = 30)
    $predicate = {
        param($d)
        $node = Find-Node $d $Text -Exact:$Exact
        return ($null -ne $node)
    }.GetNewClosure()
    $doc = Wait-Until -Predicate $predicate -TimeoutSec $TimeoutSec
    if (-not $doc) { return $null }
    return [pscustomobject]@{ Doc = $doc; Node = (Find-Node $doc $Text -Exact:$Exact) }
}

function Wait-MiniBar {
    param([string]$Needle, [int]$TimeoutSec = 60)
    $predicate = {
        param($d)
        foreach ($node in @(Find-Nodes $d $Needle)) {
            $b = Get-Bounds $node
            if ($b -and $b.Y1 -ge 1380) { return $true }
        }
        return $false
    }.GetNewClosure()
    $doc = Wait-Until -Predicate $predicate -TimeoutSec $TimeoutSec
    if (-not $doc) { return $null }
    return $doc
}

function Find-MiniBarNode {
    param([string]$Needle)
    $doc = Get-UiDump
    foreach ($node in @(Find-Nodes $doc $Needle)) {
        $b = Get-Bounds $node
        if ($b -and $b.Y1 -ge 1380) { return $node }
    }
    return $null
}

function Get-VisibleLabels {
    param($Doc)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($node in @($Doc.SelectNodes('//node'))) {
        foreach ($label in @((Get-NodeDesc $node), (Get-NodeText $node))) {
            if (-not [string]::IsNullOrEmpty($label)) { [void]$set.Add($label) }
        }
    }
    return $set
}

function Assert-LabelIn {
    param([string]$Name, $Labels, [string]$Needle, [string]$Detail = '')
    $hit = $false
    foreach ($label in $Labels) {
        if ($label -like "*$Needle*") { $hit = $true; break }
    }
    Add-Result $Name $hit $(if ($Detail) { $Detail } else { "列表/层级应包含：$Needle" })
}

function Save-Screenshot {
    param([string]$Name)
    $remote = '/sdcard/e2e_shot.png'
    $local = Join-Path $script:TempDir 'shot.png'
    $null = Invoke-Adb shell screencap -p $remote
    Remove-Item $local -ErrorAction SilentlyContinue
    $null = Invoke-Adb pull $remote $local
    if (Test-Path $local) {
        Copy-Item $local (Join-Path $script:EvidenceDir "$Name.png") -Force
        Write-Log "截图：$Name.png" 'DarkGray'
    } else {
        Write-Log "截图失败：$Name" 'Red'
    }
}

# --- 应用控制 --------------------------------------------------------------

function Start-App {
    $null = Invoke-Adb shell am force-stop $script:Package
    Start-Sleep -Milliseconds 600
    $null = Invoke-Adb shell monkey -p $script:Package -c android.intent.category.LAUNCHER 1
}

function Enter-LocalPage {
    $tab = Wait-Text '本地' -Exact -TimeoutSec 60
    if (-not $tab) { throw '启动后找不到底部「本地」Tab' }
    $null = Tap-Node $tab.Node
    $landing = Wait-Text '本地音乐' -TimeoutSec 20
    if (-not $landing) { throw '点击「本地」后未进入本地音乐页' }
    return $landing.Doc
}

function Wait-ScanDone {
    param([int]$TimeoutSec = 120)
    $predicate = {
        param($d)
        $hasHeader = $null -ne (Find-Node $d '个目录 · ')
        $scanning = $null -ne (Find-Node $d '正在扫描')
        return ($hasHeader -and (-not $scanning))
    }.GetNewClosure()
    return Wait-Until -Predicate $predicate -TimeoutSec $TimeoutSec -PollMs 1000
}

function Find-DeleteIconNear {
    # 兜底：IconButton 无语义标签时，按「可点击 + 右侧区域 + 与路径行同高」定位删除图标。
    param($Doc, $PathNode)
    $pb = Get-Bounds $PathNode
    if (-not $pb) { return $null }
    $best = $null
    $bestDist = 9999
    foreach ($node in @($Doc.SelectNodes('//node'))) {
        if ([string]$node.GetAttribute('clickable') -ne 'true') { continue }
        $b = Get-Bounds $node
        if (-not $b) { continue }
        if ($b.X1 -lt 780) { continue }
        if ($b.X2 - $b.X1 -gt 400) { continue }
        $dist = [Math]::Abs($b.CY - $pb.CY)
        if ($dist -lt 80 -and $dist -lt $bestDist) { $best = $node; $bestDist = $dist }
    }
    return $best
}

function Get-PlayerPosition {
    # 播放页两个 mm:ss 文本：第一个是当前位置，第二个是总时长。
    $doc = Get-UiDump
    $times = New-Object System.Collections.Generic.List[string]
    foreach ($node in @($doc.SelectNodes('//node'))) {
        foreach ($label in @((Get-NodeDesc $node), (Get-NodeText $node))) {
            if ($label -match '^\d{1,2}:\d{2}$') { $times.Add($label) }
        }
    }
    return $times
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

$script:LogFile = Join-Path $script:Root (Join-Path $EvidenceDir 'e2e-run.log')
$script:TempDir = Join-Path $script:Root 'build/e2e_tmp'
New-Item -ItemType Directory -Force -Path (Join-Path $script:Root $EvidenceDir) | Out-Null
New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
if (Test-Path $script:LogFile) { Remove-Item $script:LogFile -Force }

Write-Log '================= JXMusic 本地音乐/加密格式 E2E 开始 =================' 'Cyan'
Write-Log "仓库根目录：$script:Root"

# --- 0. 设备 ---------------------------------------------------------------
$devices = & $script:Adb devices 2>&1 | Out-String
if ([string]::IsNullOrWhiteSpace($Serial)) {
    $match = [regex]::Match($devices, '(?m)^([^\s]+)\s+device$')
    if (-not $match.Success) {
        Write-Log "没有可用设备：`n$devices" 'Red'
        exit 1
    }
    $script:Serial = $match.Groups[1].Value
}
Write-Log "目标设备：$script:Serial" 'Cyan'
$model = Invoke-Adb shell getprop ro.product.model
$androidVersion = Invoke-Adb shell getprop ro.build.version.release
$sdk = Invoke-Adb shell getprop ro.build.version.sdk
$screen = Invoke-Adb shell wm size
Write-Log "设备信息：model=$model / Android $androidVersion (API $sdk) / $screen"

# --- 1. 样本 ---------------------------------------------------------------
$musicPath = Join-Path $script:Root $MusicDir
if (-not (Test-Path $musicPath)) {
    Write-Log "缺少 E2E 样本目录：$musicPath，请先运行 dart run tool/gen_e2e_fixtures.dart" 'Red'
    exit 1
}
$fixtures = @(Get-ChildItem $musicPath -File | Sort-Object Name)
if ($fixtures.Count -lt 6) {
    Write-Log "E2E 样本不足（$($fixtures.Count) 个），请重新生成" 'Red'
    exit 1
}
Write-Log "本地样本 $($fixtures.Count) 个：$($fixtures.Name -join ', ')"

if (-not $SkipPush) {
    $null = Invoke-Adb shell mkdir -p $DeviceMusicDir
    $null = Invoke-Adb shell rm -f "$DeviceMusicDir/*"
    foreach ($file in $fixtures) {
        $null = Invoke-Adb push $file.FullName "$DeviceMusicDir/"
    }
    $remoteList = Invoke-Adb shell ls -l $DeviceMusicDir
    Write-Log "设备端文件列表：`n$remoteList"
    $pushOk = $true
    foreach ($file in $fixtures) {
        $remoteMd5 = (Invoke-Adb shell md5sum "$DeviceMusicDir/$($file.Name)") -split '\s+' | Select-Object -First 1
        $localMd5 = (Get-FileHash $file.FullName -Algorithm MD5).Hash.ToLower()
        if ($remoteMd5 -ne $localMd5) {
            Write-Log "push 校验失败：$($file.Name) local=$localMd5 remote=$remoteMd5" 'Red'
            $pushOk = $false
        }
    }
    Add-Result '样本 push 到设备且 MD5 一致' $pushOk "$($fixtures.Count) 个文件 → $DeviceMusicDir"
}

# --- 2. 安装 / 权限 / 启动 --------------------------------------------------
$apkPath = Join-Path $script:Root $Apk
if (-not $SkipInstall) {
    if (-not (Test-Path $apkPath)) {
        Write-Log "APK 不存在：$apkPath" 'Red'
        exit 1
    }
    $apkHash = (Get-FileHash $apkPath -Algorithm SHA256).Hash
    $apkSize = (Get-Item $apkPath).Length
    Write-Log "APK：$apkPath（$apkSize B，SHA256=$apkHash）"
    $null = Invoke-Adb shell am force-stop $script:Package
    $installOut = Invoke-Adb install -r $apkPath
    Write-Log "adb install -r：$(($installOut -split "`n")[-1])"
    Add-Result 'APK 安装成功' ($installOut -match 'Success') $installOut
}
$packageInfo = Invoke-Adb shell dumpsys package $script:Package
$versionName = [regex]::Match($packageInfo, 'versionName=([^\s]+)').Groups[1].Value
$versionCode = [regex]::Match($packageInfo, 'versionCode=(\d+)').Groups[1].Value
Write-Log "已安装版本：versionName=$versionName versionCode=$versionCode"
Add-Result '安装版本为 0.10.0+19' (($versionName -eq '0.10.0') -and ($versionCode -eq '19')) "实际 $versionName+$versionCode"

# 清空应用数据：保证「首次使用自动预填默认目录」与自定义路径 E2E 从干净状态开始。
$null = Invoke-Adb shell pm clear $script:Package
Write-Log '已 pm clear 应用数据（首次使用状态）'
$null = Invoke-Adb shell appops set $script:Package MANAGE_EXTERNAL_STORAGE allow
$appopsGranted = Invoke-Adb shell appops get $script:Package MANAGE_EXTERNAL_STORAGE
Write-Log "MANAGE_EXTERNAL_STORAGE：$appopsGranted"
Add-Result '「所有文件访问」已授权（appops allow）' ($appopsGranted -match 'allow')

$null = Invoke-Adb logcat -c
Start-App
$home = Wait-Text '今日推荐' -TimeoutSec 90
if (-not $home) { $home = Wait-Text '首页' -Exact -TimeoutSec 20 }
# 并行会话的登录弹窗不属本次验收范围：若弹出则返回键关闭，避免遮挡 Tab。
$loginPopup = Find-Node (Get-UiDump) '扫码登录'
if ($loginPopup) {
    Write-Log '检测到登录弹窗，按返回键关闭（登录链路不在本次验收范围）' 'DarkYellow'
    $null = Invoke-Adb shell input keyevent 4
    Start-Sleep -Milliseconds 800
}
Add-Result '冷启动进入首页（无白屏）' ($null -ne $home)
Save-Screenshot 'e2e-01-cold-start-home'

# --- 3. 本地页 + 默认目录首次自动扫描 --------------------------------------
$null = Enter-LocalPage
Save-Screenshot 'e2e-02-local-first-open'
Write-Log '等待首次自动扫描（默认候选目录）完成…'
$scanDone = Wait-ScanDone -TimeoutSec 180
Add-Result '首次打开自动扫描默认候选目录完成' ($null -ne $scanDone)
$labels = if ($scanDone) { Get-VisibleLabels $scanDone } else { Get-VisibleLabels (Get-UiDump) }
$headerNode = Find-Node (Get-UiDump) '个目录 · '
if ($headerNode) { Write-Log "页头摘要：$(Get-NodeDesc $headerNode)$(Get-NodeText $headerNode)" }
Save-Screenshot 'e2e-03-local-default-scan'
$null = Get-UiDump -EvidenceName 'e2e-03-local-default-scan'

# --- 4. 目录管理：删除默认目录 → 手动添加自定义路径 → 扫描 ------------------
$openedSheet = Tap-Text '扫描目录' -TimeoutSec 20
$sheet = Wait-Text '音乐目录管理' -TimeoutSec 20
Add-Result '打开「音乐目录管理」底部弹层' ($null -ne $sheet)

$deleteLoop = 0
while ($deleteLoop -lt 12) {
    $doc = Get-UiDump
    $delButtons = @(Find-Nodes $doc '删除目录')
    if ($delButtons.Count -gt 0) {
        $b = Get-Bounds $delButtons[0]
        $null = Tap-Node $delButtons[0]
        Write-Log "删除目录（点击「删除目录」按钮 @$($b.CX),$($b.CY)）"
        Start-Sleep -Milliseconds 700
        $deleteLoop++
        continue
    }
    # 兜底：按行坐标点击右侧删除图标（IconButton 无语义标签时）
    $pathNodes = @(Find-Nodes $doc '/sdcard/')
    if ($pathNodes.Count -eq 0) { break }
    $row = $pathNodes[0]
    $b = Get-Bounds $row
    $icon = Find-DeleteIconNear $doc $row
    if ($icon) {
        $null = Tap-Node $icon
        Write-Log "删除目录（可点击节点兜底 @$((Get-Bounds $icon).CX),$((Get-Bounds $icon).CY)）"
    } else {
        Invoke-Tap 930 $b.CY
        Write-Log "删除目录（坐标兜底 @930,$($b.CY)）"
    }
    Start-Sleep -Milliseconds 700
    $deleteLoop++
}
$emptySheet = Wait-Text '还没有添加扫描目录' -TimeoutSec 10
Add-Result '删除全部已配置目录后显示空态' ($null -ne $emptySheet) "循环 $deleteLoop 次"
Save-Screenshot 'e2e-04-sheet-dirs-cleared'

# 手动输入自定义路径
$null = Tap-Text '手动输入' -TimeoutSec 20
$inputDialog = Wait-Text '手动输入目录' -TimeoutSec 20
Add-Result '打开「手动输入目录」对话框' ($null -ne $inputDialog)
$editNodes = @((Get-UiDump).SelectNodes('//node[@class="android.widget.EditText"]'))
if ($editNodes.Count -gt 0) {
    $null = Tap-Node $editNodes[0]
} else {
    Write-Log '未找到 EditText 节点（autofocus 应已聚焦），直接输入' 'DarkYellow'
}
$null = Invoke-Adb shell input text $DeviceMusicDir
Start-Sleep -Milliseconds 600
$typed = Find-Node (Get-UiDump) 'jxmusic_e2e'
Add-Result '路径输入框已填入自定义目录' ($null -ne $typed) $DeviceMusicDir
$null = Tap-Text '添加' -Exact -TimeoutSec 20
Start-Sleep -Milliseconds 900
$pathShown = Wait-Text 'jxmusic_e2e' -TimeoutSec 15
Add-Result '自定义路径出现在目录列表' ($null -ne $pathShown) $DeviceMusicDir
Save-Screenshot 'e2e-05-custom-path-added'
$null = Get-UiDump -EvidenceName 'e2e-05-custom-path-added'

$null = Tap-Text '开始扫描' -Exact -TimeoutSec 20
Write-Log '已点击「开始扫描」，等待扫描完成…'
$scanDone2 = Wait-ScanDone -TimeoutSec 180
Add-Result '自定义路径扫描完成' ($null -ne $scanDone2)

# --- 5. 列表断言：标题 / 加密 chip ----------------------------------------
$allLabels = New-Object 'System.Collections.Generic.HashSet[string]'
$lastCount = -1
for ($i = 0; $i -le 10; $i++) {
    $doc = Get-UiDump
    foreach ($label in (Get-VisibleLabels $doc)) { [void]$allLabels.Add($label) }
    if ($allLabels.Count -eq $lastCount) { break }
    $lastCount = $allLabels.Count
    $null = Invoke-Adb shell input swipe 540 1400 540 900 320
    Start-Sleep -Milliseconds 700
}
$null = Get-UiDump -EvidenceName 'e2e-06-list-after-custom-scan'
Save-Screenshot 'e2e-06-list-after-custom-scan'

$headerDoc = Get-UiDump
$headerNode = Find-Node $headerDoc '个目录 · '
$headerText = if ($headerNode) { (Get-NodeDesc $headerNode) + (Get-NodeText $headerNode) } else { '' }
Write-Log "自定义路径扫描后页头：$headerText"
Add-Result '页头显示 1 个目录 · 7 首' ($headerText -match '1 个目录 · 7 首') $headerText

Assert-LabelIn '普通 WAV 样本出现在列表' $allLabels '01_E2E_普通WAV_测试'
Assert-LabelIn 'NCM 样本出现在列表（扫描即显示内嵌标题）' $allLabels 'NCM-测试歌曲'
Assert-LabelIn 'NCM 样本显示内嵌歌手/专辑' $allLabels 'E2E测试歌手'
Assert-LabelIn 'QMC v1 样本出现在列表' $allLabels '03_E2E_QMCv1_qmc3_测试'
Assert-LabelIn 'QMC v2(mflac) 样本出现在列表' $allLabels '04_E2E_QMCv2_mflac_测试'
Assert-LabelIn 'KGM 样本出现在列表' $allLabels '05_E2E_KGM_测试'
Assert-LabelIn 'VPR 样本出现在列表' $allLabels '06_E2E_VPR_测试'
Assert-LabelIn 'KGG 样本出现在列表（不消失）' $allLabels '07_E2E_KGG_不支持'
Assert-LabelIn '网易云加密 chip' $allLabels '网易云加密 · 需解密'
Assert-LabelIn 'QQ 加密 chip' $allLabels 'QQ加密 · 需解密'
Assert-LabelIn '酷狗加密 chip' $allLabels '酷狗加密 · 需解密'
Assert-LabelIn 'KGG「暂不支持」chip' $allLabels '酷狗加密 · 暂不支持'

# 回到列表顶部，便于后续点击
for ($i = 0; $i -lt 4; $i++) {
    $null = Invoke-Adb shell input swipe 540 900 540 1600 300
    Start-Sleep -Milliseconds 400
}

# --- 6. 播放：普通 WAV（播放全部，不经过解密） -----------------------------
$null = Tap-Text '播放全部' -Exact -TimeoutSec 20
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$mini = Wait-MiniBar '01_E2E_普通WAV_测试' -TimeoutSec 30
$sw.Stop()
Add-Timing '普通 WAV 起播耗时（播放全部）' $sw.Elapsed.TotalSeconds
Add-Result '普通 WAV「播放全部」起播（迷你条显示曲目）' ($null -ne $mini)
Save-Screenshot 'e2e-07-plain-wav-playing'

# 打开播放页，断言真实推进
$miniNode = Find-MiniBarNode '01_E2E_普通WAV_测试'
if ($miniNode) {
    $null = Tap-Node $miniNode
    $playerPage = Wait-Text '正在播放' -TimeoutSec 20
    Add-Result '点击迷你条进入播放页' ($null -ne $playerPage)
    Start-Sleep -Milliseconds 2500
    $times = @(Get-PlayerPosition)
    Write-Log "播放页时间：$($times -join ' / ')"
    $pos = if ($times.Count -ge 1) { $times[0] } else { '' }
    $dur = if ($times.Count -ge 2) { $times[1] } else { '' }
    Add-Result '普通 WAV 播放进度真实推进（非 00:00）' (($pos -ne '') -and ($pos -ne '00:00')) "位置=$pos 时长=$dur"
    Save-Screenshot 'e2e-08-plain-wav-player-page'
    $null = Invoke-Adb shell input keyevent 4
    Start-Sleep -Milliseconds 900
} else {
    Add-Result '点击迷你条进入播放页' $false '迷你条节点未找到'
}

# --- 7. 播放 NCM（首次解密 + 元数据） --------------------------------------
function Scroll-To-Text {
    param([string]$Text, [int]$MaxSwipes = 8)
    for ($i = 0; $i -le $MaxSwipes; $i++) {
        $found = Wait-Text $Text -TimeoutSec 3
        if ($found) { return $found }
        $null = Invoke-Adb shell input swipe 540 1400 540 900 320
        Start-Sleep -Milliseconds 600
    }
    return $null
}

$ncmNode = Scroll-To-Text 'NCM-测试歌曲' -MaxSwipes 8
Add-Result '列表中可定位 NCM 样本' ($null -ne $ncmNode)
if ($ncmNode) {
    # 点击到 mini bar 出现的耗时 ≈ 解密 + libmpv open（NCM 首次）
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Tap-Node $ncmNode.Node
    $mini = Wait-MiniBar 'NCM-测试歌曲' -TimeoutSec 60
    $sw.Stop()
    Add-Timing 'NCM 首次解密+起播耗时' $sw.Elapsed.TotalSeconds
    Add-Result 'NCM 样本解密成功并起播（迷你条显示曲目）' ($null -ne $mini)
    Save-Screenshot 'e2e-09-ncm-playing'
    $miniNode = Find-MiniBarNode 'NCM-测试歌曲'
    if ($miniNode) {
        $null = Tap-Node $miniNode
        $null = Wait-Text '正在播放' -TimeoutSec 20
        Start-Sleep -Milliseconds 2500
        $times = @(Get-PlayerPosition)
        Write-Log "NCM 播放页时间：$($times -join ' / ')"
        $pos = if ($times.Count -ge 1) { $times[0] } else { '' }
        $dur = if ($times.Count -ge 2) { $times[1] } else { '' }
        Add-Result 'NCM 解密音频播放进度真实推进' (($pos -ne '') -and ($pos -ne '00:00')) "位置=$pos 时长=$dur"
        Save-Screenshot 'e2e-10-ncm-player-page'
        $null = Invoke-Adb shell input keyevent 4
        Start-Sleep -Milliseconds 900
    }
}

# --- 8. 播放 KGM / VPR -----------------------------------------------------
foreach ($item in @(
    @{ Title = '05_E2E_KGM_测试'; Label = 'KGM'; Shot = 'e2e-11-kgm-playing' },
    @{ Title = '06_E2E_VPR_测试'; Label = 'VPR'; Shot = 'e2e-12-vpr-playing' }
)) {
    $null = Invoke-Adb shell input swipe 540 900 540 1600 300
    Start-Sleep -Milliseconds 500
    $node = Scroll-To-Text $item.Title -MaxSwipes 10
    if (-not $node) {
        Add-Result "$($item.Label) 样本定位" $false "列表中未出现 $($item.Title)"
        continue
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Tap-Node $node.Node
    $mini = Wait-MiniBar $item.Title -TimeoutSec 90
    $sw.Stop()
    Add-Timing "$($item.Label) 首次解密+起播耗时" $sw.Elapsed.TotalSeconds
    Add-Result "$($item.Label) 样本解密成功并起播" ($null -ne $mini)
    Save-Screenshot $item.Shot
}

# --- 9. KGG 明确不支持（不崩溃、中文原因） ---------------------------------
$null = Invoke-Adb shell input swipe 540 900 540 1600 300
Start-Sleep -Milliseconds 500
$kggNode = Scroll-To-Text '07_E2E_KGG_不支持' -MaxSwipes 10
Add-Result '列表中可定位 KGG 样本' ($null -ne $kggNode)
if ($kggNode) {
    $null = Tap-Node $kggNode.Node
    $kggDialog = Wait-Text '酷狗 KGG 格式需要客户端密钥，暂不支持离线解密' -TimeoutSec 30
    Add-Result 'KGG 点击后给出中文「暂不支持」原因' ($null -ne $kggDialog)
    Save-Screenshot 'e2e-13-kgg-unsupported-dialog'
    $null = Get-UiDump -EvidenceName 'e2e-13-kgg-unsupported-dialog'
    $null = Tap-Text '知道了' -Exact -TimeoutSec 10
    Start-Sleep -Milliseconds 500
}

# --- 10. NCM 二次播放（缓存命中，测耗时） ----------------------------------
$null = Invoke-Adb shell input swipe 540 900 540 1600 300
Start-Sleep -Milliseconds 500
$ncmAgain = Scroll-To-Text 'NCM-测试歌曲' -MaxSwipes 10
if ($ncmAgain) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Tap-Node $ncmAgain.Node
    $mini = Wait-MiniBar 'NCM-测试歌曲' -TimeoutSec 30
    $sw.Stop()
    Add-Timing 'NCM 二次播放（期望命中解密缓存）' $sw.Elapsed.TotalSeconds
    Add-Result 'NCM 二次播放成功' ($null -ne $mini) '用于与首次解密耗时对比'
    Save-Screenshot 'e2e-14-ncm-second-play'
}

# --- 11. logcat 证据 -------------------------------------------------------
$logcatAll = Invoke-Adb logcat -d -v time
$logcatPath = Join-Path $script:EvidenceDir 'e2e-logcat-all.txt'
Set-Content -Path $logcatPath -Value $logcatAll -Encoding UTF8
$keywords = @('JXMusic', 'PlayerBase', 'AF::TrackHandle', 'FormatDecodeException', 'libmpv', 'AndroidRuntime', 'FATAL', '解密失败', '本地曲目不可播')
$matches = @()
foreach ($line in ($logcatAll -split "`n")) {
    foreach ($keyword in $keywords) {
        if ($line -like "*$keyword*") { $matches += $line.Trim(); break }
    }
}
Set-Content -Path (Join-Path $script:EvidenceDir 'e2e-logcat-playback.txt') -Value ($matches -join "`n") -Encoding UTF8
Add-Result 'logcat 出现播放器起播事件' ($matches -join "`n" -match 'PlayerBase|AF::TrackHandle|libmpv')
Add-Result 'logcat 无解密异常/本地不可播日志' (-not (($matches -join "`n") -match 'FormatDecodeException|解密失败|本地曲目不可播'))

# --- 12. 自定义路径持久化：force-stop 重启 ---------------------------------
$null = Invoke-Adb logcat -c
$null = Invoke-Adb shell am force-stop $script:Package
Start-Sleep -Milliseconds 800
$null = Invoke-Adb shell monkey -p $script:Package -c android.intent.category.LAUNCHER 1
$null = Enter-LocalPage
$restartScan = Wait-ScanDone -TimeoutSec 120
Add-Result '重启后本地页自动扫描完成' ($null -ne $restartScan)
$restartDoc = Get-UiDump
$restartHeader = Find-Node $restartDoc '个目录 · '
$restartHeaderText = if ($restartHeader) { (Get-NodeDesc $restartHeader) + (Get-NodeText $restartHeader) } else { '' }
Write-Log "重启后页头：$restartHeaderText"
Add-Result '重启后保留上次配置的 1 个目录' ($restartHeaderText -match '1 个目录') $restartHeaderText
$restartLabels = Get-VisibleLabels $restartDoc
Assert-LabelIn '重启后自动扫描出 NCM 样本' $restartLabels 'NCM-测试歌曲'
Assert-LabelIn '重启后自动扫描出 KGM 样本' $restartLabels '05_E2E_KGM_测试'
Save-Screenshot 'e2e-15-restart-persisted-path'
$null = Get-UiDump -EvidenceName 'e2e-15-restart-persisted-path'
$null = Tap-Text '扫描目录' -TimeoutSec 20
$sheet2 = Wait-Text '音乐目录管理' -TimeoutSec 20
$sheet2Doc = if ($sheet2) { $sheet2.Doc } else { Get-UiDump }
$pathNode = Find-Node $sheet2Doc 'jxmusic_e2e'
Add-Result '目录管理弹层保留自定义路径' ($null -ne $pathNode) $DeviceMusicDir
Save-Screenshot 'e2e-16-restart-path-in-sheet'
$null = Invoke-Adb shell input keyevent 4
Start-Sleep -Milliseconds 800

# --- 13. 未授权态（横幅提示） ---------------------------------------------
$null = Invoke-Adb logcat -c
$null = Invoke-Adb shell appops set $script:Package MANAGE_EXTERNAL_STORAGE deny
$null = Invoke-Adb shell am force-stop $script:Package
Start-Sleep -Milliseconds 800
$null = Invoke-Adb shell monkey -p $script:Package -c android.intent.category.LAUNCHER 1
$null = Enter-LocalPage
$banner = Wait-Text '需要「所有文件访问」权限才能扫描自定义目录' -TimeoutSec 30
Add-Result '未授权时显示「所有文件访问」权限横幅' ($null -ne $banner)
Save-Screenshot 'e2e-17-no-permission-banner'
$null = Get-UiDump -EvidenceName 'e2e-17-no-permission-banner'
$bannerDoc = Get-UiDump
$goAuth = Find-Node $bannerDoc '去授权'
Add-Result '横幅提供「去授权」入口' ($null -ne $goAuth)

# 恢复授权并回归
$null = Invoke-Adb shell appops set $script:Package MANAGE_EXTERNAL_STORAGE allow
$null = Invoke-Adb shell am force-stop $script:Package
Start-Sleep -Milliseconds 800
$null = Invoke-Adb shell monkey -p $script:Package -c android.intent.category.LAUNCHER 1
$null = Enter-LocalPage
$recoveredScan = Wait-ScanDone -TimeoutSec 120
$recoveredDoc = Get-UiDump
$recoveredLabels = Get-VisibleLabels $recoveredDoc
$bannerGone = $null -eq (Find-Node $recoveredDoc '需要「所有文件访问」权限')
Add-Result '恢复授权后横幅消失且可再次扫描' (($null -ne $recoveredScan) -and $bannerGone)
Assert-LabelIn '恢复授权后列表恢复 NCM 样本' $recoveredLabels 'NCM-测试歌曲'
Save-Screenshot 'e2e-18-permission-restored'

# --- 14. 汇总 --------------------------------------------------------------
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('JXMusic 本地音乐 / 加密格式 E2E 结果')
$summary.Add("设备：$model / Android $androidVersion (API $sdk) / 序列号 $script:Serial")
$summary.Add("版本：$versionName+$versionCode / APK SHA256 $apkHash")
$summary.Add("时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$summary.Add('')
$summary.Add('== 断言 ==')
foreach ($r in $script:Results) {
    $summary.Add(('[{0}] {1} {2}' -f $(if ($r.Ok) { 'PASS' } else { 'FAIL' }), $r.Name, $r.Detail))
}
$summary.Add('')
$summary.Add('== 耗时 ==')
foreach ($t in $script:Timings) {
    $summary.Add(('- {0}：{1:N2}s {2}' -f $t.Name, $t.Seconds, $t.Detail))
}
$summary.Add('')
$summary.Add("合计：PASS=$script:Pass FAIL=$script:Fail")
$summaryText = $summary -join "`n"
Set-Content -Path (Join-Path $script:EvidenceDir 'e2e-summary.txt') -Value $summaryText -Encoding UTF8
Write-Log $summaryText 'White'

Write-Log "================= E2E 结束：PASS=$script:Pass FAIL=$script:Fail ================="
if ($script:Fail -gt 0) { exit 1 }
exit 0
