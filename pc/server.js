'use strict';
// 펜슬노트 노트북 프로그램
// - 아이패드 앱이 Wi-Fi로 보내는 필기를 받아 저장하고, 이 노트북의 브라우저 화면에 실시간으로 전달한다.
// - 화면(뷰어)은 이 노트북에서만 열 수 있다. (http, 이 PC 안에서만 접속 가능)
// - 아이패드는 암호화된 연결(TLS)로만 접속한다. 처음 한 번 연결 코드로 등록하면 기기 전용 비밀키를 받고,
//   그 뒤로는 비밀키로 인증한다. 아이패드는 이 노트북의 인증서를 기억해 두고 다른 인증서는 거부한다.

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');

const PORT = Number(process.env.PENCILNOTE_PORT) || 8787; // 노트북 화면용 (이 PC 전용)
const TLS_PORT = Number(process.env.PENCILNOTE_TLS_PORT) || PORT + 1; // 아이패드용 (암호화)
const DATA = path.resolve(process.env.PENCILNOTE_DATA || path.join(os.homedir(), 'Documents', 'PencilNote'));
const PUBLIC = path.join(__dirname, 'public');
const PAGES = path.join(DATA, 'pages');
const TRASH = path.join(DATA, 'trash');
const LIB_FILE = path.join(DATA, 'library.json');
const CONFIG_FILE = path.join(DATA, 'config.json');
const KEY_FILE = path.join(DATA, 'tls-key.pem');
const CERT_FILE = path.join(DATA, 'tls-cert.pem');
const MAX_DEVICES = 8;

const PAPERS = ['plain', 'ruled', 'grid', 'dot'];
const STATIC = new Set(['index.html', 'app.js', 'style.css', 'favicon.svg']);
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
};
const FILE_EXT = { drawing: 'drawing', image: 'png', thumb: 'thumb.png' };
const MAX_BODY = 64 * 1024 * 1024;
const ID_RE = /^[a-z0-9]{6,40}$/;

fs.mkdirSync(PAGES, { recursive: true });
fs.mkdirSync(TRASH, { recursive: true });

// ---------- 파일 ----------

function writeAtomic(file, data) {
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function stamp() {
  return new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
}

function pageFile(noteId, pageId, ext) {
  return path.join(PAGES, noteId, `${pageId}.${ext}`);
}

function putOrRemove(file, buf) {
  if (buf.length) writeAtomic(file, buf);
  else fs.rmSync(file, { force: true });
}

// 지운 것은 바로 없애지 않고 trash 폴더로 옮긴다.
function trashPage(noteId, pageId) {
  const dir = path.join(TRASH, `${stamp()}_${noteId}`);
  for (const ext of Object.values(FILE_EXT)) {
    const file = pageFile(noteId, pageId, ext);
    if (!fs.existsSync(file)) continue;
    fs.mkdirSync(dir, { recursive: true });
    fs.renameSync(file, path.join(dir, `${pageId}.${ext}`));
  }
}

function trashNote(note) {
  const dir = path.join(TRASH, `${stamp()}_${note.id}`);
  const src = path.join(PAGES, note.id);
  if (fs.existsSync(src)) fs.renameSync(src, dir);
  else fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'note.json'), JSON.stringify(note, null, 2));
}

// ---------- 설정 / 노트 목록 ----------

let config = readJson(CONFIG_FILE);
if (!config || !config.code || !config.id) {
  config = {
    id: crypto.randomUUID(),
    code: String(crypto.randomInt(0, 1000000)).padStart(6, '0'),
  };
  writeAtomic(CONFIG_FILE, JSON.stringify(config, null, 2));
}
if (!Array.isArray(config.devices)) config.devices = []; // 등록된 아이패드: { hash, name, added }

function saveConfig() {
  writeAtomic(CONFIG_FILE, JSON.stringify(config, null, 2));
}

