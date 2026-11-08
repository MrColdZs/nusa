// Baca waktu dari kalimat tugas (Indonesia & Inggris). Sama dengan Sources/Tasks.swift versi Mac,
// minus NSDataDetector: bagian Inggris pakai aturan sendiri.
(function (root) {
  function tidy(s) {
    let t = s.replace(/\s{2,}/g, ' ').replace(/^[\s,.-]+|[\s,.-]+$/g, '');
    for (const tail of [' at', ' on', ' by', ' in', ' pada', ' pas', ' sekitar', ' untuk', ' buat', ' dalam', ' di']) {
      if (t.toLowerCase().endsWith(tail)) t = t.slice(0, -tail.length);
    }
    return t.trim();
  }

  function atTime(base, dayOffset, h, m) {
    const d = new Date(base);
    d.setDate(d.getDate() + dayOffset);
    d.setHours(h, m, 0, 0);
    return d;
  }

  function parse(raw, now = new Date()) {
    let rest = raw.trim();
    const cut = (re) => { const m = rest.match(re); if (!m) return null; rest = rest.replace(m[0], ' '); return m; };

    // Relatif: "30 menit lagi", "dalam 2 jam", "in 45 min"
    let m = cut(/\b(?:dalam\s+)?(\d{1,3})\s*(menit|mnt|jam)\s+lagi\b/i) || cut(/\bdalam\s+(\d{1,3})\s*(menit|mnt|jam)\b/i);
    if (m) return { title: tidy(rest) || raw, due: new Date(+now + (/^j/i.test(m[2]) ? 3600000 : 60000) * +m[1]) };
    m = cut(/\bin\s+(\d{1,3})\s*(m|min|mins|minutes?|h|hr|hrs|hours?)\b/i);
    if (m) return { title: tidy(rest) || raw, due: new Date(+now + (/^h/i.test(m[2]) ? 3600000 : 60000) * +m[1]) };

    let day = null, hour = null, minute = 0, part = null, matched = false;
    if (cut(/\blusa\b/i)) { day = 2; matched = true; }
    else if (cut(/\b(besok|tomorrow)\b/i)) { day = 1; matched = true; }
    else if (cut(/\b(hari ini|today)\b/i)) { day = 0; matched = true; }
    if ((m = cut(/\b(?:jam|pukul)\s*(\d{1,2})(?:[.:](\d{2}))?\b/i))) { hour = +m[1]; minute = +(m[2] || 0); matched = true; }
    else if ((m = cut(/\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b/i))) {
      hour = +m[1] % 12 + (m[3].toLowerCase() === 'pm' ? 12 : 0); minute = +(m[2] || 0); matched = true;
    } else if ((m = cut(/\bat\s+(\d{1,2}):(\d{2})\b/i))) { hour = +m[1]; minute = +m[2]; matched = true; }
    if ((m = cut(/\b(?:nanti\s+)?(pagi|siang|sore|malam)\b/i))) { part = m[1].toLowerCase(); matched = true; }
    else if (cut(/\btonight\b/i)) { part = 'malam'; matched = true; }
    if (!matched) return { title: raw.trim(), due: null };
    cut(/\bnanti\b/i);

    if (hour != null) {
      if (part === 'siang' && hour < 11) hour += 12;
      else if ((part === 'sore') && hour < 12) hour += 12;
      else if (part === 'malam') hour = hour === 12 ? 0 : hour < 12 ? hour + 12 : hour;
    } else if (part) hour = { pagi: 8, siang: 12, sore: 16, malam: 20 }[part];
    else hour = 9;
    if (hour > 23 || minute > 59) return { title: raw.trim(), due: null };
    let due = atTime(now, day ?? 0, hour, minute);
    if (day == null && due <= now) due = atTime(now, 1, hour, minute);
    return { title: tidy(rest) || raw.trim(), due };
  }

  root.TaskParser = { parse };
})(typeof window !== 'undefined' ? window : globalThis);
