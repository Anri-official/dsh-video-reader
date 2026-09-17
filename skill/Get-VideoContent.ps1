<#
  Get-VideoContent.ps1 — 把一个视频 URL 变成我能读的文本 + 关键帧。

  管线（按代价从低到高，能停在早的步骤就停）：
    1. 元数据 + 章节        （yt-dlp --dump-json）
    2. 平台字幕            （--skip-download --write-subs，零媒体下载）
    3. 音轨 -> ASR 逐字稿   （yt-dlp -x + ffmpeg + sherpa-onnx，本地转写）
    4. 关键帧              （ffmpeg 抽帧，供视觉读取画面文字）

  用法（本机没有 pwsh，用 Windows PowerShell 直接调用；脚本已存为 UTF-8 BOM）：
    & Get-VideoContent.ps1 -Url "<url>"
    & Get-VideoContent.ps1 -Url "<url>" -FramesEvery 20      # 额外抽关键帧
    & Get-VideoContent.ps1 -Url "<url>" -Asr sensevoice-int8 # 更快的低精度引擎
    & Get-VideoContent.ps1 -Url "<url>" -NoAsr               # 只要元数据 + 字幕

  默认引擎：SenseVoice fp32 + 中文（实测同一段中文技术视频质量最好）。
  实测对比：SenseVoice fp32 > SenseVoice int8 > Paraformer small。
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Url,
  [string]$OutDir,
  [ValidateSet('sensevoice', 'sensevoice-int8', 'paraformer', 'none')][string]$Asr = 'sensevoice',
  # 语言必须匹配内容：把中文锁死在日文歌上会转出乱码（实测踩过）。
  # 不显式指定时会尝试读元数据里的 language 自动切换。
  [ValidateSet('zh', 'en', 'ja', 'ko', 'yue', 'auto')][string]$Lang = 'zh',
  [int]$FramesEvery = 0,          # >0 时每 N 秒抽一帧
  [int]$MaxFrames = 60,
  [switch]$NoAsr,
  # 默认删掉下载来的音轨（10 分钟约 19MB）。加这个开关才保留，便于复核或二次处理。
  [switch]$KeepMedia,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ROOT = Split-Path -Parent $PSCommandPath

# 工具链位置。默认在技能目录内部（setup.ps1 就下载到这里）。
# 想复用一份已经下好的工具链，二选一：
#   1) 环境变量 VIDEO_READER_TOOLS 指向那个目录
#   2) 在技能目录里放一个 tools-dir.txt，内容写上那个目录的路径
$TOOLS = $ROOT
if ($env:VIDEO_READER_TOOLS -and (Test-Path $env:VIDEO_READER_TOOLS)) {
  $TOOLS = $env:VIDEO_READER_TOOLS
} elseif (Test-Path (Join-Path $ROOT 'tools-dir.txt')) {
  $candidate = (Get-Content (Join-Path $ROOT 'tools-dir.txt') -Raw).Trim()
  if ($candidate -and (Test-Path $candidate)) { $TOOLS = $candidate }
}