function sha256(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

// 이 노트북만의 인증서. 한 번 만들어 계속 쓴다. (바뀌면 아이패드가 다시 등록해야 한다)
async function loadCertificate() {
  if (fs.existsSync(KEY_FILE) && fs.existsSync(CERT_FILE)) {
    return { key: fs.readFileSync(KEY_FILE), cert: fs.readFileSync(CERT_FILE) };
  }
  const selfsigned = require('selfsigned');
  const made = await selfsigned.generate([{ name: 'commonName', value: 'PencilNote' }], {
    keySize: 2048,
    algorithm: 'sha256',
    notAfterDate: new Date(Date.now() + 20 * 365 * 24 * 3600 * 1000),
  });
  writeAtomic(KEY_FILE, made.private);
  writeAtomic(CERT_FILE, made.cert);
  return { key: made.private, cert: made.cert };
}

function loadLibrary() {
  if (!fs.existsSync(LIB_FILE)) return { notes: [], current: null };
  try {
    const lib = JSON.parse(fs.readFileSync(LIB_FILE, 'utf8'));
    if (!lib || !Array.isArray(lib.notes)) throw new Error('형식이 다름');
    return lib;
  } catch (e) {
    const backup = LIB_FILE.replace(/\.json$/, `.broken-${stamp()}.json`);
    fs.copyFileSync(LIB_FILE, backup);
    console.error(`노트 목록 파일을 읽지 못해 새로 시작합니다. 원본은 여기에 보관했어요: ${backup}`);
    return { notes: [], current: null };
  }
}

const lib = loadLibrary();
let saveTimer = null;

function saveLibNow() {
  clearTimeout(saveTimer);
  saveTimer = null;
  writeAtomic(LIB_FILE, JSON.stringify(lib, null, 2));
}

function saveLibSoon() {
  if (!saveTimer) saveTimer = setTimeout(saveLibNow, 200);
}

function newId() {
  return crypto.randomBytes(6).toString('hex');
}

function newPage(paper) {
  return { id: newId(), paper: PAPERS.includes(paper) ? paper : 'ruled', rev: 0, gen: 0 };
}

function createNote(title) {
  const now = Date.now();
  const note = { id: newId(), title: cleanTitle(title), created: now, updated: now, pages: [newPage()] };
  lib.notes.unshift(note);
  return note;
}

function cleanTitle(title) {
  const t = String(title == null ? '' : title).replace(/\s+/g, ' ').trim().slice(0, 80);
  return t || '제목 없는 노트';
}

function findNote(id) {
  return lib.notes.find((n) => n.id === id);
}

function findPage(note, id) {
  return note.pages.find((p) => p.id === id);
}

function setCurrent(note, page) {
  lib.current = { note: note.id, page: page.id };
  note.last = page.id;
  saveLibSoon();
}

// 열려 있는 노트/페이지가 항상 하나 있도록 맞춘다.
function ensureCurrent() {
  if (!lib.notes.length) createNote('첫 노트');
  const note = (lib.current && findNote(lib.current.note)) || lib.notes[0];
  const page = (lib.current && findPage(note, lib.current.page)) || findPage(note, note.last) || note.pages[0];
  if (!lib.current || lib.current.note !== note.id || lib.current.page !== page.id) setCurrent(note, page);
}

ensureCurrent();

// ---------- 주소 ----------

function lanAddresses() {
  const out = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family !== 'IPv4' || a.internal || a.address.startsWith('169.254.')) continue;
      const virtual = /vEthernet|VirtualBox|VMware|Hyper-V|WSL|Loopback|Bluetooth|Tailscale|ZeroTier|docker|TAP|VPN/i.test(name);
      const wifi = /Wi-?Fi|WLAN|무선/i.test(name);
      out.push({ name, address: a.address, virtual, wifi });
    }
  }
  out.sort((a, b) => a.virtual - b.virtual || b.wifi - a.wifi);
  return out;
}

// ---------- 접근 확인 ----------

function remoteIp(req) {
  return String(req.socket.remoteAddress || '').replace(/^::ffff:/, '');
}

const LOCAL_HOST_RE = /^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/i;
const LOCAL_ORIGIN_RE = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/i;

// 이 노트북에서 직접 연 요청인지. (다른 웹사이트가 몰래 보내는 요청은 Host/Origin으로 걸러낸다)
function localOk(req) {
  const ip = remoteIp(req);
  if (ip !== '127.0.0.1' && ip !== '::1') return false;
  if (!LOCAL_HOST_RE.test(String(req.headers.host || ''))) return false;
  const origin = req.headers.origin;
  if (origin && !LOCAL_ORIGIN_RE.test(origin)) return false;
  return true;
}

const fails = new Map();
const MAX_FAILS = 10;
const LOCK_MS = 5 * 60 * 1000;

