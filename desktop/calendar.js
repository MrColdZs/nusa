// Kalender Windows (yang dipakai app Calendar/Mail bawaan & akun di Settings › Accounts), dibaca lewat WinRT AppointmentStore.
// Sekali ambil langsung beberapa hari (strip 7 hari di Home), jadi ganti hari nggak perlu nunggu.
const { execFile } = require('child_process');

const script = (startMs, days) => `
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation\`1' })[0]
  function Await($op, [Type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); $task.Wait(-1) | Out-Null; $task.Result }
  [Windows.ApplicationModel.Appointments.AppointmentManager, Windows.ApplicationModel.Appointments, ContentType = WindowsRuntime] | Out-Null
  $store = Await ([Windows.ApplicationModel.Appointments.AppointmentManager]::RequestStoreAsync('AllCalendarsReadOnly')) ([Windows.ApplicationModel.Appointments.AppointmentStore])
  if (-not $store) { '{"error":"denied"}'; exit }
  $cals = Await ($store.FindAppointmentCalendarsAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.ApplicationModel.Appointments.AppointmentCalendar]])
  $color = @{}
  foreach ($c in $cals) { $k = $c.DisplayColor; $color[$c.LocalId] = '#{0:x2}{1:x2}{2:x2}' -f $k.R, $k.G, $k.B }
  $apps = Await ($store.FindAppointmentsAsync([DateTimeOffset]::FromUnixTimeMilliseconds(${Math.round(startMs)}), [TimeSpan]::FromDays(${days}))) ([System.Collections.Generic.IReadOnlyList[Windows.ApplicationModel.Appointments.Appointment]])
  $ev = @(foreach ($a in $apps) {
    @{ title = $a.Subject; start = $a.StartTime.ToUnixTimeMilliseconds(); minutes = [int]$a.Duration.TotalMinutes; allDay = [bool]$a.AllDay; color = $color[$a.CalendarId] }
  })
  @{ calendars = @($cals).Count; events = $ev } | ConvertTo-Json -Compress -Depth 4
} catch {
  $m = $_.Exception.ToString()
  if ($m -match 'denied|0x80070005') { '{"error":"denied"}' } else { @{ error = $_.Exception.Message } | ConvertTo-Json -Compress }
}`;

let running = null;

/** Event kalender Windows mulai `startMs` selama `days` hari. Hasil: { calendars, events } atau { error }. */
function fetch(startMs, days) {
  if (process.platform !== 'win32') return Promise.resolve({ error: 'unsupported' });
  if (running) return running;
  running = new Promise((resolve) => {
    const enc = Buffer.from(script(startMs, days), 'utf16le').toString('base64');
    execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', enc],
      { windowsHide: true, timeout: 20000, maxBuffer: 4 * 1024 * 1024 }, (err, out) => {
        running = null;
        const line = String(out || '').trim().split('\n').pop();
        try {
          const r = JSON.parse(line);
          if (r.events) r.events = (Array.isArray(r.events) ? r.events : [r.events]).filter((e) => e && e.start);
          resolve(r);
        } catch { resolve({ error: err ? String(err.message || err) : 'unreadable' }); }
      });
  });
  return running;
}

module.exports = { fetch };
