(() => {
'use strict';

// 페이지 크기(포인트). 아이패드 앱의 Page.width / Page.height 와 같아야 한다.
const PAGE_W = 1024;
const PAGE_H = 1448;
const S = 2; // 캔버스 해상도 배율
const MARGIN = 28;

const ICONS = {
  plus: 'M12 5v14M5 12h14',
  left: 'M15 6l-6 6 6 6',
  right: 'M9 6l6 6-6 6',
  up: 'M6 15l6-6 6 6',
  down: 'M6 9l6 6 6-6',
  trash: 'M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3',
  download: 'M12 4v11M7 11l5 5 5-5M5 20h14',
  print: 'M7 9V4h10v5M7 17H5a2 2 0 0 1-2-2v-4a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2h-2M7 14h10v6H7z',
  expand: 'M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5',
  shrink: 'M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5',
  eraser: 'M5 20h14M8 17l-3.6-3.6a2 2 0 0 1 0-2.8l6.2-6.2a2 2 0 0 1 2.8 0l4.2 4.2a2 2 0 0 1 0 2.8L12 17z',
  menu: 'M4 6h16M4 12h16M4 18h16',
  pages: 'M8 3h11v14H8zM5 7v14h11',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
};

const $ = (sel) => document.querySelector(sel);

function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === 'class') node.className = v;
    else node.setAttribute(k, v);
  }
  node.append(...children);
  return node;
}

function icon(name) {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS(NS, 'path');
  path.setAttribute('d', ICONS[name]);
  svg.append(path);
  return svg;
}

for (const slot of document.querySelectorAll('[data-icon]')) slot.replaceWith(icon(slot.dataset.icon));

const appEl = $('#app');
const stageEl = $('#stage');
const pageEl = $('#page');
const canvases = { paper: $('#paper'), ink: $('#ink'), live: $('#live') };
for (const c of Object.values(canvases)) {
  c.width = PAGE_W * S;
  c.height = PAGE_H * S;
}
const paperCtx = canvases.paper.getContext('2d');
const inkCtx = canvases.ink.getContext('2d');
const liveCtx = canvases.live.getContext('2d');

let state = null; // 서버가 보내 준 전체 상태
let shown = null; // 지금 화면에 띄운 페이지 { note, page, gen }
let shownPaper = null;
let shownRev = -1; // 화면의 필기가 반영하고 있는 버전
let needFull = false; // 중간 조각을 놓쳐서 전체 이미지를 다시 받아야 하는지
let recent = []; // 최근에 받은 조각 (전체 이미지를 다시 그린 뒤 덧그리기용)
let chain = Promise.resolve(); // 그리기 작업을 순서대로 처리
let loadToken = 0;
let padView = null; // 아이패드가 보고 있는 영역
let liveStroke = null; // 쓰는 중인 획
let liveFrame = 0;
let viewMode = localStorage.getItem('pencilnote.view') === 'page' ? 'page' : 'follow';

// ---------- 서버와 통신 ----------

async function api(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}

function run(promise) {
  promise.catch((e) => console.error(e));
}

function connect() {
  const ws = new WebSocket(`ws://${location.host}/ws?role=view`);
  ws.onopen = () => { $('#offline').hidden = true; };
  ws.onmessage = (e) => {
    let m;
    try {
      m = JSON.parse(e.data);
    } catch {
      return;
    }
    if (m.t === 'state') onState(m);
    else if (m.t === 'patch') onPatch(m);
    else if (m.t === 'live') onLive(m);
    else if (m.t === 'view') onView(m);
    else if (m.t === 'saved') onSaved(m);
  };
  ws.onclose = () => {
    $('#offline').hidden = false;
    setTimeout(connect, 1000);
  };
}

// ---------- 상태 ----------

function noteById(id) {
  return state.notes.find((n) => n.id === id);
}

function curNote() {
  return noteById(state.current.note);
}

function pageInfo(noteId, pageId) {
  const note = noteById(noteId);
  return note && note.pages.find((p) => p.id === pageId);
}

function curIndex() {
  return curNote().pages.findIndex((p) => p.id === state.current.page);
}

