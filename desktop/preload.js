const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('nusa', {
  platform: process.platform,
  setRect: (r) => ipcRenderer.send('rect', r),
  media: (cmd) => ipcRenderer.send('media-cmd', cmd),
  volume: (level) => ipcRenderer.send('volume', level),
  mute: (on) => ipcRenderer.send('mute', on),
  openSource: (src) => ipcRenderer.send('open-source', src),
  copy: (t) => ipcRenderer.send('copy', t),
  open: (url) => ipcRenderer.send('open', url),
  focus: () => ipcRenderer.send('focus'),
  loginItem: (on) => ipcRenderer.invoke('login-item', on),
  contextMenu: () => ipcRenderer.send('context-menu'),
  calendar: (start, days) => ipcRenderer.invoke('calendar', start, days),
  calendarSettings: () => ipcRenderer.send('calendar-settings'),
  senandung: (method, route, body) => ipcRenderer.invoke('senandung', method, route, body),
  asset: (name) => ipcRenderer.invoke('asset', name),
  // Rak: path file yang di-drop (Electron baru nggak ngasih File.path lagi), info/ikon, buka, seret keluar
  filePath: (file) => { try { return webUtils.getPathForFile(file); } catch { return ''; } },
  fileInfo: (p) => ipcRenderer.invoke('file-info', p),
  fileOpen: (p) => ipcRenderer.send('file-open', p),
  fileShow: (p) => ipcRenderer.send('file-show', p),
  fileDrag: (p) => ipcRenderer.send('file-drag', p),
  on: (channel, fn) => {
    if (['hover', 'media', 'clip', 'open-panel', 'audio', 'device'].includes(channel)) ipcRenderer.on(channel, (_e, v) => fn(v));
  },
});