// 'ok' | 'none' | 'bad' | 'locked'
function checkCode(req, url) {
  const ip = remoteIp(req);
  const f = fails.get(ip);
  if (f && f.until > Date.now()) return 'locked';
  const given = String(req.headers['x-code'] || url.searchParams.get('code') || '').replace(/\D/g, '');
  if (!given) return 'none';
  const a = Buffer.from(given);
  const b = Buffer.from(config.code);
  if (a.length === b.length && crypto.timingSafeEqual(a, b)) {
    fails.delete(ip);
    return 'ok';
  }
  const n = ((f && f.n) || 0) + 1;
  fails.set(ip, n >= MAX_FAILS ? { n: 0, until: Date.now() + LOCK_MS } : { n, until: 0 });
  return 'bad';
}

// 등록된 아이패드가 보내는 비밀키 확인
function tokenOk(req, url) {
  const token = String(req.headers['x-token'] || url.searchParams.get('token') || '');
  if (token.length < 32) return false;
  const hash = sha256(token);
  return config.devices.some((d) => d.hash === hash);
}

// ---------- 실시간 연결 ----------

const wss = new WebSocketServer({ noServer: true, maxPayload: 32 * 1024 * 1024 });
const viewers = new Set();
let pad = null; // { ws, name }
let padView = null; // 아이패드가 지금 보고 있는 영역 (마지막으로 받은 메시지 원문)

function viewState() {
  return {
    t: 'state',
    notes: lib.notes.map((n) => ({
      id: n.id,
      title: n.title,
      updated: n.updated,
      pages: n.pages.map((p) => ({ id: p.id, paper: p.paper, rev: p.rev, gen: p.gen || 0 })),
    })),
    current: lib.current,
    pad: pad ? { name: pad.name } : null,
    addrs: lanAddresses(),
    port: TLS_PORT,
    code: config.code,
    devices: config.devices.length,
    host: os.hostname(),
    dataDir: DATA,
  };
}

function padState() {
  const note = findNote(lib.current.note);
  const index = note.pages.findIndex((p) => p.id === lib.current.page);
  const page = note.pages[index];
  return {
    t: 'state',
    note: { id: note.id, title: note.title },
    page: { id: page.id, paper: page.paper, rev: page.rev, gen: page.gen || 0 },
    index,
    count: note.pages.length,
  };
}

function sendTo(ws, text) {
  if (ws.readyState === 1) ws.send(text);
}

function toViewers(obj) {
  const text = typeof obj === 'string' ? obj : JSON.stringify(obj);
  for (const ws of viewers) sendTo(ws, text);
}

function toPad(obj) {
  if (pad) sendTo(pad.ws, JSON.stringify(obj));
}

function pushState() {
  toViewers(viewState());
  if (pad) toPad(padState());
}

function addViewer(ws) {
  viewers.add(ws);
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
  ws.on('close', () => viewers.delete(ws));
  ws.on('error', () => {});
  sendTo(ws, JSON.stringify(viewState()));
  if (pad && padView) sendTo(ws, padView);
  // 새로 연 화면이 최신 필기를 받도록 아이패드에 저장을 요청한다.
  toPad({ t: 'flush' });
}

function addPad(ws, name) {
  if (pad && pad.ws !== ws) {
    sendTo(pad.ws, JSON.stringify({ t: 'denied', reason: 'replaced' }));
    pad.ws.close(4002, 'replaced');
  }
  pad = { ws, name: String(name || 'iPad').slice(0, 40) };
  padView = null;
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
  ws.on('message', (raw, isBinary) => {
    if (!isBinary && pad && pad.ws === ws) onPadMessage(raw.toString());
  });
  ws.on('close', () => {
    if (pad && pad.ws === ws) {
      pad = null;
      padView = null;
      pushState();
    }
  });
  ws.on('error', () => {});
  pushState();
}

function onPadMessage(text) {
  let m;
  try {
    m = JSON.parse(text);
  } catch {
    return;
  }
  if (!m || typeof m !== 'object') return;
  switch (m.t) {
    case 'patch':
    case 'live':
      toViewers(text);
      break;
    case 'view':
      padView = text;
      toViewers(text);
      break;
    case 'cmd':
      onPadCommand(m.cmd);
      break;
  }
}

function onPadCommand(cmd) {
  const note = findNote(lib.current.note);
  const index = note.pages.findIndex((p) => p.id === lib.current.page);
  if (cmd === 'prev' && index > 0) setCurrent(note, note.pages[index - 1]);
  else if (cmd === 'next' && index < note.pages.length - 1) setCurrent(note, note.pages[index + 1]);
  else if (cmd === 'add') setCurrent(note, addPage(note, note.pages[index].id));
  else return;
  pushState();
}

