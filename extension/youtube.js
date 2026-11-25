// Snag on YouTube Shorts.
//  - The Shorts player: a Snag button in YouTube's own action column (like,
//    comments, share, remix), made from a copy of its Share button so it
//    looks like one of YouTube's.
//  - Shorts tiles (home and search shelves, a channel's Shorts tab): a Snag
//    pill on each tile, shown on hover.
// A Short goes to the Snag app by its link; the app downloads it with yt-dlp.
// The same look as the TikTok buttons (tiktok.js): a gold serif "S".
(() => {
  if (window.__snagYT) return;
  window.__snagYT = true;

  const GOLD = "#e3ba5c";
  // Built with DOM calls: YouTube enforces Trusted Types, which refuses
  // HTML strings (innerHTML, outerHTML).
  const SVG_NS = "http://www.w3.org/2000/svg";
  function sIcon(size) {
    const svg = document.createElementNS(SVG_NS, "svg");
    for (const [k, v] of Object.entries({ width: size, height: size, viewBox: "0 0 24 24", "aria-hidden": "true" })) {
      svg.setAttribute(k, v);
    }
    const t = document.createElementNS(SVG_NS, "text");
    for (const [k, v] of Object.entries({
      x: 12, y: 19, "text-anchor": "middle", "font-family": "Georgia, 'Times New Roman', serif",
      "font-weight": 700, "font-size": 21, fill: GOLD,
    })) t.setAttribute(k, v);
    t.textContent = "S";
    svg.appendChild(t);
    return svg;
  }

  const shortId = (href) => ((href || "").match(/\/shorts\/([A-Za-z0-9_-]{6,})/) || [])[1] || null;
  const linkOf = (id) => `https://www.youtube.com/shorts/${id}`;

  // The channel of the Short on screen, from the player's channel bar.
  function channelOnScreen() {
    for (const a of document.querySelectorAll('yt-reel-channel-bar-view-model a[href^="/@"], ytd-reel-video-renderer a[href^="/@"]')) {
      if (a.getBoundingClientRect().width === 0) continue;
      const handle = a.getAttribute("href").replace(/^\/@/, "").split(/[/?]/)[0];
      if (handle) return { platform: "youtube", handle, name: "", url: `https://www.youtube.com/@${handle}` };
    }
    return null;
  }

  // On a channel page every tile is that channel's.
  function channelOfPage() {
    const m = location.pathname.match(/^\/@([^/]+)/);
    return m ? { platform: "youtube", handle: decodeURIComponent(m[1]), name: "", url: `https://www.youtube.com/@${m[1]}` } : null;
  }

  async function run(id, account, show) {
    if (!id) { show("No Short", "bad"); return; }
    show("Saving…", "busy");
    try {
      const link = linkOf(id);
      const reply = await chrome.runtime.sendMessage({ type: "save-url", url: link, pageURL: link, account });
      if (!reply || !reply.ok) show("Failed", "bad");
      else show(reply.duplicate ? "Saved" : "Saved ✓", "ok");
    } catch (e) {
      show("Failed", "bad");
    }
  }

  // ---------- The button in the Shorts action column ----------

  function addBarButton(bar) {
    if (bar.getBoundingClientRect().height === 0) return;
    // Checked every scan, not flagged once: YouTube re-renders the column.
    if (bar.querySelector(":scope > [data-snag]")) return;
    const share = [...bar.querySelectorAll("button[aria-label]")]
      .find((b) => /share/i.test(b.getAttribute("aria-label")));
    const unit = share && (share.closest("button-view-model") || share.closest("label") || share);
    if (!unit || unit.parentElement !== bar) return;

    const copy = unit.cloneNode(true);
    copy.setAttribute("data-snag", "");
    for (const el of copy.querySelectorAll("[id], [aria-label]")) {
      el.removeAttribute("id"); el.removeAttribute("aria-label");
    }
    const btn = copy.querySelector("button") || copy;
    btn.setAttribute("aria-label", "Save to Snag");
    btn.title = "Save to Snag";
    const oldSvg = copy.querySelector("svg");
    if (oldSvg) oldSvg.replaceWith(sIcon(24));
    const label = copy.querySelector('[class*="WithLabelLabel"] span, [class*="WithLabelLabel"]');
    const show = (text, state) => {
      if (label) {
        label.textContent = text;
        label.style.color = state === "bad" ? "#ff4e45" : state === "ok" ? GOLD : "";
      }
      clearTimeout(copy.__t);
      if (state !== "busy") copy.__t = setTimeout(() => show("Snag", ""), 1900);
    };
    show("Snag", "");
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      // The column is reused as you scroll; the address names the Short.
      run(shortId(location.pathname), channelOnScreen(), show);
    }, true);
    unit.after(copy);
  }

  // ---------- Pills on Shorts tiles ----------

  const style = document.createElement("style");
  style.textContent = `
    .snag-rel { position: relative; }
    .snag-pill {
      position: absolute; top: 8px; right: 8px; z-index: 5;
      display: flex; align-items: center; gap: 4px;
      height: 28px; padding: 0 10px 0 6px; border-radius: 999px; border: 0;
      background: rgba(30, 72, 52, .92); color: #f2e9d6; cursor: pointer;
      font: 600 13px/1 Roboto, -apple-system, system-ui, sans-serif;
      box-shadow: 0 2px 8px rgba(0,0,0,.35);
      opacity: 0; transform: translateY(-2px); transition: opacity .15s, transform .15s;
    }
    .snag-tile-host:hover .snag-pill, .snag-pill[data-state] { opacity: 1; transform: none; }
    .snag-pill:hover { background: rgb(36, 86, 62); }
    .snag-pill[data-state="bad"] { background: #ff4e45; color: #fff; }
    .snag-pill svg { display: block; }
  `;
  (document.head || document.documentElement).appendChild(style);

  // A tile is a Shorts link around a thumbnail. Its title is a second link
  // to the same Short, with no picture, and is skipped.
  function addTilePill(a) {
    if (a.__snag) return;
    const id = shortId(a.getAttribute("href"));
    if (!id || !a.querySelector("img")) return;
    const r = a.getBoundingClientRect();
    if (r.width < 90 || r.height < 120) return;
    a.__snag = true;
    const host = a.parentElement || a;
    if (host.querySelector(":scope > .snag-pill")) return;
    host.classList.add("snag-tile-host");
    if (getComputedStyle(host).position === "static") host.classList.add("snag-rel");
    const pill = document.createElement("button");
    pill.type = "button";
    pill.className = "snag-pill";
    pill.title = "Save to Snag";
    pill.appendChild(sIcon(18));
    const text = document.createElement("span");
    pill.appendChild(text);
    const show = (t, state) => {
      text.textContent = t;
      if (state) pill.dataset.state = state; else delete pill.dataset.state;
      clearTimeout(pill.__t);
      if (state && state !== "busy") pill.__t = setTimeout(() => show("Snag", ""), 1900);
    };
    show("Snag", "");
    pill.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      run(id, channelOfPage(), show);
    }, true);
    host.appendChild(pill);
  }

  // ---------- Keep up with YouTube ----------

  function scan() {
    for (const bar of document.querySelectorAll("reel-action-bar-view-model")) addBarButton(bar);
    for (const a of document.querySelectorAll('a[href^="/shorts/"], a[href^="https://www.youtube.com/shorts/"]')) {
      if (a.closest("[data-snag], ytd-reel-video-renderer")) continue;
      addTilePill(a);
    }
  }

  let queued = false;
  new MutationObserver(() => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; scan(); });
  }).observe(document.documentElement, { childList: true, subtree: true });
  setInterval(scan, 1500);
  scan();
})();
