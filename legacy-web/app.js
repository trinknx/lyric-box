'use strict';
/* Lyric Box — kinetic-typography lyric player inspired by COTODAMA Lyric Speaker */

const $ = (s) => document.querySelector(s);
const root = document.documentElement;
const audio = $('#audio');
const stage = $('#stage');

const state = {
  lines: [],
  title: 'Lyric Box',
  artist: '',
  offset: 0,
  mode: 'auto',
  songStyles: ['stack', 'slide'],
  current: null,
  key: null,
  jumped: true,
  hasLyrics: false,
  beat: 0,
  beatAvg: 0,
  actx: null, an: null, fd: null,
  source: 'file', // 'file' | 'spotify'
  sp: null,       // spotify clock: { progress(ms), at(perf.now), playing, duration(ms) }
};

// one clock for both sources
const clock = {
  time() {
    if (state.source !== 'spotify') return audio.currentTime;
    const s = state.sp;
    if (!s) return 0;
    const ms = s.progress + (s.playing ? performance.now() - s.at : 0);
    return Math.min(ms, s.duration || ms) / 1000;
  },
  duration: () => (state.source === 'spotify' ? (state.sp?.duration || 0) / 1000 : audio.duration),
  paused: () => (state.source === 'spotify' ? !state.sp?.playing : audio.paused),
};
const STYLE_KEYS = ['flow', 'stack', 'slide', 'drift', 'type', 'burst', 'zoom'];
const MOOD_KEYS = ['calm', 'mid', 'energetic'];

/* ---------------- utils ---------------- */
function rng(seed) {
  let s = (seed >>> 0) || 1;
  return () => (s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296;
}
function hash(str) {
  let h = 2166136261;
  for (const c of str) { h ^= c.codePointAt(0); h = Math.imul(h, 16777619); }
  return h >>> 0;
}
const fmt = (s) => (isFinite(s) ? `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}` : '0:00');
let toastTimer;
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 3200);
}

/* ---------------- LRC parsing ---------------- */
const TAG = /\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]/g;
const WTAG_SPLIT = /(<\d{1,3}:\d{1,2}(?:\.\d{1,3})?>)/;
const toSec = (m, s) => +m * 60 + parseFloat(String(s).replace(':', '.'));
const segmenter = typeof Intl !== 'undefined' && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: 'word' }) : null;

function parseLRC(text) {
  const lines = [];
  const meta = {};
  let off = 0;
  for (const raw of text.normalize('NFC').split(/\r?\n/)) {
    const mm = raw.match(/^\s*\[(ti|ar|al|offset)\s*:(.*)\]\s*$/i);
    if (mm) {
      const k = mm[1].toLowerCase(), v = mm[2].trim();
      if (k === 'offset') off = (parseFloat(v) || 0) / 1000; else meta[k] = v;
      continue;
    }
    const times = [];
    let m;
    TAG.lastIndex = 0;
    while ((m = TAG.exec(raw))) times.push(toSec(m[1], m[2]));
    if (!times.length) continue;
    const body = raw.replace(TAG, '').trim();
    for (const t of times) lines.push({ time: Math.max(0, t - off), body });
  }
  lines.sort((a, b) => a.time - b.time);
  return { lines, meta };
}

function splitWords(text) {
  text = text.trim();
  if (!text) return [];
  if (/\s/.test(text) || !segmenter) return text.split(/\s+/);
  // languages without spaces (Japanese, Chinese…): segment into words
  const out = [];
  for (const seg of segmenter.segment(text)) {
    if (seg.isWordLike || !out.length) out.push(seg.segment);
    else out[out.length - 1] += seg.segment;
  }
  return out;
}

function buildLine(raw, index, next) {
  const words = [];
  let text = '';
  if (/<\d{1,3}:\d/.test(raw.body)) {
    // enhanced LRC: <mm:ss.xx> per word / syllable
    let t = null;
    for (const p of raw.body.split(WTAG_SPLIT)) {
      const m = p.match(/^<(\d+):([\d.]+)>$/);
      if (m) { t = toSec(m[1], m[2]); continue; }
      if (!p) continue;
      const ws = splitWords(p);
      const glue = words.length && ws.length && !/^\s/.test(p) && !/\s$/.test(text);
      ws.forEach((w, k) => {
        if (k === 0 && glue) words[words.length - 1].text += w;
        else words.push({ text: w, time: k === 0 ? t : null });
      });
      text += p;
    }
  } else {
    text = raw.body;
    splitWords(text).forEach((w) => words.push({ text: w, time: null }));
  }

  const nextTime = next ? next.time : raw.time + 8;
  const n = words.length;
  if (n) {
    const singDur = Math.max(0.3, Math.min((nextTime - raw.time) * 0.8, n * 0.5 + 0.3));
    if (words.every((w) => w.time == null)) {
      const weights = words.map((w) => w.text.length + 2);
      const total = weights.reduce((a, b) => a + b, 0);
      let acc = 0;
      words.forEach((w, k) => { w.time = raw.time + (singDur * acc) / total; acc += weights[k]; });
    } else {
      if (words[0].time == null) words[0].time = raw.time;
      let last = 0;
      for (let k = 1; k < n; k++) {
        if (words[k].time == null) continue;
        const t0 = words[last].time, t1 = words[k].time;
        for (let j = last + 1; j < k; j++) words[j].time = t0 + ((t1 - t0) * (j - last)) / (k - last);
        last = k;
      }
      for (let j = last + 1; j < n; j++) words[j].time = words[last].time + 0.25 * (j - last);
    }
  }
  const lastWord = n ? words[n - 1].time : raw.time;
  const end = Math.min(next ? next.time : Infinity, lastWord + 6);
  return { time: raw.time, end, text: text.trim(), words, index };
}

function loadLyrics(text, { quiet = false } = {}) {
  let { lines: raw, meta } = parseLRC(text);
  if (!raw.length) {
    const plain = text.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    if (!plain.length) { toast('Không đọc được lời bài hát'); return false; }
    const dur = clock.duration() > 0 ? clock.duration() : plain.length * 4;
    const start = Math.min(5, dur * 0.05), step = (dur - start) / plain.length;
    raw = plain.map((b, k) => ({ time: start + k * step, body: b }));
    toast('Lời không có mốc thời gian — đã chia đều theo độ dài bài');
  } else if (!quiet) {
    toast(`Đã nạp ${raw.filter((r) => r.body).length} dòng lời`);
  }
  state.lines = raw.map((r, i) => buildLine(r, i, raw[i + 1]));
  if (meta.ti) state.title = meta.ti;
  if (meta.ar) state.artist = meta.ar;
  state.hasLyrics = true;
  pickSongStyles();
  updateMeta();
  resetStage();
  return true;
}

/* Lyric Speaker picks a motion that matches the song's mood. We approximate it
   from singing density (words per second) and alternate two styles per song. */
