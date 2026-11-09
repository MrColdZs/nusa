// Nusa untuk Windows & Linux. Logikanya ngikutin versi Mac (Sources/*.swift).
'use strict';

const CANVAS_W = 840;
const $ = (s, r = document) => r.querySelector(s);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const LS = {
  get: (k, d) => { try { const v = localStorage.getItem('nusa.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set: (k, v) => { try { localStorage.setItem('nusa.' + k, JSON.stringify(v)); } catch {} },
};
const pad = (n) => String(n).padStart(2, '0');
const clock = (sec) => { const s = Math.max(0, Math.floor(sec)); return s >= 3600 ? `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}` : `${Math.floor(s / 60)}:${pad(s % 60)}`; };
const hhmm = (d, tz) => new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit', ...(tz ? { timeZone: tz } : {}) }).format(d);
const isWin = window.nusa?.platform === 'win32';

const S = {
  hover: false, expanded: false, pinned: false, tab: LS.get('tab', 'home'), flash: null,
  media: null, tint: null, weather: null, battery: null,
  timer: null, focus: null, clips: [], tasks: LS.get('tasks', []),
  place: Prayer.city(LS.get('city', 'Cikarang')), sound: LS.get('sound', 'adzan'), soon: LS.get('soon', true),
  q: { book: null, surah: LS.get('qSurah', 1), mark: LS.get('qMark', null), english: LS.get('qEnglish', false), font: LS.get('qFont', 'Scheherazade New') },
  reciting: null, music: { queue: [], idx: -1, playing: false, online: false, query: '', results: [], searching: false },
  menu: null, taskText: '', taskPick: null,
  // Samain versi Mac: volume sistem, Rak (Tray), kalender hari, cermin kamera, geser posisi lagu
  audio: null, shelf: LS.get('shelf', []), files: {}, dropping: false, calSel: null, mirror: null, scrub: null,
  cal: { status: 'loading', events: [], at: 0 },
};
let flashTimer = null;

/* ================= ukuran & bentuk ================= */

function presentation() {
  if (S.expanded) return 'expanded';
  if (S.flash) return 'flash';
  if (!S.hover) return 'lip';
  if (S.focus) return 'focus';
  if (S.media?.title) return 'music';
  if (S.timer) return 'timer';
  return 'idle';
}

function size(p = presentation()) {
  const bump = 12;
  const c = (w) => ({ w: w + bump, h: 24, r: 9, s: 7 });
  switch (p) {
    case 'lip': return { w: 150, h: 6, r: 3, s: 3 };
    case 'idle': return c(150);
    case 'music': return c(S.timer ? 268 : 248);
    case 'timer': return c(168);
    case 'focus': return c(250);
    case 'flash': {
      const k = S.flash.kind;
      if (SMALL_FLASH.includes(k)) return { w: 232, h: 24, r: 9, s: 7 };
      const w = { track: 318, prayer: 318, task: 340, rain: 318, focusEnd: 360, charging: 300, device: 330 }[k] || 300;
      return { w, h: k === 'charging' ? 58 : 60, r: 20, s: 10 };
    }
    default: {
      const h = { prayer: 204, quran: 400, music: 330, tasks: 330 }[S.tab] || 190;
      return { w: 760, h, r: 26, s: 14 };
    }
  }
}

let lastKey = '', lastH = 0;
function render(force) {
  const p = presentation();
  const sz = size(p);
  const island = $('#island');
  island.classList.toggle('closing', sz.h < lastH);
  lastH = sz.h;
  for (const [k, v] of Object.entries(sz)) island.style.setProperty('--' + k, v + 'px');
  island.classList.toggle('big', p === 'expanded' || p === 'flash');
  island.dataset.mode = p;
  // Latar panel Home ikut warna sampul, tipis aja
  const tinted = p === 'expanded' && (S.tab === 'home' || (S.tab === 'music' && !S.music.online)) && S.media?.title && S.tint;
  island.classList.toggle('tinted', !!tinted);
  if (S.tint) {
    island.style.setProperty('--tint', S.tint);
    $('.tint', island).style.background = `linear-gradient(135deg, ${S.tint}38, ${S.tint}0d 45%, transparent 75%)`;
  }
  const key = p === 'expanded' ? 'x:' + S.tab : p === 'flash' ? 'f:' + S.flash.kind + S.flash.id : p;
  if (force || key !== lastKey) {
    lastKey = key;
    $('#content').innerHTML = `<div class="view ${viewClass(p)}">${build(p)}</div>`;
    afterBuild(p);
  }
  live();
  // Area yang bisa diklik/hover (sisanya tembus ke app di belakang)
  const full = sz.w + sz.s * 2;
  const m = p === 'expanded' ? 6 : 0;
  nusa.setRect({ x: (CANVAS_W - full) / 2 - m, y: 0, w: full + m * 2, h: Math.max(sz.h, 8) + m });
}

/** Pop-up kecil seukuran notch (volume, baterai lemah, charger dicabut, timer selesai). */
const SMALL_FLASH = ['volume', 'low', 'unplug', 'done'];
const viewClass = (p) => p === 'flash' && SMALL_FLASH.includes(S.flash.kind) ? 'compact'
  : ({ expanded: 'panel', flash: 'pop', lip: '' }[p] ?? (p === 'idle' ? 'compact center' : 'compact'));

/* ================= isi ================= */

function build(p) {
  if (p === 'lip') return '';
  if (p === 'flash') return flashHTML(S.flash);
  if (p === 'expanded') return panelHTML();
  if (p === 'music') {
    const m = S.media;
    return `${m.art ? `<img class="art" src="${esc(m.art)}" alt="">` : `<span class="art"></span>`}<span class="t">${esc(m.title)}</span>
      <span class="eq ${m.playing ? 'on' : ''}"><i></i><i></i><i></i><i></i></span>${S.timer ? ringSVG('timer') : ''}`;
  }
  if (p === 'timer') return `${IC.timer}<span class="t"></span><span class="mono" style="color:#ff9f0a" data-live="timerLeft"></span>`;
  if (p === 'focus') return `<span data-live="focusRing"></span><span class="t">${esc(S.focus.phase === 'focus' ? S.focus.title || 'Focus' : 'Break')}</span><span class="mono" data-live="focusLeft" style="color:${S.focus.phase === 'focus' ? 'var(--mint)' : 'var(--rest)'}"></span>`;
  return `<span data-live="idle"></span>`;
}

function afterBuild(p) {
  // Cermin: kamera mati kalau panel ditutup / pindah tab
  if (S.mirror?.stream && (p !== 'expanded' || S.tab !== 'home')) stopMirror();
  const v = $('#mirror');
  if (v && S.mirror?.stream && v.srcObject !== S.mirror.stream) v.srcObject = S.mirror.stream;
  if (p !== 'expanded') return;
  if (S.tab === 'quran') scrollQuran(false);
  if (S.tab === 'home' && Date.now() - S.cal.at > 60000) loadCalendar();
  if (S.tab === 'music') { musicPoll(); $('#musicQ')?.focus(); }
  if (S.tab === 'tasks') $('#taskIn')?.focus();
}

function ringSVG(kind) {
  let frac = 0, color = '#ff9f0a';
  if (kind === 'timer' && S.timer) frac = 1 - (S.timer.end - Date.now()) / S.timer.total;
  if (kind === 'focus' && S.focus) { frac = 1 - (S.focus.end - Date.now()) / S.focus.total; color = S.focus.phase === 'focus' ? '#5cdba8' : '#ffb85a'; }
  const C = 2 * Math.PI * 5;
  return `<svg class="ring" viewBox="0 0 13 13"><circle cx="6.5" cy="6.5" r="5" stroke="${color}" opacity=".25"/><circle cx="6.5" cy="6.5" r="5" stroke="${color}"
    stroke-dasharray="${C}" stroke-dashoffset="${C * (1 - Math.max(0, Math.min(1, frac)))}" stroke-linecap="round" transform="rotate(-90 6.5 6.5)"/></svg>`;
}

/* ---------- pop-up ---------- */

function flashHTML(f) {
  switch (f.kind) {
    case 'track':
      return `${S.media?.art ? `<img class="badge" src="${esc(S.media.art)}" style="border-radius:9px;object-fit:cover" alt="">` : `<span class="badge">${IC.music}</span>`}
        <span class="txt"><b>${esc(S.media?.title)}</b><small>${esc(S.media?.artist)}</small></span><span class="eq on" style="--tint:${S.tint || '#fff'}"><i></i><i></i><i></i><i></i></span>`;
    case 'prayer':
      return `<span class="badge">${IC.moon}</span><span class="txt"><b>${f.soon ? `${esc(f.name)} in 10 minutes` : `It’s time for ${esc(f.name)}`}</b><small>${f.soon ? 'Get ready' : 'Click to dismiss'}</small></span><span class="mono" style="font-size:16px;font-weight:600">${f.time}</span>`;
    case 'task':
      return `<span class="badge" style="color:var(--mint)">${IC.bell}</span><span class="txt"><b>${esc(f.title)}</b><small>Reminder · ${esc(f.time)}</small></span>
        <button class="cbtn" data-act="taskSnooze" data-id="${f.id}" title="Snooze 10 minutes">${IC.clock}</button><button class="cbtn mint" data-act="taskDone" data-id="${f.id}" title="Mark as done">${IC.check}</button>`;
    case 'rain':
      return `<span class="badge" style="color:#73bfff">${IC.umbrella}</span><span class="txt"><b>Rain likely around ${f.time}</b><small>${f.chance}% chance · bring an umbrella</small></span>`;
    case 'focusEnd':
      return `<span class="badge" style="color:${f.rest ? 'var(--rest)' : 'var(--mint)'}">${f.rest ? IC.cup : IC.target}</span>
        <span class="txt"><b>${f.rest ? 'Break’s over' : 'Focus session done'}</b><small>${f.rest ? 'Ready for another round?' : `${focusToday()} today${f.title ? ' · ' + esc(f.title) : ''}`}</small></span>
        ${f.rest ? `<button class="pill" style="background:var(--mint)" data-act="focus">${IC.target} Focus</button>` : `<button class="pill" style="background:var(--rest)" data-act="break">${IC.cup} Break</button>`}
        <button class="cbtn" data-act="dismiss">${IC.x}</button>`;
    case 'charging': {
      const mins = S.battery?.toFull;
      const detail = mins > 0 ? (mins >= 60 ? `${Math.floor(mins / 60)} hr ${mins % 60} min until full` : `${mins} min until full`) : 'Connected to power';
      return `<span class="batt"><i id="battFill"></i>${IC.bolt}</span><span class="txt"><b>Charging</b><small>${detail}</small></span><span class="big mono">${f.percent}%</span>`;
    }
    case 'device':
      return `<span class="badge">${IC.headphones}</span><span class="txt"><b>${esc(f.name)}</b><small class="mono">${esc(f.detail)}</small></span><span style="color:var(--green);font-size:16px">${IC.check}</span>`;
    case 'volume': return `<span data-live="volFlash" style="display:contents"></span>`;
    case 'low': return smallRow(IC.battLow, 'var(--late)', 'Low battery', `${f.percent}%`, 'var(--late)');
    case 'unplug': return smallRow(IC.plug, 'var(--dim)', 'Charger removed', `${f.percent}%`, '#fff');
    case 'done': return smallRow(IC.timer, '#ff9f0a', 'Time’s up', '', '#ff9f0a');
  }
  return '';
}

const smallRow = (icon, tint, text, value, valueTint) =>
  `<span style="color:${tint};display:inline-flex">${icon}</span><span class="t">${text}</span><span class="mono" style="color:${valueTint}">${value}</span>`;

const spkIcon = (a) => !a || a.muted || a.vol === 0 ? IC.spk0 : a.vol < 0.34 ? IC.spk1 : IC.spk2;

function volFlashHTML() {
  const f = S.flash;
  if (f?.kind !== 'volume') return '';
  return `<span style="display:inline-flex;width:18px;justify-content:center">${spkIcon({ vol: f.level, muted: f.muted })}</span>
    <span class="vbar"><i style="width:${(f.muted ? 0 : f.level) * 100}%"></i></span>
    <span class="mono" style="width:38px;text-align:right">${f.muted ? 'Muted' : Math.round(f.level * 100) + '%'}</span>`;
}

function showFlash(f, seconds) {
  clearTimeout(flashTimer);
  // Volume yang digeser terus: isinya aja yang diganti, biar nggak animasi ulang tiap langkah
  if (f.kind === 'volume' && S.flash?.kind === 'volume') {
    Object.assign(S.flash, f);
    live();
    flashTimer = setTimeout(() => { S.flash = null; render(); }, seconds * 1000);
    return;
  }
  S.flash = { ...f, id: Math.random().toString(36).slice(2) };
  render();
  if (f.kind === 'charging') requestAnimationFrame(() => requestAnimationFrame(() => { const b = $('#battFill'); if (b) b.style.width = `${Math.round(36 * f.percent / 100)}px`; }));
  flashTimer = setTimeout(() => { S.flash = null; render(); }, seconds * 1000);
}

/* ---------- panel ---------- */

const TABS = [['home', 'Home', 'home'], ['music', 'Music', 'music'], ['tasks', 'Tasks', 'tasks'], ['tray', 'Tray', 'tray'], ['clips', 'Clips', 'clips'], ['prayer', 'Prayer', 'moon'], ['quran', 'Quran', 'book']];

function panelHTML() {
  const tabs = TABS.map(([k, label, ic]) => `<button class="tab ${S.tab === k ? 'on' : ''}" data-act="tab" data-tab="${k}" title="${label}">${IC[ic]}${S.tab === k ? `<span>${label}</span>` : ''}</button>`).join('');
  const timer = S.timer
    ? `<span style="color:#ff9f0a;font-size:12px" class="mono" data-live="timerLeft"></span><button class="chip" data-act="timerStop">Stop</button>`
    : `<span style="color:var(--dim)">${IC.timer}</span>${[5, 15, 25].map((m) => `<button class="chip" data-act="timer" data-m="${m}">${m}m</button>`).join('')}`;
  const w = S.weather;
  const wx = w ? `<button class="chip" data-act="wxMenu" title="${esc(wxLabel(w.code))} · feels ${Math.round(w.feels)}°">${IC[wxIcon(w.code, w.day)]}<span class="mono">${Math.round(w.temp)}°</span></button>` : '';
  const b = S.battery;
  const batt = b ? `<span class="bicon ${b.charging ? 'chg' : b.level <= 20 ? 'low' : ''}" title="${b.level}%${b.charging ? ' · charging' : ''}"><i style="width:${Math.max(8, b.level)}%"></i>${b.charging ? IC.bolt : ''}</span>
    <span class="mono" style="font-size:11px;font-weight:500">${b.level}%</span>` : '';
  const vol = S.audio ? `<span class="vol" title="${esc(S.audio.name)}"><button data-act="muteToggle" title="${S.audio.muted ? 'Unmute' : 'Mute'}">${spkIcon(S.audio)}</button>
    <span class="vtrack" id="volTrack" data-live="volLevel"></span></span><span class="sep"></span>` : '';
  return `<div class="top">${tabs}<span class="sp"></span>${vol}${timer}<span class="sep"></span>${wx}${batt}
      <button class="ibtn ${S.pinned ? 'on' : ''}" data-act="pin" title="${S.pinned ? 'Unpin panel' : 'Keep panel open'}">${S.pinned ? IC.lock : IC.unlock}</button>
      <button class="ibtn" data-act="gear" title="Settings">${IC.gear}</button></div>
    <div class="body">${({ home: homeHTML, music: musicHTML, tasks: tasksHTML, tray: trayHTML, prayer: prayerHTML, quran: quranHTML, clips: clipsHTML }[S.tab] || homeHTML)()}</div>
    ${S.menu ? menuHTML() : ''}`;
}

/* ---------- Home ---------- */

/** Sampul + ikon app sumber di pojoknya; diklik = buka app yang lagi muter. */
function coverHTML(m, cls = 'cover') {
  const src = m.hiArt || m.art;
  const img = src ? `<img class="${cls}" src="${esc(src)}" alt=""${m.hiArt && m.art ? ` data-fallback="${esc(m.art)}"` : ''}>` : `<span class="${cls} empty">${IC.music}</span>`;
  return `<span class="cwrap" ${m.path || m.source ? `data-act="openSource" title="Open ${esc(m.app || 'app')}"` : ''}>${img}${m.icon ? `<img class="appic" src="${esc(m.icon)}" alt="">` : ''}</span>`;
}

// Sampul HD gagal dimuat (offline dll.): balik ke sampul kecil dari Windows
document.addEventListener('error', (e) => { const f = e.target?.dataset?.fallback; if (f) { delete e.target.dataset.fallback; e.target.src = f; } }, true);

const seekable = (m) => m?.duration > 0 && !m.noTimeline && m.canSeek !== false;

function homeHTML() {
  const m = S.media;
  const music = m?.title
    ? `<div class="np">${coverHTML(m)}
        <div class="col" style="flex:1"><b>${esc(m.title)}</b>${m.album ? `<small>${esc(m.album)}</small>` : ''}<small>${esc(m.artist)}</small>
        <div class="ctl"><button data-act="mprev" title="Previous">${IC.prev}</button><button class="main" data-act="mtoggle" title="Play/Pause">${m.playing ? IC.pause : IC.play}</button><button data-act="mnext" title="Next">${IC.next}</button></div>
        ${m.duration && !m.noTimeline ? `<div class="bar ${seekable(m) ? 'seek' : ''}" data-live="mbar"></div>` : ''}</div></div>`
    : `<div class="note">${IC.music}<span>Nothing playing</span></div>`;
  return `<div class="col" style="width:250px;justify-content:center">${music}</div><div class="vline"></div>
    <div class="col" style="flex:1">${calendarHTML()}</div><div class="vline"></div>
    <div class="col wxcol" style="width:168px;justify-content:center">
      ${S.mirror?.stream ? `<video id="mirror" autoplay muted playsinline></video>` : `<div class="col" data-live="wxCard"></div>`}
      <button class="mirror-btn ${S.mirror?.stream ? 'on' : ''}" data-act="mirror" title="${S.mirror?.stream ? 'Close mirror' : S.mirror?.denied ? 'Camera blocked — allow it in Windows Settings › Privacy › Camera' : 'Mirror (camera)'}">${S.mirror?.stream ? IC.x : S.mirror?.denied ? IC.videoOff : IC.video}</button>
    </div>`;
}

/* Kalender: strip 7 hari kayak versi Mac. Isinya event dari kalender Windows (akun di Settings › Accounts /
   app Calendar bawaan), ditambah tugas Nusa yang jatuh tempo di hari itu dan sholat berikutnya kalau hari ini. */
const dayStart = (d) => { const x = new Date(d); x.setHours(0, 0, 0, 0); return x; };

async function loadCalendar() {
  if (!isWin) { S.cal = { status: 'off', events: [], at: Date.now() }; return; }
  const from = +dayStart(Date.now()) - 2 * 86400000;
  const r = await nusa.calendar(from, 7);
  S.cal = { status: r?.error === 'denied' ? 'denied' : r?.error ? 'error' : 'ok', events: r?.events || [], calendars: r?.calendars || 0, at: Date.now() };
  if (S.expanded && S.tab === 'home') live();
}

function calendarHTML() {
  const today = dayStart(new Date());
  const sel = S.calSel && +dayStart(S.calSel) ? dayStart(S.calSel) : today;
  const days = [-2, -1, 0, 1, 2, 3, 4].map((k) => new Date(+today + k * 86400000 + 3600000 * 2)).map(dayStart);
  const fmt = (d, o) => d.toLocaleDateString('en-US', o);
  return `<div class="cal-head"><b>${fmt(sel, { month: 'short' })}</b>${days.map((d) => {
    const isToday = +d === +today, isSel = +d === +sel, past = d < today;
    return `<button class="day ${isSel ? 'on' : ''} ${isToday ? 'today' : past ? 'past' : ''}" data-act="calDay" data-t="${+d}" title="${fmt(d, { weekday: 'long', month: 'long', day: 'numeric' })}">
      <small>${fmt(d, { weekday: 'short' }).slice(0, 3).toUpperCase()}</small><b class="mono">${d.getDate()}</b></button>`;
  }).join('')}</div><div class="cal-list" data-live="agenda"></div>`;
}

function agendaHTML() {
  const now = new Date(), today = dayStart(now);
  const sel = S.calSel ? dayStart(S.calSel) : today;
  const end = +sel + 86400000;
  const rows = [];
  if (+sel === +today) {
    const n = Prayer.next(S.place, now);
    if (n.date < end) rows.push({ color: 'var(--mint)', title: n.title, time: `${hhmm(n.date, S.place.tz)} · in ${mins(n.date - now)}`, at: +n.date });
  }
  // Event kalender Windows yang nyentuh hari ini (acara seharian / lewat tengah malam ikut kehitung)
  for (const e of S.cal.events) {
    const until = e.start + Math.max(1, e.minutes) * 60000;
    if (e.start >= end || until <= +sel) continue;
    rows.push({ color: e.color || '#0a85ff', title: e.title || 'Untitled', time: e.allDay ? 'All day' : hhmm(new Date(e.start)), at: e.allDay ? +sel - 1 : e.start, done: !e.allDay && until < +now });
  }
  for (const t of S.tasks) {
    if (t.done || !t.due) continue;
    const late = t.due < +now;
    if ((t.due >= +sel && t.due < end) || (+sel === +today && late)) rows.push({ color: late ? 'var(--late)' : 'var(--rest)', title: t.title, time: late ? 'Overdue' : hhmm(new Date(t.due)), at: t.due, late });
  }
  rows.sort((a, b) => a.at - b.at);
  if (S.cal.status === 'denied' && !rows.length) return `<button class="note" data-act="calSettings" style="gap:3px">${IC.calendar}<span>Allow calendar access in Settings</span></button>`;
  if (!rows.length) return `<div class="note" style="gap:3px">${IC.calendar}<span>${+sel === +today ? 'No more events today' : 'No events'}</span></div>`;
  return rows.slice(0, 4).map((r) => `<div class="ev ${r.late ? 'late' : r.done ? 'done' : ''}"><i style="background:${r.color}"></i><span>${esc(r.title)}</span><em class="mono">${r.time}</em></div>`).join('');
}

function wxCardHTML() {
  const w = S.weather;
  if (!w) return `<div class="note"><span>Loading weather…</span></div>`;
  const hours = w.hours.filter((h) => h.time > Date.now()).slice(0, 4);
  return `<div class="wx" style="display:flex;align-items:center;gap:8px">${IC[wxIcon(w.code, w.day)]}<b>${Math.round(w.temp)}°</b></div>
    <small style="color:var(--dim);font-size:11.5px">${wxLabel(w.code)} · feels ${Math.round(w.feels)}°</small>
    <small style="color:var(--faint);font-size:11px">${esc(S.place.name)}</small>
    <div class="wx-hours">${hours.map((h) => `<div>${hhmm(new Date(h.time), S.place.tz)}${IC[wxIcon(h.code, true)]}<b class="${h.rain >= 30 ? 'wet' : ''}">${h.rain >= 30 ? h.rain + '%' : Math.round(h.temp) + '°'}</b></div>`).join('')}</div>`;
}

/* ---------- Music ---------- */
// Senandung jalan → antrean + cari lagu. Nggak jalan → pemutar dari app apa aja (Spotify, browser, Media Player, dll).

function musicHTML() {
  const mu = S.music;
  if (!mu.online) return `<div class="col" style="flex:1">${systemPlayerHTML()}</div>`;
  const head = `<div class="field">${IC.search}<input id="musicQ" placeholder="Search songs, artists…" value="${esc(mu.query)}" autocomplete="off" spellcheck="false"></div>`;
  let list;
  if (mu.query.trim() && mu.searching && !mu.results.length) list = `<div class="note"><span>Searching…</span></div>`;
  else {
    const rows = mu.query.trim() ? mu.results : mu.queue;
    list = rows.length
      ? `<span class="label">${mu.query.trim() ? 'Results' : 'Up next'}</span><div class="scroll" style="margin-top:4px">${rows.map((s, k) => songRow(s, k, !mu.query.trim())).join('')}</div>`
      : `<div class="note">${IC.music}<span>${mu.query.trim() ? 'No songs found.' : 'Nothing queued in Senandung yet.'}</span></div>`;
  }
  return `<div class="col" style="flex:1;gap:10px">${head}${list}</div>`;
}

function systemPlayerHTML() {
  const m = S.media;
  if (!m?.title) return `<div class="note">${IC.music}<b>Nothing playing</b><span>Play something in Spotify, YouTube, or any music app — it’ll show up here.</span></div>`;
  const timeline = m.duration && !m.noTimeline;
  return `<div class="np big">${coverHTML(m)}
    <div class="col" style="flex:1;min-width:0">
      ${m.app ? `<span class="label">${m.playing ? 'Playing' : 'Paused'} · ${esc(m.app)}</span>` : ''}
      <b>${esc(m.title)}</b><small>${esc(m.artist)}</small>${m.album ? `<small>${esc(m.album)}</small>` : ''}
      <div class="ctl"><button data-act="mprev" title="Previous">${IC.prev}</button><button class="main" data-act="mtoggle" title="Play/Pause">${m.playing ? IC.pause : IC.play}</button><button data-act="mnext" title="Next">${IC.next}</button></div>
      ${timeline ? `<div class="bar ${seekable(m) ? 'seek' : ''}" data-live="mbar"></div><div class="times mono" data-live="mtime"></div>` : ''}
    </div></div>`;
}

function songRow(s, k, queue) {
  const now = queue && s.i === S.music.idx;
  const art = s.art ? (s.art.startsWith('/') ? 'http://127.0.0.1:5560' + s.art : 'http://127.0.0.1:5560/api/yt/img?u=' + encodeURIComponent(s.art)) : '';
  return `<div class="row ${now ? 'now' : ''}" data-act="${queue ? 'mjump' : 'mplay'}" data-k="${k}">
    ${art ? `<img class="cover" src="${esc(art)}" loading="lazy" alt="">` : `<span class="cover"></span>`}
    <span class="t"><b>${esc(s.title)}</b><small>${esc(s.artist)}</small></span>
    ${now ? `<span style="color:var(--mint)">${IC.wave}</span>` : ''}${s.duration ? `<span class="d">${clock(s.duration)}</span>` : ''}
    ${queue ? '' : `<button class="small-btn hov" data-act="mqueue" data-k="${k}" title="Play next">${IC.plus}</button>`}</div>`;
}

let musicTimer = null, searchTimer = null;
async function musicPoll() {
  clearTimeout(musicTimer);
  if (!S.expanded || S.tab !== 'music') return;
  const st = await nusa.senandung('GET', '/api/remote/state');
  const mu = S.music;
  const was = JSON.stringify([mu.online, mu.idx, mu.queue.length, mu.playing]);
  mu.online = !!st;
  if (st) { mu.queue = st.queue || []; mu.idx = st.idx; mu.playing = st.playing; }
  if (JSON.stringify([mu.online, mu.idx, mu.queue.length, mu.playing]) !== was && !mu.query.trim()) { refreshBody(); render(); }
  musicTimer = setTimeout(musicPoll, 1500);
}

function musicSearch() {
  clearTimeout(searchTimer);
  const q = S.music.query.trim();
  if (!q) { S.music.results = []; return refreshBody(); }
  S.music.searching = true;
  searchTimer = setTimeout(async () => {
    const res = await nusa.senandung('GET', `/api/yt/search?q=${encodeURIComponent(q)}&type=songs`);
    if (S.music.query.trim() !== q) return;
    S.music.results = (res || []).filter((x) => x.vid).slice(0, 25);
    S.music.searching = false;
    refreshBody();
  }, 400);
}

/** Ganti isi panel tanpa ngerusak kolom input yang lagi diketik. */
function refreshBody() {
  if (!S.expanded) return;
  const body = $('.body');
  if (!body) return;
  if (S.tab === 'music') {
    const field = $('.field', body);
    const html = musicHTML();
    const tmp = document.createElement('div');
    tmp.innerHTML = html;
    const fresh = tmp.firstElementChild;
    // Kolom cari yang lama dipertahanin biar ketikan & fokus nggak ilang
    if (field && fresh.firstElementChild?.classList.contains('field')) fresh.replaceChild(field, fresh.firstElementChild);
    body.replaceChildren(fresh);
    live();
  } else if (S.tab === 'tasks') {
    const list = $('#taskList');
    if (list) list.innerHTML = taskListHTML();
    const count = $('#taskCount');
    if (count) count.outerHTML = taskCountHTML();
  } else render(true);
  live();
}

/* ---------- Tasks ---------- */

const saveTasks = () => LS.set('tasks', S.tasks);
const uid = () => Math.random().toString(36).slice(2) + Date.now().toString(36);

function dueText(d) {
  const now = new Date(), t = hhmm(d);
  const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((day(d) - day(now)) / 86400000);
  if (diff === 0) return `Today ${t}`;
  if (diff === 1) return `Tomorrow ${t}`;
  if (diff === -1) return `Yesterday ${t}`;
  return `${d.toLocaleDateString('en-US', { weekday: 'short', day: 'numeric', month: 'short' })} · ${t}`;
}

function quickPicks() {
  const now = new Date();
  const tonight = new Date(now); tonight.setHours(20, 0, 0, 0);
  const tomorrow = new Date(now); tomorrow.setDate(tomorrow.getDate() + 1); tomorrow.setHours(9, 0, 0, 0);
  return [['In 30 min', +now + 1800000], ['In 1 hour', +now + 3600000], ...(tonight - now > 3600000 ? [['Tonight 20:00', +tonight]] : []), ['Tomorrow 09:00', +tomorrow]];
}

function taskCountHTML() {
  const open = S.tasks.filter((t) => !t.done), late = open.filter((t) => t.due && t.due < Date.now()).length;
  return `<span id="taskCount" style="font-size:11px;color:${late ? 'var(--late)' : 'var(--dim)'}">${open.length} to do${late ? ` · ${late} overdue` : ''}</span>`;
}

function tasksHTML() {
  const preview = S.taskPick?.[1] ?? TaskParser.parse(S.taskText).due;
  return `<div class="col" style="flex:1;gap:10px">
    <div class="field"><span class="ic mint">${IC.plus}</span><input id="taskIn" placeholder="Add a task… “Rapat QC besok jam 9”" value="${esc(S.taskText)}" autocomplete="off" spellcheck="false">
      <span id="taskPreview">${S.taskText && preview ? `<span class="chip on">${IC.bell}${dueText(new Date(preview))}</span>` : ''}</span></div>
    <div class="chips">${quickPicks().map(([l, t]) => `<button class="chip ${S.taskPick?.[0] === l ? 'on' : ''}" data-act="pick" data-l="${l}" data-t="${t}">${l}</button>`).join('')}
      <span class="sp"></span>${S.focus ? `<button class="chip on" data-act="focusStop">${S.focus.phase === 'focus' ? 'Stop focus' : 'Skip break'}</button>`
      : `<button class="chip" data-act="focus">${IC.target} Focus 25m${focusToday() ? ` · ${focusToday()} today` : ''}</button>`}${taskCountHTML()}</div>
    <div class="scroll" id="taskList">${taskListHTML()}</div></div>`;
}

function taskListHTML() {
  if (!S.tasks.length) return `<div class="note">${IC.tasks}<b>Nothing to do</b><span>Type a task with a time, like “Rapat QC besok jam 9” or “Call Budi in 30 min”.</span></div>`;
  const now = Date.now();
  const sorted = [...S.tasks].sort((a, b) => (a.done - b.done) || ((a.due ?? Infinity) - (b.due ?? Infinity)) || (a.created - b.created));
  return sorted.map((t) => {
    const late = !t.done && t.due && t.due < now;
    return `<div class="row ${t.done ? 'done' : ''}"><button class="check ${t.done ? 'on' : ''}" data-act="taskToggle" data-id="${t.id}">${t.done ? IC.check : ''}</button>
      <span class="t"><b>${esc(t.title)}</b></span>${t.due ? `<span class="d ${late ? 'late' : ''}">${late ? 'Overdue · ' : ''}${dueText(new Date(t.due))}</span>` : ''}
      ${t.done ? '' : `<button class="small-btn mint hov ${S.focus?.taskId === t.id ? 'keep' : ''}" data-act="focusTask" data-id="${t.id}" title="Focus on this for 25 minutes">${IC.target}</button>`}
      <button class="small-btn hov" data-act="taskDel" data-id="${t.id}" title="Delete">${IC.x}</button></div>`;
  }).join('');
}

function addTask() {
  const r = TaskParser.parse(S.taskText);
  if (!r.title) return;
  S.tasks.push({ id: uid(), title: r.title, due: S.taskPick ? S.taskPick[1] : r.due ? +r.due : null, done: false, notified: false, created: Date.now() });
  S.taskText = ''; S.taskPick = null;
  saveTasks();
  render(true);
}

function checkTasks() {
  const now = Date.now();
  S.tasks = S.tasks.filter((t) => !(t.done && t.doneAt && now - t.doneAt > 86400000));
  const t = S.tasks.find((x) => !x.done && !x.notified && x.due && x.due <= now);
  if (!t) return;
  t.notified = true;
  saveTasks();
  chime([880, 1320]);
  if (!S.pinned) S.expanded = false;
  showFlash({ kind: 'task', id: t.id, title: t.title, time: dueText(new Date(t.due)) }, 30);
}

/* ---------- Prayer ---------- */

function prayerHTML() {
  return `<div class="col" style="width:262px;flex-direction:row;align-items:center;gap:16px" data-live="prTop"></div>
    <div class="col" style="flex:1;margin-left:22px;gap:6px">
      <div style="display:flex;justify-content:space-between;font-size:11px"><b>Today</b><span style="color:var(--dim)" class="mono" data-live="prMarks"></span></div>
      <div class="track" data-live="prTrack"></div>
      <div class="chips"><button class="chip" data-act="cityMenu">${IC.pin} ${esc(S.place.name)} · ${S.place.zone}</button>
        <span class="chip">${qiblaArrow()} Qibla ${Math.round(Prayer.qibla(S.place).deg)}° ${Prayer.qibla(S.place).point}</span>
        <button class="chip" data-act="tab" data-tab="quran">${IC.book} Quran</button><span class="sp"></span>
        <button class="chip" data-act="soundMenu">${IC.speaker} ${{ adzan: 'Adzan', tone: 'Tone', silent: 'Silent' }[S.sound]} ${IC.chevron}</button></div>
    </div>`;
}

const qiblaArrow = () => `<span style="display:inline-grid;rotate:${Prayer.qibla(S.place).deg}deg">${IC.north}</span>`;
const mins = (ms) => { const m = Math.ceil(ms / 60000); return m >= 60 ? `${Math.floor(m / 60)} hr ${m % 60} min` : `${m} min`; };

function lastPrayer(now) {
  const done = Prayer.times(S.place, now).filter((t) => t.prayer && t.date <= now);
  if (done.length) return done[done.length - 1].date;
  return Prayer.times(S.place, new Date(+now - 86400000)).find((t) => t.key === 'isya').date;
}

function prTopHTML() {
  const now = new Date(), n = Prayer.next(S.place, now), prev = lastPrayer(now);
  const frac = Math.max(0, Math.min(1, (now - prev) / (n.date - prev)));
  const C = 2 * Math.PI * 38, left = (n.date - now) / 1000;
  const hijri = new Intl.DateTimeFormat('en-US-u-ca-islamic-umalqura', { day: 'numeric', month: 'long', year: 'numeric' }).format(now);
  return `<div class="pr-ring"><svg viewBox="0 0 84 84"><circle cx="42" cy="42" r="38" stroke="rgba(255,255,255,.1)"/><circle cx="42" cy="42" r="38" stroke="var(--mint)" stroke-linecap="round" stroke-dasharray="${C}" stroke-dashoffset="${C * (1 - frac)}"/></svg>
    <div><b>${clock(left)}</b><small>left</small></div></div>
    <div class="col" style="gap:2px"><span class="label">Up next</span><span class="pr-next">${n.title}</span>
    <span class="mono" style="color:var(--dim);font-size:12px">${hhmm(n.date, S.place.tz)} · in ${mins(n.date - now)}</span>
    <span style="color:var(--faint);font-size:11px;margin-top:4px">${hijri.replace(/ AH$/, '')} AH</span></div>`;
}

function prTrackHTML() {
  const now = new Date(), all = Prayer.times(S.place, now), five = all.filter((t) => t.prayer), n = Prayer.next(S.place, now);
  const start = +all[0].date - 1800000, end = +five[4].date + 3600000;
  const x = (d) => `calc(26px + (100% - 52px) * ${Math.max(0, Math.min(1, (d - start) / (end - start)))})`;
  return `<div class="ln"><i style="width:calc((100%) * ${Math.max(0, Math.min(1, (now - start) / (end - start)))})"></i></div>
    ${five.map((t, i) => {
      const cls = +t.date === +n.date ? 'next' : t.date <= now ? 'past' : '';
      return `<span class="dot ${cls}" style="left:${x(t.date)}"></span><span class="lbl ${cls}" style="left:${x(t.date)};top:${i % 2 ? 0 : 48}px">${t.title}<b>${hhmm(t.date, S.place.tz)}</b></span>`;
    }).join('')}<span class="now" style="left:${x(now)}"></span>`;
}

let alarm = new Prayer.Alarm(S.place);
alarm.check(new Date()); // yang udah lewat pas app baru nyala nggak dibunyiin
function checkPrayer() {
  const e = alarm.check(new Date());
  if (!e) return;
  const time = hhmm(e.date, S.place.tz);
  if (e.type === 'soon') { if (S.soon) showFlash({ kind: 'prayer', name: e.title, time, soon: true }, 6); return; }
  if (S.sound !== 'silent' && S.media?.playing) nusa.media('pause');
  playPrayerSound();
  S.expanded = false;
  showFlash({ kind: 'prayer', name: e.title, time, soon: false }, 45);
}

function playPrayerSound() {
  stopPrayerSound();
  if (S.sound === 'adzan') { const a = $('#adhan'); a.currentTime = 0; a.play().catch(() => {}); }
  else if (S.sound === 'tone') chime([660, 990, 1320]);
}
const stopPrayerSound = () => { const a = $('#adhan'); a.pause(); };

/** Bunyi pengingat kecil, dibikin langsung (nggak perlu file suara). */
function chime(freqs) {
  try {
    const ctx = new AudioContext();
    freqs.forEach((f, i) => {
      const o = ctx.createOscillator(), g = ctx.createGain(), t = ctx.currentTime + i * 0.16;
      o.frequency.value = f; o.type = 'sine';
      g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(0.18, t + 0.02); g.gain.exponentialRampToValueAtTime(0.001, t + 0.9);
      o.connect(g).connect(ctx.destination); o.start(t); o.stop(t + 1);
    });
    setTimeout(() => ctx.close(), 2500);
  } catch {}
}

/* ---------- Quran ---------- */

const QFONTS = ['Scheherazade New', 'Amiri Quran'];
const RECITERS = [['ar.alafasy', 'Mishary Alafasy'], ['ar.husary', 'Mahmoud Al-Husary'], ['ar.minshawi', 'Al-Minshawi'], ['ar.mahermuaiqly', 'Maher Al-Muaiqly']];

async function loadQuran() {
  if (S.q.book) return;
  S.q.book = JSON.parse(await nusa.asset('quran.json'));
  if (S.expanded && S.tab === 'quran') render(true);
}

function quranHTML() {
  const b = S.q.book;
  if (!b) { loadQuran(); return `<div class="note"><span>Loading Quran…</span></div>`; }
  const s = b.surahs[S.q.surah - 1];
  const mark = S.q.mark;
  const markS = mark && b.surahs[mark.s - 1];
  const tr = S.q.english ? 2 : 1;
  return `<div class="col" style="flex:1;gap:8px;--qfont:'${S.q.font}'">
    <div class="chips"><button class="surah" data-act="surahMenu"><em>${s.n}</em>${esc(s.tr)} ${IC.chevron}</button>
      <span style="color:var(--dim);font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(s.en)} · ${s.v.length} verses · ${s.t === 'Meccan' ? 'Makkah' : 'Madinah'}</span><span class="sp"></span>
      ${markS ? `<button class="chip" data-act="goMark">${IC.bookmark} ${esc(markS.tr)} ${mark.a}</button>` : ''}
      <span style="font-family:var(--qfont);font-size:22px;white-space:nowrap">${esc(s.ar)}</span>
      <button class="cbtn mint" data-act="recite" title="Listen">${S.reciting && !$('#recite').paused ? IC.pause : IC.play}</button>
      ${S.reciting ? `<button class="cbtn" data-act="reciteStop" title="Stop">${IC.stop}</button>` : ''}
      <button class="cbtn" data-act="qMenu" title="Font & reciter" style="font-weight:700;font-size:12px">Aa</button>
      <button class="chip ${S.q.english ? '' : 'on'}" data-act="qLang" data-en="0">ID</button><button class="chip ${S.q.english ? 'on' : ''}" data-act="qLang" data-en="1">EN</button>
      <button class="cbtn" data-act="surahGo" data-d="-1" ${s.n === 1 ? 'disabled style="opacity:.3"' : ''}>${IC.left}</button><button class="cbtn" data-act="surahGo" data-d="1" ${s.n === 114 ? 'disabled style="opacity:.3"' : ''}>${IC.right}</button></div>
    <div class="scroll" id="qScroll">${s.n !== 1 && s.n !== 9 ? `<div class="bism" id="ayah-0">${esc(b.bismillah)}</div>` : ''}
      ${s.v.map((v, i) => {
        const n = i + 1, marked = mark && mark.s === s.n && mark.a === n, live = S.reciting && S.reciting.s === s.n && S.reciting.a === n;
        return `<div class="ayah ${marked ? 'mark' : ''} ${live ? 'live' : ''}" id="ayah-${n}" data-act="mark" data-a="${n}" title="Click to mark as last read">
          <div class="num"><span>${marked ? IC.bookmark : n}</span><button data-act="reciteFrom" data-a="${n}" title="Listen from this verse">${live ? IC.wave : IC.play}</button></div>
          <div style="flex:1"><div class="ar">${esc(v[0])}</div><div class="tr">${esc(v[tr])}</div></div></div>`;
      }).join('')}</div></div>`;
}

function scrollQuran(smooth, ayah) {
  const target = ayah ?? (S.q.mark && S.q.mark.s === S.q.surah ? S.q.mark.a : 0);
  const el = $(`#ayah-${target}`) || $('#ayah-1');
  if (el) el.scrollIntoView({ block: target ? 'center' : 'start', behavior: smooth ? 'smooth' : 'auto' });
}

function globalAyah(s, a) { return S.q.book.surahs.slice(0, s - 1).reduce((n, x) => n + x.v.length, 0) + a; }

function recite(s, a) {
  if (S.media?.playing) nusa.media('pause');
  S.reciting = { s, a };
  const audio = $('#recite');
  audio.src = `https://cdn.islamic.network/quran/audio/128/${LS.get('reciter', 'ar.alafasy')}/${globalAyah(s, a)}.mp3`;
  audio.play().catch(() => {});
  if (S.expanded && S.tab === 'quran') { render(true); scrollQuran(true, a); }
}

$('#recite').addEventListener('ended', () => {
  const r = S.reciting;
  if (!r) return;
  const count = S.q.book.surahs[r.s - 1].v.length;
  if (r.a >= count) { S.reciting = null; return S.expanded && render(true); }
  recite(r.s, r.a + 1);
});

/* ---------- Clips ---------- */

function clipsHTML() {
  if (!S.clips.length) return `<div class="note">${IC.clips}<span>Text you copy will appear here</span></div>`;
  return `<div class="cards" style="flex:1">${S.clips.map((c, i) => `<button class="card ${S.copied === i ? 'ok' : ''}" data-act="copy" data-i="${i}"><p>${esc(c.trim())}</p><small>${S.copied === i ? 'Copied' : c.length + ' characters'}</small></button>`).join('')}</div>`;
}

/* ---------- Rak (Tray): file yang ditaruh buat nanti ---------- */

const midTrim = (s, n = 16) => s.length <= n ? s : s.slice(0, Math.ceil(n / 2) - 1) + '…' + s.slice(-(Math.floor(n / 2)));

function trayHTML() {
  const items = S.shelf;
  const inner = items.length
    ? `<div class="shelf">${items.map((p, i) => {
        const f = S.files[p];
        return `<div class="sitem" draggable="true" data-act="fileOpen" data-i="${i}" title="${esc(p)}\nClick to open · drag out to use">
          ${f?.icon ? `<img src="${esc(f.icon)}" alt="">` : `<span class="ph">${IC.clips}</span>`}<small>${esc(midTrim(f?.name || p.split(/[\\/]/).pop()))}</small>
          <button class="rm" data-act="fileRemove" data-i="${i}" title="Remove from Tray">${IC.xCircle}</button></div>`;
      }).join('')}</div>
      <div class="shelf-side"><button class="sbtn" data-act="fileShow" title="Show the last file in its folder">${IC.clips}<span>Show</span></button>
        <button class="sbtn" data-act="trayClear" title="Remove everything from Tray">${IC.x}<span>Clear</span></button></div>`
    : `<div class="note">${IC.trayIn}<span>Drop files here to keep them for later</span></div>`;
  return `<div class="drop ${S.dropping ? 'on' : ''}">${inner}</div>`;
}

async function addToShelf(p) {
  if (!p || S.shelf.includes(p)) return;
  const info = await nusa.fileInfo(p);
  if (!info) return;
  S.files[p] = info;
  S.shelf = [...S.shelf, p];
  LS.set('shelf', S.shelf);
  if (S.expanded && S.tab === 'tray') render(true);
}

function removeFromShelf(p) {
  S.shelf = S.shelf.filter((x) => x !== p);
  LS.set('shelf', S.shelf);
  render(true);
}

/** Pas nyala: ambil ikon tiap file, yang udah dihapus/dipindah dibuang dari Rak. */
async function loadShelf() {
  const keep = [];
  for (const p of S.shelf) {
    const info = await nusa.fileInfo(p);
    if (info) { S.files[p] = info; keep.push(p); }
  }
  S.shelf = keep;
  LS.set('shelf', keep);
  if (S.expanded && S.tab === 'tray') render(true);
}

/* ---------- menu kecil di dalam panel ---------- */

function menuHTML() {
  const m = S.menu;
  const item = (label, act, data, on) => `<button class="${on ? 'on' : ''}" data-act="${act}" ${Object.entries(data).map(([k, v]) => `data-${k}="${esc(v)}"`).join(' ')}>${esc(label)}</button>`;
  let body = '';
  if (m.type === 'city') body = Prayer.CITIES.map((c) => item(`${c.name} · ${c.zone}`, 'city', { c: c.name }, c.name === S.place.name)).join('');
  if (m.type === 'sound') body = [['adzan', 'Adzan'], ['tone', 'Tone'], ['silent', 'Silent']].map(([k, l]) => item(l, 'sound', { s: k }, S.sound === k)).join('')
    + `<div class="h"></div>` + item('Remind me 10 minutes before', 'soonToggle', {}, S.soon) + item('Stop sound', 'soundStop', {}, false);
  if (m.type === 'surah') body = S.q.book.surahs.map((s) => item(`${s.n}. ${s.tr} · ${s.en}`, 'surah', { n: s.n }, s.n === S.q.surah)).join('');
  if (m.type === 'q') body = `<div class="h">Arabic font</div>` + QFONTS.map((f) => item(f, 'qFont', { f }, S.q.font === f)).join('')
    + `<div class="h">Reciter</div>` + RECITERS.map(([id, n]) => item(n, 'reciter', { r: id }, LS.get('reciter', 'ar.alafasy') === id)).join('');
  if (m.type === 'gear') body = item('Start at login', 'login', {}, m.login) + item('Quit Nusa', 'quit', {}, false);
  if (m.type === 'wx' && S.weather) body = `<div class="h">${esc(S.place.name)} · ${wxLabel(S.weather.code)} · feels ${Math.round(S.weather.feels)}°</div>`
    + S.weather.hours.filter((h) => h.time > Date.now() - 1800000).map((h) => `<button>${hhmm(new Date(h.time), S.place.tz)}  ${Math.round(h.temp)}°  rain ${h.rain}%</button>`).join('') + `<div class="h">Data: Open-Meteo</div>`;
  return `<div class="menu" style="left:${m.x}px;top:${m.y}px">${body}</div>`;
}

function openMenu(type, el, extra = {}) {
  const r = el.getBoundingClientRect(), box = $('#island').getBoundingClientRect();
  S.menu = { type, x: Math.min(r.left - box.left, box.width - 220), y: r.bottom - box.top + 4, ...extra };
  render(true);
  if (type === 'surah') $('.menu .on')?.scrollIntoView({ block: 'center' });
}

/* ================= cuaca ================= */

const wxIcon = (c, day) => c === 0 ? (day ? 'sun' : 'moonStar') : c <= 2 ? (day ? 'cloudSun' : 'cloud') : c === 3 ? 'cloud' : c === 45 || c === 48 ? 'fog'
  : c >= 95 ? 'storm' : (c >= 51 && c <= 67) || (c >= 80 && c <= 82) ? 'rain' : 'cloud';
const wxLabel = (c) => c === 0 ? 'Clear' : c === 1 ? 'Mostly clear' : c === 2 ? 'Partly cloudy' : c === 3 ? 'Cloudy' : c === 45 || c === 48 ? 'Fog'
  : c >= 51 && c <= 57 ? 'Drizzle' : [65, 66, 67, 82].includes(c) ? 'Heavy rain' : (c >= 61 && c <= 81) ? 'Rain' : c >= 95 ? 'Thunderstorm' : 'Cloudy';
const isRain = (c) => (c >= 51 && c <= 67) || (c >= 80 && c <= 82) || c >= 95;
let lastRain = 0;

async function loadWeather() {
  try {
    const p = S.place;
    const url = `https://api.open-meteo.com/v1/forecast?latitude=${p.lat}&longitude=${p.lon}&current=temperature_2m,apparent_temperature,weather_code,is_day&hourly=temperature_2m,precipitation_probability,weather_code&forecast_hours=8&timeformat=unixtime`;
    const d = await (await fetch(url)).json();
    const h = d.hourly;
    S.weather = { temp: d.current.temperature_2m, feels: d.current.apparent_temperature, code: d.current.weather_code, day: d.current.is_day === 1,
      hours: h.time.map((t, i) => ({ time: t * 1000, temp: h.temperature_2m[i], rain: h.precipitation_probability[i] ?? 0, code: h.weather_code[i] })) };
    const now = Date.now();
    const wet = S.weather.hours.find((x) => x.time > now - 1800000 && x.time < now + 7200000 && x.rain >= 60);
    if (wet && now - lastRain > 3 * 3600000 && !isRain(S.weather.code) && S.focus?.phase !== 'focus') {
      lastRain = now;
      showFlash({ kind: 'rain', time: hhmm(new Date(wet.time), S.place.tz), chance: wet.rain }, 8);
    }
    render();
  } catch {}
}

/* ================= fokus & timer ================= */

const todayKey = () => 'focus-' + new Date().toISOString().slice(0, 10);
const focusToday = () => LS.get(todayKey(), 0);
let focusDone = null, timerDone = null;

function startFocus(minutes = 25, task = null) {
  clearTimeout(focusDone);
  S.flash = null;
  S.focus = { phase: 'focus', end: Date.now() + minutes * 60000, total: minutes * 60000, title: task?.title, taskId: task?.id };
  focusDone = setTimeout(finishFocus, minutes * 60000);
  render(true);
}
function startBreak(minutes = 5) {
  clearTimeout(focusDone);
  S.flash = null;
  S.focus = { phase: 'rest', end: Date.now() + minutes * 60000, total: minutes * 60000 };
  focusDone = setTimeout(finishFocus, minutes * 60000);
  render(true);
}
function finishFocus() {
  const f = S.focus;
  if (!f) return;
  S.focus = null;
  if (f.phase === 'focus') LS.set(todayKey(), focusToday() + 1);
  chime(f.phase === 'focus' ? [523, 659, 784] : [784, 659]);
  if (!S.pinned) S.expanded = false;
  showFlash({ kind: 'focusEnd', rest: f.phase === 'rest', title: f.title }, 60);
}
function startTimer(m) {
  clearTimeout(timerDone);
  S.timer = { end: Date.now() + m * 60000, total: m * 60000 };
  timerDone = setTimeout(() => { S.timer = null; chime([880, 660, 880]); render(true); if (!S.expanded) showFlash({ kind: 'done' }, 4); }, m * 60000);
  render(true);
}

/* ================= bagian yang diperbarui tiap detik ================= */

const LIVE = {
  timerLeft: () => S.timer ? clock((S.timer.end - Date.now()) / 1000 + 0.999) : '',
  focusLeft: () => S.focus ? clock((S.focus.end - Date.now()) / 1000 + 0.999) : '',
  focusRing: () => ringSVG('focus'),
  idle: () => idleHTML(),
  mbar: () => { const m = S.media; if (!m?.duration) return ''; return `<i style="width:${Math.min(100, (S.scrub ?? mediaPos()) / m.duration * 100)}%"></i>`; },
  mtime: () => { const m = S.media; if (!m?.duration) return ''; return `<span>${clock(Math.min(S.scrub ?? mediaPos(), m.duration))}</span><span>${clock(m.duration)}</span>`; },
  volLevel: () => S.audio ? `<i style="width:${(S.audio.muted ? 0 : S.audio.vol) * 100}%"></i>` : '',
  volFlash: volFlashHTML,
  agenda: agendaHTML, wxCard: wxCardHTML, prTop: prTopHTML, prTrack: prTrackHTML,
  prMarks: () => { const t = Prayer.times(S.place, new Date()); return `Imsak ${hhmm(t[0].date, S.place.tz)} · Sunrise ${hhmm(t[2].date, S.place.tz)}`; },
};

const mediaPos = () => { const m = S.media; return (m?.position || 0) + (m?.playing ? (Date.now() - m.at) / 1000 : 0); };

function live() {
  for (const el of document.querySelectorAll('[data-live]')) {
    const html = LIVE[el.dataset.live]?.() ?? '';
    if (el._last !== html) { el._last = html; el.innerHTML = html; }
  }
}

/** Notch kosong: gantian cuaca, jam, sholat berikutnya tiap 5 detik. */
let idleStep = -1;
function idleHTML() {
  const items = [...(S.weather ? ['wx'] : []), 'clock', 'prayer'];
  const step = Math.floor(Date.now() / 5000);
  const k = items[step % items.length];
  const anim = step !== idleStep ? ' style="animation:morphIn .4s var(--soft) both;display:inline-flex;gap:5px;align-items:center"' : ' style="display:inline-flex;gap:5px;align-items:center"';
  idleStep = step;
  if (k === 'wx') return `<span${anim}>${IC[wxIcon(S.weather.code, S.weather.day)]}<span class="mono">${Math.round(S.weather.temp)}°</span></span>`;
  if (k === 'clock') return `<span${anim}><span style="color:var(--dim)">${IC.clock}</span><span class="mono">${hhmm(new Date())}</span></span>`;
  const n = Prayer.next(S.place, new Date());
  return `<span${anim}><span style="color:var(--mint)">${IC.moonStar}</span><span class="mono">${n.title} ${hhmm(n.date, S.place.tz)}</span></span>`;
}

/* ================= kejadian ================= */

let closeTimer = null;
nusa.on('hover', (over) => {
  S.hover = over;
  clearTimeout(closeTimer);
  if (!over && S.expanded && !S.pinned && !S.menu) closeTimer = setTimeout(() => { S.expanded = false; render(); }, 250);
  render();
});

nusa.on('open-panel', () => { S.expanded = true; nusa.focus(); render(true); });
window.addEventListener('blur', () => { if (S.expanded && !S.pinned && !S.menu) { S.expanded = false; render(); } });

nusa.on('media', (st) => {
  const before = S.media;
  S.media = st;
  if (st?.art && st.art !== before?.art) computeTint(st.art);
  if (!st?.art) S.tint = null;
  const newTrack = before?.title && st?.title && st.title !== before.title && st.playing;
  // Posisi lagu jalan sendiri lewat live() tiap detik. Bangun ulang isi cuma kalau lagu/statusnya beneran berubah;
  // kalau tiap laporan dibangun ulang, animasi masuknya keulang terus dan panel kelihatan geter & kedip.
  const changed = mediaSig(before) !== mediaSig(st);
  if (newTrack && !S.expanded && S.focus?.phase !== 'focus') showFlash({ kind: 'track' }, 2.6);
  else if (lastKey === 'x:music') {
    if (!S.music.online && changed) refreshBody();
    render();
  }
  else render(changed && (lastKey === 'music' || lastKey === 'x:home'));
});

const mediaSig = (x) => JSON.stringify(x && [x.title, x.artist, x.album, x.art, x.hiArt, x.icon, x.app, x.playing, x.canSeek, x.noTimeline, Math.round(x.duration || 0)]);

nusa.on('clip', (t) => {
  if (!t.trim()) return;
  S.clips = [t, ...S.clips.filter((c) => c !== t)].slice(0, 20);
  if (S.expanded && S.tab === 'clips') render(true);
});

/* ---------- volume sistem & perangkat audio ---------- */

let volDragging = false;
nusa.on('audio', (a) => {
  const before = S.audio;
  if (volDragging && a) a = { ...a, vol: S.audio?.vol ?? a.vol }; // jangan loncat-loncat pas lagi digeser
  S.audio = a;
  if (!a) return render(lastKey.startsWith('x:'));
  const changed = before && before.id === a.id && (Math.abs(before.vol - a.vol) > 0.004 || before.muted !== a.muted);
  if (changed && !S.expanded && !['prayer', 'task', 'focusEnd', 'device'].includes(S.flash?.kind)) showFlash({ kind: 'volume', level: a.vol, muted: a.muted }, 1.6);
  if (S.expanded && (!before || before.muted !== a.muted || before.id !== a.id)) render(true);
  else live();
});

nusa.on('device', (d) => {
  if (S.expanded) return;
  showFlash({ kind: 'device', name: d.name.replace(/^.*\((.*)\)\s*$/, '$1') || d.name, detail: d.detail }, 4);
});

/* ---------- geser: posisi lagu & volume ---------- */

function dragOn(el, onMove, onEnd) {
  const at = (e) => { const r = el.getBoundingClientRect(); return Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)); };
  const move = (e) => onMove(at(e));
  const up = (e) => { try { el.releasePointerCapture(e.pointerId); } catch {} el.removeEventListener('pointermove', move); el.removeEventListener('pointerup', up); el.classList.remove('drag'); onEnd?.(at(e)); };
  return (e) => { try { el.setPointerCapture(e.pointerId); } catch {} el.classList.add('drag'); el.addEventListener('pointermove', move); el.addEventListener('pointerup', up); move(e); };
}

document.addEventListener('pointerdown', (e) => {
  const bar = e.target.closest('.bar.seek');
  if (bar && seekable(S.media)) {
    const dur = S.media.duration;
    dragOn(bar, (f) => { S.scrub = f * dur; live(); }, (f) => { nusa.media(`seek ${(f * dur).toFixed(2)}`); S.media = { ...S.media, position: f * dur, at: Date.now() }; S.scrub = null; live(); })(e);
    return;
  }
  const vt = e.target.closest('#volTrack');
  if (vt && S.audio) {
    volDragging = true;
    let last = 0;
    const set = (f) => {
      S.audio = { ...S.audio, vol: f, muted: f === 0 ? S.audio.muted : false }; live();
      if (Date.now() - last > 40) { last = Date.now(); nusa.volume(f); }
    };
    dragOn(vt, set, (f) => { nusa.volume(f); setTimeout(() => { volDragging = false; }, 400); })(e);
  }
});

/* ---------- usap dua jari di notch: kiri = lagu berikutnya, kanan = sebelumnya ---------- */

const swipe = { total: 0, fired: false, idle: null };
document.addEventListener('wheel', (e) => {
  if (S.expanded || !S.media?.title || !e.target.closest('#island')) return;
  clearTimeout(swipe.idle);
  swipe.idle = setTimeout(() => { swipe.total = 0; swipe.fired = false; }, 220); // jeda = usapan selesai
  if (swipe.fired || Math.abs(e.deltaX) < Math.abs(e.deltaY)) return;
  swipe.total += e.deltaX;
  if (Math.abs(swipe.total) < 45) return;
  swipe.fired = true;
  const next = swipe.total > 0;
  nusa.media(next ? 'next' : 'prev');
  const island = $('#island');
  island.style.translate = `calc(-50% + ${next ? -7 : 7}px) 0`;
  setTimeout(() => { island.style.translate = ''; }, 140);
}, { passive: true });

/* ---------- klik kanan notch: Open at login / Quit ---------- */

document.addEventListener('contextmenu', (e) => {
  if (e.target.closest('input, textarea')) return;
  e.preventDefault();
  if (e.target.closest('#island')) nusa.contextMenu();
});

/* ---------- seret file ke notch → langsung buka Rak ---------- */

const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes('Files');
document.addEventListener('dragover', (e) => { e.preventDefault(); if (hasFiles(e)) e.dataTransfer.dropEffect = 'copy'; });
document.addEventListener('dragenter', (e) => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  if (!S.expanded || S.tab !== 'tray' || !S.dropping) { S.expanded = true; S.tab = 'tray'; S.dropping = true; render(true); }
});
document.addEventListener('dragleave', (e) => {
  if (e.relatedTarget && document.documentElement.contains(e.relatedTarget)) return;
  if (S.dropping) { S.dropping = false; if (S.expanded) render(true); }
});
document.addEventListener('drop', async (e) => {
  e.preventDefault();
  S.dropping = false;
  const paths = [...(e.dataTransfer?.files || [])].map((f) => nusa.filePath(f)).filter(Boolean);
  for (const p of paths) await addToShelf(p);
  if (S.expanded) render(true);
});
document.addEventListener('dragstart', (e) => {
  const it = e.target.closest?.('.sitem');
  if (!it) return;
  e.preventDefault();
  nusa.fileDrag(S.shelf[+it.dataset.i]);
});

