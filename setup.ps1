<#
  setup.ps1 —— 一键安装 dsh-video-reader

  做两件事：
    1. 把技能复制到 DSH 的技能目录（默认 ~/.dsh/skills/video-reader）
    2. 下载运行所需的工具链到技能目录内部

  因为工具装在技能目录里，所以**删除那个目录 = 完全卸载**，不留残留。

  用法：
    ./setup.ps1                      # 轻量安装：yt-dlp + ffmpeg + 嵌入式 Python（约 200MB）
    ./setup.ps1 -WithLocalAsr        # 额外装本地语音识别（再约 1.2GB，可离线用）
    ./setup.ps1 -SkipInstall         # 只下载工具，不复制技能（开发调试用）
    ./setup.ps1 -Force               # 忽略已存在的文件，强制重下

  环境要求：Node.js（DSH 本身就需要）。下载走 Node，因为部分环境下
  PowerShell 的 Invoke-WebRequest 会 TLS 握手失败。
#>
[CmdletBinding()]
param(
  [switch]$WithLocalAsr,
  [switch]$SkipInstall,
  [string]$SkillRoot,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# 调用原生程序时临时放宽 $ErrorActionPreference。
# 原因：node / tar 都会往 stderr 写正常信息（进度、提示），而 Stop 模式会把任何 stderr
# 输出当成致命错误 —— 安装脚本会在第一次下载时就直接中断。必须最先定义这个包装。
function Invoke-Native {
  param([scriptblock]$Block)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Block } finally { $ErrorActionPreference = $prev }
}

$RepoRoot = $PSScriptRoot
$SkillSrc = Join-Path $RepoRoot 'skill'
if (-not (Test-Path (Join-Path $SkillSrc 'SKILL.md'))) { throw "找不到 skill 目录: $SkillSrc" }

# ---------- 环境检查 ----------
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw "需要 Node.js（DSH 本身也依赖它）。装好后重跑本脚本。" }
Write-Host "Node: $(Invoke-Native { & node --version })" -ForegroundColor DarkGray

$tar = Get-Command tar -ErrorAction SilentlyContinue
if (-not $tar) { Write-Host "警告：找不到 tar.exe，.tar.bz2 解压会失败（Windows 10+ 自带）" -ForegroundColor Yellow }

# ---------- 决定安装位置 ----------
if (-not $SkillRoot) {
  $dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
  $SkillRoot = Join-Path $dshHome 'skills'
}
$Target = if ($SkipInstall) { $SkillSrc } else { Join-Path $SkillRoot 'video-reader' }

Write-Host ""
Write-Host "技能源目录 : $SkillSrc"
Write-Host "安装到     : $Target"
Write-Host "本地 ASR   : $(if ($WithLocalAsr) { '安装（约 1.2GB）' } else { '跳过（默认轻量）' })"
Write-Host ""

# ---------- 1. 复制技能本体 ----------
if (-not $SkipInstall) {
  Write-Host "[1/3] 复制技能..." -ForegroundColor Cyan
  New-Item -ItemType Directory -Force -Path $Target | Out-Null
  Get-ChildItem $SkillSrc -File | Where-Object { $_.Name -ne 'fetch-file.mjs' } | ForEach-Object {
    Copy-Item $_.FullName $Target -Force
  }
  # fetch-file.mjs 也要带上，setup 以后可能需要在安装目录里重跑
  Copy-Item (Join-Path $SkillSrc 'fetch-file.mjs') $Target -Force -ErrorAction SilentlyContinue
  Write-Host "      已复制 $(@(Get-ChildItem $SkillSrc -File).Count) 个文件"
} else {
  Write-Host "[1/3] 跳过复制（-SkipInstall）" -ForegroundColor DarkGray
}

$Bin = Join-Path $Target 'bin'
New-Item -ItemType Directory -Force -Path $Bin | Out-Null

# ---------- 下载器 ----------
$Fetcher = Join-Path $Target 'fetch-file.mjs'
if (-not (Test-Path $Fetcher)) { $Fetcher = Join-Path $SkillSrc 'fetch-file.mjs' }

function Get-Item2([string]$Url, [string]$Dest, [int]$MinMB) {
  if ((Test-Path $Dest) -and -not $Force) {
    $mb = (Get-Item $Dest).Length / 1MB
    if ($mb -ge $MinMB) { Write-Host "      跳过 $(Split-Path $Dest -Leaf)（已存在 $([math]::Round($mb,1)) MB）" -ForegroundColor DarkGray; return }
  }
  # 2>&1 把 node 的进度输出（走 stderr）并进正常输出流，
  # 否则 PowerShell 会把它渲染成红色报错，成功的安装看起来像失败了。
  Invoke-Native { & node $Fetcher $Url $Dest $MinMB 2>&1 | Out-Host }
  if ($LASTEXITCODE -ne 0) { throw "下载失败: $Url" }
}

$GH = 'https://github.com'
$SHERPA_VER = 'v1.13.8'