function pickSongStyles() {
  let words = 0, secs = 0;
  for (const l of state.lines) {
    if (!l.words.length) continue;
    words += l.words.length;
    secs += Math.min(l.end - l.time, 8);
  }
  const wps = secs ? words / secs : 1.5;
  state.mood = wps > 2.6 ? 'energetic' : wps > 1.5 ? 'mid' : 'calm';
  const pool = wps > 2.6 ? ['burst', 'zoom', 'stack'] : wps > 1.5 ? ['stack', 'slide', 'burst'] : ['drift', 'type', 'slide'];
  const r = rng(hash(state.title + state.lines.length));
  const a = pool[Math.floor(r() * pool.length)];
  let b;
  do b = pool[Math.floor(r() * pool.length)]; while (b === a);
  state.songStyles = [a, b];
  root.style.setProperty('--hue', hash(state.title + state.artist) % 360);
}

function styleFor(i) {
  if (state.mode === 'auto' || MOOD_KEYS.includes(state.mode)) return 'flow';
  if (state.mode === 'mix') return state.songStyles[i % 2];
  if (state.mode === 'tour') return STYLE_KEYS[i % STYLE_KEYS.length];
  return state.mode;
}

/* ---------------- motion styles ---------------- */
const EASE = { out: 'cubic-bezier(.16,1,.3,1)', back: 'cubic-bezier(.34,1.56,.64,1)', in: 'cubic-bezier(.7,0,.84,0)' };
const A = (el, kf, o) => el.animate(kf, { fill: 'both', ...o });

function rows(inner, words, sizes, maxUnits) {
  let row = null, units = 0;
  words.forEach((w, k) => {
    const u = (w.text.length + 1) * sizes[k];
    if (!row || (units + u > maxUnits && units > 0)) {
      row = document.createElement('div');
      row.className = 'row';
      inner.appendChild(row);
      units = 0;
    }
    w.el.style.fontSize = sizes[k] + 'em';
    row.appendChild(w.el);
    units += u;
  });
}
function longestIndex(words) {
  let best = 0;
  words.forEach((w, k) => { if (w.text.length > words[best].text.length) best = k; });
  return best;
}
const hideEl = (w) => { w.el.style.opacity = 0; };
const hideChars = (w) => w.chars.forEach((c) => { c.style.opacity = 0; });

const STYLES = {
  // magazine-like blocks of different sizes, words pop in
  stack: {
    layout(inner, words, r) {
      const big = longestIndex(words);
      const sizes = words.map((w, k) => (k === big && words.length > 2 ? 1.5 : w.text.length <= 2 ? 0.72 : r() < 0.2 ? 1.2 : 1));
      if (words.length > 2) words[big].el.classList.add('em');
      rows(inner, words, sizes, 14);
    },
    prepare: hideEl,
    enter: (w) => [A(w.el, [
      { opacity: 0, transform: 'translateY(.35em) scale(.8)', filter: 'blur(10px)' },
      { opacity: 1, transform: 'none', filter: 'blur(0px)' },
    ], { duration: 420, easing: EASE.back })],
    exit: (L) => A(L.inner, [
      { opacity: 1, transform: 'none', filter: 'blur(0px)' },
      { opacity: 0, transform: 'translateY(-.3em) scale(1.04)', filter: 'blur(12px)' },
    ], { duration: 450, easing: EASE.in }),
  },

  // bold uppercase, wiped in from alternating sides
  slide: {
    layout(inner, words) { rows(inner, words, words.map(() => 1), 9); },
    prepare: hideEl,
    enter(w) {
      const row = [...w.el.parentNode.parentNode.children].indexOf(w.el.parentNode);
      const dir = row % 2 ? 1 : -1;
      return [A(w.el, [
        { opacity: 1, clipPath: dir < 0 ? 'inset(-60% 100% -60% -20%)' : 'inset(-60% -20% -60% 100%)', transform: `translateX(${dir * 0.5}em)` },
        { opacity: 1, clipPath: 'inset(-60% -20% -60% -20%)', transform: 'none' },
      ], { duration: 480, easing: EASE.out })];
    },
    exit: (L) => L.words.map((w, k) => A(w.el, [
      { clipPath: 'inset(-60% -20% -60% -20%)', transform: 'none' },
      { clipPath: 'inset(-60% -20% -60% 100%)', transform: 'translateX(.4em)' },
    ], { duration: 320, delay: k * 25, easing: EASE.in })),
  },

  // light, slow, letters breathe in — for ballads
  drift: {
    layout(inner, words) { rows(inner, words, words.map(() => 0.8), 16); },
    prepare: hideChars,
    enter: (w) => w.chars.map((c, i) => A(c, [
      { opacity: 0, filter: 'blur(8px)', transform: 'translateY(.3em)' },
      { opacity: 1, filter: 'blur(0px)', transform: 'none' },
    ], { duration: 1000, delay: i * 45, easing: EASE.out })),
    exit: (L) => A(L.inner, [
      { opacity: 1, filter: 'blur(0px)', transform: 'none', letterSpacing: '.04em' },
      { opacity: 0, filter: 'blur(8px)', transform: 'translateY(-.25em)', letterSpacing: '.22em' },
    ], { duration: 750, easing: 'ease-in-out' }),
  },

  // typewriter with caret, letters fall away
  type: {
    layout(inner, words) {
      rows(inner, words, words.map(() => 0.7), 20);
      const caret = document.createElement('span');
      caret.className = 'caret';
      inner.firstChild?.prepend(caret);
    },
    prepare: hideChars,
    enter(w, L) {
      const anims = w.chars.map((c, i) => A(c, [{ opacity: 0 }, { opacity: 1 }], { duration: 1, delay: i * 35 }));
      // caret follows the last typed letter
      anims[anims.length - 1].finished.then(() => { const c = L.inner.querySelector('.caret'); if (c) w.el.after(c); }, () => {});
      return anims;
    },
    exit(L) {
      L.inner.querySelector('.caret')?.remove();
      return L.words.flatMap((w) => w.chars.map((c) => A(c, [
        { opacity: 1, transform: 'none' },
        { opacity: 0, transform: `translateY(${1 + L.r() * 1.5}em) rotate(${(L.r() - 0.5) * 100}deg)` },
      ], { duration: 500 + L.r() * 300, delay: L.r() * 200, easing: EASE.in })));
    },
  },

  // energetic: letters fly in from everywhere and explode out
  burst: {
    layout(inner, words, r) {
      rows(inner, words, words.map(() => 0.8 + r() * 0.55), 11);
      words.forEach((w) => { w.el.style.transform = `rotate(${(r() - 0.5) * 10}deg)`; });
    },
    prepare: hideChars,
    enter: (w, L) => w.chars.map((c, i) => A(c, [
      { opacity: 0, transform: `translate(${(L.r() - 0.5) * 5}em, ${(L.r() - 0.5) * 4}em) rotate(${(L.r() - 0.5) * 240}deg) scale(1.8)` },
      { opacity: 1, transform: 'none' },
    ], { duration: 600, delay: i * 25, easing: EASE.back })),
    exit: (L) => L.words.flatMap((w) => w.chars.map((c) => A(c, [
      { opacity: 1, transform: 'none' },
      { opacity: 0, transform: `translate(${(L.r() - 0.5) * 8}em, ${(L.r() - 0.5) * 6}em) rotate(${(L.r() - 0.5) * 300}deg) scale(.3)` },
    ], { duration: 450, easing: EASE.in }))),
  },

  // one huge word at a time — for rap / fast songs
  zoom: {
    layout(inner, words) {
      words.forEach((w) => {
        w.el.style.fontSize = Math.min(2.4, 5 / (w.text.length + 1) + 0.9) + 'em';
        inner.appendChild(w.el);
      });
    },
    post(L) {
      const maxW = stage.clientWidth * 0.86;
      L.words.forEach((w) => {
        const wd = w.el.offsetWidth;
        if (wd > maxW) w.el.style.fontSize = parseFloat(w.el.style.fontSize) * (maxW / wd) + 'em';
      });
    },
    prepare: hideEl,
    enter(w, L) {
      const out = [];
      const prev = L.words[w.k - 1];
      if (prev) out.push(A(prev.el, [
        { opacity: 1, transform: 'none', filter: 'blur(0px)' },
        { opacity: 0, transform: 'scale(1.6)', filter: 'blur(6px)' },
      ], { duration: 220, easing: EASE.in }));
      out.push(A(w.el, [
        { opacity: 0, transform: 'scale(.3)' },
        { opacity: 1, transform: 'none' },
      ], { duration: 340, easing: EASE.back }));
      return out;
    },
    exit: (L) => A(L.inner, [
      { opacity: 1, transform: 'none' },
      { opacity: 0, transform: 'scale(.7)' },
    ], { duration: 260, easing: EASE.in }),
  },
};