function addPage(note, afterId) {
  let index = note.pages.findIndex((p) => p.id === afterId);
  if (index < 0) index = note.pages.length - 1;
  const page = newPage(note.pages[index] ? note.pages[index].paper : 'ruled');
  note.pages.splice(index + 1, 0, page);
  note.updated = Date.now();
  return page;
}

setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) {
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    ws.ping();
  }
}, 15000);

// ---------- HTTP ----------

function send(res, status, body, headers) {
  res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', ...headers });
  res.end(body);
}

function json(res, obj, status = 200) {
  send(res, status, JSON.stringify(obj), { 'Content-Type': 'application/json; charset=utf-8' });
}

function fail(status, error) {
  return Object.assign(new Error(error), { status });
}

function readBody(req, limit = MAX_BODY) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(fail(413, 'too large'));
        req.destroy();
      } else {
        chunks.push(c);
      }
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function readJsonBody(req) {
  const body = await readBody(req, 1024 * 1024);
  if (!body.length) return {};
  try {
    const obj = JSON.parse(body.toString('utf8'));
    return obj && typeof obj === 'object' ? obj : {};
  } catch {
    throw fail(400, 'bad json');
  }
}

function intParam(url, name) {
  const v = Number(url.searchParams.get(name));
  if (!Number.isInteger(v) || v < 0) throw fail(400, `bad ${name}`);
  return v;
}

