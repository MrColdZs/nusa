const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('nusa', {
  platform: process.platform,
  setRect: (r) => ipcRenderer.send('rect', r),
  media: (cmd) => ipcRenderer.send('media-cmd', cmd),
  copy: (t) => ipcRenderer.send('copy', t),
  open: (url) => ipcRenderer.send('open', url),
  focus: () => ipcRenderer.send('focus'),
  loginItem: (on) => ipcRenderer.invoke('login-item', on),
  senandung: (method, route, body) => ipcRenderer.invoke('senandung', method, route, body),
  asset: (name) => ipcRenderer.invoke('asset', name),
  on: (channel, fn) => {
    if (['hover', 'media', 'clip', 'open-panel'].includes(channel)) ipcRenderer.on(channel, (_e, v) => fn(v));
  },
});