/* ---------- cermin kamera ---------- */

async function toggleMirror() {
  if (S.mirror?.stream) return stopMirror(true);
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 480 }, audio: false });
    S.mirror = { stream };
  } catch { S.mirror = { denied: true }; }
  render(true);
}
function stopMirror(rerender) {
  S.mirror?.stream?.getTracks().forEach((t) => t.stop());
  S.mirror = null;
  if (rerender) render(true);
}

/** Warna paling hidup dari sampul (sampul dari server lain bisa nolak dibaca, ya udah tanpa warna). */
function computeTint(src) {
  const img = new Image();
  img.crossOrigin = 'anonymous';
  img.onload = () => {
    try {
      const c = document.createElement('canvas'); c.width = c.height = 24;
      const g = c.getContext('2d'); g.drawImage(img, 0, 0, 24, 24);
      const px = g.getImageData(0, 0, 24, 24).data;
      let best = null;
      for (let i = 0; i < px.length; i += 4) {
        const [r, gr, b] = [px[i] / 255, px[i + 1] / 255, px[i + 2] / 255];
        const mx = Math.max(r, gr, b), mn = Math.min(r, gr, b), sat = mx ? (mx - mn) / mx : 0;
        if (sat * mx > (best?.score ?? 0.12)) best = { score: sat * mx, r, g: gr, b, mx };
      }
      if (!best) { S.tint = null; return render(); }
      const k = Math.max(1, 0.88 / best.mx);
      S.tint = '#' + [best.r, best.g, best.b].map((v) => Math.round(Math.min(1, v * k) * 255).toString(16).padStart(2, '0')).join('');
    } catch { S.tint = null; }
    render(true);
  };
  img.src = src;
}

