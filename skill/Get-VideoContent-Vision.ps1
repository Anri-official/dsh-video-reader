<#
  Get-VideoContent-Vision.ps1 —— 云端视觉路线（对比测试用，与原脚本完全独立）

  与 Get-VideoContent.ps1 的区别：
    原脚本：音轨 -> 本地 ASR -> 逐字稿（只有"说了什么"）
    本脚本：低清画面 -> 抽帧 -> 云端视觉模型 OCR（能拿到"画面上写了什么"）

  为什么单开一个文件：方便对比、也方便一键回退 —— 不满意直接删掉本文件即可，
  原有的 Get-VideoContent.ps1 一个字节都没改。

  用法：
    & Get-VideoContent-Vision.ps1 -Url "<url>"
    & Get-VideoContent-Vision.ps1 -Url "<url>" -Interval 10 -CropBottom 0.20   # 只要底部字幕带
    & Get-VideoContent-Vision.ps1 -Url "<url>" -Interval 15 -Mode code          # 编程课：优先保代码
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Url,
  [string]$OutDir,
  [int]$Interval = 20,            # 每 N 秒抽一帧
  [int]$MaxFrames = 150,
  [double]$CropBottom = 0,        # >0 时只裁底部这块（占高度比例），如 0.20 = 底部 20%
  [ValidateSet('text', 'code')][string]$Mode = 'text',
  [int]$MaxHeight = 480,          # 画面下载高度上限
  # 默认删掉下载来的低清画面（10 分钟约 22MB），只留识别出的文字。
  [switch]$KeepMedia,
  # 抽出的帧在 OCR 完成后通常已无用（文字已提取），默认一并删除，让每次运行只剩几十 KB。
  # 想事后逐帧复核画面的，加这个开关。
  [switch]$KeepFrames
)

$ErrorActionPreference = 'Stop'
$ROOT = Split-Path -Parent $PSCommandPath

# ---------- 工具链位置 ----------
# 默认在技能目录内部；可用 VIDEO_READER_TOOLS 环境变量或 tools-dir.txt 指向已有工具链。
$TOOLS = $ROOT
if ($env:VIDEO_READER_TOOLS -and (Test-Path $env:VIDEO_READER_TOOLS)) {
  $TOOLS = $env:VIDEO_READER_TOOLS
} elseif (Test-Path (Join-Path $ROOT 'tools-dir.txt')) {
  $candidate = (Get-Content (Join-Path $ROOT 'tools-dir.txt') -Raw).Trim()
  if ($candidate -and (Test-Path $candidate)) { $TOOLS = $candidate }
}

# ---------- 组件定位（与原脚本同一套工具） ----------
function Find-First($patterns) {
  foreach ($p in $patterns) { if (Test-Path $p) { return $p } }
  return $null
}
$PY = Find-First @("$TOOLS\python\python.exe")
$YTDLP_PYZ = Find-First @("$TOOLS\bin\yt-dlp.pyz")
$FFMPEG = Find-First @("$TOOLS\bin\ffmpeg.exe")
$OCR = Find-First @("$ROOT\vision-ocr.mjs", "$TOOLS\vision-ocr.mjs")
if (-not $FFMPEG) { throw "找不到 ffmpeg.exe（先跑 setup.ps1）" }
if (-not $OCR) { throw "找不到 vision-ocr.mjs" }

function Invoke-YtDlp { & $PY $YTDLP_PYZ @args }

# ---------- 输出目录 ----------
if (-not $OutDir) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $OutDir = Join-Path $ROOT "out\vision-$stamp"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Work = Join-Path $OutDir 'work'
$Frames = Join-Path $OutDir 'frames'
New-Item -ItemType Directory -Force -Path $Work, $Frames | Out-Null
Write-Host "[1/4] 输出目录: $OutDir"

# ---------- 元数据 ----------
Write-Host "[2/4] 取元数据 + 章节 ..."
$meta = (Invoke-YtDlp --dump-json --no-warnings --no-playlist $Url 2>$null) | ConvertFrom-Json
$dur = [int]$meta.duration
Write-Host "      标题: $($meta.title)"
Write-Host "      时长: $([TimeSpan]::FromSeconds($dur))"
$chapters = @()
if ($meta.chapters) { $chapters = @($meta.chapters) }
if ($chapters.Count) { Write-Host "      章节: $($chapters.Count)" }

