// Snag on Unsplash. A Snag button inside Unsplash's own button rows, built
// from the classes of the buttons beside it so it looks and behaves like
// one of them:
//  - a photo's page and the photo overlay a grid opens (/photos/…): a
//    "Snag" button in the top bar, just left of Download;
//  - grids (home feed, search, topics, collections, profiles): a round S
//    button in each photo's hover bar, beside Like and Add to collection.
// Unsplash names its classes with hashes that change, so the rows are found
// by what their buttons are (Download, Add to collection), not by class.
//
// A click reads the photo from Unsplash's own photo data (the page's session
// calls /napi/photos/<id>) and saves the original upload, named after the
// photo and its photographer, linked to their Unsplash profile, with a note
// carrying the photo's page and description.
//
// Unsplash+ photos are saved at the size the page shows them (1080 px), not
// as the full-size original, which is what a paid download is for.
// If the photo data can't be read, the picture on screen is saved instead.
(() => {
  if (window.__snagUnsplash || window.top !== window) return;
  window.__snagUnsplash = true;

  const PHOTO_RE = /^\/(?:[a-z]{2}(?:-[A-Z]{2})?\/)?(?:photos|illustrations)\/([^/?#]+)/;
  const IMG_HOST = /^(images|plus)\.unsplash\.com$/;

  const abs = (u) => { try { return new URL(u, location.href).href; } catch (e) { return ""; } };
  const hostOf = (u) => { try { return new URL(u).hostname; } catch (e) { return ""; } };

  function photoSlug(href) {
    try { return (new URL(href, location.href).pathname.match(PHOTO_RE) || [])[1] || ""; }
    catch (e) { return ""; }
  }

  function isPhotoImage(el) {
    return !!el && el.tagName === "IMG" && IMG_HOST.test(hostOf(el.currentSrc || el.src));
  }

  // The largest Unsplash picture inside a box (skips avatars and logos).
  function imageIn(box) {
    let best = null, area = 0;
    for (const img of box.querySelectorAll("img")) {
      if (!isPhotoImage(img)) continue;
      const r = img.getBoundingClientRect();
      if (r.width < 120 || r.height < 120) continue;
      if (r.width * r.height > area) { area = r.width * r.height; best = img; }
    }
    return best;
  }

  // ---------- Reading a photo ----------

  const cache = new Map();

  async function fetchJSON(path) {
    const res = await fetch(path, { credentials: "include", headers: { "Accept": "application/json" } });
    if (!res.ok) throw new Error("HTTP " + res.status);
    return res.json();
  }

  // The photo from Unsplash's own data. A photo's address is "<slug>-<id>";
  // the data answers to the whole slug, and to the 11-character id alone.
  async function fetchPhoto(slug) {
    if (cache.has(slug)) return cache.get(slug);
    let d;
    try { d = await fetchJSON(`/napi/photos/${encodeURIComponent(slug)}`); }
    catch (e) {
      if (slug.length <= 11) throw e;
      d = await fetchJSON(`/napi/photos/${encodeURIComponent(slug.slice(-11))}`);
    }
    if (!d || !d.urls) throw new Error("no photo data");
    const paid = !!(d.premium || d.plus);
    const u = d.user || {};
    const photo = {
      page: (d.links && d.links.html) || `https://unsplash.com/photos/${slug}`,
      title: (d.description || d.alt_description || "").trim(),
      description: (d.description && d.alt_description && d.description !== d.alt_description)
        ? d.alt_description.trim() : "",
      url: paid ? d.urls.regular : d.urls.raw,
      person: u.username ? {
        platform: "unsplash", handle: u.username, name: u.name || "",
        url: `https://unsplash.com/@${u.username}`,
        avatar: (u.profile_image && (u.profile_image.large || u.profile_image.medium)) || "",
      } : null,
    };
    cache.set(slug, photo);
    return photo;
  }

  // When the data can't be read: the widest picture the page offers. A free
  // photo's address without its resize query is the original; an Unsplash+
  // one stays at the size shown.
  function screenPhoto(target) {
    const img = target.img;
    let url = img.currentSrc || img.src || "", w = 0;
    for (const part of (img.getAttribute("srcset") || "").split(",")) {
      const [u, size] = part.trim().split(/\s+/);
      const n = parseInt(size || "0", 10);
      if (u && n > w) { w = n; url = u; }
    }
    url = abs(url);
    if (hostOf(url) === "images.unsplash.com") url = url.split("?")[0];
    return {
      page: `https://unsplash.com/photos/${target.slug}`,
      title: (img.alt || "").trim(), description: "", url, person: null,
    };
  }

  // ---------- Saving ----------

  async function save(target, ui) {
    ui("busy");
    let photo;
    try { photo = await fetchPhoto(target.slug); }
    catch (e) {
      const img = target.img();
      photo = img ? screenPhoto({ slug: target.slug, img }) : null;
    }
    if (!photo || !photo.url) { ui("fail", "Nothing to save"); return; }
    const who = photo.person && (photo.person.name || photo.person.handle);
    const name = [photo.title ? photo.title.charAt(0).toUpperCase() + photo.title.slice(1) : "Unsplash photo", who]
      .filter(Boolean).join(" — ").slice(0, 140);
    const note = [
      photo.description,
      `Unsplash: ${photo.page}`,
      who ? `Photo by ${who}: ${photo.person.url}` : "",
    ].filter(Boolean).join("\n");
    try {
      const reply = await chrome.runtime.sendMessage({
        type: "save-remote", pageURL: photo.page, note, account: photo.person,
        items: [{ url: photo.url, ext: "jpg", name }],
      });
      if (!reply || !reply.ok) { ui("fail", "Snag could not save it"); return; }
      ui("ok", reply.duplicate ? "Already in Snag" : `Saved${reply.folderName ? " to " + reply.folderName : ""}`);
    } catch (e) {
      ui("fail", "Snag could not save it");
    }
  }

  // ---------- Icons ----------
  // Built node by node: no HTML strings. They draw in the button's own text
  // colour, like Unsplash's icons.

  function svg(size) {
    const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    s.setAttribute("width", size);
    s.setAttribute("height", size);
    s.setAttribute("viewBox", "0 0 24 24");
    s.setAttribute("aria-hidden", "true");
    s.style.display = "block";
    s.style.flex = "none";
    return s;
  }

  function sIcon(size) {
    const s = svg(size);
    const t = document.createElementNS("http://www.w3.org/2000/svg", "text");
    t.setAttribute("x", "12");
    t.setAttribute("y", "18.5");
    t.setAttribute("text-anchor", "middle");
    t.setAttribute("font-family", "Georgia, 'Times New Roman', serif");
    t.setAttribute("font-weight", "700");
    t.setAttribute("font-size", "20");
    t.setAttribute("fill", "currentColor");
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
      c.setAttribute("fill", "currentColor");
      s.appendChild(c);
    }
    return s;
  }

  // ---------- Finding Unsplash's own buttons ----------

  const labelOf = (el) => [el.getAttribute("aria-label"), el.getAttribute("title"), el.textContent]
    .filter(Boolean).join(" ").replace(/\s+/g, " ").trim();

  const isDownload = (el) => /^download( free)?$/i.test((el.textContent || "").trim())
    || /^download/i.test(el.getAttribute("aria-label") || el.getAttribute("title") || "");
  const isCollect = (el) => /collection/i.test(labelOf(el));
  const isLike = (el) => /\blike\b|bookmark/i.test(el.getAttribute("aria-label") || el.getAttribute("title") || "");
  const isEdit = (el) => /^edit image/i.test((el.textContent || "").trim());

  // The smallest ancestor of `from` that also holds an element `want` picks.
  function rowWith(from, want, stop) {
    for (let el = from.parentElement; el && el !== stop && el !== document.body; el = el.parentElement) {
      if ([...el.querySelectorAll("button, a")].some((b) => b !== from && want(b))) return el;
    }
    return null;
  }

  // The child of `row` that holds `el` (a button often sits in a wrapper
  // that carries the row's spacing).
  function slotOf(row, el) {
    let c = el;
    while (c && c.parentElement !== row) c = c.parentElement;
    return c;
  }

  // A copy of `slot` around our button: same wrapper element and classes,
  // so the gaps match.
  function wrapLike(slot, inner, button) {
    if (slot === inner) return button;
    const w = slot.cloneNode(false);
    w.removeAttribute("id");
    w.appendChild(button);
    return w;
  }

  function makeButton(model, kind, size, onClick) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = (model ? model.className : "") + " snag-unsplash-btn";
    if (model && model.getAttribute("style")) btn.setAttribute("style", model.getAttribute("style"));
    btn.style.display = btn.style.display || "inline-flex";
    btn.style.alignItems = "center";
    btn.style.justifyContent = "center";
    btn.style.gap = "6px";
    btn.style.cursor = "pointer";
    const label = kind === "text" ? document.createElement("span") : null;
    const ui = (state, tip) => {
      const icon = state === "busy" ? dotsIcon(size) : state === "idle" ? sIcon(size) : markIcon(size, state === "ok");
      if (label) {
        label.textContent = state === "busy" ? "Saving…" : state === "ok" ? "Saved" : state === "fail" ? "Failed" : "Snag";
        btn.replaceChildren(icon, label);
      } else {
        btn.replaceChildren(icon);
      }
      btn.title = tip || "Save to Snag";
      btn.setAttribute("aria-label", tip || "Save to Snag");
      clearTimeout(btn.__snagT);
      if (state === "ok" || state === "fail") btn.__snagT = setTimeout(() => ui("idle"), 2200);
    };
    ui("idle");
    // The photo's link and Unsplash's own handlers sit around it: take
    // the click in the capture phase before they can.
    for (const type of ["pointerdown", "mousedown", "mouseup", "click"]) {
      btn.addEventListener(type, (e) => {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        if (type !== "click" || btn.__snagBusy) return;
        btn.__snagBusy = true;
        Promise.resolve(onClick(ui)).finally(() => { btn.__snagBusy = false; });
      }, true);
    }
    return btn;
  }

  // ---------- A photo's page and the photo overlay ----------

  function addHeaderButton() {
    const slug = photoSlug(location.href);
    if (!slug) return;
    // The top bar's Download (not a grid tile's, which sits inside a figure).
    const download = [...document.querySelectorAll("button, a")]
      .find((el) => isDownload(el) && !el.closest("figure") && el.getBoundingClientRect().width > 60);
    if (!download) return;
    const row = rowWith(download, isCollect);
    if (!row || row.querySelector(".snag-unsplash-btn")) return;
    // Copy the plain text button next to it ("Edit image"), else Download's.
    const model = [...row.querySelectorAll("button, a")].find(isEdit) || download;
    const slot = slotOf(row, download);
    const btn = makeButton(model, "text", 16, (ui) => save({
      slug: photoSlug(location.href) || slug,
      img: () => imageIn(document.querySelector('[role="dialog"]') || document.querySelector("main") || document),
    }, ui));
    // Wrapped the way its model is (Download sits in its split-button box,
    // "Edit image" stands alone in the row).
    row.insertBefore(wrapLike(slotOf(row, model) || slot, model, btn), slot);
  }

  // ---------- Grid photos ----------

  function addTileButton(tile) {
    const link = tile.querySelector('a[href*="/photos/"], a[href*="/illustrations/"]');
    const slug = link && photoSlug(link.getAttribute("href"));
    if (!slug || tile.querySelector(".snag-unsplash-btn")) return;
    const collect = [...tile.querySelectorAll("button, a")].find(isCollect);
    if (!collect) return;   // the hover bar isn't drawn yet; the next scan adds it
    const row = rowWith(collect, isLike, tile) || collect.parentElement;
    const slot = slotOf(row, collect);
    const btn = makeButton(collect, "icon", 18, (ui) => save({ slug, img: () => imageIn(tile) }, ui));
    // First in the row, ahead of Like: [Snag] [Like] [+]. Each button sits
    // in a show-on-hover wrapper; ours gets a copy of it.
    const like = [...row.querySelectorAll("button, a")].find(isLike);
    const before = (like && slotOf(row, like)) || slot;
    row.insertBefore(wrapLike(slot, collect, btn), before);
  }

  // ---------- Watching the page ----------

  function scan() {
    addHeaderButton();
    for (const tile of document.querySelectorAll("figure")) addTileButton(tile);
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
