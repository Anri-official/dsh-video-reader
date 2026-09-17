# 疑难杂症

这份文档记录的是**开发过程中真实踩过的坑**，不是理论问题清单。每一条都对应一次实际的排错。

---

## 一、网络与下载

### GitHub 下载只有 0.08 MB/s

直连 GitHub Releases 在某些网络下慢到不可用（实测 0.08 MB/s，200MB 的 ffmpeg 要 40 分钟）。

**解决**：`fetch-file.mjs` 会自动依次尝试镜像，实测 **1.8–17 MB/s**（快 20–200 倍）：

| 镜像 | 实测速度 |
|---|---|
| `gh-proxy.com` | **1.8 MB/s** ← 默认首选 |
| `ghfast.top` | 0.70 MB/s |
| 直连 | 0.08 MB/s |

强制指定：`$env:GH_MIRROR = 'https://gh-proxy.com/'`

### PowerShell 的 `Invoke-WebRequest` 直接报 TLS 错误

症状：`基础连接已经关闭: 接收时发生错误`，或 curl 报 `schannel: SEC_E_NO_CREDENTIALS`。

**原因**：部分环境下 PowerShell / curl 走 Windows schannel，凭据获取失败。**同一时刻 Node 的 fetch 完全正常。**

**解决**：本项目所有下载都走 `fetch-file.mjs`（Node），不用 `Invoke-WebRequest`。

### `raw.githubusercontent.com` 解析到 0.0.0.0

某些网络会把它黑洞掉，`curl` 报 `Could not resolve host`。

**解决**：读 GitHub 上的文件改走 API：

```
https://api.github.com/repos/<owner>/<repo>/contents/<path>   → base64 内容
```

### `huggingface.co` 连不上

**解决**：模型尽量从 **GitHub Releases** 拿（sherpa-onnx 把模型直接放在 release 里）。备选镜像：`hf-mirror.com`、`modelscope.cn`。

### `winget` 用不了

`winget.exe` 可能是**0 字节的商店占位符**，执行返回 `-1978335231`。同理可能没有 `choco` / `scoop` / `git`。

**解决**：本项目的 `setup.ps1` 全程直连下载，不依赖任何包管理器。

---

## 二、PowerShell 陷阱（这三个都真实踩过）

### 1. 脚本必须存成 UTF-8 **带 BOM**

Windows PowerShell 5.1 会把无 BOM 的 `.ps1` 当作 GBK 读取。脚本里的中文会变成乱码，**而且乱码会吃掉引号**，报出一堆莫名其妙的语法错误：

```
Missing ')' in method call.
Unexpected token '}' in expression or statement.
```

**解决**：保存为 UTF-8 with BOM。`setup.ps1` 已处理；如果你自己改了脚本，记得重新加 BOM。

### 2. 变量后面的冒号会被吃进变量名

```powershell
$keep = 0.2
$vf += ",crop=iw:ih*$keep:0:ih*$y"     # ❌ 结果是 "crop=iw:ih**0.8"
```

PowerShell 把 `$keep:0` 解析成变量 `keep:0`（作用域语法），值变空，**整个 filter 被拼坏**。ffmpeg 报 `Undefined constant or missing '(' in '*0.8'`。

**解决**：用花括号界定变量名：

```powershell
$vf += ",crop=iw:ih*${keep}:0:ih*${y}"   # ✅
```

**只要变量后面紧跟冒号，就必须写 `${...}`。**

### 3. `$args` 是保留变量，不能当函数参数名

```powershell
function T($label, $args) { ... }   # ❌ $args 会被 PowerShell 覆盖
```

**解决**：换个名字（如 `$ArgList`）。

### 4. `Join-Path` 返回字符串，不是 FileInfo

```powershell
$seg = Join-Path $Work "ch01.wav"
Invoke-Asr $seg.FullName        # ❌ $null —— 字符串没有 FullName 属性
Invoke-Asr $seg                 # ✅
```