document.addEventListener('input', (e) => {
  if (e.target.id === 'musicQ') { S.music.query = e.target.value; musicSearch(); }
  if (e.target.id === 'taskIn') {
    S.taskText = e.target.value;
    const due = S.taskPick?.[1] ?? TaskParser.parse(S.taskText).due;
    $('#taskPreview').innerHTML = S.taskText && due ? `<span class="chip on">${IC.bell}${dueText(new Date(due))}</span>` : '';
  }
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && e.target.id === 'taskIn') addTask();
  if (e.key === 'Escape') { if (S.menu) { S.menu = null; render(true); } else if (S.expanded) { S.expanded = false; render(); } }
});

document.addEventListener('click', (e) => {
  const el = e.target.closest('[data-act]');
  if (S.menu && !e.target.closest('.menu')) { S.menu = null; if (!el || el.dataset.act.endsWith('Menu')) return render(true); }
  if (!el) {
    // Klik notch kecil: buka panel
    if (!S.expanded && e.target.closest('#island')) {
      if (S.flash?.kind === 'prayer') { stopPrayerSound(); S.flash = null; return render(); }
      if (S.flash?.kind === 'task') { S.flash = null; S.tab = 'tasks'; }
      S.expanded = true; nusa.focus(); render(true);
    }
    return;
  }
  const d = el.dataset;
  const task = () => S.tasks.find((t) => t.id === d.id);
  const A = {
    tab: () => { S.tab = d.tab; LS.set('tab', S.tab); S.menu = null; render(true); },
    pin: () => { S.pinned = !S.pinned; render(true); },
    gear: async () => openMenu('gear', el, { login: await nusa.loginItem() }),
    login: async () => { await nusa.loginItem(!S.menu?.login); S.menu = null; render(true); },
    quit: () => window.close(),
    timer: () => startTimer(+d.m), timerStop: () => { clearTimeout(timerDone); S.timer = null; render(true); },
    wxMenu: () => openMenu('wx', el),
    mprev: () => nusa.media('prev'), mnext: () => nusa.media('next'), mtoggle: () => nusa.media('toggle'),
    openSource: () => { const m = S.media; if (m) nusa.openSource({ pid: m.pid, path: m.path, source: m.source }); },
    muteToggle: () => { if (S.audio) { nusa.mute(!S.audio.muted); S.audio = { ...S.audio, muted: !S.audio.muted }; render(true); } },
    calDay: () => { S.calSel = +d.t; render(true); },
    calSettings: () => nusa.calendarSettings(),
    mirror: () => toggleMirror(),
    fileOpen: () => nusa.fileOpen(S.shelf[+d.i]),
    fileRemove: () => { e.stopPropagation(); removeFromShelf(S.shelf[+d.i]); },
    fileShow: () => nusa.fileShow(S.shelf[S.shelf.length - 1]),
    trayClear: () => { S.shelf = []; LS.set('shelf', []); render(true); },
    mjump: () => { const s = S.music.queue[+d.k]; if (s) nusa.senandung('POST', '/api/remote/cmd', { cmd: 'jump', index: s.i }); },
    mplay: () => { const s = S.music.results[+d.k]; if (s) nusa.senandung('POST', '/api/remote/cmd', { cmd: 'play', item: s }); },
    mqueue: () => { e.stopPropagation(); const s = S.music.results[+d.k]; if (s) nusa.senandung('POST', '/api/remote/cmd', { cmd: 'queue', item: s }); },
    pick: () => { S.taskPick = S.taskPick?.[0] === d.l ? null : [d.l, +d.t]; render(true); $('#taskIn')?.focus(); },
    taskToggle: () => { const t = task(); if (t) { t.done = !t.done; t.doneAt = t.done ? Date.now() : null; saveTasks(); refreshBody(); } },
    taskDel: () => { S.tasks = S.tasks.filter((t) => t.id !== d.id); saveTasks(); refreshBody(); },
    taskDone: () => { const t = task(); if (t) { t.done = true; t.doneAt = Date.now(); saveTasks(); } S.flash = null; render(); },
    taskSnooze: () => { const t = task(); if (t) { t.due = Date.now() + 600000; t.notified = false; saveTasks(); } S.flash = null; render(); },
    focus: () => startFocus(), break: () => startBreak(), focusStop: () => { clearTimeout(focusDone); S.focus = null; render(true); },
    focusTask: () => startFocus(25, task()),
    dismiss: () => { S.flash = null; render(); },
    cityMenu: () => openMenu('city', el), soundMenu: () => openMenu('sound', el),
    city: () => { S.place = Prayer.city(d.c); LS.set('city', d.c); alarm = new Prayer.Alarm(S.place); alarm.check(new Date()); S.menu = null; loadWeather(); render(true); },
    sound: () => { S.sound = d.s; LS.set('sound', d.s); S.menu = null; render(true); playPrayerSound(); setTimeout(stopPrayerSound, 4000); },
    soonToggle: () => { S.soon = !S.soon; LS.set('soon', S.soon); S.menu = null; render(true); },
    soundStop: () => { stopPrayerSound(); S.menu = null; render(true); },
    surahMenu: () => openMenu('surah', el), qMenu: () => openMenu('q', el),
    surah: () => { S.q.surah = +d.n; LS.set('qSurah', S.q.surah); S.menu = null; render(true); scrollQuran(false, 0); },
    surahGo: () => { S.q.surah = Math.min(114, Math.max(1, S.q.surah + +d.d)); LS.set('qSurah', S.q.surah); render(true); scrollQuran(false, 0); },
    qLang: () => { S.q.english = d.en === '1'; LS.set('qEnglish', S.q.english); const top = $('#qScroll')?.scrollTop; render(true); if ($('#qScroll')) $('#qScroll').scrollTop = top; },
    qFont: () => { S.q.font = d.f; LS.set('qFont', d.f); S.menu = null; render(true); },
    reciter: () => { LS.set('reciter', d.r); S.menu = null; if (S.reciting) recite(S.reciting.s, S.reciting.a); else render(true); },
    mark: () => { S.q.mark = { s: S.q.surah, a: +d.a }; LS.set('qMark', S.q.mark); const top = $('#qScroll').scrollTop; render(true); $('#qScroll').scrollTop = top; },
    goMark: () => { S.q.surah = S.q.mark.s; LS.set('qSurah', S.q.surah); render(true); scrollQuran(true, S.q.mark.a); },
    recite: () => {
      const a = $('#recite');
      if (S.reciting) { a.paused ? a.play() : a.pause(); return render(true); }
      recite(S.q.surah, S.q.mark && S.q.mark.s === S.q.surah ? S.q.mark.a : 1);
    },
    reciteFrom: () => { e.stopPropagation(); recite(S.q.surah, +d.a); },
    reciteStop: () => { $('#recite').pause(); S.reciting = null; render(true); },
    copy: () => { nusa.copy(S.clips[+d.i]); S.copied = +d.i; render(true); setTimeout(() => { S.copied = null; render(true); }, 1200); },
  };
  A[d.act]?.();
});