# ---------- 定位组件 ----------
function Find-First($patterns) {
  foreach ($p in $patterns) { if (Test-Path $p) { return $p } }
  return $null
}
# yt-dlp 走「嵌入式 Python + zipapp」：yt-dlp.exe 是 PyInstaller 自解包程序，
# 每次运行都要往系统临时目录解压，在受限环境里会触发权限问题。zipapp 不写外部文件。
$PY = Find-First @("$TOOLS\python\python.exe")
$YTDLP_PYZ = Find-First @("$TOOLS\bin\yt-dlp.pyz")
$YTDLP_EXE = Find-First @("$TOOLS\bin\yt-dlp.exe")
$FFMPEG = Find-First @("$TOOLS\bin\ffmpeg.exe", (Get-ChildItem "$TOOLS\ffmpeg*\bin\ffmpeg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName))
$SHERPA = Find-First @((Get-ChildItem "$TOOLS\sherpa-onnx*\bin\sherpa-onnx-offline.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName))

# 统一入口：优先免提权的 zipapp，退回到 exe
function Invoke-YtDlp {
  if ($script:PY -and $script:YTDLP_PYZ) { & $script:PY $script:YTDLP_PYZ @args }
  elseif ($script:YTDLP_EXE) { & $script:YTDLP_EXE @args }
  else { throw "没有可用的 yt-dlp" }
}

$MODELS = "$TOOLS\models"
$PARA = Get-ChildItem "$MODELS\sherpa-onnx-paraformer-zh-small*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
$SENSE = Get-ChildItem "$MODELS\sherpa-onnx-sense-voice*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $FFMPEG) { throw "找不到 ffmpeg.exe" }
if (-not $SHERPA) { Write-Host "      (警告：找不到 sherpa-onnx-offline.exe，ASR 将不可用)" }

# ---------- 准备输出目录 ----------
if (-not $OutDir) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $OutDir = Join-Path $ROOT "out\$stamp"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Work = Join-Path $OutDir 'work'
New-Item -ItemType Directory -Force -Path $Work | Out-Null
Write-Host "[1/5] 输出目录: $OutDir"

# ---------- 1. 元数据 ----------
Write-Host "[2/5] 取元数据 ..."
$metaJson = Invoke-YtDlp --dump-json --no-warnings --no-playlist $Url 2>$null
if (-not $metaJson) { throw "yt-dlp 无法解析这个 URL: $Url" }
$meta = $metaJson | ConvertFrom-Json
$meta | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutDir 'metadata.json') -Encoding utf8

$title = $meta.title
$dur = [int]$meta.duration
$chapters = @()
if ($meta.chapters) { $chapters = @($meta.chapters) }
Write-Host "      标题: $title"
Write-Host "      时长: $([TimeSpan]::FromSeconds($dur))  章节: $($chapters.Count)"

# 内容语言和 ASR 语言不匹配会直接毁掉转写：默认 zh，但元数据给了别的语言就用它。
if (-not $PSBoundParameters.ContainsKey('Lang') -and $meta.language) {
  $detected = ([string]$meta.language).ToLower()
  if ($detected -match '^(zh|yue|ja|ko|en)') {
    $Lang = $Matches[1]
    Write-Host "      按元数据自动切换识别语言: $Lang"
  }
}

# ---------- 2. 字幕 ----------
$transcriptPath = Join-Path $OutDir 'transcript.txt'
$subText = $null
Write-Host "[3/5] 尝试平台字幕（零媒体下载）..."
& Invoke-YtDlp --skip-download --write-subs --write-auto-subs `
  --sub-langs "zh-Hans,zh-CN,zh,en" --convert-subs srt `
  --no-warnings -o "$Work\sub.%(ext)s" $Url 2>$null | Out-Null
$subFile = Get-ChildItem "$Work\sub*.srt" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($subFile) {
  Write-Host "      拿到字幕: $($subFile.Name)"
  $subText = (Get-Content $subFile.FullName -Raw) -replace '(?m)^\d+$', '' -replace '(?m)^\d{2}:\d{2}:\d{2}[,.]\d{3} -->.*$', '' -replace '(?m)^\s*$', ''
  $subText = ($subText -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) -join "`n"
} else {
  Write-Host "      没有可用字幕（多数平台字幕需登录）"
}

# ---------- 3. 音轨 + ASR ----------
$asrText = $null
if (-not $NoAsr -and $Asr -ne 'none' -and -not $subText) {
  if (-not $SHERPA) { Write-Host "      !! 找不到 sherpa-onnx-offline.exe，跳过转写" }
  else {
    Write-Host "[4/5] 取音轨（只下音频，不保留视频）..."
    & Invoke-YtDlp -x --audio-format wav --postprocessor-args "-ar 16000 -ac 1" `
      --ffmpeg-location $FFMPEG `
      --no-warnings -o "$Work\audio.%(ext)s" $Url 2>$null | Out-Null
    $wav = Get-ChildItem "$Work\audio*.wav" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $wav) { Write-Host "      !! 音轨获取失败" }
    else {
      Write-Host "      音频: $([math]::Round($wav.Length/1MB,1)) MB"

      # 引擎参数
      # 实测（同一段中文技术视频 A/B）：SenseVoice fp32 + 指定中文 质量最好，
      # 标点断句和术语都明显优于 int8 与 Paraformer。默认就用它。
      $engineArgs = @()
      $engineName = ''
      if ($Asr -like 'sensevoice*' -and $SENSE) {
        if ($Asr -eq 'sensevoice-int8') {
          $m = Get-ChildItem "$($SENSE.FullName)\model*.onnx" | Sort-Object Length | Select-Object -First 1
        } else {
          $m = Get-ChildItem "$($SENSE.FullName)\model*.onnx" | Sort-Object Length -Descending | Select-Object -First 1
        }
        $engineArgs = @(
          "--sense-voice-model=$($m.FullName)",
          "--tokens=$($SENSE.FullName)\tokens.txt",
          "--sense-voice-language=$Lang",
          "--sense-voice-use-itn=true"
        )
        $engineName = "SenseVoice ($($m.Name))"
      } elseif ($PARA) {
        $m = Get-ChildItem "$($PARA.FullName)\model*.onnx" | Sort-Object Length | Select-Object -First 1
        $engineArgs = @("--paraformer=$($m.FullName)", "--tokens=$($PARA.FullName)\tokens.txt")
        $engineName = "Paraformer ($($m.Name))"
      } else {
        Write-Host "      !! 没有可用 ASR 模型，跳过转写"
      }

      if ($engineArgs.Count) {
        Write-Host "      引擎: $engineName"

        function Invoke-Asr([string]$wavPath) {
          if (-not (Test-Path $wavPath)) { return "" }
          # 显式拼参数数组：比混用 splat + 位置参数可靠
          $allArgs = @($script:engineArgs) + @('--num-threads=4', '--print-args=false', $wavPath)
          # sherpa 会往 stderr 写配置回显；$ErrorActionPreference='Stop' 会把 stderr 当致命错误，
          # 所以调用原生程序期间临时放宽，否则脚本会在第一章就中断。
          $prevEap = $ErrorActionPreference
          $ErrorActionPreference = 'Continue'
          try { $out = & $SHERPA @allArgs 2>&1 } finally { $ErrorActionPreference = $prevEap }
          $texts = @()
          foreach ($l in $out) {
            $s = ([string]$l).Trim()
            if ($s.StartsWith('{') -and $s.EndsWith('}')) {
              try {
                $j = $s | ConvertFrom-Json
                if ($j.text) { $texts += ([string]$j.text).Trim() }
              } catch { }
            }
            elseif ($s -match '^\s*\d+:\s*(.+)$' -and $Matches[1].Trim()) {
              $texts += $Matches[1].Trim()
            }
          }
          return ($texts -join "`n")
        }

        if ($chapters.Count -gt 0) {
          Write-Host "      按章节分段转写（$($chapters.Count) 段）..."
          $sb = New-Object System.Text.StringBuilder
          $i = 0
          foreach ($c in $chapters) {
            $i++
            $start = [double]$c.start_time
            $end = [double]$c.end_time
            $seg = Join-Path $Work ("ch{0:d2}.wav" -f $i)
            & $FFMPEG -hide_banner -loglevel error -y -ss $start -to $end -i $wav.FullName -ar 16000 -ac 1 $seg 2>$null
            if (Test-Path $seg) {
              $t = Invoke-Asr $seg   # $seg 是 Join-Path 返回的字符串，不能用 .FullName
              [void]$sb.AppendLine("### $([TimeSpan]::FromSeconds($start).ToString('mm\:ss')) - $([TimeSpan]::FromSeconds($end).ToString('mm\:ss'))  $($c.title)")
              [void]$sb.AppendLine()
              [void]$sb.AppendLine($t)
              [void]$sb.AppendLine()
              Remove-Item $seg -Force
            }
          }
          $asrText = $sb.ToString()
        } else {
          Write-Host "      整段转写（无章节信息，可能要几分钟）..."
          $asrText = Invoke-Asr $wav.FullName
        }
      }
    }
  }
} else {
  if ($NoAsr) { Write-Host "[4/5] 跳过 ASR（-NoAsr）" }
  elseif ($subText) { Write-Host "[4/5] 已有平台字幕，跳过 ASR" }
  else { Write-Host "[4/5] 跳过 ASR（未启用或不适用）" }
}

# ---------- 4. 关键帧 ----------
if ($FramesEvery -gt 0) {
  Write-Host "[5/5] 抽关键帧（每 $FramesEvery 秒，最多 $MaxFrames 帧）..."
  $framesDir = Join-Path $OutDir 'frames'
  New-Item -ItemType Directory -Force -Path $framesDir | Out-Null
  # 帧来自画面，而 audio.wav 里没有视频流 —— 必须单独取一个低清视频。
  # 取 480p 以下的最小组合，通常只有几十 MB，不会退回"下载整个视频"。
  # 注意：如果前面走了 ASR 分支，work 里已有 audio.wav，这里不能再用它。
  & Invoke-YtDlp -f "worstvideo[height<=480]+worstaudio/worst[height<=480]/worst" `
    --ffmpeg-location $FFMPEG --no-warnings -o "$Work\video.%(ext)s" $Url 2>$null | Out-Null
  $vid = Get-ChildItem "$Work\video.*" -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -notin @('.wav', '.part') } | Select-Object -First 1
  if ($vid) {
    Write-Host "      画面源: $($vid.Name) ($([math]::Round($vid.Length/1MB,1)) MB)"
    & $FFMPEG -hide_banner -loglevel error -y -i $vid.FullName `
      -vf "fps=1/$FramesEvery,scale=1280:-1" -frames:v $MaxFrames "$framesDir\f%03d.png" 2>$null
  } else {
    Write-Host "      !! 取不到视频画面，无法抽帧"
  }
  $n = (Get-ChildItem "$framesDir\*.png" -ErrorAction SilentlyContinue).Count
  Write-Host "      抽到 $n 帧 -> $framesDir"
} else {
  Write-Host "[5/5] 跳过抽帧（需要时加 -FramesEvery 20）"
}

# ---------- 5. 汇总 ----------
$body = New-Object System.Text.StringBuilder
[void]$body.AppendLine("# $title")
[void]$body.AppendLine()
[void]$body.AppendLine("- 来源: $Url")
[void]$body.AppendLine("- 时长: $([TimeSpan]::FromSeconds($dur).ToString('hh\:mm\:ss'))")
if ($meta.uploader) { [void]$body.AppendLine("- 作者: $($meta.uploader)") }
if ($meta.upload_date) { [void]$body.AppendLine("- 发布: $($meta.upload_date)") }
[void]$body.AppendLine("- 抓取: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$body.AppendLine()
if ($chapters.Count -gt 0) {
  [void]$body.AppendLine("## 章节")
  [void]$body.AppendLine()
  foreach ($c in $chapters) {
    [void]$body.AppendLine("- $([TimeSpan]::FromSeconds([double]$c.start_time).ToString('mm\:ss')) - $([TimeSpan]::FromSeconds([double]$c.end_time).ToString('mm\:ss'))  $($c.title)")
  }
  [void]$body.AppendLine()
}
if ($meta.description) {
  [void]$body.AppendLine("## 简介")
  [void]$body.AppendLine()
  [void]$body.AppendLine($meta.description)
  [void]$body.AppendLine()
}
if ($subText) {
  [void]$body.AppendLine("## 逐字稿（平台字幕）")
  [void]$body.AppendLine()
  [void]$body.AppendLine($subText)
} elseif ($asrText) {
  [void]$body.AppendLine("## 逐字稿（本地 ASR）")
  [void]$body.AppendLine()
  [void]$body.AppendLine($asrText)
} else {
  [void]$body.AppendLine("## 逐字稿")
  [void]$body.AppendLine()
  [void]$body.AppendLine("_未取得：没有平台字幕，且 ASR 未执行或失败。_")
}
$body.ToString() | Set-Content $transcriptPath -Encoding utf8

# ---------- 清理中间产物 ----------
# work\ 里是下载来的音轨（10 分钟约 19MB），只是中间产物，文字才是结果。
# 默认删掉，避免每跑一次就在磁盘上留一份平台内容的副本、以及让 out\ 无限膨胀。
if (-not $KeepMedia) {
  if (Test-Path $Work) {
    $freed = [math]::Round((Get-ChildItem $Work -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB, 1)
    Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "已清理中间媒体（释放 $freed MB）—— 要保留请加 -KeepMedia"
  }
}

Write-Host ""
Write-Host "完成 -> $transcriptPath"
Write-Host "字符数: $($body.Length)"
$total = [math]::Round((Get-ChildItem $OutDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1KB, 1)
Write-Host "本次占用: $total KB"