function onState(s) {
  state = s;
  if (!s.pad) {
    padView = null;
    clearLive();
  }
  renderNotes();
  renderToolbar();
  renderThumbs();
  renderPad();

  const cur = s.current;
  const page = pageInfo(cur.note, cur.page);
  if (!shown || shown.note !== cur.note || shown.page !== cur.page || shown.gen !== page.gen) {
    shown = { note: cur.note, page: cur.page, gen: page.gen };
    recent = [];
    shownRev = -1;
    needFull = false;
    clearLive();
    inkCtx.clearRect(0, 0, PAGE_W * S, PAGE_H * S);
    loadFull();
  }
  if (shownPaper !== page.paper) {
    shownPaper = page.paper;
    drawPaper(paperCtx, page.paper, S);
  }
  layout(false);
}

function onSaved(m) {
  const note = noteById(m.note);
  const page = pageInfo(m.note, m.page);
  if (!page) return;
  page.rev = m.rev;
  note.updated = m.updated;
  renderNotes();
  renderThumbs();
  // 저장될 때마다 전체 이미지로 다시 맞춘다. 조각이 어긋났더라도 여기서 바로잡힌다.
  if (shown && m.note === shown.note && m.page === shown.page && (needFull || m.rev >= shownRev)) loadFull();
}

// ---------- 필기 표시 ----------

function loadFull() {
  const token = ++loadToken;
  const target = shown;
  chain = chain.then(async () => {
    if (token !== loadToken) return;
    let bitmap = null;
    let rev = 0;
    try {
      const res = await fetch(`/api/notes/${target.note}/pages/${target.page}/image?t=${Date.now()}`);
      if (!res.ok) return;
      rev = Number(res.headers.get('X-Rev')) || 0;
      if (res.status === 200) bitmap = await createImageBitmap(await res.blob());
    } catch (e) {
      console.error(e);
      return;
    }
    if (token !== loadToken) return;
    inkCtx.clearRect(0, 0, PAGE_W * S, PAGE_H * S);
    if (bitmap) {
      inkCtx.drawImage(bitmap, 0, 0, PAGE_W * S, PAGE_H * S);
      bitmap.close();
    }
    shownRev = rev;
    needFull = false;
    recent = recent.filter((p) => p.rev > rev);
    for (const p of recent) await drawPatch(p);
  }).catch((e) => console.error(e));
}

function onPatch(m) {
  if (!shown || m.note !== shown.note || m.page !== shown.page) return;
  recent.push(m);
  if (recent.length > 120) recent.shift();
  chain = chain.then(() => drawPatch(m)).catch((e) => console.error(e));
}

async function decodePng(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return createImageBitmap(new Blob([bytes], { type: 'image/png' }));
}

// 조각 = "이 사각형 영역은 지금 이렇게 생겼다". 해당 영역을 지우고 받은 그림으로 바꾼다.
async function drawPatch(m) {
  if (!shown || m.note !== shown.note || m.page !== shown.page) return;
  if (m.rev <= shownRev) return;
  const gap = shownRev >= 0 && m.base > shownRev;
  if (m.w > 0 && m.h > 0) {
    const bitmap = m.png ? await decodePng(m.png) : null;
    if (!shown || m.note !== shown.note || m.page !== shown.page) return;
    inkCtx.clearRect(m.x * S, m.y * S, m.w * S, m.h * S);
    if (bitmap) {
      inkCtx.drawImage(bitmap, m.x * S, m.y * S, m.w * S, m.h * S);
      bitmap.close();
    }
  }
  shownRev = m.rev;
  if (liveStroke && liveStroke.ended) clearLive();
  if (gap && !needFull) {
    needFull = true;
    run(api('POST', '/api/flush'));
  }
}

// 쓰는 중인 획: 펜을 떼기 전까지 임시로 그려 두고, 완성된 조각이 오면 지운다.
function onLive(m) {
  if (!shown || m.note !== shown.note || m.page !== shown.page) return;
  if (!liveStroke || liveStroke.sid !== m.sid) {
    clearLive();
    liveStroke = { sid: m.sid, tool: m.tool, color: m.color || '#000000', width: m.width || 3, pts: [], ended: false, box: null };
  }
  if (Array.isArray(m.pts)) liveStroke.pts.push(...m.pts);
  if (m.phase === 'end') {
    liveStroke.ended = true;
    const sid = m.sid;
    setTimeout(() => {
      if (liveStroke && liveStroke.sid === sid) clearLive();
    }, 800);
  }
  if (!liveFrame) liveFrame = requestAnimationFrame(drawLive);
}

