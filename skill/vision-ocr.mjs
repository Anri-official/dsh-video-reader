// vision-ocr.mjs — 把一目录的关键帧逐张送给视觉模型，取回画面上的文字。
//
// key 解析顺序（第一个有值的生效）：
//   1. 环境变量 VISION_API_KEY
//   2. 环境变量 DEEPSEEK_API_KEY
//   3. DSH 的凭据文件 $DSH_HOME/.credentials.yaml（本机装了 DSH 时的便利回退）
// key 只用于发起请求，任何情况下都不会被打印。
//
// 用法: node vision-ocr.mjs <framesDir> <outFile> <intervalSec> <mode>
//   mode: text | code
// 可用环境变量: VISION_API_KEY / DEEPSEEK_API_KEY / VISION_MODEL / VISION_BASE
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const [framesDir, outFile, intervalSec, mode] = process.argv.slice(2);
const INT = Number(intervalSec) || 10;

function resolveKey() {
  for (const name of ['VISION_API_KEY', 'DEEPSEEK_API_KEY']) {
    const v = process.env[name];
    if (v && v.trim()) return { key: v.trim(), from: `环境变量 ${name}` };
  }
  // 可选回退：本机 DSH 的凭据文件
  const home = process.env.DSH_HOME;
  if (home) {
    const f = join(home, '.credentials.yaml');
    if (existsSync(f)) {
      const m = readFileSync(f, 'utf8').match(/DEEPSEEK_API_KEY\s*:\s*(\S+)/);
      if (m) return { key: m[1].replace(/^["']|["']$/g, ''), from: 'DSH 凭据文件' };
    }
  }
  return null;
}

const found = resolveKey();
if (!found) {
  console.error([
    '',
    '找不到视觉模型的 API key。请任选一种方式提供：',
    '',
    '  PowerShell:  $env:VISION_API_KEY = "sk-..."      # 仅当前会话',
    '  bash:        export VISION_API_KEY=sk-...',
    '',
    '  或写成 .env 后由 setup.ps1 读取，或直接设为系统环境变量。',
    '  兼容 DEEPSEEK_API_KEY；装了 DSH 的话也会自动读它的凭据文件。',
    '',
  ].join('\n'));
  process.exit(2);
}
const key = found.key;
const MODEL = process.env.VISION_MODEL || 'deepseek-flash';
const API = (process.env.VISION_BASE || 'https://api.deepseek.com') + '/chat/completions';

const PROMPT = mode === 'code'
  ? '把这张图里的所有文字原样转录，尤其是代码：保留缩进和符号。没有文字就回「无」。只输出内容，不要解释。'
  : '把这张图里的所有文字原样转录（包括字幕、标题、代码、界面文字）。没有文字就回「无」。只输出内容，不要解释。';

const frames = readdirSync(framesDir).filter(f => f.toLowerCase().endsWith('.png')).sort();
if (frames.length === 0) {
  console.error(`目录里没有 PNG: ${framesDir}`);
  process.exit(2);
}
console.error(`使用 ${MODEL}（key 来自${found.from}），共 ${frames.length} 帧`);

async function ocr(file, attempt = 1) {
  const b64 = readFileSync(join(framesDir, file)).toString('base64');
  try {
    const r = await fetch(API, {
      method: 'POST',
      headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 700,
        temperature: 0,
        messages: [{
          role: 'user',
          content: [
            { type: 'text', text: PROMPT },
            { type: 'image_url', image_url: { url: `data:image/png;base64,${b64}` } },
          ],
        }],
      }),
    });
    const j = await r.json();
    if (j.error) throw new Error(j.error.message || JSON.stringify(j.error));
    return { text: (j.choices?.[0]?.message?.content || '').trim(), usage: j.usage || {} };
  } catch (e) {
    if (attempt < 3) { await new Promise(r => setTimeout(r, 1500 * attempt)); return ocr(file, attempt + 1); }
    return { text: `[失败: ${e.message}]`, usage: {} };
  }
}

const results = new Array(frames.length);
let done = 0, inTok = 0, outTok = 0;
const CONC = Number(process.env.VISION_CONCURRENCY) || 3;
let cursor = 0;
async function worker() {
  while (true) {
    const i = cursor++;
    if (i >= frames.length) return;
    const r = await ocr(frames[i]);
    results[i] = r;
    inTok += r.usage.prompt_tokens || 0;
    outTok += r.usage.completion_tokens || 0;
    done++;
    process.stderr.write(`\r  视觉识别 ${done}/${frames.length}  (输入 ${inTok} tok, 输出 ${outTok} tok)`);
  }
}
await Promise.all(Array.from({ length: CONC }, worker));
process.stderr.write('\n');

const fmt = (s) => `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(Math.round(s % 60)).padStart(2, '0')}`;
const lines = [];
for (let i = 0; i < frames.length; i++) {
  const t = i * INT;
  const txt = (results[i]?.text || '').trim();
  if (!txt || txt === '无') continue;
  lines.push(`### ${fmt(t)} - ${fmt(t + INT)}  (${frames[i]})`);
  lines.push('');
  lines.push(txt);
  lines.push('');
}
writeFileSync(outFile, lines.join('\n'));
console.log(JSON.stringify({ frames: frames.length, written: lines.length, inTok, outTok, model: MODEL, outFile }));