async function handle(req, res) {
  const url = new URL(req.url, 'http://local');
  const seg = url.pathname.split('/').filter(Boolean);
  const method = req.method;

  // 아이패드가 같은 Wi-Fi에서 이 노트북을 찾을 때 쓰는 주소. 내용은 이름뿐이라 누구나 볼 수 있다.
  if (url.pathname === '/ping') {
    return json(res, { app: 'pencilnote', v: 1, id: config.id, name: os.hostname() });
  }

  const local = localOk(req);

  if (seg[0] !== 'api') {
    if (!local) return send(res, 403, '이 주소는 펜슬노트 아이패드 앱 전용입니다. 화면은 노트북에서 http://localhost:' + PORT + ' 로 여세요.');
    if (method !== 'GET') return send(res, 405, 'method not allowed');
    const name = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
    if (!STATIC.has(name)) return send(res, 404, 'not found');
    const data = fs.readFileSync(path.join(PUBLIC, name));
    res.writeHead(200, { 'Content-Type': MIME[path.extname(name)], 'Cache-Control': 'no-store' });
    return res.end(data);
  }

  // 처음 등록: 연결 코드가 맞으면 이 아이패드 전용 비밀키를 만들어 준다.
  if (seg[1] === 'pair' && method === 'POST') {
    const verdict = checkCode(req, url);
    if (verdict !== 'ok') return json(res, { error: verdict }, verdict === 'locked' ? 429 : 401);
    const body = await readJsonBody(req);
    const token = crypto.randomBytes(32).toString('hex');
    config.devices.push({ hash: sha256(token), name: String(body.name || 'iPad').slice(0, 40), added: Date.now() });
    while (config.devices.length > MAX_DEVICES) config.devices.shift();
    saveConfig();
    pushState();
    return json(res, { token, id: config.id, name: os.hostname() });
  }

  if (!local && !tokenOk(req, url)) return json(res, { error: 'token' }, 401);

  // --- 페이지 파일: 아이패드와 노트북 화면 둘 다 사용 ---
  if (seg[1] === 'notes' && seg[3] === 'pages' && seg.length === 6 && ID_RE.test(seg[2]) && ID_RE.test(seg[4])) {
    const note = findNote(seg[2]);
    const page = note && findPage(note, seg[4]);
    if (!page) return json(res, { error: 'not found' }, 404);
    const kind = seg[5];

    if (method === 'GET' && FILE_EXT[kind]) {
      const headers = { 'X-Rev': String(page.rev), 'X-Gen': String(page.gen || 0), 'Cache-Control': 'no-store' };
      let data = null;
      try {
        data = fs.readFileSync(pageFile(note.id, page.id, FILE_EXT[kind]));
      } catch {
        data = null;
      }
      if (!data || !data.length) {
        res.writeHead(204, headers);
        return res.end();
      }
      res.writeHead(200, {
        ...headers,
        'Content-Type': kind === 'drawing' ? 'application/octet-stream' : 'image/png',
        'Content-Length': data.length,
      });
      return res.end(data);
    }

    // 본문 = 필기 원본(dlen 바이트) + 페이지 이미지(ilen 바이트) + 작은 미리보기(나머지)
    if (method === 'PUT' && kind === 'save') {
      const rev = intParam(url, 'rev');
      const gen = intParam(url, 'gen');
      const dlen = intParam(url, 'dlen');
      const ilen = intParam(url, 'ilen');
      const body = await readBody(req);
      if (body.length < dlen + ilen) throw fail(400, 'short body');
      // 본문을 받는 사이에 페이지가 지워졌거나 비워졌으면 저장하지 않는다.
      if (!findNote(note.id) || !findPage(note, page.id)) return json(res, { error: 'not found' }, 404);
      if (gen !== (page.gen || 0)) return json(res, { error: 'stale' }, 409);
      fs.mkdirSync(path.join(PAGES, note.id), { recursive: true });
      putOrRemove(pageFile(note.id, page.id, FILE_EXT.drawing), body.subarray(0, dlen));
      putOrRemove(pageFile(note.id, page.id, FILE_EXT.image), body.subarray(dlen, dlen + ilen));
      putOrRemove(pageFile(note.id, page.id, FILE_EXT.thumb), body.subarray(dlen + ilen));
      page.rev = rev;
      note.updated = Date.now();
      saveLibSoon();
      toViewers({ t: 'saved', note: note.id, page: page.id, rev, updated: note.updated });
      return json(res, { ok: true });
    }

    if (!local) return json(res, { error: 'forbidden' }, 403);

    if (method === 'POST' && kind === 'clear') {
      trashPage(note.id, page.id);
      page.gen = (page.gen || 0) + 1;
      page.rev += 1;
      note.updated = Date.now();
      saveLibSoon();
      pushState();
      return json(res, { ok: true });
    }

    if (method === 'POST' && kind === 'move') {
      const body = await readJsonBody(req);
      const from = note.pages.indexOf(page);
      const to = from + (body.dir < 0 ? -1 : 1);
      if (to < 0 || to >= note.pages.length) return json(res, { ok: true });
      note.pages.splice(from, 1);
      note.pages.splice(to, 0, page);
      note.updated = Date.now();
      saveLibSoon();
      pushState();
      return json(res, { ok: true });
    }

    return json(res, { error: 'not found' }, 404);
  }

  // --- 여기부터는 노트북 화면 전용 ---
  if (!local) return json(res, { error: 'forbidden' }, 403);

  if (seg[1] === 'state' && method === 'GET') return json(res, viewState());

  // 등록된 아이패드를 모두 해제하고 연결 코드도 새로 만든다.
  if (seg[1] === 'unpair' && method === 'POST') {
    config.devices = [];
    config.code = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
    saveConfig();
    if (pad) pad.ws.close(4003, 'unpaired');
    pushState();
    return json(res, { ok: true });
  }

  if (seg[1] === 'flush' && method === 'POST') {
    toPad({ t: 'flush' });
    return json(res, { ok: true });
  }

  if (seg[1] === 'open' && method === 'POST') {
    const body = await readJsonBody(req);
    const note = findNote(body.note);
    if (!note) return json(res, { error: 'not found' }, 404);
    const page = findPage(note, body.page) || findPage(note, note.last) || note.pages[0];
    setCurrent(note, page);
    pushState();
    return json(res, { ok: true });
  }

  if (seg[1] === 'notes' && seg.length === 2 && method === 'POST') {
    const body = await readJsonBody(req);
    const note = createNote(body.title);
    setCurrent(note, note.pages[0]);
    pushState();
    return json(res, { ok: true, id: note.id });
  }

  if (seg[1] === 'notes' && seg.length >= 3 && ID_RE.test(seg[2])) {
    const note = findNote(seg[2]);
    if (!note) return json(res, { error: 'not found' }, 404);

    if (seg.length === 3 && method === 'PATCH') {
      const body = await readJsonBody(req);
      note.title = cleanTitle(body.title);
      saveLibSoon();
      pushState();
      return json(res, { ok: true });
    }

    if (seg.length === 3 && method === 'DELETE') {
      trashNote(note);
      lib.notes.splice(lib.notes.indexOf(note), 1);
      ensureCurrent();
      saveLibSoon();
      pushState();
      return json(res, { ok: true });
    }

    if (seg.length === 4 && seg[3] === 'pages' && method === 'POST') {
      const body = await readJsonBody(req);
      const page = addPage(note, body.after);
      setCurrent(note, page);
      pushState();
      return json(res, { ok: true, id: page.id });
    }

    if (seg.length === 5 && seg[3] === 'pages' && ID_RE.test(seg[4])) {
      const page = findPage(note, seg[4]);
      if (!page) return json(res, { error: 'not found' }, 404);

      if (method === 'PATCH') {
        const body = await readJsonBody(req);
        if (!PAPERS.includes(body.paper)) return json(res, { error: 'bad paper' }, 400);
        page.paper = body.paper;
        saveLibSoon();
        pushState();
        return json(res, { ok: true });
      }

      if (method === 'DELETE') {
        if (note.pages.length <= 1) return json(res, { error: 'last page' }, 400);
        const index = note.pages.indexOf(page);
        trashPage(note.id, page.id);
        note.pages.splice(index, 1);
        note.updated = Date.now();
        if (lib.current.note === note.id && lib.current.page === page.id) {
          setCurrent(note, note.pages[Math.min(index, note.pages.length - 1)]);
        }
        saveLibSoon();
        pushState();
        return json(res, { ok: true });
      }
    }
  }

  return json(res, { error: 'not found' }, 404);
}