# ---------- 2. 基础工具 ----------
Write-Host "[2/3] 下载基础工具（约 200MB）..." -ForegroundColor Cyan
$Tmp = Join-Path $Target 'tmp'
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

# yt-dlp：用 zipapp + 嵌入式 Python，而不是 yt-dlp.exe。
# 原因：那个 exe 是 PyInstaller 自解包程序，每次运行都要往系统临时目录解压，
# 在受限环境里会触发权限问题；zipapp 不写外部文件。
Get-Item2 "$GH/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" (Join-Path $Bin 'yt-dlp.pyz') 2

$PyDir = Join-Path $Target 'python'
if (-not (Test-Path (Join-Path $PyDir 'python.exe')) -or $Force) {
  $pyZip = Join-Path $Tmp 'python-embed.zip'
  Get-Item2 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip' $pyZip 10
  Write-Host "      解压 Python..."
  if (Test-Path $PyDir) { Remove-Item $PyDir -Recurse -Force }
  Expand-Archive -Path $pyZip -DestinationPath $PyDir -Force
}

if (-not (Test-Path (Join-Path $Bin 'ffmpeg.exe')) -or $Force) {
  $ffZip = Join-Path $Tmp 'ffmpeg.zip'
  Get-Item2 "$GH/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip" $ffZip 80
  Write-Host "      解压 ffmpeg（只取 exe）..."
  $ffTmp = Join-Path $Tmp 'ffmpeg'
  if (Test-Path $ffTmp) { Remove-Item $ffTmp -Recurse -Force }
  Expand-Archive -Path $ffZip -DestinationPath $ffTmp -Force
  Get-ChildItem $ffTmp -Recurse -Filter 'ffmpeg.exe'  | Select-Object -First 1 | ForEach-Object { Copy-Item $_.FullName $Bin -Force }
  Get-ChildItem $ffTmp -Recurse -Filter 'ffprobe.exe' | Select-Object -First 1 | ForEach-Object { Copy-Item $_.FullName $Bin -Force }
  Remove-Item $ffTmp -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item (Join-Path $Tmp 'ffmpeg.zip'), (Join-Path $Tmp 'python-embed.zip') -Force -ErrorAction SilentlyContinue

# ---------- 3. 本地 ASR（可选） ----------
if ($WithLocalAsr) {
  Write-Host "[3/3] 下载本地语音识别（约 1.2GB）..." -ForegroundColor Cyan
  $shTar = Join-Path $Tmp 'sherpa-onnx.tar.bz2'
  Get-Item2 "$GH/k2-fsa/sherpa-onnx/releases/download/$SHERPA_VER/sherpa-onnx-$SHERPA_VER-win-x64-shared-MD-Release.tar.bz2" $shTar 10
  if (-not (Get-ChildItem $Target -Directory -Filter 'sherpa-onnx-*' -ErrorAction SilentlyContinue) -or $Force) {
    Write-Host "      解压 sherpa-onnx..."
    Invoke-Native { & tar -xjf $shTar -C $Target }
  }

  $Models = Join-Path $Target 'models'
  New-Item -ItemType Directory -Force -Path $Models | Out-Null
  # SenseVoice：中英日韩粤，实测在中文技术内容上质量最好
  $svName = 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17'
  if (-not (Test-Path (Join-Path $Models $svName)) -or $Force) {
    $svTar = Join-Path $Tmp "$svName.tar.bz2"
    Get-Item2 "$GH/k2-fsa/sherpa-onnx/releases/download/asr-models/$svName.tar.bz2" $svTar 300
    Write-Host "      解压 SenseVoice..."
    Invoke-Native { & tar -xjf $svTar -C $Models }
    Remove-Item $svTar -Force -ErrorAction SilentlyContinue
  } else { Write-Host "      跳过 SenseVoice（已存在）" -ForegroundColor DarkGray }
  Remove-Item $shTar -Force -ErrorAction SilentlyContinue
} else {
  Write-Host "[3/3] 跳过本地 ASR（未加 -WithLocalAsr）" -ForegroundColor DarkGray
}

Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue

# ---------- 完成 ----------
Write-Host ""
Write-Host "安装完成" -ForegroundColor Green
Write-Host ""
Write-Host "已装内容:"
Get-ChildItem $Target -Force | Where-Object { $_.Name -notin @('tmp') } | ForEach-Object {
  $kind = if ($_.PSIsContainer) { '目录' } else { '文件' }
  Write-Host ("  {0,-42} {1}" -f $_.Name, $kind)
}
Write-Host ""
$size = (Get-ChildItem $Target -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Host "占用: $([math]::Round($size/1MB,1)) MB"
Write-Host ""
Write-Host "下一步:"
Write-Host "  1. 新开一个对话，agent 就会看到这个技能"
if (-not $WithLocalAsr) {
  Write-Host "  2. 只有云端视觉可用。要用离线语音识别，重跑: ./setup.ps1 -WithLocalAsr"
}
Write-Host "  3. 云端视觉需要 API key，设为环境变量: `$env:VISION_API_KEY = 'sk-...'"
Write-Host ""
Write-Host "卸载: 删除目录 $Target 即可"