/* ---------------- COTODAMA-like "flow" canvas ----------------
   Every lyric line becomes a text block on one big virtual canvas. A new block is
   placed next to the previous one (sometimes turned 90°) and the camera pans /
   rotates / zooms onto it, so older lines stay on screen, dimmed and sideways.
   Letters are spelled out while they are sung. Mood picks font + motion. */
const MOODS = {
  calm: {
    fonts: ['f-serif'], turn: 0.3, cam: 1500, camEase: 'cubic-bezier(.45,0,.15,1)',
    emph: 1.45, units: 15, maxZoom: 1.25, ghost: 0.45, label: 0.08,
    kf: (g) => [{ opacity: g, filter: 'blur(6px)', transform: 'translateY(.12em)' }, { opacity: 1, filter: 'blur(0px)', transform: 'none' }],
    dur: 650, ease: 'cubic-bezier(.2,.7,.2,1)',
  },
  mid: {
    fonts: ['f-serif', 'f-sans'], turn: 0.4, cam: 950, camEase: 'cubic-bezier(.65,0,.2,1)',
    emph: 1.7, units: 12, maxZoom: 1.45, ghost: 0.3, label: 0.15,
    kf: (g) => [{ opacity: g, transform: 'translateY(.35em)' }, { opacity: 1, transform: 'none' }],
    dur: 300, ease: 'cubic-bezier(.16,1,.3,1)',
  },
  energetic: {
    fonts: ['f-impact', 'f-sans'], turn: 0.55, cam: 520, camEase: 'cubic-bezier(.3,1.35,.45,1)',
    emph: 2, units: 9, maxZoom: 1.7, ghost: 0.1, label: 0.25,
    kf: (g) => [{ opacity: g, transform: 'scale(1.7)' }, { opacity: 1, transform: 'none' }],
    dur: 220, ease: 'cubic-bezier(.34,1.56,.64,1)',
  },
};

const Flow = {
  world: null,
  blocks: [],

  ensure() {
    if (this.world) return;
    this.world = document.createElement('div');
    this.world.id = 'world';
    stage.appendChild(this.world);
    this.blocks = [];
  },

  drop() { this.world = null; this.blocks = []; },

  fadeOut() {
    const w = this.world;
    if (!w) return;
    this.drop();
    w.style.transition = 'opacity .7s';
    w.style.opacity = 0;
    setTimeout(() => w.remove(), 750);
  },

  add(line, seed, moodKey, instant) {
    this.ensure();
    const M = MOODS[moodKey];
    const r = rng(seed);
    const el = document.createElement('div');
    el.className = 'block ' + M.fonts[Math.floor(rng(hash(state.title))() * M.fonts.length)];
    const words = buildWordEls(line);
    const L = { outer: el, inner: el, words, S: STYLES.flow, r, line, M, ghost: 0 };

    // hierarchy: one emphasised word, tiny function words, left-aligned rows
    const avg = words.reduce((a, w) => a + w.text.length, 0) / (words.length || 1);
    let big = -1;
    if (words.length >= 2 && r() < 0.85) {
      const cands = words.map((w, k) => k).filter((k) => words[k].text.length >= Math.min(4, avg));
      big = cands.length ? cands.reduce((a, k) => (words[k].text.length + r() * 2 > words[a].text.length ? k : a), cands[0]) : -1;
    }
    const sizes = words.map((w, k) => (k === big ? M.emph : w.text.length <= 2 && avg > 3.5 ? 0.62 : r() < 0.15 ? 1.18 : 1));
    let row = null, units = 0;
    words.forEach((w, k) => {
      const u = (w.text.length + 1) * sizes[k];
      const isolate = (k === big || k - 1 === big) && r() < 0.6;
      if (!row || (units + u > M.units && units > 0) || (isolate && units > 0)) {
        row = document.createElement('div');
        row.className = 'row';
        el.appendChild(row);
        units = 0;
      }
      w.el.style.fontSize = sizes[k] + 'em';
      if (k === big) w.el.classList.add('em');
      row.appendChild(w.el);
      units += u;
    });
    if (words.length <= 4 && r() < M.label) el.classList.add('label');
    L.ghost = r() < M.ghost ? 0.16 : 0;

    this.world.appendChild(el);
    const w = el.offsetWidth, h = el.offsetHeight;
    const fs = parseFloat(getComputedStyle(stage).fontSize);
    const prev = this.blocks.at(-1);
    let x = 0, y = 0, rot = 0;
    if (prev) {
      const dr = r() < M.turn ? (r() < 0.5 ? 90 : -90) : 0;
      const ex = dr ? h : w, ey = dr ? w : h; // new block extents in prev's frame
      const gap = fs * 0.3;
      let off;
      if (dr === 0 && r() < 0.65) off = { x: -prev.w / 2 + ex / 2, y: prev.h / 2 + gap + ey / 2 };       // below, left-aligned
      else if (r() < 0.5) off = { x: prev.w / 2 + gap + ex / 2, y: -prev.h / 2 + ey / 2 };              // right, top-aligned
      else off = { x: -prev.w / 2 - gap - ex / 2, y: prev.h / 2 - ey / 2 };                             // left, bottom-aligned
      const a = (prev.rot * Math.PI) / 180;
      x = prev.x + off.x * Math.cos(a) - off.y * Math.sin(a);
      y = prev.y + off.x * Math.sin(a) + off.y * Math.cos(a);
      rot = prev.rot + dr;
    }
    el.style.transform = `translate(${x - w / 2}px, ${y - h / 2}px) rotate(${rot}deg)`;
    const b = { el, x, y, w, h, rot };
    this.blocks.push(b);

    // older lines stay, dimmed, then fade away
    const n = this.blocks.length;
    this.blocks.forEach((o, i) => {
      if (i === n - 1) return;
      o.el.style.opacity = i === n - 2 ? 0.26 : 0.1;
    });
    while (this.blocks.length > 4) {
      const old = this.blocks.shift();
      old.el.style.opacity = 0;
      setTimeout(() => old.el.remove(), 900);
    }
    this.focus(b, M, instant);
    words.forEach((wd) => wd.chars.forEach((c) => { c.style.opacity = L.ghost; }));
    return L;
  },

  focus(b, M, instant) {
    const W = stage.clientWidth, H = stage.clientHeight;
    const s = Math.min(M.maxZoom, (W * 0.7) / b.w, (H * 0.76) / b.h);
    this.world.style.transition = instant ? 'none' : `transform ${M.cam}ms ${M.camEase}`;
    this.world.style.transform = `translate(${W * 0.43}px, ${H / 2}px) scale(${s}) rotate(${-b.rot}deg) translate(${-b.x}px, ${-b.y}px)`;
  },
};

