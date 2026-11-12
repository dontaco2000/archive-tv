/// The remote control page served at /remote: one self-contained file, no external resources.
/// Sized to fit a 260x370 window (the number pad opens as a panel over it) without scrolling; grows a little on wider screens (phones).
const remotePage = r'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<meta name="theme-color" content="#16161b">
<title>Archive TV Remote</title>
<style>
  :root { --edge:#2c2c35; --btn:#34343f; --btn-hi:#454554; --txt:#e8e6df; --dim:#8d8b99;
          --lcd:#0d1a12; --lcd-txt:#8dffb0; --amber:#ffc24a; --c:clamp(34px, min(11vw, 7vh), 50px); }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
  html,body { margin:0; height:100%; overflow:hidden; background:#1d1d23; color:var(--txt);
    font-family:"Segoe UI",system-ui,-apple-system,Roboto,sans-serif; user-select:none; -webkit-user-select:none; }
  body { display:flex; justify-content:center; }
  /* The remote is the whole window: no margins, no scrollbars; rows centred, gaps grow on tall screens. */
  .remote { width:100%; max-width:420px; height:100%; background:linear-gradient(180deg,#26262e,#18181d 60%,#141418);
    padding:8px; display:flex; flex-direction:column; justify-content:center; gap:clamp(6px, 1.8vh, 16px); }
  .remote > * { flex-shrink:0; }
  .lcd { background:var(--lcd); border-radius:8px; padding:4px 6px; border:1px solid #000; position:relative;
    box-shadow:inset 0 2px 6px #000c; font-family:Consolas,"Courier New",monospace; color:var(--lcd-txt);
    text-shadow:0 0 6px #4dff8a55; display:flex; align-items:center; gap:6px; }
  .lcd img { width:32px; height:24px; object-fit:contain; background:#ffffff10; border-radius:4px; flex-shrink:0; }
  .lcd .txt { min-width:0; flex:1; padding-right:22px; } /* room for the CC button */
  .lcd .ch { font-size:13px; font-weight:700; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .lcd .title { font-size:11px; color:#d9ffe4; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .lcd .sub { font-size:10px; color:#6fcf8f; display:flex; justify-content:space-between; gap:6px; }
  .lcd .mode { color:var(--amber); }
  .brand { position:absolute; right:6px; top:3px; font:700 7px/1 Consolas,monospace; letter-spacing:2px; color:#4a7a5a; text-shadow:none; }
  button { font:inherit; color:var(--txt); background:var(--btn); border:0; border-radius:9px; min-height:34px; padding:0 3px;
    box-shadow:0 2px 0 #0b0b0e, inset 0 1px 0 #ffffff1a; cursor:pointer; font-weight:600; font-size:11px; letter-spacing:.3px; }
  button:hover { background:var(--btn-hi); }
  button:active, button.hit { transform:translateY(2px); box-shadow:0 0 0 #0b0b0e; background:#55556a; }
  .grid { display:grid; gap:5px; }
  .g2 { grid-template-columns:1fr 1fr; } .g3 { grid-template-columns:repeat(3,1fr); } .g4 { grid-template-columns:repeat(4,1fr); }
  .pill { border-radius:17px; font-size:10px; }
  .c-red { background:#5a2523; } .c-green { background:#244d33; } .c-blue { background:#253a63; } .c-yellow { background:#5b4f1f; }
  .c-red:hover{background:#73302d} .c-green:hover{background:#2e6141} .c-blue:hover{background:#2f4a7d} .c-yellow:hover{background:#736427}
  .fav-on { color:var(--amber); }
  /* Middle: BACK/FAV | D-pad | CH up/down. Every button sits in its own grid cell. */
  .mid { display:grid; grid-template-columns:1fr auto 1fr; gap:5px; }
  .side { display:flex; flex-direction:column; justify-content:space-between; gap:4px; }
  .side span { text-align:center; font-size:9px; color:var(--dim); letter-spacing:2px; }
  .pad { display:grid; grid-template-columns:repeat(3,var(--c)); grid-template-rows:repeat(3,var(--c)); gap:2px;
    padding:4px; border-radius:50%; background:radial-gradient(circle,#3a3a46,#24242c);
    box-shadow:0 3px 10px #000a, inset 0 1px 0 #ffffff1a; }
  .pad button { min-height:0; font-size:13px; border-radius:8px; }
  .pad .u { grid-area:1/2; } .pad .l { grid-area:2/1; } .pad .r { grid-area:2/3; } .pad .d { grid-area:3/2; }
  .pad .ok { grid-area:2/2; border-radius:50%; background:var(--btn-hi); }
  .vol { display:flex; align-items:center; gap:5px; }
  .vol button { width:34px; font-size:15px; flex-shrink:0; }
  .vol .mute { width:auto; padding:0 6px; font-size:10px; }
  .mute.on { background:#7a2a26; color:#fff; }
  .bar { flex:1; height:16px; border-radius:8px; background:#04100a; border:1px solid #2a5a3a; position:relative;
    cursor:pointer; touch-action:none; overflow:hidden; }
  .bar i { position:absolute; inset:0 auto 0 0; background:linear-gradient(90deg,#2f9b55,#8dffb0); width:0; }
  .bar.muted i { background:repeating-linear-gradient(45deg,#5a3a3a 0 6px,#3a2626 6px 12px); }
  .bar b { position:absolute; inset:0; text-align:center; font:700 10px/14px Consolas,monospace; color:#fff; text-shadow:0 0 3px #000; }
  .panel { position:fixed; inset:4px; display:none; flex-direction:column; gap:6px; padding:8px; border-radius:18px;
    background:#18181d; border:1px solid var(--edge); box-shadow:0 8px 30px #000; }
  .panel.open { display:flex; }
  .panel header { display:flex; justify-content:space-between; align-items:center; font-size:11px; letter-spacing:2px; color:var(--dim); }
  .panel header button { min-width:60px; }
  .num { flex:1; grid-auto-rows:1fr; } .num button { font-size:16px; font-family:Consolas,monospace; }
  .num .word { font-size:11px; font-family:inherit; }
  .entry { text-align:center; font:700 16px Consolas,monospace; color:var(--lcd-txt); min-height:20px; }
  #pin { position:fixed; inset:0; background:#000c; display:none; align-items:center; justify-content:center; }
  #pin div { background:#1d1d23; border:1px solid var(--edge); border-radius:16px; padding:14px; text-align:center; width:220px; }
  #pin input { width:100%; font:700 24px Consolas,monospace; text-align:center; letter-spacing:8px; margin:10px 0;
    background:var(--lcd); color:var(--lcd-txt); border:1px solid #2a5a3a; border-radius:10px; padding:6px; }
  .hint { font-size:10px; color:var(--dim); }
  /* CC: the now-playing window turns into the settings view; the D-pad rows hide meanwhile, so the remote keeps its size. */
  #ccBtn { position:absolute; right:5px; bottom:4px; min-height:0; height:17px; padding:0 5px; font:700 9px/17px Consolas,monospace;
    background:#14301f; color:var(--lcd-txt); border:1px solid #2a5a3a; border-radius:4px; box-shadow:none; }
  #ccBtn.on { background:var(--lcd-txt); color:#062010; }
  .lcd.set { flex:1; flex-direction:column; align-items:stretch; padding:6px 7px; }
  .lcd.set > img, .lcd.set > .txt, .lcd.set > .brand { display:none; }
  .lcd.set #ccBtn { top:4px; bottom:auto; }
  body.set .hide-set { display:none; }
  #settings { display:none; flex-direction:column; gap:5px; font-size:10px; }
  .lcd.set #settings { display:flex; }
  #settings .hd { font-weight:700; letter-spacing:2px; color:var(--amber); }
  #settings .row { display:flex; align-items:center; gap:4px; }
  #settings .row > span:first-child { width:58px; flex-shrink:0; }
  #settings button { min-height:0; height:20px; padding:0 4px; font:700 9px Consolas,monospace; color:var(--lcd-txt);
    background:#14301f; border:1px solid #2a5a3a; border-radius:4px; box-shadow:none; flex:1; }
  #settings button.sel { background:var(--lcd-txt); color:#062010; }
  #settings .sz { flex:0 0 22px; font-size:12px; }
  #sizeLevel { flex:1; text-align:center; letter-spacing:1px; }
  #sample { text-align:center; color:#fff; background:#000a; font-family:"Segoe UI",sans-serif; font-weight:600; text-shadow:0 0 2px #000, 0 0 2px #000;
    border-radius:3px; padding:1px 4px; align-self:center; white-space:nowrap; line-height:1.2; }
  #ccNote { color:#6fcf8f; min-height:12px; }
  .off { color:#ff7b6b; }
</style>
</head>
<body>
<div class="remote" id="remote" title="Keys: arrows, Enter, Esc, 0-9, G guide, M menu, I info, F fav, O on demand, U/Space mute, +/- volume, PgUp/PgDn channel">
  <div class="lcd">
    <span class="brand">ARCHIVE TV</span>
    <img id="logo" alt="">
    <div class="txt">
      <div class="ch" id="ch">-- ----</div>
      <div class="title" id="title">Connecting...</div>
      <div class="sub"><span id="left"></span><span class="mode" id="mode"></span></div>
    </div>
    <button id="ccBtn" title="Captions and settings">CC</button>
    <div id="settings">
      <div class="hd">SETTINGS</div>
      <div class="row"><span>CAPTIONS</span><button id="setCaptions">OFF</button></div>
      <div id="ccNote"></div>
      <div class="row"><span>CC SIZE</span><button class="sz" id="sizeDown" title="Smaller">&minus;</button><b id="sizeLevel">----</b><button class="sz" id="sizeUp" title="Bigger">+</button></div>
      <div id="sample">Sample caption</div>
      <div class="row" id="setLeveling"><span>LEVELING</span><button data-v="off">OFF</button><button data-v="normal">NORM</button><button data-v="strong">STRONG</button></div>
      <div class="row" id="setWeather"><span>WEATHER</span><button data-v="web">WXSTAR</button><button data-v="native">CLASSIC</button></div>
      <div class="row" id="setPicture"><span>PICTURE</span><button data-v="auto">AUTO</button><button data-v="fill">FILL</button><button data-v="off">OFF</button></div>
      <div class="row"><span>WI-FI</span><b id="wifi">--</b></div>
    </div>
  </div>

  <div class="grid g4 hide-set">
    <button class="pill c-red" data-key="guide">GUIDE</button>
    <button class="pill c-green" data-key="menu">MENU</button>
    <button class="pill c-blue" data-key="info">INFO</button>
    <button class="pill c-yellow" data-key="ondemand" title="On Demand">ON DEM</button>
  </div>

  <div class="mid hide-set">
    <div class="side">
      <button data-key="back">BACK</button><button data-key="favorite" id="fav">&#9733; FAV</button>
    </div>
    <div class="pad">
      <button class="u" data-key="up" title="Up">&#9650;</button>
      <button class="l" data-key="left" title="Left">&#9664;</button>
      <button class="ok" data-key="ok">OK</button>
      <button class="r" data-key="right" title="Right">&#9654;</button>
      <button class="d" data-key="down" title="Down">&#9660;</button>
    </div>
    <div class="side">
      <button data-key="channelUp" title="Channel up">CH &#9650;</button><button data-key="channelDown" title="Channel down">CH &#9660;</button>
    </div>
  </div>

  <div class="vol">
    <button data-key="volDown" title="Volume down">&minus;</button>
    <div class="bar" id="bar" title="Volume: click or drag"><i id="fill"></i><b id="lvl">--</b></div>
    <button data-key="volUp" title="Volume up">+</button>
    <button class="mute" data-key="mute" id="mute">MUTE</button>
  </div>

  <div class="grid g2">
    <button id="numOpen" title="Number pad">123</button>
    <button data-key="fullscreen" title="Fullscreen">FULL</button>
  </div>
</div>

<div class="panel" id="nums">
  <header><span>CHANNEL #</span><button data-close>CLOSE</button></header>
  <div class="entry" id="entry"></div>
  <div class="grid g3 num">
    <button data-d="1">1</button><button data-d="2">2</button><button data-d="3">3</button>
    <button data-d="4">4</button><button data-d="5">5</button><button data-d="6">6</button>
    <button data-d="7">7</button><button data-d="8">8</button><button data-d="9">9</button>
    <button class="word" id="numClr">CLR</button><button data-d="0">0</button><button class="word" id="numGo">GO</button>
  </div>
</div>

<div id="pin"><div>
  <div style="font-weight:700;letter-spacing:2px">ENTER PIN</div>
  <div class="hint">Shown in Archive TV: Menu &gt; Remote on Wi-Fi</div>
  <input id="pinIn" inputmode="numeric" maxlength="4" autocomplete="off">
  <button id="pinGo" style="width:100%">CONNECT</button>
</div></div>

<script>
(() => {
  const $ = id => document.getElementById(id);
  let pin = localStorage.getItem('atvPin') || '';
  let logoFor = null, dragging = false;

  function headers() { return { 'Content-Type': 'application/json', 'X-Remote': '1', 'X-Pin': pin }; }

  async function api(path, body) {
    const r = await fetch(path, body === undefined ? { headers: headers() } : { method: 'POST', headers: headers(), body: JSON.stringify(body) });
    if (r.status === 401) { showPin(); throw new Error('pin'); }
    if (!r.ok) throw new Error(r.status);
    return r.json();
  }

  function showPin() { $('pin').style.display = 'flex'; $('pinIn').focus(); }
  $('pinGo').onclick = () => { pin = $('pinIn').value.trim(); localStorage.setItem('atvPin', pin); $('pin').style.display = 'none'; poll(); };
  $('pinIn').onkeydown = e => { if (e.key === 'Enter') $('pinGo').click(); e.stopPropagation(); };

  // The number pad opens over the remote; it builds the number here and tunes it on GO.
  const closeAll = () => document.querySelectorAll('.panel.open').forEach(p => p.classList.remove('open'));
  document.querySelectorAll('[data-close]').forEach(b => b.addEventListener('click', closeAll));
  $('numOpen').onclick = () => $('nums').classList.add('open');
  let typed = '';
  const showTyped = () => $('entry').textContent = typed ? typed + '_' : '';
  document.querySelectorAll('[data-d]').forEach(b => b.addEventListener('click', () => { typed = (typed + b.dataset.d).slice(-3); showTyped(); }));
  $('numClr').onclick = () => { typed = ''; showTyped(); };
  $('numGo').onclick = () => { if (typed) send('/api/channel', { number: +typed }); typed = ''; showTyped(); closeAll(); };

  function setVol(level, muted) {
    $('fill').style.width = level + '%';
    $('bar').classList.toggle('muted', muted);
    $('lvl').innerHTML = muted ? '<span class="off">MUTE</span>' : level;
    $('mute').classList.toggle('on', muted);
    $('mute').textContent = muted ? 'MUTED' : 'MUTE';
  }

  // CC: settings view in the now-playing window. Changes go through POST /api/setting; the poll shows the result.
  let st = null;
  const lcd = document.querySelector('.lcd');
  function toggleSettings(open) {
    open = open === undefined ? !lcd.classList.contains('set') : open;
    lcd.classList.toggle('set', open);
    document.body.classList.toggle('set', open);
    if (st) renderSettings(st);
  }
  $('ccBtn').onclick = () => toggleSettings();
  const setting = (name, value) => send('/api/setting', { name, value });
  $('setCaptions').onclick = () => st && setting('captionsOn', !st.captionsOn);
  $('sizeDown').onclick = () => st && setting('captionSize', Math.max(1, st.captionSize - 1));
  $('sizeUp').onclick = () => st && setting('captionSize', Math.min(7, st.captionSize + 1));
  document.querySelectorAll('#setLeveling button').forEach(b => b.onclick = () => setting('leveling', b.dataset.v));
  document.querySelectorAll('#setWeather button').forEach(b => b.onclick = () => setting('weatherMode', b.dataset.v));
  document.querySelectorAll('#setPicture button').forEach(b => b.onclick = () => setting('picture', b.dataset.v));
  const notes = { forced: 'Foreign: English subs forced', none: 'No captions on this show', on: 'Showing captions', off: '' };
  function renderSettings(s) {
    $('ccBtn').classList.toggle('on', !!s.captionsOn || s.captions === 'forced');
    if (!lcd.classList.contains('set')) return;
    $('setCaptions').textContent = s.captionsOn ? 'ON' : 'OFF';
    $('setCaptions').classList.toggle('sel', !!s.captionsOn);
    $('ccNote').textContent = notes[s.captions] || '';
    $('sizeLevel').textContent = '▮'.repeat(s.captionSize) + '▯'.repeat(7 - s.captionSize) + ' ' + s.captionSize;
    $('sample').style.fontSize = (8 + s.captionSize * 1.5) + 'px';
    document.querySelectorAll('#setLeveling button').forEach(b => b.classList.toggle('sel', b.dataset.v === s.leveling));
    document.querySelectorAll('#setWeather button').forEach(b => b.classList.toggle('sel', b.dataset.v === s.weatherMode));
    document.querySelectorAll('#setPicture button').forEach(b => b.classList.toggle('sel', b.dataset.v === s.picture));
    $('wifi').textContent = s.remoteLan ? 'ON (phones can connect)' : 'OFF (this PC only)';
  }

  function render(s) {
    st = s;
    renderSettings(s);
    const c = s.channel;
    $('ch').textContent = c ? (c.number + ' ' + c.name.toUpperCase()) : 'NO CHANNEL';
    $('title').textContent = s.message || s.title || (s.standBy ? 'STAND BY...' : '');
    $('left').textContent = s.entry ? ('CH ' + s.entry + '_') : (s.onDemand ? 'ON DEMAND' : (s.minutesLeft != null ? s.minutesLeft + ' min left' : ''));
    $('mode').textContent = s.mode === 'watch' ? '' : s.mode.toUpperCase();
    if (!dragging) setVol(s.volume, s.muted);
    $('fav').classList.toggle('fav-on', !!s.favorite);
    const n = c ? c.number : null;
    if (n !== logoFor) { logoFor = n; $('logo').style.visibility = 'hidden'; if (n != null) $('logo').src = '/logo/' + n + '.png'; }
  }
  $('logo').onload = () => $('logo').style.visibility = 'visible';
  $('logo').onerror = () => $('logo').style.visibility = 'hidden';

  // The TV app closes this window when it exits; if it went away without doing so (crash), the
  // remote closes itself after about 5 s without an answer (only works in its own app window).
  let misses = 0;
  async function poll() {
    try { render(await api('/api/state')); misses = 0; }
    catch (e) {
      if (e.message === 'pin') return;
      $('title').textContent = 'NO SIGNAL - is Archive TV running?';
      if (++misses >= 5 && location.hostname === '127.0.0.1') window.close();
    }
  }

  async function send(path, body) {
    try { await api(path, body); } catch (e) { /* the next poll shows the state */ }
    setTimeout(poll, 120);
  }

  function press(k, el) {
    if (el) { el.classList.add('hit'); setTimeout(() => el.classList.remove('hit'), 120); }
    send('/api/key', { key: k });
  }
  document.querySelectorAll('[data-key]').forEach(b => b.addEventListener('click', () => press(b.dataset.key)));

  // Volume bar: click or drag to set the level.
  const bar = $('bar');
  let lastSent = 0;
  function levelAt(e) { const r = bar.getBoundingClientRect(); return Math.round(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * 100); }
  bar.addEventListener('pointerdown', e => { dragging = true; bar.setPointerCapture(e.pointerId); move(e); });
  bar.addEventListener('pointermove', e => { if (dragging) move(e); });
  bar.addEventListener('pointerup', e => { if (!dragging) return; dragging = false; const l = levelAt(e); setVol(l, false); send('/api/volume', { level: l }); });
  function move(e) {
    const l = levelAt(e); setVol(l, false);
    const t = Date.now(); if (t - lastSent > 150) { lastSent = t; api('/api/volume', { level: l }).catch(() => {}); }
  }

  const keymap = { ArrowUp:'up', ArrowDown:'down', ArrowLeft:'left', ArrowRight:'right', Enter:'ok', Escape:'back', Backspace:'back',
    g:'guide', m:'menu', i:'info', f:'favorite', o:'ondemand', u:'mute', ' ':'mute', '+':'volUp', '=':'volUp', '-':'volDown',
    PageUp:'channelUp', PageDown:'channelDown', F11:'fullscreen' };
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && document.querySelector('.panel.open')) { closeAll(); e.preventDefault(); return; }
    if ((e.key === 'Escape' || e.key === 'Backspace') && lcd.classList.contains('set')) { toggleSettings(false); e.preventDefault(); return; }
    const k = /^[0-9]$/.test(e.key) ? e.key : keymap[e.key.length === 1 ? e.key.toLowerCase() : e.key];
    if (!k) return;
    e.preventDefault();
    press(k, document.querySelector('[data-key="' + k + '"]'));
  });

  poll();
  setInterval(poll, 1000);
})();
</script>
</body>
</html>
''';