function clearLive() {
  if (liveStroke && liveStroke.box) eraseBox(liveStroke.box);
  liveStroke = null;
}

function eraseBox(b) {
  liveCtx.clearRect(b.x * S, b.y * S, b.w * S, b.h * S);
}

function drawLive() {
  liveFrame = 0;
  const s = liveStroke;
  if (!s) return;
  if (s.box) eraseBox(s.box);
  const pts = s.pts;
  if (pts.length < 2) return;

  const pointer = s.tool === 'eraser' || s.tool === 'lasso';
  const width = pointer ? 2 : Math.max(1, s.width);
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;

  liveCtx.save();
  liveCtx.scale(S, S);
  liveCtx.lineCap = 'round';
  liveCtx.lineJoin = 'round';
  if (pointer) {
    // 지우개/올가미는 선을 남기지 않으므로 위치만 동그라미로 표시
    const x = pts[pts.length - 2];
    const y = pts[pts.length - 1];
    const r = s.tool === 'eraser' ? 12 : 6;
    liveCtx.strokeStyle = 'rgba(60, 60, 60, .55)';
    liveCtx.lineWidth = 1.5;
    liveCtx.beginPath();
    liveCtx.arc(x, y, r, 0, Math.PI * 2);
    liveCtx.stroke();
    x0 = x - r; y0 = y - r; x1 = x + r; y1 = y + r;
  } else {
    liveCtx.strokeStyle = s.color;
    liveCtx.globalAlpha = s.tool === 'marker' ? 0.35 : 1;
    liveCtx.lineWidth = width;
    liveCtx.beginPath();
    liveCtx.moveTo(pts[0], pts[1]);
    for (let i = 0; i < pts.length; i += 2) {
      const x = pts[i];
      const y = pts[i + 1];
      liveCtx.lineTo(x, y);
      if (x < x0) x0 = x;
      if (y < y0) y0 = y;
      if (x > x1) x1 = x;
      if (y > y1) y1 = y;
    }
    liveCtx.stroke();
  }
  liveCtx.restore();

  const pad = width + 3;
  const bx = Math.floor(x0 - pad);
  const by = Math.floor(y0 - pad);
  s.box = { x: bx, y: by, w: Math.ceil(x1 + pad) - bx, h: Math.ceil(y1 + pad) - by };
}

// 종이 무늬. 아이패드 앱의 PaperView 와 같은 위치에 같은 선을 그린다.
function drawPaper(ctx, kind, scale) {
  ctx.save();
  ctx.setTransform(scale, 0, 0, scale, 0, 0);
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, PAGE_W, PAGE_H);
  if (kind === 'ruled') {
    ctx.strokeStyle = 'rgba(70, 110, 170, 0.30)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let y = 132; y <= PAGE_H - 44; y += 44) {
      ctx.moveTo(0, y);
      ctx.lineTo(PAGE_W, y);
    }
    ctx.stroke();
  } else if (kind === 'grid') {
    ctx.strokeStyle = 'rgba(70, 110, 170, 0.22)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let y = 32; y < PAGE_H; y += 32) {
      ctx.moveTo(0, y);
      ctx.lineTo(PAGE_W, y);
    }
    for (let x = 32; x < PAGE_W; x += 32) {
      ctx.moveTo(x, 0);
      ctx.lineTo(x, PAGE_H);
    }
    ctx.stroke();
  } else if (kind === 'dot') {
    ctx.fillStyle = 'rgba(60, 80, 110, 0.40)';
    for (let y = 32; y < PAGE_H; y += 32) {
      for (let x = 32; x < PAGE_W; x += 32) {
        ctx.beginPath();
        ctx.arc(x, y, 1.5, 0, Math.PI * 2);
        ctx.fill();
      }
    }
  }
  ctx.restore();
}

// ---------- 화면 배치 ----------

function onView(m) {
  if (!(m.w > 0 && m.h > 0)) return;
  padView = m;
  layout(true);
}

