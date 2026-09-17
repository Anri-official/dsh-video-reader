# dsh-video-reader

**给 DeepSeek Harness 装上"看懂视频"的能力。**
把视频链接变成可读的文本：章节时间轴、语音逐字稿、以及**画面上的文字**（字幕 / PPT / 代码）。

不需要下载整个视频——只取音轨，或取一份低清画面。

> English version below ↓

---

## 它解决什么问题

模型看不见视频。而视频里的信息分成两半，**要用两条不同的管线去取**：

| 信息在哪 | 用哪条管线 | 成本 |
|---|---|---|
| **说了什么**（讲课、访谈、播客） | 本地离线语音识别 | 免费、离线、10 分钟约 30 秒 |
| **写了什么**（板书、代码、屏幕字幕） | 云端视觉模型读屏 | 需要 API key、按量计费 |

---

## 安装（三步）

```powershell
git clone https://github.com/Anri-official/dsh-video-reader
cd dsh-video-reader
./setup.ps1
```

装完**新开一个对话**，agent 就会看到 `video-reader` 技能。

```powershell
./setup.ps1                  # 默认：约 200MB，含画面路线
./setup.ps1 -WithLocalAsr    # 额外装离线语音识别（再约 1.2GB，之后完全离线）
```

> 工具装在技能目录内部，所以**删除 `~/.dsh/skills/video-reader` = 完全卸载**，不留残留。

---

## 使用教程

### 场景一：英语网课（要看板书 / 例句 / 屏幕字幕）

**用画面路线。** 网课的干货几乎都在屏幕上，语音识别拿不到。

```powershell
$env:VISION_API_KEY = 'sk-...'      # 只需设一次

& "$env:USERPROFILE\.dsh\skills\video-reader\Get-VideoContent-Vision.ps1" `
    -Url "https://www.bilibili.com/video/BVxxxx" `
    -Interval 10 `
    -Mode text
```

- `-Interval 10` = 每 10 秒截一帧。网课信息密，间隔要小
- 产出：`transcript-vision.md`，每帧一段，**按时间戳排列**

### 场景二：编程网课（要看代码）

**同样用画面路线，但要加 `-Mode code`** —— 它会要求模型保留缩进和符号。

```powershell
& "$env:USERPROFILE\.dsh\skills\video-reader\Get-VideoContent-Vision.ps1" `
    -Url "<视频链接>" `
    -Interval 8 `
    -Mode code
```

> ⚠️ **代码 OCR 有已知混淆**：`l/1/I`、`O/0`、`rn/m`。关键代码请人工核对。

### 场景三：讲座 / 访谈 / 播客（纯口播）

**用语音路线。** 免费、离线、不需要 key。

```powershell
& "$env:USERPROFILE\.dsh\skills\video-reader\Get-VideoContent.ps1" -Url "<视频链接>"
```

自动按视频章节分段，产出带时间轴的逐字稿。英文内容加 `-Lang en`：

```powershell
& "...\Get-VideoContent.ps1" -Url "<视频链接>" -Lang en
```

### 场景四：信息在两边都有（最全面）

两条都跑，互相补：

```powershell
& "...\Get-VideoContent.ps1"        -Url "<视频链接>"          # 说了什么
& "...\Get-VideoContent-Vision.ps1" -Url "<视频链接>" -Interval 12   # 写了什么
```

### 只想快速看个大概

```powershell
# 只要标题、章节、简介——不下载任何媒体，1 秒返回
& "...\Get-VideoContent.ps1" -Url "<视频链接>" -NoAsr
```

---

## 参数速查

**`Get-VideoContent.ps1`（语音）**

| 参数 | 说明 |
|---|---|
| `-Asr sensevoice` | 默认。质量最好 |
| `-Asr sensevoice-int8` | 更快，略差 |
| `-Asr paraformer` | 最快，中文专用 |
| `-Lang zh\|en\|ja\|ko\|yue\|auto` | **必须匹配内容语言**，默认 `zh` |
| `-NoAsr` | 只取元数据 + 字幕 |
| `-FramesEvery 20` | 顺便抽关键帧 |

**`Get-VideoContent-Vision.ps1`（画面）**

