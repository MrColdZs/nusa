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
# Sesi yang ditampilin & dikontrol: yang lagi Playing dulu (Spotify, browser, apa aja), baru sesi "current" dari Windows.
function Pick() {
  $all = @($mgr.GetSessions())
  $on = $all | Where-Object { $_.GetPlaybackInfo().PlaybackStatus -eq 'Playing' } | Select-Object -First 1
  if ($on) { return $on }
  $cur = $mgr.GetCurrentSession()
  if ($cur) { return $cur }
  return $all | Select-Object -First 1
}
`;

const PS_LOOP = PS_HEAD + `
[Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
$asRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [Type[]]@([Windows.Storage.Streams.IInputStream]))
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lastKey = ''
$lastSrc = $null; $srcPath = ''; $srcPid = 0
while ($true) {
  $s = Pick
  $o = $null
  if ($s) {
    $p = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    $tl = $s.GetTimelineProperties()
    $info = $s.GetPlaybackInfo()
    $src = $s.SourceAppUserModelId
    # Proses app sumber (buat ikon app di sampul & klik buat buka app-nya); dicari sekali per ganti app
    if ($src -ne $lastSrc) {
      $lastSrc = $src; $srcPath = ''; $srcPid = 0
      foreach ($n in @(($src -replace '\\.exe$', ''), ($src -split '!')[-1])) {
        $pr = @(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.Path })
        $w = $pr | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if (-not $w) { $w = $pr | Select-Object -First 1 }
        if ($w) { $srcPath = $w.Path; $srcPid = $w.Id; break }
      }
    }
    $o = @{ title = $p.Title; artist = $p.Artist; album = $p.AlbumTitle; source = $src; path = $srcPath; pid = $srcPid;
            canSeek = $info.Controls.IsPlaybackPositionEnabled;
            playing = ($info.PlaybackStatus -eq 'Playing'); position = $tl.Position.TotalSeconds; duration = ($tl.EndTime - $tl.StartTime).TotalSeconds;
            updated = $tl.LastUpdatedTime.ToUnixTimeMilliseconds() }
    $key = "$($s.SourceAppUserModelId)|$($p.Title)|$($p.Artist)"
    if ($key -ne $lastKey) {
      $lastKey = $key
      $o.art = ''
      if ($p.Thumbnail) {
        try {
          $st = Await ($p.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
          # Lewat reflection: PowerShell 5.1 nggak bisa nge-cast stream WinRT (__ComObject) kalau dipanggil biasa
          $ns = $asRead.Invoke($null, @($st))
          $ms = New-Object System.IO.MemoryStream
          $ns.CopyTo($ms); $ns.Dispose()
          $bytes = $ms.ToArray()
          if ($bytes.Length -gt 0) {
            $type = if ($bytes[0] -eq 0xFF) { 'image/jpeg' } elseif ($bytes[0] -eq 0x89) { 'image/png' } elseif ($bytes[0] -eq 0x47) { 'image/gif' } elseif ($bytes[0] -eq 0x52) { 'image/webp' } else { 'image/bmp' }
            $o.art = "data:$type;base64," + [Convert]::ToBase64String($bytes)
          }
        } catch { }
      }
    }
  }
  if ($o) { [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress)) } else { [Console]::Out.WriteLine('{}') }
  [Console]::Out.Flush()
  Start-Sleep -Milliseconds 1000
}`;

/** "Spotify.exe" / "SpotifyAB.SpotifyMusic_xxx!Spotify" / "MSEdge" → nama yang enak dibaca. */
function appName(id = '') {
  const known = { spotify: 'Spotify', chrome: 'Chrome', msedge: 'Edge', firefox: 'Firefox', brave: 'Brave', opera: 'Opera',
    vivaldi: 'Vivaldi', zunemusic: 'Media Player', zunevideo: 'Movies & TV', vlc: 'VLC', applemusic: 'Apple Music',
    itunes: 'iTunes', deezer: 'Deezer', tidal: 'TIDAL', youtube: 'YouTube Music', foobar: 'foobar2000', aimp: 'AIMP', musicbee: 'MusicBee' };
  const low = String(id).toLowerCase();
  for (const k in known) if (low.includes(k)) return known[k];
  const tail = String(id).split('!').pop().split('\\').pop().replace(/\.exe$/i, '');
  return tail.replace(/^.*\./, '') || 'Media';
}

const encode = (script) => Buffer.from(script, 'utf16le').toString('base64');

function startWindows() {
  let lastArt = null;
  const run = () => {
    const ps = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encode(PS_LOOP)], { windowsHide: true });
    let buf = '';
    ps.stdout.setEncoding('utf8');
    ps.stdout.on('data', (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        try {
          const o = JSON.parse(line);
          if (!o.title) { osState = null; continue; }
          if ('art' in o) lastArt = o.art || null; // '' = lagu baru tanpa cover
          o.art = lastArt;
          o.app = appName(o.source);
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
        position: +position / 1e6 || 0, at: Date.now(), source: player, app: player, canSeek: true } : null;
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

let lastSent = '', lastState = null;
function publish() {
  const state = osState || senandung || null;
  // Posisi yang maju normal nggak perlu dikirim (halaman ngitung sendiri); kirim kalau ada yang berubah atau posisinya loncat (seek)
  const key = JSON.stringify(state && { ...state, at: 0, position: 0, updated: 0 });
  if (key === lastSent && state && lastState) {
    const predicted = (lastState.position || 0) + (lastState.playing ? (Date.now() - lastState.at) / 1000 : 0);
    if (Math.abs(predicted - (state.position || 0)) < 1.5) return;
  } else if (key === lastSent) return;
  lastSent = key;
  lastState = state && { ...state };
  emit(state);
}

function start(cb) {
  emit = cb;
  if (process.platform === 'win32') startWindows();
  else if (process.platform === 'linux') startLinux();
  pollSenandung();
}

function command(cmd) {
  // "seek 74.5" = lompat ke detik 74.5
  const seek = /^seek (\d+(?:\.\d+)?)$/.exec(String(cmd));
  if (seek) {
    const sec = +seek[1];
    if (osState) osState = { ...osState, position: sec, at: Date.now() }; // langsung kelihatan, nggak nunggu laporan berikutnya
    if (process.platform === 'win32') {
      const script = PS_HEAD + `$s = Pick; if ($s) { Await ($s.TryChangePlaybackPositionAsync([long]${Math.round(sec * 1e7)})) ([bool]) | Out-Null }`;
      spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encode(script)], { windowsHide: true });
    } else if (process.platform === 'linux') execFile('playerctl', ['position', String(sec)], () => {});
    return publish();
  }
  if (!['toggle', 'next', 'prev', 'pause'].includes(cmd)) return;
  if (process.platform === 'win32') {
    const call = { toggle: 'TryTogglePlayPauseAsync', next: 'TrySkipNextAsync', prev: 'TrySkipPreviousAsync', pause: 'TryPauseAsync' }[cmd];
    const script = PS_HEAD + `$s = Pick; if ($s) { Await ($s.${call}()) ([bool]) | Out-Null }`;
    spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encode(script)], { windowsHide: true });
  } else if (process.platform === 'linux') {
    execFile('playerctl', [{ toggle: 'play-pause', next: 'next', prev: 'previous', pause: 'pause' }[cmd]], () => {});
  }
}

module.exports = { start, command };