# ---------- 取低清画面 ----------
Write-Host "[3/4] 取画面（限制高度 $MaxHeight，只取画面不取整片）..."
& Invoke-YtDlp -f "worstvideo[height<=$MaxHeight]+worstaudio/worst[height<=$MaxHeight]/worst" `
  --ffmpeg-location $FFMPEG --no-warnings -o "$Work\video.%(ext)s" $Url 2>$null | Out-Null
$vid = Get-ChildItem "$Work\video.*" -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -notin @('.wav', '.part') } | Select-Object -First 1
if (-not $vid) { throw "取不到画面" }
Write-Host "      画面源: $($vid.Name) ($([math]::Round($vid.Length/1MB,1)) MB)"

# ---------- 抽帧 ----------
$vf = "fps=1/$Interval"
if ($CropBottom -gt 0) {
  # 只保留底部字幕带：像素量降到约 1/5，但不损失字幕本身的分辨率。
  # 注意：必须写 ${keep} 而不是 $keep —— 后面的冒号会被 PowerShell 当成变量名的一部分
  # （"$keep:0" 会被解析成变量 keep:0，值变空，filter 直接被拼坏）。
  $keep = [math]::Round($CropBottom, 3)
  $y = [math]::Round(1 - $CropBottom, 3)
  $vf += ",crop=iw:ih*${keep}:0:ih*${y}"
}
Write-Host "      抽帧: 每 $Interval 秒一帧，最多 $MaxFrames 帧$(if($CropBottom -gt 0){", 裁剪底部 $([int]($CropBottom*100))%"})"
Get-ChildItem "$Frames\*.png" -ErrorAction SilentlyContinue | Remove-Item -Force
& $FFMPEG -hide_banner -loglevel error -y -i $vid.FullName -vf $vf -frames:v $MaxFrames "$Frames\f%04d.png" 2>$null
$n = (Get-ChildItem "$Frames\*.png" -ErrorAction SilentlyContinue).Count
Write-Host "      抽到 $n 帧"
if ($n -eq 0) { throw "没有抽到任何帧" }

# ---------- 云端视觉 OCR ----------
Write-Host "[4/4] 云端视觉识别（每帧一次请求，3 路并发）..."
$ocrOut = Join-Path $OutDir 'vision-ocr.md'
# node 把进度写 stderr；$ErrorActionPreference='Stop' 会把它当致命错误，这里临时放宽
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $json = & node $OCR $Frames $ocrOut $Interval $Mode 2>&1 | Select-Object -Last 1
} finally { $ErrorActionPreference = $prevEap }
Write-Host "      $json"

# ---------- 汇总 ----------
$stampStr = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$head = @()
$head += "# $($meta.title)  —— 云端视觉路线"
$head += ""
$head += "- 来源: $Url"
$head += "- 时长: $([TimeSpan]::FromSeconds($dur).ToString('hh\:mm\:ss'))"
if ($meta.uploader) { $head += "- 作者: $($meta.uploader)" }
$head += "- 抓取: $stampStr"
$head += "- 抽帧: 每 $Interval 秒$(if($CropBottom -gt 0){"，裁剪底部 $([int]($CropBottom*100))%"})，共 $n 帧"
$head += "- 模型: $(if($env:VISION_MODEL){$env:VISION_MODEL}else{'deepseek-flash'})"
$head += ""
if ($chapters.Count) {
  $head += "## 章节"
  $head += ""
  foreach ($c in $chapters) {
    $head += "- $([TimeSpan]::FromSeconds([double]$c.start_time).ToString('mm\:ss')) - $([TimeSpan]::FromSeconds([double]$c.end_time).ToString('mm\:ss'))  $($c.title)"
  }
  $head += ""
}
$head += "## 逐帧画面文字（云端视觉）"
$head += ""
$body = ($head -join "`n") + (Get-Content $ocrOut -Raw -Encoding UTF8)
$final = Join-Path $OutDir 'transcript-vision.md'
$body | Set-Content $final -Encoding UTF8

# ---------- 清理中间产物 ----------
# 画面和帧都只是"为了拿到文字"而付出的下载与解码成本；文字落地后它们就是纯占用。
# 默认删掉，让一次运行只留下几十 KB。
$freed = 0
if (-not $KeepMedia -and (Test-Path $Work)) {
  $freed += (Get-ChildItem $Work -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not $KeepFrames -and (Test-Path $Frames)) {
  $freed += (Get-ChildItem $Frames -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  Remove-Item $Frames -Recurse -Force -ErrorAction SilentlyContinue
}
if ($freed -gt 0) {
  Write-Host "已清理中间产物（释放 $([math]::Round($freed/1MB,1)) MB）—— 保留请加 -KeepMedia / -KeepFrames"
}

Write-Host ""
Write-Host "完成 -> $final"
Write-Host "字符数: $($body.Length)"
$total = [math]::Round((Get-ChildItem $OutDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1KB, 1)
Write-Host "本次占用: $total KB"





