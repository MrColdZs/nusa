// Volume output sistem + perangkat yang lagi dipakai (buat slider volume, pop-up volume, dan pop-up headphone).
// - Windows: Core Audio lewat C# kecil yang dikompilasi PowerShell (Add-Type), jalan terus & baca perintah dari stdin
// - Linux: `pactl` (PulseAudio / PipeWire)
const { spawn, execFile } = require('child_process');

const CS = `
using System;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace NusaAudio {
  [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioEndpointVolume {
    int RegisterControlChangeNotify(IntPtr p);
    int UnregisterControlChangeNotify(IntPtr p);
    int GetChannelCount(out uint c);
    int SetMasterVolumeLevel(float l, ref Guid g);
    int SetMasterVolumeLevelScalar(float l, ref Guid g);
    int GetMasterVolumeLevel(out float l);
    int GetMasterVolumeLevelScalar(out float l);
    int SetChannelVolumeLevel(uint n, float l, ref Guid g);
    int SetChannelVolumeLevelScalar(uint n, float l, ref Guid g);
    int GetChannelVolumeLevel(uint n, out float l);
    int GetChannelVolumeLevelScalar(uint n, out float l);
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, ref Guid g);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool m);
  }
  [StructLayout(LayoutKind.Sequential)] struct PKEY { public Guid fmtid; public int pid; }
  [StructLayout(LayoutKind.Sequential)] struct PROPVAR { public ushort vt; public ushort r1; public ushort r2; public ushort r3; public IntPtr p; public IntPtr p2; }
  [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    int GetCount(out int c);
    int GetAt(int i, out PKEY k);
    int GetValue(ref PKEY k, out PROPVAR v);
  }
  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    int OpenPropertyStore(int access, out IPropertyStore ps);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    int GetState(out int s);
  }
  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int flow, int mask, out IntPtr devs);
    int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice d);
  }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo {}

  public static class Helper {
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVAR v);
    static readonly Guid DEV = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0");
    static readonly Guid ENDPOINT = new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e");
    static readonly Guid INSTANCE = new Guid("b3f8fa53-0004-438e-9003-51a46e139bfc");
    static float wantVol = float.NaN;
    static int wantMute = -1;

    static PROPVAR Get(IPropertyStore ps, Guid g, int pid, out bool ok) {
      PKEY k = new PKEY(); k.fmtid = g; k.pid = pid;
      PROPVAR v;
      ok = ps.GetValue(ref k, out v) == 0;
      return v;
    }
    static string Str(IPropertyStore ps, Guid g, int pid) {
      bool ok; PROPVAR v = Get(ps, g, pid, out ok);
      if (!ok) return null;
      string s = v.vt == 31 ? Marshal.PtrToStringUni(v.p) : null;
      PropVariantClear(ref v);
      return s;
    }
    static int Num(IPropertyStore ps, Guid g, int pid) {
      bool ok; PROPVAR v = Get(ps, g, pid, out ok);
      if (!ok) return -1;
      int n = (v.vt == 19 || v.vt == 3) ? (int)(v.p.ToInt64() & 0xFFFFFFFF) : -1;
      PropVariantClear(ref v);
      return n;
    }
    static string Esc(string s) {
      if (s == null) return "";
      StringBuilder b = new StringBuilder();
      foreach (char c in s) {
        if (c == '"' || c == '\\\\') { b.Append('\\\\'); b.Append(c); }
        else if (c < ' ') b.Append(' ');
        else b.Append(c);
      }
      return b.ToString();
    }

    static void ReadInput() {
      string line;
      while ((line = Console.In.ReadLine()) != null) {
        string[] p = line.Trim().Split(' ');
        if (p.Length < 2) continue;
        float f;
        if (p[0] == "vol" && float.TryParse(p[1], NumberStyles.Float, CultureInfo.InvariantCulture, out f)) wantVol = Math.Max(0f, Math.Min(1f, f));
        if (p[0] == "mute") wantMute = p[1] == "1" ? 1 : 0;
      }
      Environment.Exit(0);
    }

    public static void Run() {
      Console.OutputEncoding = Encoding.UTF8;
      Thread t = new Thread(ReadInput); t.IsBackground = true; t.Start();
      IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
      Guid iid = typeof(IAudioEndpointVolume).GUID;
      Guid ctx = Guid.Empty;
      string curId = null, name = "", inst = "";
      int ff = -1;
      IAudioEndpointVolume vol = null;
      string last = "";
      while (true) {
        string line = "{}";
        try {
          IMMDevice dev;
          if (en.GetDefaultAudioEndpoint(0, 1, out dev) == 0 && dev != null) {
            string id; dev.GetId(out id);
            if (id != curId) {
              object o; dev.Activate(ref iid, 23, IntPtr.Zero, out o);
              vol = (IAudioEndpointVolume)o;
              IPropertyStore ps; dev.OpenPropertyStore(0, out ps);
              name = Str(ps, DEV, 14) ?? "";
              inst = Str(ps, INSTANCE, 2) ?? "";
              ff = Num(ps, ENDPOINT, 0);
              curId = id;
            }
            if (!float.IsNaN(wantVol)) { float w = wantVol; wantVol = float.NaN; vol.SetMasterVolumeLevelScalar(w, ref ctx); if (w > 0) vol.SetMute(false, ref ctx); }
            if (wantMute >= 0) { bool m = wantMute == 1; wantMute = -1; vol.SetMute(m, ref ctx); }
            float level; vol.GetMasterVolumeLevelScalar(out level);
            bool muted; vol.GetMute(out muted);
            string up = inst.ToUpperInvariant();
            bool bt = up.Contains("BTHENUM") || up.Contains("BTHHFENUM") || up.Contains("BTHLE");
            line = "{\\"vol\\":" + Math.Round(level, 3).ToString(CultureInfo.InvariantCulture) + ",\\"muted\\":" + (muted ? "true" : "false")
              + ",\\"id\\":\\"" + Esc(curId) + "\\",\\"name\\":\\"" + Esc(name) + "\\",\\"bt\\":" + (bt ? "true" : "false") + ",\\"ff\\":" + ff + "}";
          }
        } catch { curId = null; }
        if (line != last) { Console.Out.WriteLine(line); Console.Out.Flush(); last = line; }
        Thread.Sleep(200);
      }
    }
  }
}`;