// 보여 줄 영역(페이지 좌표)을 무대에 꽉 차게 맞춘다.
function layout(smooth) {
  const sw = stageEl.clientWidth;
  const sh = stageEl.clientHeight;
  if (!sw || !sh) return;
  const following = viewMode === 'follow' && padView && state && state.pad;
  const v = following
    ? padView
    : { x: -MARGIN, y: -MARGIN, w: PAGE_W + MARGIN * 2, h: PAGE_H + MARGIN * 2 };
  const k = Math.min(sw / v.w, sh / v.h);
  const tx = (sw - v.w * k) / 2 - v.x * k;
  const ty = (sh - v.h * k) / 2 - v.y * k;
  pageEl.classList.toggle('smooth', !!smooth);
  pageEl.style.transform = `translate(${tx.toFixed(2)}px, ${ty.toFixed(2)}px) scale(${k.toFixed(5)})`;
}

new ResizeObserver(() => layout(false)).observe(stageEl);

function setViewMode(mode) {
  viewMode = mode;
  localStorage.setItem('pencilnote.view', mode);
  renderToolbar();
  layout(true);
}

function setFocus(on) {
  appEl.classList.toggle('focus', on);
  $('#exitFocus').hidden = !on;
  if (on && !document.fullscreenElement) run(document.documentElement.requestFullscreen());
  if (!on && document.fullscreenElement) run(document.exitFullscreen());
}

document.addEventListener('fullscreenchange', () => {
  if (!document.fullscreenElement) setFocus(false);
});

// ---------- 그리기: 목록과 도구 ----------

function fmtDate(ms) {
  const d = new Date(ms);
  const now = new Date();
  const hm = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  if (d.toDateString() === now.toDateString()) return `오늘 ${hm}`;
  if (d.getFullYear() === now.getFullYear()) return `${d.getMonth() + 1}월 ${d.getDate()}일`;
  return `${d.getFullYear()}. ${d.getMonth() + 1}. ${d.getDate()}.`;
}

function renderNotes() {
  const list = $('#noteList');
  list.textContent = '';
  for (const n of state.notes) {
    const item = el('li', { class: n.id === state.current.note ? 'note active' : 'note' },
      el('div', { class: 'note-title' }, n.title),
      el('div', { class: 'note-meta' }, `${n.pages.length}쪽 · ${fmtDate(n.updated)}`));
    item.addEventListener('click', () => run(api('POST', '/api/open', { note: n.id })));
    const del = el('button', { class: 'mini danger', type: 'button', title: '노트 삭제' }, icon('trash'));
    del.addEventListener('click', (e) => {
      e.stopPropagation();
      if (confirm(`"${n.title}" 노트를 삭제할까요?\n(파일은 저장 폴더의 trash 폴더로 옮겨집니다)`)) run(api('DELETE', `/api/notes/${n.id}`));
    });
    item.append(del);
    list.append(item);
  }
}

function renderToolbar() {
  if (!state) return;
  const note = curNote();
  const index = curIndex();
  const title = $('#title');
  if (document.activeElement !== title) title.value = note.title;
  $('#pageLabel').textContent = `${index + 1} / ${note.pages.length}`;
  $('#prevPage').disabled = index <= 0;
  $('#nextPage').disabled = index >= note.pages.length - 1;
  for (const b of document.querySelectorAll('#paperSeg button')) b.classList.toggle('on', b.dataset.paper === note.pages[index].paper);
  for (const b of document.querySelectorAll('#viewSeg button')) b.classList.toggle('on', b.dataset.view === viewMode);
}

const thumbEls = new Map(); // pageId -> { root, img, num, up, down, del, rev, gen }

function makeThumb(noteId, pageId) {
  const img = el('img', { alt: '', hidden: '' });
  img.addEventListener('load', () => { img.hidden = false; });
  img.addEventListener('error', () => { img.hidden = true; });
  const num = el('span', { class: 'num' });
  const up = el('span', { class: 'mini', role: 'button', tabindex: '0', title: '위로 옮기기' }, icon('up'));
  const down = el('span', { class: 'mini', role: 'button', tabindex: '0', title: '아래로 옮기기' }, icon('down'));
  const del = el('span', { class: 'mini danger', role: 'button', tabindex: '0', title: '페이지 삭제' }, icon('trash'));
  const root = el('button', { class: 'thumb', type: 'button' }, img, num, el('span', { class: 'tools' }, up, down, del));

  const base = `/api/notes/${noteId}/pages/${pageId}`;
  root.addEventListener('click', () => run(api('POST', '/api/open', { note: noteId, page: pageId })));
  const act = (node, fn) => {
    const go = (e) => {
      e.stopPropagation();
      e.preventDefault();
      fn();
    };
    node.addEventListener('click', go);
    node.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') go(e); });
  };
  act(up, () => run(api('POST', `${base}/move`, { dir: -1 })));
  act(down, () => run(api('POST', `${base}/move`, { dir: 1 })));
  act(del, () => {
    const n = noteById(noteId);
    if (n && n.pages.length <= 1) return alert('마지막 한 페이지는 삭제할 수 없어요. 대신 "비우기"를 쓰세요.');
    if (confirm('이 페이지를 삭제할까요?\n(파일은 저장 폴더의 trash 폴더로 옮겨집니다)')) run(api('DELETE', base));
  });
  return { root, img, num, rev: -1, gen: -1 };
}