**特别注意**：`Test-Path $seg` 会**成功**，所以错误会推迟到调用处才暴露。这个 bug 表现为"运行时提示没找到输入文件"。

### 5. `$ErrorActionPreference = 'Stop'` + 原生程序写 stderr = 脚本中断

`ffmpeg` / `sherpa-onnx` / `node` 都会往 stderr 写正常信息（进度、配置回显）。在 `Stop` 模式下，PowerShell 5.1 会把**任何 stderr 输出当成致命错误**。

**解决**：调用原生程序期间临时放宽：

```powershell
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $out = & $exe @allArgs 2>&1 } finally { $ErrorActionPreference = $prev }
```

---

## 三、yt-dlp 与权限

### `yt-dlp.exe` 报 `Failed to create parent directory structure`

**原因**：`yt-dlp.exe` 是 **PyInstaller 单文件自解包**程序，每次运行都要把自己的运行时解压到系统临时目录。在受限环境（沙箱、无写权限的临时目录）里会失败。

**解决**：**不用 exe**，改用 **Python zipapp**：

```
python\python.exe  +  bin\yt-dlp.pyz
```

嵌入式 Python 解压即用，不写注册表、不碰系统目录，**完全落在项目目录内**。

`setup.ps1` 默认就是装这一套。

---

## 四、sherpa-onnx 的用法

### 没有 `--print-result` 这个参数

只有 `--print-args`。传错参数它直接打印用法并退出。

常用参数：

```
--sense-voice-model=<model.onnx>   --sense-voice-language=zh   --sense-voice-use-itn=true
--paraformer=<model.onnx>
--tokens=<tokens.txt>
--num-threads=4        --print-args=false
```

### 识别结果是一行 JSON，而且配置回显在 stderr

```
{"lang": "", "emotion": "", "text": "识别出来的文字", "timestamps": [], ...}
```

日志里另有一大段 `OfflineRecognizerConfig(...)` 回显，走的是 stderr —— 配合 `$ErrorActionPreference` 那个坑，很容易让人误以为崩了。

**解析方式**：逐行找以 `{` 开头、`}` 结尾的行，`ConvertFrom-Json` 后取 `.text`。

---

## 五、识别质量

### 唱歌识别不了，换引擎也没用

语音识别模型是在**说话**上训练的。演唱会、MV、带伴奏的现场，转写会碎得不成句。

**这不是 bug，是原理限制。** 日语歌换成 `language=ja` 会比 `zh` 好一些，但仍然不可用。

**正解**：用视觉路线读屏幕上的歌词/字幕。若视频没有字幕，改用正规歌词来源。

### 语言必须匹配内容

把中文锁死用在日文歌上，输出是纯乱码。用 `-Lang` 指定，或让它从元数据自动判断。

同一段中文内容，`auto` 明显不如显式 `zh`。

### 量化会伤精度

SenseVoice 的 fp32 明显优于 int8，尤其在专有名词上。**别为了省 600MB 删掉 fp32 模型。**

---

## 六、ffmpeg

### `crop` 表达式在 PowerShell 里被拼坏

见上面「变量后面的冒号」那条 —— 这是最容易误判成 ffmpeg 问题的一类错误。

### 抽帧抽不出来

如果你在改脚本：**帧来自画面，而音轨文件里没有视频流**。要从 `audio.wav` 抽帧是永远抽不出来的，必须单独取一份视频（本项目取的是 480p 以下的低清画面，通常只有几十 MB）。

---

## 七、还是不行？

收集这些信息再提问：

```powershell
node --version
& "$env:USERPROFILE\.dsh\skills\video-reader\bin\ffmpeg.exe" -version | Select-Object -First 1
Get-ChildItem "$env:USERPROFILE\.dsh\skills\video-reader" | Select-Object Name
```

以及**完整的报错文本**（不要截断）。