/* ================= mulai ================= */

navigator.getBattery?.().then((b) => {
  // PC tanpa baterai: Chromium ngelapor "100%, lagi dicas" terus; ikon baterai nggak usah ditampilin
  if (b.level === 1 && b.charging && b.chargingTime === 0 && b.dischargingTime === Infinity) return;
  let warned = false;
  const read = () => {
    S.battery = { level: Math.round(b.level * 100), charging: b.charging, toFull: isFinite(b.chargingTime) ? Math.round(b.chargingTime / 60) : null };
    // Baterai lemah: sekali aja tiap turun ke 20%
    if (b.charging || S.battery.level > 20) warned = false;
    else if (!warned) { warned = true; if (!S.expanded) showFlash({ kind: 'low', percent: S.battery.level }, 4); }
  };
  read();
  b.addEventListener('chargingchange', () => {
    read();
    if (S.expanded) return render(true);
    showFlash(b.charging ? { kind: 'charging', percent: S.battery.level } : { kind: 'unplug', percent: S.battery.level }, b.charging ? 3.5 : 2.4);
  });
  b.addEventListener('levelchange', () => { read(); render(); });
  b.addEventListener('chargingtimechange', read);
});
loadShelf();
loadCalendar();
setInterval(loadCalendar, 5 * 60000);

setInterval(live, 1000);
setInterval(checkPrayer, 15000);
setTimeout(() => { checkTasks(); setInterval(checkTasks, 10000); }, 3000);
setInterval(loadWeather, 15 * 60000);
loadWeather();
render(true);

// Pengait buat tes otomatis (dipakai mode potret pas development)
window.__nusa = { S, render, showFlash, startFocus, startTimer, recite, loadQuran };