const PS = `$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
${CS}
'@
[NusaAudio.Helper]::Run()`;

let proc = null;
let emit = () => {};

function startWindows() {
  const run = () => {
    proc = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', Buffer.from(PS, 'utf16le').toString('base64')],
      { windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'] });
    let buf = '';
    proc.stdout.setEncoding('utf8');
    proc.stdout.on('data', (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        try { const o = JSON.parse(line); emit(o.id ? o : null); } catch { /* baris rusak, lewati */ }
      }
    });
    proc.on('exit', () => { proc = null; setTimeout(run, 3000); });
  };
  run();
}

function startLinux() {
  const read = () => execFile('sh', ['-c', 'pactl get-default-sink; pactl get-sink-volume @DEFAULT_SINK@; pactl get-sink-mute @DEFAULT_SINK@'], { timeout: 1500 }, (err, out) => {
    if (err) return emit(null);
    const [sink, volLine = '', muteLine = ''] = out.split('\n');
    const pct = /(\d+)%/.exec(volLine);
    emit({ id: sink, name: sink.replace(/^bluez_(output|sink)\./, '').replace(/_/g, ' '), vol: pct ? Math.min(1, +pct[1] / 100) : 0,
      muted: /yes/i.test(muteLine), bt: sink.startsWith('bluez'), ff: -1 });
  });
  setInterval(read, 500);
  read();
}

function start(cb) {
  emit = cb;
  if (process.platform === 'win32') startWindows();
  else if (process.platform === 'linux') startLinux();
}

/** level 0..1 */
function setVolume(level) {
  const v = Math.max(0, Math.min(1, +level || 0));
  if (process.platform === 'win32') proc?.stdin.write(`vol ${v.toFixed(3)}\n`);
  else if (process.platform === 'linux') execFile('pactl', ['set-sink-volume', '@DEFAULT_SINK@', `${Math.round(v * 100)}%`], () => {});
}

function setMute(on) {
  if (process.platform === 'win32') proc?.stdin.write(`mute ${on ? 1 : 0}\n`);
  else if (process.platform === 'linux') execFile('pactl', ['set-sink-mute', '@DEFAULT_SINK@', on ? '1' : '0'], () => {});
}

/** Baterai headphone Bluetooth (Windows: properti PnP; Linux: upower). Hasil contoh "Battery 80%". */
function battery(name, done) {
  const clean = String(name).replace(/^.*\((.*)\)\s*$/, '$1').replace(/['‘’]/g, "''").replace(/[*?[\]]/g, '').trim();
  if (!clean) return done(null);
  if (process.platform === 'win32') {
    const ps = `$ErrorActionPreference='SilentlyContinue'; Get-PnpDevice -FriendlyName '*${clean}*' | ForEach-Object { (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2').Data } | Where-Object { $_ -ne $null } | Select-Object -First 1`;
    execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { windowsHide: true, timeout: 8000 }, (err, out) => {
      const n = parseInt(String(out).trim(), 10);
      done(Number.isFinite(n) ? `Battery ${n}%` : null);
    });
  } else {
    execFile('sh', ['-c', 'upower -e | grep -i -E "headset|headphone|bluez" | head -1 | xargs -r upower -i | grep -i percentage'], { timeout: 3000 }, (err, out) => {
      const m = /(\d+)%/.exec(String(out));
      done(m ? `Battery ${m[1]}%` : null);
    });
  }
}

module.exports = { start, setVolume, setMute, battery };