STYLES.flow = {
  // spell the word letter by letter across the time it is sung
  enter(w, L) {
    const next = L.words[w.k + 1]?.time ?? w.time + 0.6;
    const span = Math.max(0.12, Math.min(next - w.time, 0.8)) * 800;
    const step = span / Math.max(1, w.chars.length);
    return w.chars.map((c, i) => A(c, L.M.kf(L.ghost), { duration: L.M.dur, delay: i * step, easing: L.M.ease }));
  },
};

/* ---------------- instrumental: beat graphics ---------------- */
const viz = { el: null, ctx: null, on: 0 };
function drawViz() {
  if (!viz.el) {
    viz.el = document.createElement('canvas');
    viz.el.id = 'viz';
    stage.before(viz.el);
    viz.ctx = viz.el.getContext('2d');
  }
  const want = state.key === 'none' && !clock.paused() ? 1 : 0;
  viz.on += (want - viz.on) * 0.06;
  viz.el.style.opacity = viz.on.toFixed(3);
  if (viz.on < 0.01) return;
  const c = viz.el, dpr = devicePixelRatio || 1;
  const W = c.clientWidth, H = c.clientHeight;
  if (c.width !== Math.round(W * dpr)) { c.width = W * dpr; c.height = H * dpr; }
  const g = viz.ctx;
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, W, H);
  g.fillStyle = getComputedStyle(root).getPropertyValue('--fg');
  const n = 32, gap = W * 0.6 / n, bw = gap * 0.45, x0 = W * 0.2, now = performance.now() / 1000;
  for (let i = 0; i < n; i++) {
    let v;
    if (state.fd && state.source !== 'spotify') v = state.fd[2 + Math.floor((Math.abs(i - (n - 1) / 2) / (n / 2)) ** 1.6 * 160)] / 255;
    else v = 0.25 + 0.2 * Math.sin(now * 3 + i * 0.5) + state.beat * 0.6 * Math.exp(-(((i - n / 2) / 8) ** 2));
    const h = Math.max(bw, v * H * 0.42);
    g.globalAlpha = 0.25 + v * 0.75;
    g.beginPath();
    g.roundRect(x0 + i * gap, H / 2 - h / 2, bw, h, bw / 2);
    g.fill();
  }
}

function buildWordEls(line) {
  return line.words.map((w, k) => {
    const el = document.createElement('span');
    el.className = 'w';
    const chars = [...w.text].map((ch) => {
      const s = document.createElement('span');
      s.className = 'c';
      s.textContent = ch;
      el.appendChild(s);
      return s;
    });
    return { el, chars, text: w.text, time: w.time, shown: false, k };
  });
}

/* ---------------- stage rendering ---------------- */
function sizeStage() {
  stage.style.fontSize = Math.min(stage.clientHeight * 0.13, stage.clientWidth * 0.075) + 'px';
}

function makeLine(line, styleKey, seed) {
  const S = STYLES[styleKey];
  const outer = document.createElement('div');
  outer.className = 'line s-' + styleKey;
  const inner = document.createElement('div');
  inner.className = 'inner';
  outer.appendChild(inner);
  const words = buildWordEls(line);
  const L = { outer, inner, words, S, r: rng(seed), line };
  S.layout(inner, words, L.r, line);
  stage.appendChild(outer);
  S.post?.(L);
  // fit inside the screen
  const s = Math.min(1, (stage.clientWidth * 0.88) / outer.offsetWidth, (stage.clientHeight * 0.82) / outer.offsetHeight);
  outer.style.transform = `translate(-50%, -50%) scale(${s})`;
  words.forEach((w) => S.prepare(w));
  return L;
}

function exitLine(L) {
  const res = L.S.exit(L);
  const anims = Array.isArray(res) ? res : [res];
  const remove = () => L.outer.remove();
  Promise.all(anims.map((a) => a.finished)).then(remove, remove);
}

function titleLine(t) {
  const line = buildLine({ time: 0, body: state.title }, -1, null);
  line.words.forEach((w, k) => { w.time = t + 0.15 + k * 0.22; });
  return line;
}

function lineIndexAt(t) {
  const L = state.lines;
  let lo = 0, hi = L.length - 1, ans = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (L[mid].time <= t) { ans = mid; lo = mid + 1; } else hi = mid - 1;
  }
  return ans;
}

function keyAt(t) {
  if (!state.lines.length) return 'title';
  const i = lineIndexAt(t);
  if (i < 0) return t < state.lines[0].time - 0.6 ? 'title' : 'none';
  const l = state.lines[i];
  if (!l.words.length || t >= l.end) return 'none';
  return i;
}

