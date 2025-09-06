// =========================
// Globals & NUI helper
// =========================
let sideTimer = null;
let currentDeviceId = null;
let panelRefreshTimer = null;

function postNUI(endpoint, payload) {
  return fetch(`https://${GetParentResourceName()}/${endpoint}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: payload ? JSON.stringify(payload) : "{}"
  }).then(r => r.json().catch(() => ({}))).catch(() => ({}));
}

// =========================
// Message router
// =========================
window.addEventListener("message", (event) => {
  const data = event.data || {};
  const action = data.action;

  // === Bestehendes Kaufmenü (Parkuhr/Automat) ===
  if (action === "open") {
    currentDeviceId = data.deviceId || null;
    document.body.classList.remove("panel-open"); // Panel sicher schließen
    document.body.style.display = "flex";
    const menu = document.getElementById("menu");
    if (menu) menu.style.display = "block";
    const longDur = document.getElementById("long-durations");
    if (longDur) longDur.style.display = currentDeviceId ? "flex" : "none";
  }

  if (action === "showSideInfo") {
    showSideInfo(data.info || {});
  }

  if (action === "openWarn") {
    document.body.classList.remove("panel-open");
    document.body.style.display = "flex";
    const win = document.getElementById("warn-window");
    if (win) win.style.display = "block";
    const plateEl = document.getElementById("warn-plate");
    const reasonEl = document.getElementById("warn-reason");
    if (plateEl) plateEl.textContent = data.plate || "-";
    if (reasonEl) reasonEl.value = "";
  }

  if (action === "hideTicketInfo") hideSideInfo();
  if (action === "closeAll") hideAll();

  // === Zentrale / Panel ===
  if (action === "openPanel") {
    openPanel();                 // nur öffnen
    postNUI("panelRequest", {}); // frische Daten anfordern
  }
  if (action === "panelData") {
    if (document.body.classList.contains("panel-open")) {
      renderPanel(data.data);
    }
  }
});

// =========================
// Kaufen / Close (Bestandssystem)
function buy(minutes) {
  postNUI("buyTicket", { minutes, deviceId: currentDeviceId }).then(() => closeMenu());
}
function closeMenu() {
  postNUI("close");
  currentDeviceId = null;
  const menu = document.getElementById("menu");
  if (menu) menu.style.display = "none";
  const warnOpen  = document.getElementById("warn-window")?.style.display === "block";
  const panelOpen = document.body.classList.contains("panel-open");
  if (!warnOpen && !panelOpen) document.body.style.display = "none";
}

// =========================
// Verwarnung (Bestandssystem)
function submitWarning() {
  const plate = document.getElementById("warn-plate").textContent;
  const reason = document.getElementById("warn-reason").value || "Kein Grund angegeben";
  postNUI("submitWarning", { plate, reason }).then(() => closeWarn());
}
function closeWarn() {
  postNUI("closeWarn");
  const win = document.getElementById("warn-window");
  if (win) win.style.display = "none";
  const menuOpen  = document.getElementById("menu")?.style.display === "block";
  const panelOpen = document.body.classList.contains("panel-open");
  if (!menuOpen && !panelOpen) document.body.style.display = "none";
}

// =========================
// Seitliches HUD
function showSideInfo(info) {
  document.body.style.display = "flex";
  const p = document.getElementById("side-info");
  if (!p) return;

  const plateEl   = document.getElementById("s-plate");
  const ownerEl   = document.getElementById("s-owner");
  const expiresEl = document.getElementById("s-expires");

  if (plateEl)   plateEl.textContent   = info.plate  || "-";
  if (ownerEl)   ownerEl.textContent   = info.owner  || "-";
  if (expiresEl) expiresEl.textContent = formatExpires(info);

  p.style.display = "block";
  requestAnimationFrame(() => p.classList.add("show"));

  if (sideTimer) clearTimeout(sideTimer);
  sideTimer = setTimeout(hideSideInfo, 8000);
}
function hideSideInfo() {
  const p = document.getElementById("side-info");
  if (!p) return;
  p.classList.remove("show");
  setTimeout(() => {
    p.style.display = "none";
    const menuOpen  = document.getElementById("menu")?.style.display === "block";
    const warnOpen  = document.getElementById("warn-window")?.style.display === "block";
    const panelOpen = document.body.classList.contains("panel-open");
    if (!menuOpen && !warnOpen && !panelOpen) document.body.style.display = "none";
  }, 180);
}

// =========================
// Datum/Format-Helfer (robust)
function formatExpires(info) {
  let epoch = Number(info.expiresEpoch);
  if (!Number.isNaN(epoch) && epoch > 0) {
    if (epoch < 1e12) epoch *= 1000;
    const d = new Date(epoch);
    if (!Number.isNaN(d.getTime())) {
      return d.toLocaleString("de-DE", { hour12: false, timeZone: "Europe/Berlin" });
    }
  }
  const str = info.expires;
  if (typeof str === "string" && str.length) {
    const iso = str.includes("T") ? str : str.replace(" ", "T");
    const d = new Date(iso + "Z");
    if (!Number.isNaN(d.getTime())) {
      return d.toLocaleString("de-DE", { hour12: false, timeZone: "Europe/Berlin" });
    }
    return str;
  }
  return "-";
}
function fmtDate(ts) {
  let d = null;
  if (ts instanceof Date) d = ts;
  else if (typeof ts === "number") { if (ts < 1e12) ts *= 1000; d = new Date(ts); }
  else if (typeof ts === "string") {
    const s = ts.includes("T") ? ts : ts.replace(" ", "T");
    d = new Date(s + "Z"); if (Number.isNaN(d.getTime())) d = new Date(ts);
  } else return "";
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleString("de-DE", { hour12: false, timeZone: "Europe/Berlin" });
}

// =========================
// ESC → Panel schließen
document.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape" && document.body.classList.contains("panel-open")) {
    postNUI("panelClose", {}); // Lua gibt Fokus frei
    closePanel();
  }
});

// =========================
// Panel open/close
function openPanel() {
  document.body.style.display = "flex";
  document.body.classList.add("panel-open");

  // DOM-Grundgerüst einmalig anlegen
  if (!document.querySelector("#parkuhr-panel")) {
    const root = document.createElement("div");
    root.id = "parkuhr-panel";
    root.innerHTML = `
      <div class="panel-wrapper">
        <div class="panel-banner">
          Parkraum Zentrale
          <button id="panel-close-btn" title="Schließen">×</button>
        </div>
        <div class="panel-body">
          <aside class="panel-sidebar">
            <button class="panel-item active" data-view="devices">Geräteübersicht</button>
            <button class="panel-item" id="panel-refresh-btn" title="Aktualisieren">↻ Aktualisieren</button>
          </aside>
          <main class="panel-content">
            <div id="view-devices"></div>
          </main>
        </div>
      </div>`;
    document.body.appendChild(root);

    // Close-Button
    document.getElementById("panel-close-btn").addEventListener("click", (e) => {
      e.preventDefault(); e.stopPropagation();
      postNUI("panelClose", {});
      closePanel();
    });

    // Manuelles Refresh
    document.getElementById("panel-refresh-btn").addEventListener("click", () => {
      postNUI("panelRequest", {});
    });
  }

  // Fallback-CSS (Panel nur sichtbar, wenn body.panel-open)
  if (!document.getElementById("parkuhr-panel-style")) {
    const s = document.createElement("style");
    s.id = "parkuhr-panel-style";
    s.textContent = `
      #parkuhr-panel{display:none; position:fixed; inset:5% 8%; background:rgba(15,18,24,0.92); color:#fff; border-radius:12px; overflow:hidden; box-shadow:0 10px 30px rgba(0,0,0,.5); z-index:99999; font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;}
      body.panel-open #parkuhr-panel{display:block;}
      .panel-banner{position:relative; padding:16px 56px 16px 20px; font-size:20px; font-weight:700; background:linear-gradient(90deg,#1f3b73,#2a6f9c);}
      #panel-close-btn{position:absolute; right:12px; top:10px; width:34px; height:34px; border-radius:8px; border:0; cursor:pointer; font-size:20px; background:rgba(255,255,255,0.15); color:#fff;}
      #panel-close-btn:hover{background:rgba(255,255,255,0.25);}
      .panel-body{display:flex; height:calc(100% - 56px);}
      .panel-sidebar{width:220px; background:rgba(0,0,0,0.25); padding:12px; display:flex; flex-direction:column; gap:8px;}
      .panel-sidebar .panel-item{background:rgba(255,255,255,0.06); color:#fff; border:0; padding:10px 12px; border-radius:8px; text-align:left; cursor:pointer;}
      .panel-sidebar .panel-item.active{background:rgba(255,255,255,0.14);}
      .panel-content{flex:1; padding:16px; overflow:auto;}
      .dev-table{width:100%; border-collapse:collapse; font-size:14px;}
      .dev-table th,.dev-table td{padding:10px 12px; border-bottom:1px solid rgba(255,255,255,0.08); vertical-align:top;}
      .dev-table th{text-align:left; color:#cfe3ff; font-weight:600;}
      .badge{display:inline-block; padding:2px 8px; border-radius:999px; background:rgba(255,255,255,0.12); color:#fff; font-size:12px;}
      .sales-summary{opacity:0.9; margin-bottom:6px;}
      .sales-details{display:none; margin-top:6px; font-size:13px; line-height:1.4;}
      .toggle-btn{margin-top:6px; display:inline-block; padding:4px 8px; border-radius:6px; border:0; background:rgba(255,255,255,0.10); color:#fff; cursor:pointer;}
      .toggle-btn:hover{background:rgba(255,255,255,0.18);}
      h3.section-title{margin:12px 0 6px 4px; font-weight:700; font-size:16px; color:#cfe3ff;}
      h3.section-title .badge{margin-left:6px;}
    `;
    document.head.appendChild(s);
  }

  // jedes Öffnen: frische Daten + Auto-Refresh
  postNUI("panelRequest", {});
  if (panelRefreshTimer) clearInterval(panelRefreshTimer);
  panelRefreshTimer = setInterval(() => {
    if (document.body.classList.contains("panel-open")) postNUI("panelRequest", {});
  }, 10000);
}
function closePanel() {
  document.body.classList.remove("panel-open");
  if (panelRefreshTimer) { clearInterval(panelRefreshTimer); panelRefreshTimer = null; }
  const menuOpen  = document.getElementById("menu")?.style.display === "block";
  const warnOpen  = document.getElementById("warn-window")?.style.display === "block";
  if (!menuOpen && !warnOpen) document.body.style.display = "none";
}

// =========================
// Render Panel (Automaten zuerst, dann Parkuhren)
// =========================
function renderPanel(payload) {
  const wrap = document.querySelector("#view-devices");
  if (!wrap) return;

  const devices = Array.isArray(payload?.devices) ? payload.devices : [];
  const machines = devices.filter(d => (d.type || "").toLowerCase() === "machine");
  const meters   = devices.filter(d => (d.type || "").toLowerCase() !== "machine");

  const niceType = (t) => {
    if (!t) return "";
    const map = { machine:"Automat", meter_small:"Kleine Parkuhr", meter_big:"Große Parkuhr", device:"Gerät" };
    return map[t] || t;
  };

  const summarizeSales = (salesArr) => {
    const counts = {};
    (Array.isArray(salesArr) ? salesArr : []).forEach(s => {
      const label = (s && s.label) ? s.label : "Ticket";
      counts[label] = (counts[label] || 0) + 1;
    });
    const order = ["7 Tage", "1 Tag", "60 Minuten", "30 Minuten", "10 Minuten", "Min", "Ticket"];
    const keys = Object.keys(counts).sort((a,b) => {
      const ia = order.findIndex(k => a.includes(k));
      const ib = order.findIndex(k => b.includes(k));
      return (ia<0 && ib<0) ? a.localeCompare(b) : (ia<0 ? 1 : ib<0 ? -1 : ia - ib);
    });
    return keys.map(k => `${counts[k]}× ${k}`).join(", ");
  };

  const rowHTML = (dev) => {
    const salesArr = Array.isArray(dev.sales) ? dev.sales : [];
    const summary = summarizeSales(salesArr);
    const rows = salesArr.slice(0, 20).map(s => {
      const when  = fmtDate(s && s.ts);
      const label = (s && s.label) ? s.label : "Ticket";
      return when ? `${when} – Ticket für ${label}` : `Ticket für ${label}`;
    }).join("<br>");

    const revenue = Number(dev.revenue || 0);
    const currency = payload?.currency || "";
    const revenueStr = revenue > 0
      ? `${currency}${revenue.toLocaleString("de-DE", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
      : "—";

    const pos = dev.pos
      ? `${Number(dev.pos.x).toFixed(1)}, ${Number(dev.pos.y).toFixed(1)}, ${Number(dev.pos.z).toFixed(1)}`
      : "";

    const detailId = `sales-${dev.id}`;

    return `
      <tr>
        <td>#${dev.id}</td>
        <td><span class="badge">${niceType(dev.type)}</span></td>
        <td>${pos}</td>
        <td>
          <div class="sales-summary">${summary || "—"}</div>
          ${rows ? `<button class="toggle-btn" data-target="${detailId}">Details anzeigen</button>` : ""}
          <div class="sales-details" id="${detailId}">${rows}</div>
        </td>
        <td><strong>${revenueStr}</strong></td>
      </tr>
    `;
  };

  const tableHTML = (title, list) => {
    if (!list.length) return "";
    const rows = list.map(rowHTML).join("");
    return `
      <h3 class="section-title">${title} <span class="badge">${list.length}</span></h3>
      <div class="devices">
        <table class="dev-table">
          <thead>
            <tr>
              <th>ID</th>
              <th>Typ</th>
              <th>Position</th>
              <th>Letzte Verkäufe</th>
              <th>Einnahmen</th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
    `;
  };

  let html = "";
  html += tableHTML("Automaten", machines);
  html += tableHTML("Parkuhren", meters);
  if (!html) html = `<div style="opacity:.8">Keine Geräte gefunden.</div>`;

  wrap.innerHTML = html;

  // Toggle-Handler für Details
  wrap.querySelectorAll(".toggle-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      const id = btn.getAttribute("data-target");
      const box = document.getElementById(id);
      if (!box) return;
      const visible = box.style.display === "block";
      box.style.display = visible ? "none" : "block";
      btn.textContent = visible ? "Details anzeigen" : "Details ausblenden";
    });
  });
}

// =========================
// Utilities
// =========================
function hideAll() {
  const menu = document.getElementById("menu");
  const warn = document.getElementById("warn-window");
  const side = document.getElementById("side-info");
  if (menu) menu.style.display = "none";
  if (warn) warn.style.display = "none";
  if (side) side.style.display = "none";
  document.body.style.display = "none";
  document.body.classList.remove("panel-open");
}