function renderThumbs() {
  const note = curNote();
  const list = $('#thumbList');
  const seen = new Set();
  let active = null;
  note.pages.forEach((p, i) => {
    let t = thumbEls.get(p.id);
    if (!t) {
      t = makeThumb(note.id, p.id);
      thumbEls.set(p.id, t);
    }
    seen.add(p.id);
    t.num.textContent = String(i + 1);
    const isActive = p.id === state.current.page;
    if (isActive && !t.root.classList.contains('active')) active = t.root;
    t.root.classList.toggle('active', isActive);
    if (t.rev !== p.rev || t.gen !== p.gen) {
      t.rev = p.rev;
      t.gen = p.gen;
      t.img.src = `/api/notes/${note.id}/pages/${p.id}/thumb?rev=${p.rev}&gen=${p.gen}`;
    }
    if (list.children[i] !== t.root) list.insertBefore(t.root, list.children[i] || null);
  });
  for (const [id, t] of thumbEls) {
    if (seen.has(id)) continue;
    t.root.remove();
    thumbEls.delete(id);
  }
  if (active) active.scrollIntoView({ block: 'nearest' });
}

function renderPad() {
  const on = !!state.pad;
  $('#padDot').className = on ? 'dot on' : 'dot';
  $('#miniDot').className = on ? 'dot on' : 'dot';
  $('#padStatus').textContent = on ? `${state.pad.name} 연결됨` : '아이패드 연결 대기 중';
  const real = state.addrs.filter((a) => !a.virtual);
  const addrs = real.length ? real : state.addrs;
  $('#padAddr').textContent = addrs.length ? addrs[0].address : '네트워크 없음';
  const other = $('#padOther');
  other.hidden = addrs.length < 2;
  other.textContent = addrs.length < 2 ? '' : `안 되면: ${addrs.slice(1).map((a) => a.address).join(', ')}`;
  $('#padCode').textContent = `${state.code.slice(0, 3)} ${state.code.slice(3)}`;
  $('#waitHint').hidden = on;
  $('#padDevices').textContent = `등록된 기기 ${state.devices}대`;
  $('#unpair').hidden = !state.devices;
}

// ---------- 동작 ----------

function openIndex(i) {
  const note = curNote();
  if (i < 0 || i >= note.pages.length) return;
  run(api('POST', '/api/open', { note: note.id, page: note.pages[i].id }));
}

