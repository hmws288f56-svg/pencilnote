'use strict';
// 개발용: 아이패드 없이 노트북 화면을 시험하는 가짜 아이패드.
// 실제 앱과 같은 방식으로 접속해서 획을 그리고, 조각/전체 이미지를 보낸다.
//   node tools/fake-pad.js --code 123456 [--host 127.0.0.1] [--port 8787] [--strokes 14]
// 같은 PC에서 돌리면 --code 없이도 접속된다.

const zlib = require('zlib');
const WebSocket = require('ws');

const args = Object.fromEntries(process.argv.slice(2).join(' ').split('--').filter(Boolean).map((s) => {
  const [k, ...v] = s.trim().split(/\s+/);
  return [k, v.join(' ') || '1'];
}));
const HOST = args.host || '127.0.0.1';
const PORT = Number(args.port) || 8787;
const CODE = args.code || '';
const STROKES = Number(args.strokes) || 14;
const BASE = `http://${HOST}:${PORT}`;

const PAGE_W = 1024;
const PAGE_H = 1448;
const S = 2;
const W = PAGE_W * S;
const H = PAGE_H * S;

// ---------- PNG ----------

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(body) >>> 0);
  return Buffer.concat([len, body, crc]);
}

function encodePng(rgba, w, h) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  }
  const head = Buffer.alloc(13);
  head.writeUInt32BE(w, 0);
  head.writeUInt32BE(h, 4);
  head[8] = 8;
  head[9] = 6;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', head),
    chunk('IDAT', zlib.deflateSync(raw, { level: 6 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ---------- 그리기 ----------

let pixels = Buffer.alloc(W * H * 4);

function stamp(cx, cy, r, color) {
  const x0 = Math.max(0, Math.floor(cx - r - 1));
  const x1 = Math.min(W - 1, Math.ceil(cx + r + 1));
  const y0 = Math.max(0, Math.floor(cy - r - 1));
  const y1 = Math.min(H - 1, Math.ceil(cy + r + 1));
  for (let y = y0; y <= y1; y++) {
    for (let x = x0; x <= x1; x++) {
      const d = Math.hypot(x - cx, y - cy);
      const a = Math.max(0, Math.min(1, r + 0.5 - d));
      if (a <= 0) continue;
      const i = (y * W + x) * 4;
      const alpha = Math.round(a * 255);
      if (alpha > pixels[i + 3]) {
        pixels[i] = color[0];
        pixels[i + 1] = color[1];
        pixels[i + 2] = color[2];
        pixels[i + 3] = alpha;
      }
    }
  }
}

function rasterize(stroke) {
  const r = (stroke.width * S) / 2;
  const p = stroke.pts;
  for (let i = 0; i + 3 < p.length; i += 2) {
    const ax = p[i] * S;
    const ay = p[i + 1] * S;
    const bx = p[i + 2] * S;
    const by = p[i + 3] * S;
    const n = Math.max(1, Math.ceil(Math.hypot(bx - ax, by - ay)));
    for (let k = 0; k <= n; k++) stamp(ax + ((bx - ax) * k) / n, ay + ((by - ay) * k) / n, r, stroke.rgb);
  }
}

function bounds(stroke) {
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;
  for (let i = 0; i < stroke.pts.length; i += 2) {
    x0 = Math.min(x0, stroke.pts[i]);
    y0 = Math.min(y0, stroke.pts[i + 1]);
    x1 = Math.max(x1, stroke.pts[i]);
    y1 = Math.max(y1, stroke.pts[i + 1]);
  }
  const m = stroke.width + 6;
  const x = Math.max(0, Math.floor(x0 - m));
  const y = Math.max(0, Math.floor(y0 - m));
  return { x, y, w: Math.min(PAGE_W, Math.ceil(x1 + m)) - x, h: Math.min(PAGE_H, Math.ceil(y1 + m)) - y };
}

function crop(b) {
  const w = b.w * S;
  const h = b.h * S;
  const out = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) {
    const from = ((b.y * S + y) * W + b.x * S) * 4;
    pixels.copy(out, y * w * 4, from, from + w * 4);
  }
  return encodePng(out, w, h);
}

function thumbnail() {
  const f = 8;
  const w = W / f;
  const h = H / f;
  const out = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let best = 0;
      let bi = 0;
      for (let dy = 0; dy < f; dy += 2) {
        for (let dx = 0; dx < f; dx += 2) {
          const i = ((y * f + dy) * W + x * f + dx) * 4;
          if (pixels[i + 3] > best) {
            best = pixels[i + 3];
            bi = i;
          }
        }
      }
      if (best) pixels.copy(out, (y * w + x) * 4, bi, bi + 4);
    }
  }
  return encodePng(out, w, h);
}

