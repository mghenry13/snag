// Snag on Dribbble.
//  - A shot's page (and the shot overlay a grid opens): a round Snag button
//    in the header beside Like and Save, styled like Dribbble's own.
//  - Grids (popular, search, profiles, collections): a Snag button in each
//    tile's hover bar, next to "Get in touch", Save and Like. It saves the
//    shot without opening it.
// A shot saves every image and video in it at full size, as one group when
// there are several, named after the shot and its designer, and linked to
// the designer's Dribbble profile.
//
// Full size: a picture's address without its "?resize=…" query is the
// original upload. A video's "large-….mp4" is the best copy Dribbble plays.
//
// Dribbble rate-limits quick page loads, so a grid's shot is read only when
// its button is clicked, never ahead of time. If that read fails, the tile's
// own picture or video preview is saved instead.
(() => {
  if (window.__snagDribbble) return;
  window.__snagDribbble = true;

  const GOLD = "#e3ba5c";
  const SHOT_RE = /^\/shots\/(\d+)/;
  const MEDIA_SEL = ".content-block img, .content-block video, img.content-block, video.content-block";

  // ---------- Icons ----------
  // Built node by node: no HTML strings.

  function svg(size) {
    const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    s.setAttribute("width", size);
    s.setAttribute("height", size);
    s.setAttribute("viewBox", "0 0 24 24");
    s.setAttribute("aria-hidden", "true");
    s.style.display = "block";
    return s;
  }

  function sIcon(size) {
    const s = svg(size);
    const t = document.createElementNS("http://www.w3.org/2000/svg", "text");
    t.setAttribute("x", "12");
    t.setAttribute("y", "19");
    t.setAttribute("text-anchor", "middle");
    t.setAttribute("font-family", "Georgia, 'Times New Roman', serif");
    t.setAttribute("font-weight", "700");
    t.setAttribute("font-size", "21");
    t.setAttribute("fill", GOLD);
    t.textContent = "S";
    s.appendChild(t);
    return s;
  }

  function markIcon(size, ok) {
    const s = svg(size);
    const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
    p.setAttribute("d", ok ? "M5 12.5l4.5 4.5L19 7.5" : "M6.5 6.5l11 11M17.5 6.5l-11 11");
    p.setAttribute("fill", "none");
    p.setAttribute("stroke", ok ? "#079455" : "#d92d20");
    p.setAttribute("stroke-width", "2.4");
    p.setAttribute("stroke-linecap", "round");
    p.setAttribute("stroke-linejoin", "round");
    s.appendChild(p);
    return s;
  }

  function dotsIcon(size) {
    const s = svg(size);
    for (const x of [6, 12, 18]) {
      const c = document.createElementNS("http://www.w3.org/2000/svg", "circle");
      c.setAttribute("cx", x);
      c.setAttribute("cy", "12");
      c.setAttribute("r", "1.8");
      c.setAttribute("fill", GOLD);
      s.appendChild(c);
    }
    return s;
  }

  // ---------- Reading a shot ----------

  const abs = (u) => { try { return new URL(u, location.href).href; } catch (e) { return ""; } };

  // A picture's original: its address with the resize query taken off.
  function original(u) {
    const url = abs(u);
    return /cdn\.dribbble\.com\/userupload\//.test(url) ? url.split("?")[0] : url;
  }

  function extOf(url, fallback) {
    const m = url.split("?")[0].match(/\.([a-z0-9]{2,5})$/i);
    return m ? m[1].toLowerCase() : fallback;
  }

  // Every picture and video in a shot, in order. The shot's own media sit in
  // its content blocks; "More by" and related shots further down do not.
  function mediaIn(root) {
    const out = [], seen = new Set();
    for (const m of root.querySelectorAll(MEDIA_SEL)) {
      let url = "", ext = "";
      if (m.tagName === "VIDEO") {
        url = abs(m.getAttribute("src") || (m.querySelector("source") || {}).src || "");
        ext = extOf(url, "mp4");
      } else {
        url = original(m.getAttribute("src") || "");
        ext = extOf(url, "png");
      }
      if (!/^https?:/.test(url) || seen.has(url)) continue;
      seen.add(url);
      out.push({ url, ext });
    }
    return out;
  }

  // The designer, from the shot's header: avatar link, name link, picture.
  function designerIn(root) {
    const hdr = root.querySelector(".user-sticky-header__container") || root;
    const a = [...hdr.querySelectorAll("a.hoverable[href^='/'], a[href^='/'].user-sticky-header__avatar")]
      .find((x) => /^\/[^/?#]+\/?$/.test(x.getAttribute("href") || ""));
    if (!a) return null;
    const handle = a.getAttribute("href").replace(/^\//, "").replace(/\/$/, "");
    const named = [...hdr.querySelectorAll(`a[href="/${handle}"]`)].map((x) => x.textContent.trim()).find(Boolean);
    const img = hdr.querySelector("img.photo, img[class*=avatar]");
    return {
      platform: "dribbble", handle, name: named || (img && img.alt) || "",
      url: `https://dribbble.com/${handle}`, avatar: img ? abs(img.getAttribute("src") || "") : "",
    };
  }

  function titleIn(root, doc) {
    const h = root.querySelector("h1.shot-header__title, h1");
    if (h && h.textContent.trim()) return h.textContent.trim();
    const og = doc.querySelector('meta[property="og:title"]');
    return og ? og.content.trim() : "";
  }

  // A shot read from its own page, fetched (same origin, so with the user's
  // session). Used from grids.
  async function fetchShot(id) {
    const res = await fetch(`/shots/${id}`, { credentials: "include" });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const doc = new DOMParser().parseFromString(await res.text(), "text/html");
    const root = doc.querySelector(".js-shot-container") || doc;
    const link = (doc.querySelector('link[rel="canonical"]') || {}).href;
    return {
      id, page: link && SHOT_RE.test(new URL(link).pathname) ? link : `https://dribbble.com/shots/${id}`,
      title: titleIn(root, doc), designer: designerIn(root), media: mediaIn(root),
    };
  }

  // ---------- Saving ----------

  async function save(shot, btn) {
    if (!shot.media.length) { show(btn, "fail", "Nothing to save"); return; }
    show(btn, "busy", "Saving…");
    const who = shot.designer && (shot.designer.name || shot.designer.handle);
    const base = [shot.title || "Dribbble shot", who].filter(Boolean).join(" — ");
    const many = shot.media.length > 1;
    const note = [`Dribbble: ${shot.page}`, who ? `By ${who}: ${shot.designer.url}` : ""].filter(Boolean).join("\n");
    try {
      const reply = await chrome.runtime.sendMessage({
        type: "save-remote", pageURL: shot.page, note, account: shot.designer,
        items: shot.media.map((m, i) => ({ url: m.url, ext: m.ext, name: many ? `${base} (${i + 1})` : base })),
      });
      if (!reply || !reply.ok) { show(btn, "fail", "Snag could not save it"); return; }
      show(btn, "ok", reply.duplicate ? "Already in Snag" : `Saved${reply.folderName ? " to " + reply.folderName : ""}`);
    } catch (e) {
      show(btn, "fail", "Snag could not save it");
    }
  }

  function show(btn, state, tip) {
    const size = btn.__snagSize;
    btn.replaceChildren(state === "busy" ? dotsIcon(size) : state === "idle" ? sIcon(size) : markIcon(size, state === "ok"));
    btn.title = tip;
    btn.setAttribute("aria-label", tip);
    clearTimeout(btn.__snagT);
    if (state === "ok" || state === "fail") {
      btn.__snagT = setTimeout(() => show(btn, "idle", "Save to Snag"), 2200);
    }
  }

  function makeButton(classes, size, onClick) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = classes + " snag-dribbble-btn";
    btn.__snagSize = size;
    show(btn, "idle", "Save to Snag");
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (btn.__snagBusy) return;
      btn.__snagBusy = true;
      Promise.resolve(onClick(btn)).finally(() => { btn.__snagBusy = false; });
    }, true);
    return btn;
  }

  // ---------- Shot page and shot overlay ----------

  function addHeaderButton(icons) {
    if (icons.querySelector(".snag-dribbble-btn")) return;
    // Keep the classes of the Like button next to it, so it follows
    // Dribbble's look (outlined circle, hover state, dark mode).
    const like = icons.querySelector("button");
    const classes = like ? like.className.replace(/\blike-shot\b|\bbucket-shot\b|\bis-active\b|\bactive\b/g, "").trim()
      : "btn2 btn2--tertiary btn2--circle";
    const btn = makeButton(classes, 18, async (b) => {
      const root = icons.closest(".js-shot-container") || document;
      const idEl = icons.querySelector("[shot-id]");
      const id = (idEl && idEl.getAttribute("shot-id")) || ((location.pathname.match(SHOT_RE) || [])[1]);
      const fromPath = SHOT_RE.test(location.pathname) && location.pathname.match(SHOT_RE)[1] === id;
      const shot = {
        id, page: fromPath ? location.origin + location.pathname : `https://dribbble.com/shots/${id}`,
        title: titleIn(root, document), designer: designerIn(root), media: mediaIn(root),
      };
      // A shot still loading in the overlay has no media yet: read its page.
      if (!shot.media.length && id) {
        try { Object.assign(shot, await fetchShot(id)); } catch (e) { /* says "Nothing to save" */ }
      }
      await save(shot, b);
    });
    icons.appendChild(btn);
  }

  // ---------- Grid tiles ----------

  // The tile's own preview, for when the shot's page cannot be read.
  function tileMedia(tile) {
    const base = tile.querySelector(".js-thumbnail-base");
    const teaser = base && (base.getAttribute("data-video-teaser-large") || base.getAttribute("data-video-teaser-medium"));
    if (teaser) return [{ url: abs(teaser), ext: "mp4" }];
    const img = tile.querySelector("figure img");
    if (!img) return [];
    const url = original(img.getAttribute("data-animated-url") || img.currentSrc || img.src);
    return url ? [{ url, ext: extOf(url, "png") }] : [];
  }

  function tileDesigner(tile) {
    const a = [...tile.querySelectorAll(".shot-details-container a[href^='/']")]
      .find((x) => /^\/[^/?#]+\/?$/.test(x.getAttribute("href") || ""));
    if (!a) return null;
    const handle = a.getAttribute("href").replace(/^\//, "").replace(/\/$/, "");
    const img = tile.querySelector(".shot-details-container img");
    return {
      platform: "dribbble", handle,
      name: [...tile.querySelectorAll(`.shot-details-container a[href="/${handle}"]`)].map((x) => x.textContent.trim()).find(Boolean) || "",
      url: `https://dribbble.com/${handle}`, avatar: img ? abs(img.getAttribute("src") || "") : "",
    };
  }

  function addTileButton(tile) {
    const bar = tile.querySelector("ul.shot-actions-container");
    if (!bar || bar.querySelector(".snag-dribbble-btn")) return;
    const link = tile.querySelector("a.shot-thumbnail-link");
    const m = link && (link.getAttribute("href") || "").match(SHOT_RE);
    if (!m) return; // ads and links that leave Dribbble
    const id = m[1];
    const like = bar.querySelector("button.like-shot, li button");
    const classes = like ? like.className.replace(/\blike-shot\b|\bbucket-shot\b|\bis-active\b|\bactive\b/g, "").trim()
      : "btn2 btn2--secondary-alt btn2--circle";
    const li = document.createElement("li");
    li.className = "shot-action";
    li.appendChild(makeButton(classes, 16, async (b) => {
      show(b, "busy", "Saving…");
      let shot;
      try {
        shot = await fetchShot(id);
      } catch (e) {
        shot = null;
      }
      if (!shot || !shot.media.length) {
        const title = (tile.querySelector(".shot-title") || {}).textContent || "";
        shot = { id, page: abs(link.getAttribute("href")).split("?")[0], title: title.trim(),
                 designer: (shot && shot.designer) || tileDesigner(tile), media: tileMedia(tile) };
      }
      await save(shot, b);
    }));
    bar.insertBefore(li, bar.firstChild);
  }

  // ---------- Watching the page ----------

  function scan() {
    for (const icons of document.querySelectorAll(".user-sticky-header__icon-actions")) addHeaderButton(icons);
    for (const tile of document.querySelectorAll("li.shot-thumbnail")) addTileButton(tile);
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
