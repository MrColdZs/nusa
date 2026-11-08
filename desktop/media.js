// Lagu yang lagi diputar, per sistem:
// - Windows: media controls sistem (SMTC) lewat PowerShell + WinRT
// - Linux: MPRIS lewat `playerctl`
// - Cadangan di semua sistem: antrean Senandung (http://127.0.0.1:5560/api/remote/state)
const { spawn, execFile } = require('child_process');
const http = require('http');

let emit = () => {};
let osState = null;
let senandung = null;

const PS_HEAD = `
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation\`1' })[0]
function Await($op, [Type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); $task.Wait(-1) | Out-Null; $task.Result }
[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null
$mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
`;

const PS_LOOP = PS_HEAD + `
[Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
$lastKey = ''
while ($true) {
  $s = $mgr.GetCurrentSession()
  if ($s) {
    $p = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    $tl = $s.GetTimelineProperties()
    $info = $s.GetPlaybackInfo()
    $o = @{ title = $p.Title; artist = $p.Artist; album = $p.AlbumTitle; source = $s.SourceAppUserModelId;
            playing = ($info.PlaybackStatus -eq 'Playing'); position = $tl.Position.TotalSeconds; duration = $tl.EndTime.TotalSeconds;
            updated = [DateTimeOffset]::new($tl.LastUpdatedTime).ToUnixTimeMilliseconds() }
    $key = "$($p.Title)|$($p.Artist)"
    if ($key -ne $lastKey -and $p.Thumbnail) {
      $st = Await ($p.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
      $ms = New-Object System.IO.MemoryStream
      [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($st).CopyTo($ms)
      $o.art = 'data:image/png;base64,' + [Convert]::ToBase64String($ms.ToArray())
      $lastKey = $key
    }
    [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress))
  } else { [Console]::Out.WriteLine('{}') }
  [Console]::Out.Flush()
  Start-Sleep -Milliseconds 1000
}`;

const encode = (script) => Buffer.from(script, 'utf16le').toString('base64');

function startWindows() {
  let lastArt = null;
  const run = () => {
    const ps = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encode(PS_LOOP)], { windowsHide: true });
    let buf = '';
    ps.stdout.on('data', (d) => {
      buf += d.toString();
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        try {
          const o = JSON.parse(line);
          if (!o.title) { osState = null; continue; }
          if (o.art) lastArt = o.art; else o.art = lastArt;
          const at = o.updated || Date.now();
          osState = { ...o, position: (o.position || 0) + (o.playing ? (Date.now() - at) / 1000 : 0), at: Date.now() };
        } catch { /* baris rusak, lewati */ }
      }
      publish();
    });
    ps.on('exit', () => setTimeout(run, 3000));
  };
  run();
}

function startLinux() {
  const fmt = '{{status}}\t{{artist}}\t{{title}}\t{{album}}\t{{mpris:artUrl}}\t{{mpris:length}}\t{{position}}\t{{playerName}}';
  setInterval(() => {
    execFile('playerctl', ['metadata', '--format', fmt], { timeout: 1500 }, (err, out) => {
      if (err) { osState = null; return publish(); }
      const [status, artist, title, album, art, length, position, player] = out.trim().split('\t');
      osState = title ? { title, artist, album, art: art || null, playing: status === 'Playing', duration: +length / 1e6 || 0,
        position: +position / 1e6 || 0, at: Date.now(), source: player } : null;
      publish();
    });
  }, 1000);
}

/** Senandung: dipakai kalau sistem nggak ngelaporin apa-apa (dan buat tab Music). */
function pollSenandung() {
  setInterval(() => {
    http.get('http://127.0.0.1:5560/api/remote/state', { timeout: 1200 }, (res) => {
      let b = '';
      res.on('data', (d) => (b += d));
      res.on('end', () => {
        try {
          const s = JSON.parse(b);
          const cur = (s.queue || []).find((q) => q.i === s.idx);
          senandung = cur ? { title: cur.title, artist: cur.artist, art: cur.art ? 'http://127.0.0.1:5560' + cur.art : null,
            playing: !!s.playing, duration: cur.duration || 0, position: 0, at: Date.now(), source: 'Senandung', noTimeline: true } : null;
        } catch { senandung = null; }
        publish();
      });
    }).on('error', () => { senandung = null; publish(); });
  }, 2000);
}

let lastSent = '';
function publish() {
  const state = osState || senandung || null;
  const key = JSON.stringify(state && { ...state, at: 0, position: Math.round(state.position || 0) });
  if (key === lastSent) return;
  lastSent = key;
  emit(state);
}

function start(cb) {
  emit = cb;
  if (process.platform === 'win32') startWindows();
  else if (process.platform === 'linux') startLinux();
  pollSenandung();
}

function command(cmd) {
  if (!['toggle', 'next', 'prev', 'pause'].includes(cmd)) return;
  if (process.platform === 'win32') {
    const call = { toggle: 'TryTogglePlayPauseAsync', next: 'TrySkipNextAsync', prev: 'TrySkipPreviousAsync', pause: 'TryPauseAsync' }[cmd];
    const script = PS_HEAD + `$s = $mgr.GetCurrentSession(); if ($s) { Await ($s.${call}()) ([bool]) | Out-Null }`;
    spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encode(script)], { windowsHide: true });
  } else if (process.platform === 'linux') {
    execFile('playerctl', [{ toggle: 'play-pause', next: 'next', prev: 'previous', pause: 'pause' }[cmd]], () => {});
  }
}

module.exports = { start, command };