// 손글씨처럼 보이는 꼬불꼬불한 획
function makeStroke(n) {
  const row = Math.floor(n / 7);
  const col = n % 7;
  const ox = 90 + col * 125 + Math.random() * 20;
  const oy = 150 + row * 88 + Math.random() * 10;
  const kinds = [
    { tool: 'pen', color: '#1b1b1f', rgb: [27, 27, 31], width: 3 },
    { tool: 'pen', color: '#1d4fd8', rgb: [29, 79, 216], width: 3 },
    { tool: 'pen', color: '#d6336c', rgb: [214, 51, 108], width: 4 },
  ];
  const kind = kinds[row % kinds.length];
  const pts = [];
  const loops = 2 + Math.random() * 2;
  for (let i = 0; i <= 46; i++) {
    const t = i / 46;
    const x = ox + t * 92 + Math.sin(t * Math.PI * 2 * loops) * 9;
    const y = oy + Math.cos(t * Math.PI * 2 * loops) * 20 + Math.sin(t * 5) * 6;
    pts.push(Math.round(x * 10) / 10, Math.round(y * 10) / 10);
  }
  return { ...kind, pts };
}

// ---------- 통신 ----------

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const headers = CODE ? { 'X-Code': CODE } : {};

let ws = null;
let loaded = null; // { note, page, gen }
let rev = 0;
let patchBase = 0;
let strokes = [];
let dirty = false; // 아직 올리지 않은 획이 있는지
let session = 0;
let sid = 0;

function send(obj) {
  if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
}

async function loadPage(st) {
  const my = ++session;
  // 실제 앱처럼, 다른 페이지로 넘어가기 전에 쓰던 페이지를 먼저 올린다.
  if (loaded && dirty) save().catch((e) => console.error(e));
  const target = { note: st.note.id, page: st.page.id, gen: st.page.gen };
  const res = await fetch(`${BASE}/api/notes/${target.note}/pages/${target.page}/drawing`, { headers });
  if (my !== session) return;
  strokes = [];
  if (res.status === 200) {
    try {
      strokes = JSON.parse(Buffer.from(await res.arrayBuffer()).toString('utf8'));
    } catch {
      strokes = []; // 진짜 아이패드가 저장한 필기는 형식이 달라서 읽지 못한다
    }
  }
  if (my !== session) return;
  pixels = Buffer.alloc(W * H * 4);
  for (const s of strokes) rasterize(s);
  loaded = target;
  dirty = false;
  rev = Number(res.headers.get('X-Rev')) || st.page.rev || 0;
  patchBase = rev;
  console.log(`페이지 열림 ${st.index + 1}/${st.count} · 획 ${strokes.length}개 · rev ${rev}`);
  send({ t: 'view', x: 0, y: 0, w: PAGE_W, h: 700 });
  await write(my);
}

async function write(my) {
  const start = strokes.length;
  for (let n = start; n < start + STROKES; n++) {
    if (my !== session) return;
    const stroke = makeStroke(n);
    const id = ++sid;
    const meta = { t: 'live', note: loaded.note, page: loaded.page, sid: id, tool: stroke.tool, color: stroke.color, width: stroke.width };
    for (let i = 0; i < stroke.pts.length; i += 8) {
      send({ ...meta, phase: i === 0 ? 'begin' : 'move', pts: stroke.pts.slice(i, i + 8) });
      await sleep(16);
    }
    send({ ...meta, phase: 'end', pts: [] });
    if (my !== session) return;

    strokes.push(stroke);
    rasterize(stroke);
    rev += 1;
    dirty = true;
    const b = bounds(stroke);
    send({ t: 'patch', note: loaded.note, page: loaded.page, rev, base: patchBase, ...b, png: crop(b).toString('base64') });
    patchBase = rev;

    // 아래로 내려가면 보고 있는 영역도 따라 내려간다
    const top = Math.max(0, Math.min(PAGE_H - 700, b.y - 300));
    send({ t: 'view', x: 0, y: top, w: PAGE_W, h: 700 });
    await sleep(140);
  }
  await sleep(600);
  if (my === session) await save();
}

async function save() {
  const target = loaded;
  dirty = false;
  const drawing = Buffer.from(JSON.stringify(strokes));
  const image = encodePng(pixels, W, H);
  const thumb = thumbnail();
  const url = `${BASE}/api/notes/${target.note}/pages/${target.page}/save?rev=${rev}&gen=${target.gen}&dlen=${drawing.length}&ilen=${image.length}`;
  const res = await fetch(url, { method: 'PUT', headers, body: Buffer.concat([drawing, image, thumb]) });
  console.log(`저장 rev ${rev} → ${res.status} (이미지 ${Math.round(image.length / 1024)}KB, 미리보기 ${Math.round(thumb.length / 1024)}KB)`);
}

function connect() {
  ws = new WebSocket(`ws://${HOST}:${PORT}/ws?role=pad&name=${encodeURIComponent('가짜 아이패드')}${CODE ? `&code=${CODE}` : ''}`);
  ws.on('open', () => console.log('연결됨'));
  ws.on('message', (raw) => {
    const m = JSON.parse(raw.toString());
    if (m.t === 'denied') {
      console.log(`거절됨: ${m.reason}`);
      process.exit(1);
    } else if (m.t === 'state') {
      const same = loaded && loaded.note === m.note.id && loaded.page === m.page.id && loaded.gen === m.page.gen;
      if (!same) loadPage(m).catch((e) => console.error(e));
    } else if (m.t === 'flush') {
      if (loaded && dirty) save().catch((e) => console.error(e));
    }
  });
  ws.on('close', () => {
    console.log('연결 끊김');
    process.exit(0);
  });
  ws.on('error', (e) => console.error(e.message));
}

connect();