function show(key, t) {
  const jumped = state.jumped;
  state.jumped = false;
  if (jumped) {
    stage.replaceChildren();
    Flow.drop();
  } else if (state.current && state.current.S !== STYLES.flow) {
    exitLine(state.current);
  }
  state.current = null;
  state.key = key;
  // keep the DOM small if lines change very fast
  const lines = stage.querySelectorAll('.line');
  for (let i = 0; i < lines.length - 3; i++) lines[i].remove();

  const line = key === 'none' ? null : key === 'title' ? titleLine(t) : state.lines[key];
  const styleKey = key === 'title' ? (STYLE_KEYS.includes(state.mode) ? state.mode : 'flow') : styleFor(key);
  if (!line || !line.words.length || styleKey !== 'flow') Flow.fadeOut();
  if (!line || !line.words.length) return;
  const seed = hash(line.text) + (key === 'title' ? 0 : key);
  if (styleKey === 'flow') {
    const mood = MOOD_KEYS.includes(state.mode) ? state.mode : state.mood || 'mid';
    state.current = Flow.add(line, seed, mood, jumped);
  } else {
    state.current = makeLine(line, styleKey, seed);
  }
}

function updateLine(L, t) {
  for (const w of L.words) {
    if (w.shown || w.time > t) continue;
    w.shown = true;
    const anims = L.S.enter(w, L) || [];
    if (state.source === 'spotify') state.beat = Math.max(state.beat, 0.5); // no audio access: pulse on words
    if (t - w.time > 0.5) anims.forEach((a) => a.finish()); // after a seek, show already-sung words instantly
  }
}

function resetStage() {
  state.jumped = true;
  state.key = null;
}

/* ---------------- audio reactivity ---------------- */
function initAudioGraph() {
  if (state.actx) { state.actx.resume(); return; }
  try {
    const C = window.AudioContext || window.webkitAudioContext;
    const ctx = new C();
    const src = ctx.createMediaElementSource(audio);
    const an = ctx.createAnalyser();
    an.fftSize = 1024;
    an.smoothingTimeConstant = 0.6;
    src.connect(an);
    an.connect(ctx.destination);
    state.actx = ctx; state.an = an; state.fd = new Uint8Array(an.frequencyBinCount);
  } catch (e) { console.warn('Audio analyser unavailable', e); }
}

function react() {
  let b = 0;
  if (state.an && !audio.paused) {
    state.an.getByteFrequencyData(state.fd);
    let s = 0;
    for (let i = 1; i < 8; i++) s += state.fd[i];
    b = s / (7 * 255);
  }
  state.beatAvg = state.beatAvg * 0.97 + b * 0.03;
  const punch = Math.max(0, b - state.beatAvg * 1.05) * 3.5;
  state.beat = Math.max(punch, state.beat * 0.88);
  root.style.setProperty('--beat', Math.min(1, state.beat).toFixed(3));
  root.style.setProperty('--level', b.toFixed(3));
}

/* ---------------- main loop ---------------- */
let seeking = false;
function tick() {
  requestAnimationFrame(tick);
  const t = clock.time() + state.offset;
  const key = keyAt(t);
  document.body.classList.toggle('playing', !clock.paused());
  if (key !== state.key) show(key, t);
  if (state.current) updateLine(state.current, t);
  react();
  drawViz();
  if (!seeking) {
    const d = clock.duration();
    $('#cur').textContent = fmt(clock.time());
    $('#seek').value = d ? (clock.time() / d) * 1000 : 0;
  }
}

/* ---------------- loading ---------------- */
let audioUrl = null;
function loadAudio(src, { title, artist } = {}) {
  SP.stop();
  if (audioUrl) URL.revokeObjectURL(audioUrl);
  audioUrl = src.startsWith('blob:') ? src : null;
  audio.src = src;
  state.lines = [];
  state.hasLyrics = false;
  state.title = title || 'Không tên';
  state.artist = artist || '';
  pickSongStyles();
  updateMeta();
  resetStage();
  $('#hint').classList.add('hide');
}

function loadAudioFile(file) {
  const name = file.name.replace(/\.[^.]+$/, '').replace(/_/g, ' ');
  const parts = name.split(/\s+-\s+/);
  const artist = parts.length > 1 ? parts[0] : '';
  const title = parts.length > 1 ? parts.slice(1).join(' - ') : name;
  loadAudio(URL.createObjectURL(file), { title, artist });
  $('#q').value = name;
  audio.addEventListener('loadedmetadata', () => {
    if (!state.hasLyrics) search(name, true);
  }, { once: true });
}

async function loadLyricsFile(file) {
  const text = await file.text();
  $('#lrcText').value = text;
  loadLyrics(text);
}

function handleFiles(files) {
  const list = [...files];
  const a = list.find((f) => f.type.startsWith('audio/') || f.type.startsWith('video/') || /\.(mp3|m4a|aac|wav|flac|ogg|opus|webm|mp4)$/i.test(f.name));
  const l = list.find((f) => /\.(lrc|txt)$/i.test(f.name));
  if (a) loadAudioFile(a);
  if (l) loadLyricsFile(l);
  if (!a && !l) toast('Định dạng không hỗ trợ');
}

function updateMeta() {
  $('#mTitle').textContent = state.title;
  $('#mArtist').textContent = state.artist || (state.hasLyrics ? '' : 'Chưa có lời');
  document.title = state.title === 'Lyric Box' ? 'Lyric Box' : `${state.title} · Lyric Box`;
}

/* ---------------- LRCLIB search ---------------- */
async function search(q, autoApply = false) {
  q = q.trim();
  const ul = $('#results');
  if (!q) return;
  ul.innerHTML = '<li class="msg">Đang tìm…</li>';
  try {
    const res = await fetch('https://lrclib.net/api/search?q=' + encodeURIComponent(q));
    if (!res.ok) throw new Error(res.status);
    let items = (await res.json()).filter((x) => x.syncedLyrics);
    const d = clock.duration();
    if (isFinite(d) && d > 0) items.sort((x, y) => Math.abs(x.duration - d) - Math.abs(y.duration - d));
    items = items.slice(0, 10);
    ul.replaceChildren();
    if (!items.length) { ul.innerHTML = '<li class="msg">Không tìm thấy lời đồng bộ</li>'; return; }
    for (const it of items) {
      const li = document.createElement('li');
      li.innerHTML = '<b></b><small></small>';
      li.querySelector('b').textContent = it.trackName;
      li.querySelector('small').textContent = `${it.artistName} · ${fmt(it.duration)}`;
      li.onclick = () => applyResult(it);
      ul.appendChild(li);
    }
    if (autoApply && !state.hasLyrics && isFinite(d) && Math.abs(items[0].duration - d) < 4) {
      applyResult(items[0]);
      toast(`Tự tìm thấy lời: ${items[0].trackName} — ${items[0].artistName}`);
    }
  } catch (e) {
    ul.innerHTML = '<li class="msg">Không kết nối được LRCLIB</li>';
  }
}

function applyResult(it) {
  $('#lrcText').value = it.syncedLyrics;
  loadLyrics(it.syncedLyrics, { quiet: true });
  state.title = it.trackName;
  state.artist = it.artistName;
  pickSongStyles();
  updateMeta();
  resetStage();
}