| 参数 | 说明 |
|---|---|
| `-Interval 10` | 每 N 秒一帧。越小越全，也越贵 |
| `-CropBottom 0.20` | 只截底部字幕带，**省约 5 倍 token** 且不损失字幕清晰度 |
| `-Mode code` | 保留代码缩进与符号 |
| `-MaxFrames 150` | 帧数上限，控制成本 |

---

## 常见问题

**Q：一定要 API key 吗？**
只有画面路线需要。语音路线完全免费离线。

**Q：贵吗？**
实测一段 9 分半的视频，38 帧，**输入 9,728 token / 输出 10,025 token**——按 DeepSeek 价格约几分钱。

**Q：支持 YouTube 吗？**
支持，以及 yt-dlp 支持的绝大多数站点。

**Q：音乐视频 / MV 能识别歌词吗？**
**不能。** 语音识别是在"说话"上训练的，唱歌换任何引擎都不行。若视频画面带字幕，可以用画面路线读屏幕上已有的歌词。**本工具不产出受版权保护作品的完整转录。**

**Q：报错怎么办？**
见 [docs/troubleshooting.md](docs/troubleshooting.md)——里面记录了开发中真实踩过的每一个坑（含 Windows 上做任何工具都通用的 PowerShell 陷阱）。

---

## 实测数据

同一段 96 秒中文技术视频，四个语音引擎对比：

| 引擎 | 结果 |
|---|---|
| **SenseVoice fp32 + 指定中文** | **最好**——整句完整、标点正确、专有名词最准 |
| SenseVoice int8 中文 | 良好，丢词略多 |
| SenseVoice int8 auto | 明显更差，**指定语言很重要** |
| Paraformer small | 最啰嗦、无标点、杂音多 |

画面路线能把视频里的**设置面板、菜单、链接、代码**逐字读出——这是语音识别完全做不到的。

---

## 卸载

```powershell
Remove-Item "$env:USERPROFILE\.dsh\skills\video-reader" -Recurse -Force
```

---

## English

**Give DeepSeek Harness the ability to read videos.** Turn a video URL into readable text: chapter
timeline, spoken transcript, and **the text on screen** (subtitles, slides, code). The full video is
never downloaded — only the audio track, or a low-resolution picture.

```powershell
git clone https://github.com/Anri-official/dsh-video-reader
cd dsh-video-reader
./setup.ps1                  # ~200 MB, vision pipeline incl.
./setup.ps1 -WithLocalAsr    # + offline speech recognition (~1.2 GB more)
```

Two independent pipelines:

| Information lives in… | Pipeline | Cost |
| --- | --- | --- |
| What is **said** | offline ASR (sherpa-onnx / SenseVoice) | free, private, no key |
| What is **shown** | vision-model OCR | needs an API key |

```powershell
# spoken content
& "$env:USERPROFILE\.dsh\skills\video-reader\Get-VideoContent.ps1" -Url "<URL>" -Lang en

# on-screen content (English lecture slides / code)
$env:VISION_API_KEY = 'sk-...'
& "$env:USERPROFILE\.dsh\skills\video-reader\Get-VideoContent-Vision.ps1" -Url "<URL>" -Interval 10 -Mode code
```

Tools are installed **inside the skill folder**, so deleting that folder uninstalls everything.
Deleting `~/.dsh/skills/video-reader` leaves nothing behind.

**Requirements**: Node.js, Windows (verified on Windows 10/11 + PowerShell 5.1).

**Limitations**: singing is out of scope for ASR; speech covers zh/en/ja/ko/yue only; code OCR
confuses `l/1/I` and `O/0`. For personal study only — respect each platform's terms and don't
redistribute downloaded content. This project does not produce full transcripts of copyrighted works.

---

## 致谢 / Credits

工具链全部来自这些优秀的开源项目，本项目只负责把它们串起来：

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — 下载与元数据
- [FFmpeg](https://ffmpeg.org/) — 音频转换与抽帧
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — 离线语音识别运行时
- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) / [Paraformer](https://github.com/modelscope/FunASR) — 语音识别模型（各自遵循其原始许可）
- 下载默认走 [gh-proxy](https://gh-proxy.com/) 镜像加速

## License

MIT —— 见 [LICENSE](LICENSE)。
