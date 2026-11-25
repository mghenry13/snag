// Snag on Pinterest.
// One "Snag" button that follows the mouse onto whichever pin it is over,
// wherever pins show:
//  - grids: the home feed, search, boards, sections, profiles (created and
//    saved), "More to explore" under a pin, and the shop tabs;
//  - a pin's own page and the pin overlay a grid opens (/pin/<id>/);
//  - idea pins and carousel pins, which hold several pages or slides.
// The button sits at the picture's top right, under Pinterest's own Save.
// An open pin also gets Snag as an icon in its own action row, next to the
// heart, comments and share buttons.
// It is one fixed element at the top of the page, not one per pin: Pinterest
// redraws its grid constantly and its hover overlay covers anything inside
// a pin.
//
// What a click saves: the pin read from Pinterest's own pin data (the page
// session's PinResource call), so every slide of a carousel and every page
// of an idea pin, at original size, and a video pin's mp4. Several files
// are kept as one group. Each item is named after the pin and the person
// who made it, linked to their Pinterest profile, and its note carries the
// pin, the site it links to and its description.
//
// If the pin data can't be read, the picture on screen is saved at the
// largest size the page offers (the original when Pinterest has one), and a
// video pin is handed to Snag's own downloader by its pin address.
(() => {
  if (window.__snagPinterest || window.top !== window) return;
  window.__snagPinterest = true;

  const PIN_RE = /\/pin\/([^/?#]+)/;
  const IMG_HOST = /(^|\.)pinimg\.com$/;

  // ---------- Finding the pin under the mouse ----------

  const abs = (u) => { try { return new URL(u, location.href).href; } catch (e) { return ""; } };

  function pinIdFrom(href) {
    const m = (href || "").match(PIN_RE);
    if (!m) return "";
    // Some pin links are "/pin/some-title--123456/": the id is the end.
    const seg = decodeURIComponent(m[1]);
    return seg.includes("--") ? seg.split("--").pop() : seg;
  }

  function isPinImage(el) {
    if (!el || el.tagName !== "IMG") return false;
    try { return IMG_HOST.test(new URL(el.currentSrc || el.src).hostname); } catch (e) { return false; }
  }

  // A grid's pin: the tile Pinterest lays out, with a link to the pin.
  // The open pin's page is itself laid out as one big grid item: a "tile"
  // holding the closeup is the open pin, not a grid pin.
  const TILE = '[data-test-id="pin"], [data-grid-item="true"], [data-test-id="pinWrapper"]';
  const CLOSEUP = '[data-test-id="closeup-image"], [data-test-id="closeupActionBar"], [data-test-id="closeup-body-image-container"]';
  function gridItemOf(el) {
    const tile = el && el.closest(TILE);
    return tile && !tile.querySelector(CLOSEUP) && !tile.closest(CLOSEUP) ? tile : null;
  }

  // The picture or video of a grid tile, or of the open pin.
  function mediaIn(box) {
    if (!box) return null;
    const video = box.querySelector("video");
    let best = null, area = 0;
    for (const img of box.querySelectorAll("img")) {
      if (!isPinImage(img)) continue;
      const r = img.getBoundingClientRect();
      if (r.width < 90 || r.height < 90) continue; // avatars, board covers
      if (r.width * r.height > area) { area = r.width * r.height; best = img; }
    }
    if (video) {
      const r = video.getBoundingClientRect();
      if (r.width >= 90 && r.height >= 90 && r.width * r.height >= area) return video;
    }
    return best;
  }

  // The open pin's own picture: the closeup on a pin page or pin overlay.
  function closeupBox(el) {
    return el && el.closest([
      '[data-test-id="closeup-image"]', '[data-test-id="pin-closeup-image"]',
      '[data-test-id="closeup-body-image-container"]', '[data-test-id="visual-content-container"]',
      '[data-test-id="story-pin-closeup"]', '[data-test-id="carousel-closeup"]',
      '[data-test-id="closeup-mweb-image"]', '[data-test-id="closeup-container"]',
    ].join(","));
  }

  /// The pin the mouse is over: { id, media, inGrid } or null.
  function pinAt(x, y) {
    for (const el of document.elementsFromPoint(x, y)) {
      if (el === btn || btn.contains(el)) return current;
      const tile = gridItemOf(el);
      if (tile) {
        const a = tile.querySelector('a[href*="/pin/"]');
        const id = a && pinIdFrom(a.getAttribute("href"));
        const media = mediaIn(tile);
        if (id && media) return { id, media, inGrid: true, tile };
        // Ads and promoted shop tiles have no pin link: nothing to save.
        if (!id) return null;
      }
      const box = closeupBox(el);
      const here = pinIdFrom(location.pathname);
      if (box && here) {
        const media = (el.tagName === "IMG" && isPinImage(el)) || el.tagName === "VIDEO" ? el : mediaIn(box);
        if (media) return { id: here, media, inGrid: false };
      }
      // A pin page laid out some way the selectors above don't know: any
      // large Pinterest picture outside a grid is the open pin's.
      if (here && !tile && (isPinImage(el) || el.tagName === "VIDEO") && !gridItemOf(el)) {
        const r = el.getBoundingClientRect();
        if (r.width >= 200 && r.height >= 200) return { id: here, media: el, inGrid: false };
      }
    }
    return null;
  }

  // ---------- Reading a pin ----------

  // The biggest picture in an "images" map ({"236x": {url, width}, "orig": …}).
  function bestImage(images) {
    if (!images) return "";
    if (images.orig && images.orig.url) return images.orig.url;
    if (images.originals && images.originals.url) return images.originals.url;
    let best = "", w = 0;
    for (const v of Object.values(images)) {
      if (v && v.url && (v.width || 0) >= w) { w = v.width || 0; best = v.url; }
    }
    return best;
  }

  // The biggest progressive mp4 in a "video_list" (HLS playlists can't be saved).
  function bestVideo(list) {
    if (!list) return "";
    let best = "", w = -1;
    for (const v of Object.values(list)) {
      if (!v || !v.url || !/\.mp4(\?|$)/i.test(v.url)) continue;
      if ((v.width || 0) > w) { w = v.width || 0; best = v.url; }
    }
    return best;
  }

  function extOf(url, fallback) {
    const m = (url || "").split("?")[0].match(/\.([a-z0-9]{2,5})$/i);
    return m ? m[1].toLowerCase().replace("jpeg", "jpg") : fallback;
  }

  // Every file of a pin, in order: idea pin pages, carousel slides, or the
  // pin's one video or picture.
  function filesOf(d) {
    const out = [];
    const add = (url, kind) => { if (url && !out.some((f) => f.url === url)) out.push({ url, ext: extOf(url, kind === "video" ? "mp4" : "jpg") }); };

    const pages = d.story_pin_data && d.story_pin_data.pages;
    if (Array.isArray(pages) && pages.length) {
      for (const page of pages) {
        for (const b of page.blocks || []) {
          const v = b.video && bestVideo(b.video.video_list);
          if (v) add(v, "video");
          else if (b.image) add(bestImage(b.image.images), "image");
        }
      }
      if (out.length) return out;
    }
    const slots = d.carousel_data && d.carousel_data.carousel_slots;
    if (Array.isArray(slots) && slots.length > 1) {
      for (const s of slots) add(bestImage(s.images), "image");
      if (out.length) return out;
    }
    const v = d.videos && bestVideo(d.videos.video_list);
    if (v) add(v, "video");
    else add(bestImage(d.images), "image");
    return out;
  }

  function personOf(d) {
    // The person who made it beats the person who re-pinned it.
    const p = d.native_creator || d.origin_pinner || d.pinner;
    if (!p || !p.username) return null;
    return {
      platform: "pinterest", handle: p.username, name: p.full_name || "",
      url: `https://www.pinterest.com/${p.username}/`,
      avatar: p.image_xlarge_url || p.image_large_url || p.image_medium_url || "",
    };
  }

  const cache = new Map(); // id -> pin

  // The pin from Pinterest's own pin data, fetched with the page's session.
  async function fetchPin(id) {
    if (cache.has(id)) return cache.get(id);
    const data = { options: { id, field_set_key: "detailed" }, context: {} };
    const url = `/resource/PinResource/get/?source_url=${encodeURIComponent(`/pin/${id}/`)}`
      + `&data=${encodeURIComponent(JSON.stringify(data))}&_=${Date.now()}`;
    const res = await fetch(url, {
      credentials: "include",
      headers: { "Accept": "application/json, text/javascript, */*; q=0.01", "X-Requested-With": "XMLHttpRequest",
                 "X-Pinterest-PWS-Handler": "www/pin/[id].js" },
    });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const d = (await res.json())?.resource_response?.data;
    if (!d) throw new Error("no pin data");
    const pin = {
      id, page: `https://www.pinterest.com/pin/${id}/`,
      title: (d.title || d.grid_title || d.seo_title || "").trim(),
      description: (d.description || d.closeup_unified_description || "").trim(),
      link: d.link || "", person: personOf(d), files: filesOf(d),
    };
    cache.set(id, pin);
    return pin;
  }

  // ---------- When the pin data can't be read ----------

  // The widest picture the page offers; Pinterest's "originals" path when
  // the address has a size in it, with that sized copy kept as a fallback
  // (an original can be a PNG or GIF where the copy is a JPEG).
  function screenImage(img) {
    let url = img.currentSrc || img.src || "", w = 0;
    for (const part of (img.getAttribute("srcset") || "").split(",")) {
      const [u, size] = part.trim().split(/\s+/);
      const n = parseInt(size || "0", 10);
      if (u && n > w) { w = n; url = u; }
    }
    url = abs(url);
    const orig = url.replace(/\/\d+x(\d+)?\//, "/originals/");
    return { url: orig, fallbackURL: orig !== url ? url : undefined, ext: extOf(url, "jpg") };
  }

  function screenTitle(target) {
    const box = target.inGrid ? target.tile : document;
    const t = box.querySelector('[data-test-id="pinTitle"], [data-test-id="closeup-title"] h1, h1');
    return ((t && t.textContent) || (target.media.alt || "")).trim();
  }

  // ---------- Saving ----------

  async function save(target, flash = floatFlash) {
    flash("Saving…");
    let pin = null;
    try { pin = await fetchPin(target.id); } catch (e) { pin = null; }
    const page = `https://www.pinterest.com/pin/${target.id}/`;

    if (!pin || !pin.files.length) {
      if (target.media.tagName === "VIDEO") {
        // Pinterest streams video in pieces: let Snag's downloader fetch it.
        await send({ type: "save-url", url: page, pageURL: page, note: `Pinterest: ${page}` }, flash);
        return;
      }
      const file = screenImage(target.media);
      pin = { id: target.id, page, title: screenTitle(target), description: "", link: "", person: null, files: [file] };
    }

    const who = pin.person && (pin.person.name || pin.person.handle);
    const base = [pin.title || "Pinterest pin", who].filter(Boolean).join(" — ").slice(0, 140);
    const many = pin.files.length > 1;
    const note = [
      pin.description,
      `Pinterest: ${pin.page}`,
      pin.link ? `Source: ${pin.link}` : "",
      who ? `By ${who}: ${pin.person.url}` : "",
    ].filter(Boolean).join("\n");
    await send({
      type: "save-remote", pageURL: pin.page, note, account: pin.person,
      items: pin.files.map((f, i) => ({ url: f.url, fallbackURL: f.fallbackURL, ext: f.ext,
                                        name: many ? `${base} (${i + 1})` : base })),
    }, flash, pin.files.length);
  }

  async function send(msg, flash, count) {
    try {
      const reply = await chrome.runtime.sendMessage(msg);
      if (!reply || !reply.ok) { flash("Failed", true); return; }
      flash(reply.duplicate ? "Already saved"
            : count > 1 ? `Saved ${reply.saved || count} ✓`
            : reply.folderName ? `Saved to ${reply.folderName} ✓` : "Saved ✓");
    } catch (e) {
      flash("Failed", true);
    }
  }

  // ---------- The button ----------

  const btn = document.createElement("button");
  btn.type = "button";
  btn.textContent = "Snag";
  Object.assign(btn.style, {
    position: "fixed", zIndex: "2147483647", display: "none",
    background: "rgba(0,0,0,.78)", color: "#fff", border: "1px solid rgba(255,255,255,.18)",
    borderRadius: "999px", padding: "9px 14px", fontSize: "13px", fontWeight: "700",
    cursor: "pointer", backdropFilter: "blur(10px)", lineHeight: "1",
    fontFamily: "-apple-system, system-ui, sans-serif",
    boxShadow: "0 4px 14px rgba(0,0,0,.3)", pointerEvents: "auto",
  });
  document.documentElement.appendChild(btn);

  let current = null; // the pin the button is on
  let busy = false;
  let resetT = 0;

  // Pinterest's tile opens the pin on any click inside it: take the click
  // in the capture phase before it can.
  for (const type of ["pointerdown", "mousedown", "mouseup", "click", "touchstart"]) {
    btn.addEventListener(type, (e) => {
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      if (type === "click" && current && !busy) {
        busy = true;
        save(current).finally(() => { busy = false; });
      }
    }, true);
  }

  function floatFlash(text, bad) {
    btn.textContent = text;
    btn.style.background = bad ? "rgba(190,55,55,.92)"
      : text.startsWith("Saving") ? "rgba(63,110,247,.92)"
      : "rgba(45,150,90,.92)";
    clearTimeout(resetT);
    if (!text.startsWith("Saving")) {
      resetT = setTimeout(() => {
        btn.textContent = "Snag";
        btn.style.background = "rgba(0,0,0,.78)";
      }, 1900);
    }
  }

  function place() {
    if (!current || !current.media.isConnected) {
      if (!busy) { btn.style.display = "none"; current = null; }
      return;
    }
    const r = current.media.getBoundingClientRect();
    if (r.bottom < 40 || r.top > innerHeight - 20 || r.width < 1) {
      if (!busy) btn.style.display = "none";
      return;
    }
    btn.style.display = "block";
    const w = btn.offsetWidth || 64;
    // In a grid, under Pinterest's own Save button; on an open pin, its corner.
    const top = r.top + (current.inGrid ? 62 : 14);
    btn.style.top = Math.max(8, Math.min(top, r.bottom - 44)) + "px";
    btn.style.left = Math.max(8, Math.min(r.right - w - 12, innerWidth - w - 8)) + "px";
  }

  let mouse = null, queued = false;
  addEventListener("mousemove", (e) => {
    mouse = { x: e.clientX, y: e.clientY };
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      if (busy || !mouse) return;
      const hit = pinAt(mouse.x, mouse.y);
      // The open pin has Snag in its own action row: no floating copy on it.
      const h = hit && !hit.inGrid && document.querySelector(".snag-pin-action") ? null : hit;
      if (h !== current) current = h;
      place();
    });
  }, { passive: true, capture: true });

  addEventListener("scroll", place, { passive: true, capture: true });
  addEventListener("resize", place);
  // Leaving the window hides it.
  document.addEventListener("mouseleave", () => { if (!busy) { current = null; place(); } });

  // ---------- Snag in the open pin's action row ----------
  // The open pin (its page, or the overlay a grid opens) gets an icon button
  // in Pinterest's own row (heart, comments, share, then Snag, then more), made
  // from a copy of the Comments button so it looks and lines up like theirs.

  const SVG_NS = "http://www.w3.org/2000/svg";

  function icon(model, kind) {
    const s = document.createElementNS(SVG_NS, "svg");
    for (const a of ["class", "width", "height"]) if (model && model.hasAttribute(a)) s.setAttribute(a, model.getAttribute(a));
    s.setAttribute("viewBox", "0 0 24 24");
    s.setAttribute("aria-hidden", "true");
    if (kind === "S") {
      const t = document.createElementNS(SVG_NS, "text");
      Object.entries({ x: "12", y: "19", "text-anchor": "middle", "font-family": "Georgia, 'Times New Roman', serif",
                       "font-weight": "700", "font-size": "21", fill: "currentColor" })
        .forEach(([k, v]) => t.setAttribute(k, v));
      t.textContent = "S";
      s.appendChild(t);
    } else if (kind === "busy") {
      for (const x of [6, 12, 18]) {
        const c = document.createElementNS(SVG_NS, "circle");
        c.setAttribute("cx", x); c.setAttribute("cy", "12"); c.setAttribute("r", "2"); c.setAttribute("fill", "currentColor");
        c.setAttribute("fill-opacity", "0.4"); // faint, so it isn't read as the "more" button
        s.appendChild(c);
      }
    } else {
      const p = document.createElementNS(SVG_NS, "path");
      p.setAttribute("d", kind === "ok" ? "M5 12.5l4.5 4.5L19 7.5" : "M6.5 6.5l11 11M17.5 6.5l-11 11");
      Object.entries({ fill: "none", stroke: kind === "ok" ? "#079455" : "#d92d20", "stroke-width": "2.6",
                       "stroke-linecap": "round", "stroke-linejoin": "round" })
        .forEach(([k, v]) => p.setAttribute(k, v));
      s.appendChild(p);
    }
    return s;
  }

  // The open pin's picture or video: the largest Pinterest media outside the
  // grids below it.
  function closeupMedia() {
    const slide = document.querySelector('[data-test-id="closeup-carousel-active-slide"]');
    const box = (slide && mediaIn(slide)) ? slide
      : document.querySelector('[data-test-id="closeup-image"], [data-test-id="closeup-body-image-container"]');
    const inBox = box && mediaIn(box);
    if (inBox) return inBox;
    let best = null, area = 0;
    for (const el of document.querySelectorAll("img, video")) {
      if (gridItemOf(el) || (el.tagName === "IMG" && !isPinImage(el))) continue;
      const r = el.getBoundingClientRect();
      if (r.width < 150 || r.height < 150) continue;
      if (r.width * r.height > area) { area = r.width * r.height; best = el; }
    }
    return best;
  }

  function addActionButton() {
    const id = pinIdFrom(location.pathname);
    if (!id) return;
    for (const items of document.querySelectorAll('[data-test-id="closeup-action-items"]')) {
      const row = items.firstElementChild;
      if (!row || row.querySelector(".snag-pin-action")) continue;
      const model = row.querySelector('button[aria-label="Comments"], button[aria-label*="omment"]');
      const unit = model && [...row.children].find((c) => c.contains(model));
      if (!unit) continue;

      const copy = unit.cloneNode(true);
      copy.classList.add("snag-pin-action");
      copy.querySelectorAll("[id]").forEach((e) => e.removeAttribute("id"));
      copy.querySelectorAll("[data-test-id]").forEach((e) => e.removeAttribute("data-test-id"));
      copy.querySelectorAll("[aria-label]").forEach((e) => e.setAttribute("aria-label", "Snag"));
      const button = copy.querySelector("button");
      button.title = "Save to Snag";
      const model_svg = copy.querySelector("svg");
      const holder = model_svg.parentNode;
      const show = (kind) => holder.replaceChild(icon(model_svg, kind), holder.querySelector("svg"));
      show("S");

      let busy = false, t = 0;
      const flash = (text, bad) => {
        clearTimeout(t);
        if (text.startsWith("Saving")) { show("busy"); button.title = "Saving…"; return; }
        show(bad ? "bad" : "ok");
        button.title = text;
        t = setTimeout(() => { show("S"); button.title = "Save to Snag"; }, 1900);
      };
      for (const type of ["pointerdown", "mousedown", "mouseup", "click"]) {
        button.addEventListener(type, (e) => {
          e.preventDefault();
          e.stopPropagation();
          e.stopImmediatePropagation();
          if (type !== "click" || busy) return;
          const pinId = pinIdFrom(location.pathname);
          const media = closeupMedia();
          if (!pinId || !media) { flash("Failed", true); return; }
          busy = true;
          save({ id: pinId, media, inGrid: false }, flash).finally(() => { busy = false; });
        }, true);
      }
      // Before the "more" menu, which Pinterest keeps last.
      const more = [...row.children].find((c) => c.querySelector('[data-test-id="closeup-more-options"]'));
      row.insertBefore(copy, more || null);
    }
  }

  // Pinterest swaps pins without reloading and redraws the row as it does.
  let scanQueued = false;
  new MutationObserver(() => {
    if (scanQueued) return;
    scanQueued = true;
    requestAnimationFrame(() => { scanQueued = false; addActionButton(); });
  }).observe(document.documentElement, { childList: true, subtree: true });
  addActionButton();
})();