function safeName(title) {
  return title.replace(/[\\/:*?"<>|]/g, ' ').trim() || '펜슬노트';
}

function savePng() {
  const note = curNote();
  const c = document.createElement('canvas');
  c.width = PAGE_W * S;
  c.height = PAGE_H * S;
  const ctx = c.getContext('2d');
  ctx.drawImage(canvases.paper, 0, 0);
  ctx.drawImage(canvases.ink, 0, 0);
  c.toBlob((blob) => {
    const a = el('a', { href: URL.createObjectURL(blob), download: `${safeName(note.title)}-${curIndex() + 1}.png` });
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  }, 'image/png');
}

// 노트의 모든 페이지를 인쇄용으로 늘어놓고 인쇄 창을 연다. 인쇄 창에서 "PDF로 저장"을 고르면 PDF가 된다.
async function savePdf() {
  const btn = $('#savePdf');
  btn.disabled = true;
  try {
    const note = curNote();
    const area = $('#printArea');
    area.textContent = '';
    await Promise.all(note.pages.map(async (p) => {
      const bg = document.createElement('canvas');
      bg.width = PAGE_W * S;
      bg.height = PAGE_H * S;
      drawPaper(bg.getContext('2d'), p.paper, S);
      const paper = new Image();
      paper.src = bg.toDataURL('image/png');
      const ink = new Image();
      ink.src = `/api/notes/${note.id}/pages/${p.id}/image?t=${Date.now()}`;
      const sheet = el('div', { class: 'sheet' }, paper, ink);
      area.append(sheet);
      await paper.decode().catch(() => {});
      await ink.decode().catch(() => ink.remove());
    }));
    const oldTitle = document.title;
    document.title = safeName(note.title);
    window.addEventListener('afterprint', () => {
      document.title = oldTitle;
      area.textContent = '';
    }, { once: true });
    window.print();
  } finally {
    btn.disabled = false;
  }
}

// 좁은 창에서 목록 여닫기
function toggleDrawer(name) {
  const other = name === 'show-side' ? 'show-thumbs' : 'show-side';
  document.body.classList.remove(other);
  document.body.classList.toggle(name);
}

function closeDrawers() {
  document.body.classList.remove('show-side', 'show-thumbs');
}

$('#menuBtn').addEventListener('click', () => toggleDrawer('show-side'));
$('#thumbBtn').addEventListener('click', () => toggleDrawer('show-thumbs'));
$('#moreBtn').addEventListener('click', () => $('#toolbar').classList.toggle('open'));
stageEl.addEventListener('click', closeDrawers);
$('#noteList').addEventListener('click', closeDrawers);

$('#newNote').addEventListener('click', async () => {
  const d = new Date();
  await api('POST', '/api/notes', { title: `${d.getMonth() + 1}월 ${d.getDate()}일 노트` }).catch((e) => console.error(e));
  const title = $('#title');
  title.focus();
  title.select();
});

$('#title').addEventListener('change', (e) => {
  run(api('PATCH', `/api/notes/${state.current.note}`, { title: e.target.value }));
});
$('#title').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') e.target.blur();
  if (e.key === 'Escape') {
    e.target.value = curNote().title;
    e.target.blur();
  }
});

$('#prevPage').addEventListener('click', () => openIndex(curIndex() - 1));
$('#nextPage').addEventListener('click', () => openIndex(curIndex() + 1));
$('#addPage').addEventListener('click', () => {
  run(api('POST', `/api/notes/${state.current.note}/pages`, { after: state.current.page }));
});

$('#paperSeg').addEventListener('click', (e) => {
  const paper = e.target.dataset.paper;
  if (paper) run(api('PATCH', `/api/notes/${state.current.note}/pages/${state.current.page}`, { paper }));
});

$('#viewSeg').addEventListener('click', (e) => {
  if (e.target.dataset.view) setViewMode(e.target.dataset.view);
});

$('#clearPage').addEventListener('click', () => {
  if (confirm('이 페이지의 필기를 모두 지울까요?\n(지운 필기는 저장 폴더의 trash 폴더에 남습니다)')) {
    run(api('POST', `/api/notes/${state.current.note}/pages/${state.current.page}/clear`));
  }
});

$('#unpair').addEventListener('click', () => {
  if (confirm('등록된 아이패드를 모두 해제하고 연결 코드를 새로 만들까요?\n(아이패드에서 새 코드로 다시 연결해야 합니다)')) run(api('POST', '/api/unpair'));
});

$('#savePng').addEventListener('click', savePng);
$('#savePdf').addEventListener('click', () => run(savePdf()));
$('#focusBtn').addEventListener('click', () => setFocus(true));
$('#exitFocus').addEventListener('click', () => setFocus(false));

document.addEventListener('keydown', (e) => {
  if (!state || e.target.closest('input, textarea') || e.ctrlKey || e.metaKey || e.altKey) return;
  if (e.key === 'ArrowLeft' || e.key === 'PageUp') openIndex(curIndex() - 1);
  else if (e.key === 'ArrowRight' || e.key === 'PageDown') openIndex(curIndex() + 1);
  else if (e.key === 'f' || e.key === 'F') setFocus(!appEl.classList.contains('focus'));
  else if (e.key === 'Escape') {
    setFocus(false);
    closeDrawers();
  }
  else return;
  e.preventDefault();
});

connect();
})();
