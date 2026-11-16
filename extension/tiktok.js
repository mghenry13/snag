// Snag on TikTok.
//  - Feed and post pages: a Snag button in TikTok's own action column, made
//    from a copy of its Share button so it looks like one of TikTok's.
//  - Grids (search results, profiles, liked, collections): a Snag pill on
//    each video tile, shown on hover.
// A video goes to the Snag app by its link, which downloads it with yt-dlp
// (TikTok serves videos to signed-out clients). A photo post's slides are
// read from the post's own page data and saved as one group, like a carousel.
// TikTok's markup changes often, so posts are found from things that last:
// post links, data-e2e names, and the player's "xgwrapper-<n>-<id>" id.
(() => {
  if (window.__snagTT) return;
  window.__snagTT = true;

  const POST_RE = /\/@([^/?#]*)\/(video|photo)\/(\d{6,})/;
  const GOLD = "#e3ba5c";
  const S_ICON = (size) =>
    `<svg width="${size}" height="${size}" viewBox="0 0 24 24" aria-hidden="true">` +
    `<text x="12" y="19" text-anchor="middle" font-family="Georgia, 'Times New Roman', serif" ` +
    `font-weight="700" font-size="21" fill="${GOLD}">S</text></svg>`;

  // ---------- Which post ----------

  function parse(href) {
    const m = (href || "").match(POST_RE);
    return m ? { user: m[1] || "_", kind: m[2], id: m[3] } : null;
  }

  // A feed item's box.
  function rootOf(el) {
    return el.closest('article, [data-e2e="recommend-list-item-container"], [class*="DivItemContainer"]');
  }

  function postFromRoot(root) {
    if (!root) return null;
    for (const a of root.querySelectorAll('a[href*="/video/"], a[href*="/photo/"]')) {
      const p = parse(a.getAttribute("href"));
      if (p) return p;
    }
    const w = root.querySelector('[id^="xgwrapper-"]');
    const idm = w && w.id.match(/-(\d{6,})$/);
    if (idm) {
      const author = root.querySelector('[data-e2e="video-author-uniqueid"], a[href^="/@"]');
      const user = author
        ? ((author.getAttribute("href") || "").replace(/^\/@/, "").split(/[/?]/)[0] || author.textContent.trim())
        : "";
      return { user: user || "_", kind: "video", id: idm[1] };
    }
    return null;
  }

  // The feed item nearest the middle of the screen: the one being watched.
  function centeredItem() {
    const mid = innerHeight / 2;
    let best = null, bestD = Infinity;
    for (const el of document.querySelectorAll('[data-e2e="recommend-list-item-container"], article')) {
      const r = el.getBoundingClientRect();
      if (r.height < 200 || r.bottom < 0 || r.top > innerHeight) continue;
      const d = Math.abs((r.top + r.bottom) / 2 - mid);
      if (d < bestD) { bestD = d; best = el; }
    }
    return best;
  }

  // The post on screen. The address names it on a post page and in the
  // full-screen view. In the feed, TikTok now keeps one action column for
  // the whole page, so the post is the item in the middle, and its author
  // is the one the description layer shows.
  function currentPost(near) {
    const fromPath = parse(location.pathname);
    if (fromPath) return fromPath;
    const item = (near && rootOf(near)) || centeredItem();
    const p = postFromRoot(item);
    if (!p) return null;
    if (p.user === "_") {
      const a = document.querySelector(
        '[data-e2e="anchoring-description-layer"] a[href^="/@"], [data-e2e="cinema-creator-identity"] a[href^="/@"]');
      const user = a && a.getAttribute("href").replace(/^\/@/, "").split(/[/?]/)[0];
      if (user) p.user = user;
    }
    return p;
  }

  const linkOf = (p) => `https://www.tiktok.com/@${p.user}/${p.kind}/${p.id}`;
  const accountOf = (p, extra) =>
    p.user && p.user !== "_"
      ? { platform: "tiktok", handle: p.user, name: (extra && extra.name) || "",
          url: `https://www.tiktok.com/@${p.user}`, avatar: (extra && extra.avatar) || "" }
      : null;

  // ---------- Photo posts ----------

  // Every TikTok post page carries its post's data as JSON, including each
  // photo's full-size address. Same-origin, so this fetch has the user's
  // session. Only the /video/ form of the address includes it: TikTok's
  // /photo/ page leaves the post out of the JSON and loads it later.
  async function photoPost(link) {
    try {
      const html = await (await fetch(link.replace("/photo/", "/video/"), { credentials: "include" })).text();
      const m = html.match(/<script[^>]+id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>([\s\S]*?)<\/script>/);
      if (!m) return null;
      const data = JSON.parse(m[1]);
      const item = data?.__DEFAULT_SCOPE__?.["webapp.video-detail"]?.itemInfo?.itemStruct;
      const images = item?.imagePost?.images || [];
      const urls = images.map((im) => im?.imageURL?.urlList?.[0]).filter(Boolean);
      if (!urls.length) return null;
      return {
        urls,
        caption: (item.desc || "").replace(/\s+/g, " ").trim(),
        name: item.author?.nickname || "",
        avatar: item.author?.avatarLarger || "",
      };
    } catch (e) {
      return null;
    }
  }

  // ---------- Saving ----------

  async function save(p) {
    const link = linkOf(p);
    if (p.kind === "photo") {
      const post = await photoPost(link);
      if (post) {
        const base = `@${p.user}` + (post.caption ? ` — ${post.caption.slice(0, 60)}` : "");
        return chrome.runtime.sendMessage({
          type: "save-remote",
          pageURL: link,
          note: [post.caption, `— @${p.user}`, link].filter(Boolean).join("\n\n"),
          account: accountOf(p, post),
          items: post.urls.map((url, i) => ({
            url, ext: "jpg", name: post.urls.length > 1 ? `${base} (${i + 1})` : base,
          })),
        });
      }
    }
    return chrome.runtime.sendMessage({ type: "save-url", url: link, pageURL: link, account: accountOf(p) });
  }

  // Runs a save and reports it through `show(text, state)`.
  async function run(p, show) {
    if (!p) { show("No post", "bad"); return; }
    show("Saving…", "busy");
    try {
      const reply = await save(p);
      if (!reply || !reply.ok) show("Failed", "bad");
      else show(reply.duplicate ? "Saved" : "Saved ✓", "ok");
    } catch (e) {
      show("Failed", "bad");
    }
  }

  // ---------- The button in TikTok's action column ----------

  const SHARE = '[data-e2e="share-icon"], [data-e2e="browse-share-icon"], [data-e2e="video-share-icon"]';

  function addBarButton(shareIcon) {
    const shareBtn = shareIcon.closest("button") || shareIcon.parentElement;
    if (!shareBtn) return;
    // The unit TikTok repeats down the column: the button, or a wrapper that
    // holds only it.
    let unit = shareBtn;
    while (unit.parentElement && unit.parentElement.children.length === 1) unit = unit.parentElement;
    // Checked every scan, not flagged once: TikTok re-renders the column and
    // can drop the copy.
    if (!unit.parentElement || unit.parentElement.querySelector(":scope > [data-snag]")) return;

    const copy = unit.cloneNode(true);
    copy.setAttribute("data-snag", "");
    copy.removeAttribute("id");
    for (const el of copy.querySelectorAll("[data-e2e], [id], [aria-label]")) {
      el.removeAttribute("data-e2e"); el.removeAttribute("id"); el.removeAttribute("aria-label");
    }
    const btn = copy.matches("button") ? copy : copy.querySelector("button") || copy;
    btn.setAttribute("aria-label", "Save to Snag");
    btn.title = "Save to Snag";
    // TikTok's icon sits in a round grey well; swap the share arrow for an S.
    const oldSvg = copy.querySelector("svg");
    const size = oldSvg ? Math.round(oldSvg.getBoundingClientRect().width || parseFloat(oldSvg.getAttribute("width")) || 24) : 24;
    if (oldSvg) oldSvg.outerHTML = S_ICON(size || 24);
    const label = copy.querySelector("strong") || copy.querySelector("span:last-child");
    const show = (text, state) => {
      if (label) label.textContent = text;
      if (label) label.style.color = state === "bad" ? "#fe2c55" : state === "ok" ? GOLD : "";
      clearTimeout(copy.__t);
      if (state !== "busy") copy.__t = setTimeout(() => show("Snag", ""), 1900);
    };
    show("Snag", "");
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      run(currentPost(unit), show);
    }, true);
    unit.after(copy);
  }

  // ---------- Pills on grid tiles ----------

  const style = document.createElement("style");
  style.textContent = `
    .snag-rel { position: relative; }
    .snag-pill {
      position: absolute; top: 8px; right: 8px; z-index: 5;
      display: flex; align-items: center; gap: 4px;
      height: 28px; padding: 0 10px 0 6px; border-radius: 999px; border: 0;
      background: rgba(30, 72, 52, .92); color: #f2e9d6; cursor: pointer;
      font: 600 13px/1 -apple-system, system-ui, sans-serif;
      box-shadow: 0 2px 8px rgba(0,0,0,.35);
      opacity: 0; transform: translateY(-2px); transition: opacity .15s, transform .15s;
    }
    .snag-tile-host:hover .snag-pill, .snag-pill[data-state] { opacity: 1; transform: none; }
    .snag-pill:hover { background: rgb(36, 86, 62); }
    .snag-pill[data-state="bad"] { background: #fe2c55; color: #fff; }
    .snag-pill svg { display: block; }
  `;
  (document.head || document.documentElement).appendChild(style);

  // A tile is a post link that holds a picture and is not inside the feed's
  // own player (whose column already has a button).
  function addTilePill(a) {
    if (a.__snag) return;
    const p = parse(a.getAttribute("href"));
    if (!p) return;
    const media = a.querySelector("img, video, picture, canvas");
    if (!media) return;
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
    const text = document.createElement("span");
    pill.innerHTML = S_ICON(18);
    pill.appendChild(text);
    const show = (t, state) => {
      text.textContent = t;
      if (state && state !== "") pill.dataset.state = state; else delete pill.dataset.state;
      clearTimeout(pill.__t);
      if (state !== "busy" && state !== "") pill.__t = setTimeout(() => show("Snag", ""), 1900);
    };
    show("Snag", "");
    pill.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      run(p, show);
    }, true);
    host.appendChild(pill);
  }

  // ---------- Right-click > Save to Snag ----------

  // TikTok's video addresses are signed for the tab and useless on their
  // own, so the context menu asks which post is on screen.
  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg && msg.type === "snag-tiktok-current") {
      const p = currentPost();
      sendResponse(p ? { link: linkOf(p), account: accountOf(p) } : null);
    }
  });

  // ---------- Keep up with TikTok ----------

  function scan() {
    for (const icon of document.querySelectorAll(SHARE)) addBarButton(icon);
    for (const a of document.querySelectorAll('a[href*="/video/"], a[href*="/photo/"]')) {
      if (a.closest("[data-snag]")) continue;
      // A feed item already has the button in its column.
      const root = rootOf(a);
      if (root && root.querySelector(SHARE)) continue;
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
