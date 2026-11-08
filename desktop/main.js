// Nusa untuk Windows & Linux: jendela transparan di tengah atas layar, isinya notch HTML.
const { app, BrowserWindow, screen, ipcMain, clipboard, Tray, Menu, nativeImage, shell } = require('electron');
const fs = require('fs');
const path = require('path');
const media = require('./media');

const W = 840, H = 440;
let win = null, tray = null;
let rect = { x: 0, y: 0, w: 0, h: 0 };
let inside = false;

/** Kirim ke halaman; kalau gagal (halaman lagi dimuat ulang dll.) diabaikan aja. */
function send(channel, value) {
  try { if (win && !win.isDestroyed()) win.webContents.send(channel, value); } catch {}
}

// Mode tes: data di folder terpisah biar data asli nggak kesentuh
if (process.env.NUSA_USERDATA) app.setPath('userData', process.env.NUSA_USERDATA);
if (!app.requestSingleInstanceLock()) app.quit();
// Linux butuh ini biar latar jendela bisa transparan
if (process.platform === 'linux') app.commandLine.appendSwitch('enable-transparent-visuals');
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

function place() {
  const d = screen.getPrimaryDisplay().bounds;
  win.setBounds({ x: Math.round(d.x + d.width / 2 - W / 2), y: d.y, width: W, height: H });
}

function create() {
  win = new BrowserWindow({
    width: W, height: H, frame: false, transparent: true, resizable: false, movable: false, minimizable: false,
    maximizable: false, fullscreenable: false, alwaysOnTop: true, skipTaskbar: true, hasShadow: false, show: false,
    backgroundColor: '#00000000', title: 'Nusa',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, backgroundThrottling: false },
  });
  win.setAlwaysOnTop(true, 'screen-saver');
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  win.setIgnoreMouseEvents(true);
  place();
  win.loadFile(path.join(__dirname, 'app', 'index.html'));
  win.once('ready-to-show', () => win.showInactive());
  screen.on('display-metrics-changed', place);
  screen.on('display-added', place);
  screen.on('display-removed', place);

  // Klik di luar notch harus tembus ke app di belakang: cek posisi kursor 25x per detik
  setInterval(() => {
    if (!win || win.isDestroyed()) return;
    const p = screen.getCursorScreenPoint();
    const b = win.getBounds();
    const x = p.x - b.x, y = p.y - b.y;
    const over = x >= rect.x && x <= rect.x + rect.w && y >= rect.y && y <= rect.y + rect.h;
    if (over === inside) return;
    inside = over;
    win.setIgnoreMouseEvents(!over);
    send('hover', over);
  }, 40);

  media.start((state) => send('media', state && JSON.parse(JSON.stringify(state))));

  // Riwayat clipboard (teks aja), dicek tiap detik
  let lastClip = clipboard.readText();
  setInterval(() => {
    const t = clipboard.readText();
    if (t && t !== lastClip) { lastClip = t; send('clip', String(t)); }
  }, 1000);
}

ipcMain.on('rect', (_e, r) => { rect = r; });

// Server Senandung (tab Music): lewat proses utama biar nggak keblok CORS di halaman file://
ipcMain.handle('senandung', (_e, method, route, body) => new Promise((resolve) => {
  if (!/^\/api\/(remote\/(state|cmd)|yt\/search)/.test(route)) return resolve(null);
  const data = body ? JSON.stringify(body) : null;
  const req = require('http').request({ host: '127.0.0.1', port: 5560, path: route, method, timeout: 8000,
    headers: data ? { 'Content-Type': 'application/json', 'X-Senandung-Remote': '1', 'Content-Length': Buffer.byteLength(data) } : {} }, (res) => {
    let b = '';
    res.on('data', (d) => (b += d));
    res.on('end', () => { try { resolve(JSON.parse(b)); } catch { resolve(null); } });
  });
  req.on('error', () => resolve(null));
  req.on('timeout', () => { req.destroy(); resolve(null); });
  if (data) req.write(data);
  req.end();
}));

// Aset bawaan (data Quran) dibaca lewat sini; fetch file:// nggak jalan di halaman
ipcMain.handle('asset', (_e, name) => {
  if (!/^[a-z0-9.-]+\.json$/i.test(name)) return null;
  return fs.readFileSync(path.join(__dirname, 'app', 'assets', name), 'utf8');
});
ipcMain.on('media-cmd', (_e, cmd) => media.command(cmd));
ipcMain.on('copy', (_e, text) => clipboard.writeText(String(text)));
ipcMain.on('open', (_e, url) => { if (/^https?:\/\//.test(url)) shell.openExternal(url); });
ipcMain.on('focus', () => win && win.focus());
ipcMain.handle('login-item', (_e, on) => {
  if (process.platform === 'linux') return linuxAutostart(on);
  if (on !== undefined) app.setLoginItemSettings({ openAtLogin: !!on });
  return app.getLoginItemSettings().openAtLogin;
});

/** Linux nggak punya API login item: tulis file .desktop di ~/.config/autostart. */
function linuxAutostart(on) {
  const file = path.join(app.getPath('home'), '.config', 'autostart', 'nusa.desktop');
  if (on === true) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, `[Desktop Entry]\nType=Application\nName=Nusa\nExec="${process.env.APPIMAGE || process.execPath}"\nX-GNOME-Autostart-enabled=true\n`);
  } else if (on === false) fs.rmSync(file, { force: true });
  return fs.existsSync(file);
}

function makeTray() {
  const icon = nativeImage.createFromPath(path.join(__dirname, 'build', 'tray.png')).resize({ width: 18, height: 18 });
  tray = new Tray(icon);
  tray.setToolTip('Nusa');
  const rebuild = async () => {
    const atLogin = process.platform === 'linux' ? linuxAutostart() : app.getLoginItemSettings().openAtLogin;
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: 'Open Nusa', click: () => send('open-panel') },
      { label: 'Start at login', type: 'checkbox', checked: atLogin, click: (m) => {
        process.platform === 'linux' ? linuxAutostart(m.checked) : app.setLoginItemSettings({ openAtLogin: m.checked });
        rebuild();
      } },
      { type: 'separator' },
      { label: 'Quit Nusa', click: () => app.quit() },
    ]));
  };
  rebuild();
  tray.on('click', () => send('open-panel'));
}

// Mode tes (dipakai pas development di Mac): jalanin langkah-langkah lalu potret jendela
async function shotMode(dir, steps) {
  for (const [js, name, wait] of steps) {
    if (js) await win.webContents.executeJavaScript(js);
    await new Promise((r) => setTimeout(r, wait ?? 900));
    if (name) fs.writeFileSync(path.join(dir, name + '.png'), (await win.webContents.capturePage()).toPNG());
  }
  app.quit();
}

app.whenReady().then(() => {
  // Linux: kasih jeda dikit biar compositor siap (kalau nggak, latar transparan jadi hitam)
  setTimeout(() => {
    create();
    makeTray();
    if (process.env.NUSA_SHOT_DIR) {
      win.webContents.once('did-finish-load', () => setTimeout(() => {
        shotMode(process.env.NUSA_SHOT_DIR, JSON.parse(fs.readFileSync(process.env.NUSA_SHOT_STEPS, 'utf8')));
      }, 2500));
    }
  }, process.platform === 'linux' ? 400 : 0);
});
app.on('second-instance', () => win && send('open-panel'));
app.on('window-all-closed', () => app.quit());