/* ---------------- demo song ---------------- */
const DEMO_LRC = `[ti:Chữ Bay Trong Đêm]
[ar:Lyric Box · Demo]
[00:05.00]Đêm nay thành phố như đang ngủ quên
[00:10.00]Chỉ còn tiếng nhạc khẽ gọi tên em
[00:15.00]Từng con chữ bay trong ánh đèn
[00:20.00]Rơi vào tim như những vì sao
[00:25.00]
[00:27.50]Hát lên đi
[00:30.00]Cho đêm dài thêm sáng
[00:32.50]Hát lên đi
[00:35.00]Để lời ca ngân vang mãi
[00:40.00]Let the words dance in the light
[00:45.00]Lyric Box ♪
[00:49.00]`;

async function makeDemoAudio() {
  const sr = 32000, beat = 60 / 96, bars = 20, dur = bars * 4 * beat;
  const ctx = new OfflineAudioContext(1, Math.ceil(sr * (dur + 1)), sr);
  const master = ctx.createGain();
  master.gain.value = 0.5;
  master.connect(ctx.destination);
  const mtof = (m) => 440 * 2 ** ((m - 69) / 12);
  const chords = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]];
  const noise = ctx.createBuffer(1, sr * 0.3, sr);
  const nd = noise.getChannelData(0);
  for (let i = 0; i < nd.length; i++) nd[i] = Math.random() * 2 - 1;

  const env = (g, t, a, peak, d) => {
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(peak, t + a);
    g.gain.exponentialRampToValueAtTime(0.0001, t + a + d);
  };
  const noiseHit = (t, type, freq, peak, d) => {
    const s = ctx.createBufferSource(); s.buffer = noise;
    const f = ctx.createBiquadFilter(); f.type = type; f.frequency.value = freq;
    const g = ctx.createGain(); env(g, t, 0.002, peak, d);
    s.connect(f).connect(g).connect(master); s.start(t); s.stop(t + d + 0.05);
  };

  for (let bar = 0; bar < bars; bar++) {
    const t0 = bar * 4 * beat, ch = chords[bar % 4];
    const drums = bar >= 2 && bar !== 10 && bar < 19;
    for (const m of ch) {
      for (const det of [-6, 6]) {
        const o = ctx.createOscillator(); o.type = 'sawtooth'; o.frequency.value = mtof(m); o.detune.value = det;
        const f = ctx.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = 900;
        const g = ctx.createGain(); env(g, t0, 0.4, 0.05, 4 * beat);
        o.connect(f).connect(g).connect(master); o.start(t0); o.stop(t0 + 4 * beat + 0.5);
      }
    }
    if (bar >= 2 && bar < 19) {
      for (let e = 0; e < 8; e++) {
        const t = t0 + e * beat / 2;
        const o = ctx.createOscillator(); o.type = 'triangle'; o.frequency.value = mtof(ch[0] - 24 + (e % 4 === 3 ? 12 : 0));
        const g = ctx.createGain(); env(g, t, 0.01, 0.35, beat / 2 - 0.02);
        o.connect(g).connect(master); o.start(t); o.stop(t + beat / 2);
      }
    }
    if (!drums) continue;
    for (let b = 0; b < 4; b++) {
      const t = t0 + b * beat;
      const o = ctx.createOscillator(); o.frequency.setValueAtTime(140, t); o.frequency.exponentialRampToValueAtTime(42, t + 0.12);
      const g = ctx.createGain(); env(g, t, 0.003, 1, 0.35);
      o.connect(g).connect(master); o.start(t); o.stop(t + 0.4);
      noiseHit(t + beat / 2, 'highpass', 7000, 0.18, 0.05);
      if (b % 2) noiseHit(t, 'bandpass', 1800, 0.5, 0.16);
    }
  }
  const buf = await ctx.startRendering();
  return URL.createObjectURL(toWav(buf));
}

function toWav(buf) {
  const d = buf.getChannelData(0), n = d.length;
  const ab = new ArrayBuffer(44 + n * 2), v = new DataView(ab);
  const w = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  w(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); w(8, 'WAVE'); w(12, 'fmt ');
  v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, buf.sampleRate, true); v.setUint32(28, buf.sampleRate * 2, true);
  v.setUint16(32, 2, true); v.setUint16(34, 16, true); w(36, 'data'); v.setUint32(40, n * 2, true);
  let peak = 0;
  for (let i = 0; i < n; i++) peak = Math.max(peak, Math.abs(d[i]));
  const g = peak ? 0.9 / peak : 1;
  for (let i = 0; i < n; i++) v.setInt16(44 + i * 2, Math.max(-1, Math.min(1, d[i] * g)) * 32767, true);
  return new Blob([ab], { type: 'audio/wav' });
}

let demoUrl = null;
async function playDemo() {
  toast('Đang tạo nhạc demo…');
  demoUrl = demoUrl || (await makeDemoAudio());
  loadAudio(demoUrl, { title: 'Chữ Bay Trong Đêm' });
  loadLyrics(DEMO_LRC, { quiet: true });
  setMode('auto');
  $('#panel').classList.remove('open');
  play();
}

/* ---------------- controls ---------------- */
function play() {
  if (state.source === 'spotify') return SP.toggle();
  if (!audio.src) { $('#panel').classList.add('open'); return; }
  initAudioGraph();
  audio.play().catch(() => {});
}
function togglePlay() {
  if (state.source === 'spotify') return SP.toggle();
  audio.paused ? play() : audio.pause();
}
function seekTo(sec) {
  const d = clock.duration() || 0;
  sec = Math.max(0, Math.min(d, sec));
  if (state.source === 'spotify') SP.seek(sec);
  else audio.currentTime = sec;
}
function setMode(m) {
  state.mode = m;
  $('#styleSel').value = m;
  resetStage();
}
function setOffset(v) {
  state.offset = Math.round(v * 10) / 10;
  $('#offVal').textContent = (state.offset > 0 ? '+' : '') + state.offset.toFixed(1) + 's';
  resetStage();
}
function setTheme(th) {
  root.dataset.theme = th;
  store.set('theme', th);
}
function toggleFs() {
  if (document.fullscreenElement) document.exitFullscreen();
  else document.documentElement.requestFullscreen?.();
}

audio.addEventListener('seeking', resetStage);
audio.addEventListener('loadedmetadata', () => { $('#dur').textContent = fmt(audio.duration); });