function onRequest(req, res) {
  handle(req, res).catch((e) => {
    if (!e.status) console.error(e);
    if (!res.headersSent) json(res, { error: e.status ? e.message : 'server error' }, e.status || 500);
    else res.end();
  });
}

function onUpgrade(req, socket, head) {
  const url = new URL(req.url, 'http://local');
  const role = url.searchParams.get('role');
  if (url.pathname !== '/ws' || (role !== 'view' && role !== 'pad')) return socket.destroy();

  if (role === 'view') {
    if (!localOk(req)) return socket.destroy();
    return wss.handleUpgrade(req, socket, head, addViewer);
  }

  // 아이패드: 비밀키가 틀려도 일단 연결을 받은 뒤 이유를 알려 주고 끊는다. (앱이 안내 문구를 띄울 수 있게)
  const verdict = localOk(req) || tokenOk(req, url) ? 'ok' : 'token';
  wss.handleUpgrade(req, socket, head, (ws) => {
    if (verdict !== 'ok') {
      ws.on('error', () => {});
      ws.send(JSON.stringify({ t: 'denied', reason: verdict }));
      return ws.close(4001, verdict);
    }
    addPad(ws, url.searchParams.get('name'));
  });
}

function onListenError(e) {
  if (e.code === 'EADDRINUSE') {
    console.log(`펜슬노트가 이미 실행 중입니다. 브라우저에서 http://localhost:${PORT} 를 여세요.`);
    process.exit(0);
  }
  throw e;
}

function listen(server, port, host) {
  return new Promise((resolve) => {
    server.on('request', onRequest);
    server.on('upgrade', onUpgrade);
    server.on('error', onListenError);
    server.listen(port, host, resolve);
  });
}

async function main() {
  const tls = await loadCertificate();
  const fingerprint = new crypto.X509Certificate(tls.cert).fingerprint256;

  // 노트북 화면: 이 PC 안에서만 열리는 주소에만 연다.
  await listen(http.createServer(), PORT, '127.0.0.1');
  const v6 = http.createServer();
  v6.on('request', onRequest);
  v6.on('upgrade', onUpgrade);
  v6.on('error', () => {}); // IPv6가 꺼진 PC에서는 그냥 넘어간다
  v6.listen(PORT, '::1');

  // 아이패드: 암호화된 연결만 받는다.
  await listen(https.createServer({ key: tls.key, cert: tls.cert, minVersion: 'TLSv1.2' }), TLS_PORT);

  const addrs = lanAddresses().filter((a) => !a.virtual);
  console.log('');
  console.log('  펜슬노트 실행 중  (이 창을 닫으면 종료됩니다)');
  console.log('');
  console.log(`  노트북 화면   http://localhost:${PORT}`);
  console.log(`  아이패드 주소 ${addrs.length ? addrs.map((a) => a.address).join('  또는  ') : '(Wi-Fi에 연결되어 있지 않음)'}`);
  console.log(`  연결 코드     ${config.code.slice(0, 3)} ${config.code.slice(3)}  (처음 한 번만 필요)`);
  console.log(`  등록된 기기   ${config.devices.length}대`);
  console.log(`  저장 위치     ${DATA}`);
  console.log(`  인증서 지문   ${fingerprint.split(':').slice(0, 8).join(':')}...`);
  console.log('');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

function shutdown() {
  if (saveTimer) saveLibNow();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
process.on('SIGHUP', shutdown);
