// fetch-file.mjs — 带镜像回退的下载器。
//
// 为什么不用 PowerShell 的 Invoke-WebRequest：在部分环境（含本项目的开发机）它的 TLS
// 握手会直接失败（schannel SEC_E_NO_CREDENTIALS），而 Node 的 fetch 正常。
//
// 为什么要镜像：GitHub 直连在部分网络下只有 0.08 MB/s，套上 gh-proxy 实测 1.8–17 MB/s。
//
// 用法: node fetch-file.mjs <url> <destPath> [minMB]
//   已存在且 >= minMB 时跳过（幂等，可反复运行）。
import { createWriteStream, existsSync, statSync, mkdirSync } from 'node:fs';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { dirname } from 'node:path';

const [url, dest, minMBArg] = process.argv.slice(2);
const minMB = Number(minMBArg) || 0;

if (!url || !dest) {
  console.error('用法: node fetch-file.mjs <url> <destPath> [minMB]');
  process.exit(2);
}

if (existsSync(dest) && statSync(dest).size >= minMB * 1048576) {
  console.log(`SKIP  ${dest.split(/[\\/]/).pop()} (已存在 ${(statSync(dest).size / 1048576).toFixed(1)} MB)`);
  process.exit(0);
}
mkdirSync(dirname(dest), { recursive: true });

const MIRRORS = process.env.GH_MIRROR
  ? [process.env.GH_MIRROR]
  : ['https://gh-proxy.com/', 'https://ghfast.top/', ''];

function candidates(u) {
  // 只对 GitHub 链接套镜像；其他主机原样
  if (!/^https?:\/\/github\.com\//i.test(u)) return [u];
  const out = MIRRORS.map(m => m + u);
  if (!out.includes(u)) out.push(u);
  return out;
}

async function tryFetch(target) {
  const started = Date.now();
  const r = await fetch(target, { redirect: 'follow', headers: { 'user-agent': 'dsh-video-reader-setup' } });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const total = Number(r.headers.get('content-length') || 0);
  let got = 0, last = 0;
  const body = Readable.fromWeb(r.body);
  body.on('data', (c) => {
    got += c.length;
    const now = Date.now();
    if (now - last > 3000) {
      last = now;
      const pct = total ? ` ${((got / total) * 100).toFixed(0)}%` : '';
      process.stdout.write(`\r      ${(got / 1048576).toFixed(1)}/${(total / 1048576).toFixed(1)} MB${pct}   `);
    }
  });
  await pipeline(body, createWriteStream(dest));
  process.stdout.write('\r');
  const secs = (Date.now() - started) / 1000;
  console.log(`OK    ${dest.split(/[\\/]/).pop()}  ${(got / 1048576).toFixed(1)} MB in ${secs.toFixed(1)}s`);
  return true;
}

let lastErr;
for (const target of candidates(url)) {
  const label = target === url ? 'direct' : target.split('/')[2];
  try {
    process.stdout.write(`      尝试 ${label} ...\n`);
    await tryFetch(target);
    process.exit(0);
  } catch (e) {
    lastErr = e;
    process.stdout.write(`      失败(${label}): ${e.message}\n`);
  }
}
console.error(`ERR   全部镜像都失败: ${lastErr && lastErr.message}`);
process.exit(1);