$('#btnPlay').onclick = togglePlay;
$('#hintDemo').onclick = playDemo;
$('#btnDemo').onclick = playDemo;
$('#btnPanel').onclick = () => $('#panel').classList.toggle('open');
$('#btnClose').onclick = () => $('#panel').classList.remove('open');
$('#btnFs').onclick = toggleFs;
$('#btnTheme').onclick = () => setTheme(root.dataset.theme === 'night' ? 'clear' : 'night');
$('#styleSel').onchange = (e) => setMode(e.target.value);
$('#offMinus').onclick = () => setOffset(state.offset - 0.1);
$('#offPlus').onclick = () => setOffset(state.offset + 0.1);
$('#fileAudio').onchange = (e) => e.target.files[0] && handleFiles(e.target.files);
$('#fileLrc').onchange = (e) => e.target.files[0] && loadLyricsFile(e.target.files[0]);
$('#btnApply').onclick = () => loadLyrics($('#lrcText').value);
$('#btnSearch').onclick = () => search($('#q').value);
$('#q').onkeydown = (e) => { if (e.key === 'Enter') search(e.target.value); };

const seek = $('#seek');
seek.oninput = () => { seeking = true; $('#cur').textContent = fmt((seek.value / 1000) * (clock.duration() || 0)); };
seek.onchange = () => {
  seekTo((seek.value / 1000) * (clock.duration() || 0));
  seeking = false;
};

document.addEventListener('fullscreenchange', () => {
  document.body.classList.toggle('fs', !!document.fullscreenElement);
  setTimeout(() => { sizeStage(); resetStage(); }, 60);
});

document.addEventListener('keydown', (e) => {
  if (e.target.matches('input, textarea, select')) return;
  const k = e.key;
  if (k === ' ') { e.preventDefault(); togglePlay(); }
  else if (k === 'ArrowRight') seekTo(clock.time() + 5);
  else if (k === 'ArrowLeft') seekTo(clock.time() - 5);
  else if (k === '[') setOffset(state.offset - 0.1);
  else if (k === ']') setOffset(state.offset + 0.1);
  else if (k === 'f' || k === 'F') toggleFs();
  else if (k === 't' || k === 'T') setTheme(root.dataset.theme === 'night' ? 'clear' : 'night');
  else if (k === 's' || k === 'S') {
    const opts = [...$('#styleSel').options].map((o) => o.value);
    setMode(opts[(opts.indexOf(state.mode) + 1) % opts.length]);
    toast('Kiểu: ' + $('#styleSel').selectedOptions[0].textContent);
  }
});

// drag & drop
let dragDepth = 0;
addEventListener('dragenter', (e) => { e.preventDefault(); dragDepth++; document.body.classList.add('dragging'); });
addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; document.body.classList.remove('dragging'); } });
addEventListener('dragover', (e) => e.preventDefault());
addEventListener('drop', (e) => {
  e.preventDefault();
  dragDepth = 0;
  document.body.classList.remove('dragging');
  handleFiles(e.dataTransfer.files);
});

// auto-hide controls while playing
let idleTimer;
function wake() {
  document.body.classList.remove('idle');
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => {
    if (!clock.paused() && !$('#panel').classList.contains('open')) document.body.classList.add('idle');
  }, 2600);
}
['mousemove', 'touchstart', 'keydown'].forEach((ev) => addEventListener(ev, wake, { passive: true }));


/* ---------------- Spotify ----------------
   Spotify does not expose its audio stream, so we follow the playback clock:
   - "follow" mode polls the Web API (works with Free accounts, any device)
   - "play here" uses the Web Playback SDK (Premium only) */
const SP_SCOPES = 'user-read-playback-state user-read-currently-playing user-modify-playback-state streaming user-read-email user-read-private';
const redirectUri = () => location.origin + location.pathname;
const b64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch {} },
};

async function fetchLyrics(track, artist, album, duration) {
  try {
    const p = new URLSearchParams({ track_name: track, artist_name: artist, duration: Math.round(duration) });
    if (album) p.set('album_name', album);
    let r = await fetch('https://lrclib.net/api/get?' + p);
    if (r.ok) {
      const j = await r.json();
      if (j.syncedLyrics) return j.syncedLyrics;
    }
    r = await fetch('https://lrclib.net/api/search?' + new URLSearchParams({ track_name: track, artist_name: artist }));
    if (r.ok) {
      const items = (await r.json()).filter((x) => x.syncedLyrics)
        .sort((a, b) => Math.abs(a.duration - duration) - Math.abs(b.duration - duration));
      if (items[0] && Math.abs(items[0].duration - duration) < 5) return items[0].syncedLyrics;
    }
  } catch {}
  return null;
}

const SP = {
  token: JSON.parse(store.get('sp_token') || 'null'),
  clientId: store.get('sp_client') || '',
  timer: null, trackId: null, player: null,

  async login() {
    const id = $('#spClient').value.trim();
    if (!id) return toast('Nhập Spotify Client ID trước');
    store.set('sp_client', id);
    this.clientId = id;
    const verifier = b64url(crypto.getRandomValues(new Uint8Array(48)));
    store.set('sp_verifier', verifier);
    const challenge = b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
    location.href = 'https://accounts.spotify.com/authorize?' + new URLSearchParams({
      client_id: id, response_type: 'code', redirect_uri: redirectUri(),
      code_challenge_method: 'S256', code_challenge: challenge, scope: SP_SCOPES,
    });
  },

  async handleRedirect() {
    const q = new URLSearchParams(location.search);
    if (!q.has('code') && !q.has('error')) return;
    history.replaceState(null, '', redirectUri());
    if (q.get('error')) return toast('Spotify: ' + q.get('error'));
    await this.tokenRequest(new URLSearchParams({
      grant_type: 'authorization_code', code: q.get('code'), redirect_uri: redirectUri(),
      client_id: this.clientId, code_verifier: store.get('sp_verifier') || '',
    }));
    store.set('sp_verifier', null);
    if (this.token) this.start();
  },

  async tokenRequest(body) {
    try {
      const r = await fetch('https://accounts.spotify.com/api/token', {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body,
      });
      const j = await r.json();
      if (!r.ok) throw new Error(j.error_description || j.error);
      this.token = { access: j.access_token, refresh: j.refresh_token || this.token?.refresh, exp: Date.now() + (j.expires_in - 60) * 1000 };
      store.set('sp_token', JSON.stringify(this.token));
    } catch (e) {
      toast('Spotify: ' + e.message);
      this.logout();
    }
  },

  async access() {
    if (!this.token) return null;
    if (Date.now() > this.token.exp) {
      await this.tokenRequest(new URLSearchParams({ grant_type: 'refresh_token', refresh_token: this.token.refresh, client_id: this.clientId }));
    }
    return this.token?.access || null;
  },

  async api(path, opts = {}) {
    const tk = await this.access();
    if (!tk) throw new Error('Chưa kết nối');
    const r = await fetch('https://api.spotify.com/v1' + path, {
      ...opts, headers: { Authorization: 'Bearer ' + tk, ...(opts.body ? { 'Content-Type': 'application/json' } : {}) },
    });
    if (r.status === 401) { this.token.exp = 0; throw new Error('Phiên hết hạn'); }
    if (!r.ok) {
      const j = await r.json().catch(() => ({}));
      throw new Error(j.error?.message || r.status);
    }
    const txt = await r.text();
    return txt ? JSON.parse(txt) : null;
  },

  logout() {
    this.stop();
    this.token = null;
    store.set('sp_token', null);
    this.render();
  },

  start() {
    if (!this.token) return toast('Kết nối Spotify trước');
    audio.pause();
    state.source = 'spotify';
    state.sp = { progress: 0, at: performance.now(), playing: false, duration: 0 };
    this.trackId = null;
    state.title = 'Spotify';
    state.artist = 'Đang chờ bài hát…';
    state.lines = [];
    updateMeta();
    resetStage();
    $('#hint').classList.add('hide');
    $('#panel').classList.remove('open');
    clearInterval(this.timer);
    this.timer = setInterval(() => this.poll(), 2000);
    this.poll();
    this.render();
    toast('Đang theo dõi bài phát trên Spotify');
  },

  stop() {
    clearInterval(this.timer);
    this.timer = null;
    this.player?.disconnect();
    this.player = null;
    this.trackId = null;
    if (state.source === 'spotify') state.source = 'file';
    this.render();
  },

  async poll() {
    if (state.source !== 'spotify' || (document.hidden && !this.player)) return;
    let s;
    try { s = await this.api('/me/player'); } catch (e) { console.warn('Spotify poll', e); return; }
    if (!s || !s.item) return this.update(null);
    this.update({
      id: s.item.uri, name: s.item.name, artists: s.item.artists.map((a) => a.name),
      album: s.item.album?.name, duration: s.item.duration_ms, progress: s.progress_ms, playing: s.is_playing,
    });
  },

  update(info) {
    if (state.source !== 'spotify') return;
    if (!info) {
      state.sp.playing = false;
      if (!this.trackId) $('#mArtist').textContent = 'Mở Spotify và phát một bài';
      return;
    }
    const cur = clock.time() * 1000;
    const drift = Math.abs(cur - info.progress);
    // ignore small drift caused by network latency so words don't jitter
    if (drift > 350 || info.playing !== state.sp.playing || info.id !== this.trackId) {
      state.sp = { progress: info.progress, at: performance.now(), playing: info.playing, duration: info.duration };
    }
    state.sp.duration = info.duration;
    $('#dur').textContent = fmt(info.duration / 1000);
    if (info.id !== this.trackId) {
      this.trackId = info.id;
      this.newTrack(info);
    } else if (drift > 1500) {
      resetStage();
    }
  },

  async newTrack(info) {
    const id = info.id;
    state.title = info.name;
    state.artist = info.artists.join(', ');
    state.lines = [];
    state.hasLyrics = false;
    pickSongStyles();
    updateMeta();
    resetStage();
    $('#q').value = `${info.artists[0]} - ${info.name}`;
    const lrc = await fetchLyrics(info.name, info.artists[0], info.album, info.duration / 1000);
    if (this.trackId !== id) return;
    if (!lrc) {
      toast('Không tìm thấy lời đồng bộ — thử tìm thủ công trong bảng bên phải');
      search($('#q').value);
      return;
    }
    loadLyrics(lrc, { quiet: true });
    state.title = info.name;
    state.artist = info.artists.join(', ');
    pickSongStyles();
    updateMeta();
    resetStage();
  },

  async toggle() {
    if (this.player) return this.player.togglePlay();
    const playing = state.sp?.playing;
    try {
      await this.api('/me/player/' + (playing ? 'pause' : 'play'), { method: 'PUT' });
      state.sp = { ...state.sp, progress: clock.time() * 1000, at: performance.now(), playing: !playing };
    } catch (e) {
      toast('Điều khiển từ đây cần Spotify Premium (' + e.message + ')');
    }
  },

  async seek(sec) {
    const ms = Math.round(sec * 1000);
    try {
      if (this.player) await this.player.seek(ms);
      else await this.api('/me/player/seek?position_ms=' + ms, { method: 'PUT' });
      state.sp = { ...state.sp, progress: ms, at: performance.now() };
      resetStage();
    } catch (e) {
      toast('Tua từ đây cần Spotify Premium');
    }
  },

  async playHere() {
    if (!this.token) return toast('Kết nối Spotify trước');
    if (!window.Spotify) {
      await new Promise((res, rej) => {
        window.onSpotifyWebPlaybackSDKReady = res;
        const s = document.createElement('script');
        s.src = 'https://sdk.scdn.co/spotify-player.js';
        s.onerror = rej;
        document.head.appendChild(s);
      }).catch(() => toast('Không tải được Spotify SDK'));
      if (!window.Spotify) return;
    }
    if (state.source !== 'spotify') this.start();
    const player = new window.Spotify.Player({ name: 'Lyric Box', getOAuthToken: (cb) => this.access().then(cb), volume: 0.8 });
    player.addListener('ready', async ({ device_id }) => {
      try {
        await this.api('/me/player', { method: 'PUT', body: JSON.stringify({ device_ids: [device_id], play: true }) });
        toast('Đang phát trên thiết bị “Lyric Box”');
      } catch (e) { toast('Không chuyển được thiết bị: ' + e.message); }
    });
    player.addListener('player_state_changed', (s) => {
      if (!s) return;
      const tr = s.track_window.current_track;
      this.update({
        id: tr.uri, name: tr.name, artists: tr.artists.map((a) => a.name),
        album: tr.album?.name, duration: s.duration, progress: s.position, playing: !s.paused,
      });
    });
    for (const ev of ['initialization_error', 'authentication_error', 'account_error', 'playback_error']) {
      player.addListener(ev, ({ message }) => toast('Spotify: ' + message));
    }
    player.activateElement?.();
    if (await player.connect()) this.player = player;
  },

  render() {
    const on = !!this.token;
    $('#spLogin').hidden = on;
    $('#spConnected').hidden = !on;
    $('#spClient').value = this.clientId;
    $('#spRedirect').textContent = redirectUri();
    $('#spHostNote').hidden = location.hostname !== 'localhost';
    $('#spHostLink').href = location.href.replace('//localhost', '//127.0.0.1');
    $('#btnSpFollow').textContent = state.source === 'spotify' ? 'Đang theo dõi Spotify ✓' : 'Theo dõi bài đang phát';
  },
};

$('#btnSpLogin').onclick = () => SP.login();
$('#btnSpFollow').onclick = () => SP.start();
$('#btnSpHere').onclick = () => SP.playHere();
$('#btnSpLogout').onclick = () => SP.logout();
document.addEventListener('visibilitychange', () => { if (!document.hidden) SP.poll(); });
SP.render();
SP.handleRedirect();
setTheme(store.get('theme') || 'clear');

new ResizeObserver(() => { sizeStage(); resetStage(); }).observe(stage);
document.fonts?.ready.then(resetStage);
sizeStage();
updateMeta();
requestAnimationFrame(tick);
