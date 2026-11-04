// Snag on Instagram: one floating save button that targets whichever video
// is most visible. It lives on <body> at fixed position with the maximum
// z-index — Instagram's player overlay sits above anything placed inside
// the post, which is why an in-place button only toggled play/pause.
(() => {
  if (window.__snagIg) return;
  window.__snagIg = true;

  const harvested = []; // {shortcode, url}
  window.addEventListener("message", (e) => {
    if (e.source !== window || !e.data || !e.data.__snagIgVideos) return;
    for (const entry of e.data.__snagIgVideos) {
      if (!harvested.some((h) => h.url === entry.url)) harvested.push(entry);
    }
  });
  const metaByCode = new Map(); // shortcode -> {user, caption}
  window.addEventListener("message", (e) => {
    if (e.source !== window || !e.data || !e.data.__snagIgMeta) return;
    for (const m of e.data.__snagIgMeta) metaByCode.set(m.shortcode, m);
  });
  window.postMessage({ __snagIgReplay: true }, "*");

  function currentShortcode() {
    const m = location.pathname.match(/\/(?:reels?|p|tv)\/([A-Za-z0-9_-]+)/);
    return m ? m[1] : "";
  }

  // The player streams in pieces: a URL seen in the network log carries
  // bytestart/byteend and fetches only that slice. Without them the CDN
  // returns the whole file, instead of a broken fragment saved as "done".
  function wholeFile(u) {
    try {
      const url = new URL(u);
      url.searchParams.delete("bytestart");
      url.searchParams.delete("byteend");
      return url.toString();
    } catch (e) { return u; }
  }

  function timedVideoURLs() {
    try {
      return performance.getEntriesByType("resource")
        .map((e) => e.name)
        .filter((n) => /\.mp4/.test(n) && /cdninstagram|fbcdn/.test(n));
    } catch (e) { return []; }
  }

  // The video occupying the most screen space right now.
  function currentVideo() {
    let best = null, bestArea = 0;
    for (const v of document.querySelectorAll("video")) {
      const r = v.getBoundingClientRect();
      if (r.width < 80 || r.height < 80) continue;
      const vis = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0))
                * Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
      if (vis > bestArea) { bestArea = vis; best = v; }
    }
    return best;
  }

  // The largest visible Instagram photo. Photo posts (/p/) have no <video>,
  // so the button used to never appear on them at all.
  function currentImage() {
    let best = null, bestArea = 0;
    for (const img of document.querySelectorAll("img")) {
      const src = img.currentSrc || img.src || "";
      if (!/cdninstagram|fbcdn/.test(src)) continue;
      const r = img.getBoundingClientRect();
      if (r.width < 150 || r.height < 150) continue;   // skips avatars
      const vis = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0))
                * Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
      if (vis > bestArea) { bestArea = vis; best = img; }
    }
    return best;
  }

  /// Video wins when present; otherwise the photo on screen.
  function currentMedia() {
    const v = currentVideo();
    if (v) return { el: v, kind: "video" };
    const i = currentImage();
    return i ? { el: i, kind: "image" } : null;
  }

  // Instagram serves several sizes; take the widest the page offers.
  function bestImageURL(img) {
    const set = img.getAttribute("srcset") || "";
    let bestURL = img.currentSrc || img.src || "", bestW = 0;
    for (const part of set.split(",")) {
      const [u, w] = part.trim().split(/\s+/);
      const width = parseInt(w || "0", 10);
      if (u && width > bestW) { bestW = width; bestURL = u; }
    }
    return bestURL;
  }

  // The post a video belongs to. On a post page that is the address bar; in
  // the feed or a profile grid, the post's own link inside its card or the
  // open post dialog.
  function postLinkFor(video) {
    const here = location.pathname.match(/\/(reels?|p|tv)\/([A-Za-z0-9_-]+)/);
    if (here) return `https://www.instagram.com/${here[1] === "reels" ? "reel" : here[1]}/${here[2]}/`;
    const box = video && video.closest("article, [role='dialog'], [role='presentation']");
    const a = box && box.querySelector('a[href*="/p/"], a[href*="/reel/"]');
    if (a) {
      const m = a.getAttribute("href").match(/\/(p|reel)\/([A-Za-z0-9_-]+)/);
      if (m) return `https://www.instagram.com/${m[1]}/${m[2]}/`;
    }
    return null;
  }

  function shortcodeOf(link) {
    const m = link && link.match(/\/(?:p|reel|tv)\/([A-Za-z0-9_-]+)/);
    return m ? m[1] : "";
  }

  // A complete, playable file for this video, or null. Only progressive files
  // (with sound) count: the player's own network requests are byte-range
  // slices of separate video and audio streams, and saving one of those gave
  // a fragment.
  function resolveURL(video) {
    const direct = video && (video.currentSrc || video.src) || "";
    if (direct.startsWith("http")) return direct;

    // Match THIS reel by its shortcode — the feed preloads neighbours, so
    // any positional guess saves someone else's video.
    const code = shortcodeOf(postLinkFor(video)) || currentShortcode();
    if (code) {
      const hit = harvested.find((h) => h.shortcode === code);
      if (hit) return hit.url;
    }
    // Single video on screen and only one candidate: unambiguous.
    const videos = Array.from(document.querySelectorAll("video"));
    const untagged = harvested.filter((h) => !h.shortcode);
    if (videos.length === 1 && harvested.length === 1) return harvested[0].url;
    if (videos.length === 1 && untagged.length === 1) return untagged[0].url;

    return null;
  }

  function permalink() {
    const m = location.pathname.match(/\/(reels?|p|tv)\/([A-Za-z0-9_-]+)/);
    return m ? `https://www.instagram.com/${m[1] === "reels" ? "reel" : m[1]}/${m[2]}/`
             : location.href.split("?")[0];
  }

  // The post's own address for the item on screen: in the feed the address
  // bar is just instagram.com, which saved every feed item with that as its
  // link and a generic name.
  function linkFor(el) {
    return postLinkFor(el) || permalink();
  }

  // The account that posted the item on screen: its own card's header.
  function authorOf(el) {
    const box = el && el.closest("article, [role='dialog']");
    const href = (box || document).querySelector('header a[href^="/"]')?.getAttribute("href") || "";
    const handle = href.replace(/\//g, "");
    return /^[A-Za-z0-9._]+$/.test(handle) ? handle : "";
  }

  // "Caption\n\n— @account\n\nlink". Instagram's own data first; the page
  // text when the post arrived some way the intercept did not see (a post
  // page shows its caption in an <h1>).
  function noteFor(link, el) {
    const m = metaByCode.get(shortcodeOf(link)) || {};
    const user = m.user || authorOf(el);
    let caption = m.caption || "";
    if (!caption) {
      const box = el && el.closest("article, [role='dialog']");
      caption = ((box || document).querySelector("h1")?.innerText || "").trim();
    }
    return [caption, user ? `— @${user}` : "", link].filter(Boolean).join("\n\n");
  }

  function accountFor(link, el) {
    const meta = metaByCode.get(shortcodeOf(link)) || {};
    const handle = meta.user || authorOf(el);
    if (!handle) return null;
    // The post header's own picture when the data had none.
    const box = el && el.closest("article, [role='dialog']");
    const img = box && [...box.querySelectorAll("header img")].find((i) => /profile picture/i.test(i.alt || ""));
    return { platform: "instagram", handle, name: meta.name || "", url: `https://www.instagram.com/${handle}/`,
             avatar: meta.avatar || (img && (img.currentSrc || img.src)) || "" };
  }

  function itemName(link, el) {
    const code = ((link || permalink()).match(/\/([A-Za-z0-9_-]+)\/?$/) || [])[1] || "reel";
    const user = (location.pathname.match(/^\/([A-Za-z0-9._]+)\//) || [])[1];
    // The author of THIS post, not the first header on the page (whichever
    // post sits at the top of the feed).
    const handle = metaByCode.get(code)?.user || authorOf(el);
    const who = handle || (user && !["reel", "reels", "p", "tv"].includes(user) ? user : null);
    return who ? `${who} — ${code}` : `Instagram ${code}`;
  }

  // ---- the button ----------------------------------------------------------

  const btn = document.createElement("button");
  btn.textContent = "Save to Snag";
  Object.assign(btn.style, {
    position: "fixed", zIndex: "2147483647",
    background: "rgba(0,0,0,.78)", color: "#fff", border: "1px solid rgba(255,255,255,.18)",
    borderRadius: "9px", padding: "7px 12px", fontSize: "12px", fontWeight: "600",
    cursor: "pointer", backdropFilter: "blur(10px)", display: "none",
    fontFamily: "-apple-system, system-ui, sans-serif", lineHeight: "1",
    boxShadow: "0 4px 14px rgba(0,0,0,.35)", pointerEvents: "auto",
  });
  document.documentElement.appendChild(btn);

  // Beat Instagram's overlay: consume the event in the capture phase.
  for (const type of ["pointerdown", "mousedown", "mouseup", "click", "touchstart"]) {
    btn.addEventListener(type, (e) => {
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      if (type === "click") save();
    }, true);
  }

  function place() {
    const m = currentMedia();
    if (!m) { btn.style.display = "none"; return; }
    const r = m.el.getBoundingClientRect();
    if (r.bottom < 0 || r.top > innerHeight) { btn.style.display = "none"; return; }
    btn.style.display = "block";
    btn.style.top = Math.max(8, r.top + 12) + "px";
    btn.style.left = Math.min(innerWidth - 130, r.right - 128) + "px";
  }

  let busy = false;
  async function save() {
    if (busy) return;
    const media = currentMedia();
    if (!media) { flash("Nothing to save here", true); return; }

    // A carousel: every slide, not just the one on screen.
    const postURL = linkFor(media.el);
    const slides = metaByCode.get(shortcodeOf(postURL))?.slides || [];
    if (slides.length > 1) { await saveSlides(slides, postURL, media.el); return; }

    let isVideo = media.kind === "video";
    let url = isVideo ? resolveURL(media.el) : bestImageURL(media.el);
    const postLink = isVideo ? postLinkFor(media.el) : null;

    // No complete file on the page: let Snag fetch the post itself. Its
    // downloader signs in with your browser and merges video and sound.
    if (isVideo && !url) {
      if (postLink) { await saveViaSnag(postLink, media.el); return; }
      // A photo post can carry a stray <video> (a suggested clip): save the
      // picture on screen instead of refusing.
      const img = currentImage();
      if (img) { url = bestImageURL(img); isVideo = false; }
    }
    if (!url) { flash("Open the post, then save", true); return; }
    // Keep the real extension: Instagram serves .jpg and .webp.
    let ext = "jpg";
    if (isVideo) ext = "mp4";
    else {
      const m = url.split("?")[0].match(/\.(jpe?g|png|webp|heic)$/i);
      if (m) ext = m[1].toLowerCase() === "jpeg" ? "jpg" : m[1].toLowerCase();
    }
    busy = true;
    flash("Saving…");
    try {
      // The CDN links are signed, so no cookies are needed, and sending them
      // makes the CDN refuse the request.
      const res = await fetch(url, { credentials: "omit" });
      if (!res.ok) throw new Error("HTTP " + res.status);
      const buf = await res.arrayBuffer();
      // Chrome caps a runtime message at 64 MiB, and base64 adds a third, so
      // anything past ~45 MB can never arrive as bytes. Larger files go
      // straight to the app-download fallback below, which now reports
      // honestly if Instagram refuses it.
      if (buf.byteLength > 45 * 1024 * 1024) throw new Error("too large for a message");
      let bin = "";
      const bytes = new Uint8Array(buf);
      for (let i = 0; i < bytes.length; i += 0x8000) {
        bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      }
      const link = linkFor(media.el);
      const reply = await chrome.runtime.sendMessage({
        type: "save-bytes", dataBase64: btoa(bin), ext,
        name: itemName(link, media.el), sourceURL: url, pageURL: link,
        note: noteFor(link, media.el), account: accountFor(link, media.el),
      });
      flash(reply && reply.duplicate ? "Already saved"
            : reply && reply.folderName ? `Saved to ${reply.folderName} ✓` : "Saved ✓");
    } catch (err) {
      // The page's file could not be fetched or is too big for a message.
      // For a video, hand Snag the post link, not the file address:
      // Instagram's file addresses are refused outside this browser tab.
      if (isVideo && postLink) { busy = false; await saveViaSnag(postLink, media.el); return; }
      try {
        const link = linkFor(media.el);
        const reply = await chrome.runtime.sendMessage({
          type: "save-url", url, pageURL: link, note: noteFor(link, media.el), account: accountFor(link, media.el),
        });
        flash(reply && reply.ok
              ? (reply.folderName ? `Saved to ${reply.folderName} ✓` : "Saved ✓")
              : "Failed", !(reply && reply.ok));
      } catch (e2) {
        flash("Failed", true);
      }
    }
    busy = false;
  }

  // The CDN links are signed, so the background worker can fetch each one
  // without the page's cookies, and Snag gets real bytes with a real name.
  async function saveSlides(slides, link, el) {
    busy = true;
    flash(`Saving ${slides.length}…`);
    const base = itemName(link, el);
    try {
      const reply = await chrome.runtime.sendMessage({
        type: "save-remote", pageURL: link, note: noteFor(link, el), account: accountFor(link, el),
        items: slides.map((s, i) => {
          const m = s.url.split("?")[0].match(/\.(jpe?g|png|webp|heic|mp4)$/i);
          const ext = s.kind === "video" ? "mp4"
            : m ? (m[1].toLowerCase() === "jpeg" ? "jpg" : m[1].toLowerCase()) : "jpg";
          return { url: s.url, ext, name: `${base} (${i + 1})` };
        }),
      });
      flash(!reply || !reply.ok ? "Failed"
            : reply.duplicate ? "Already saved"
            : `Saved ${reply.saved || slides.length} ✓`, !(reply && reply.ok));
    } catch (e) {
      flash("Failed", true);
    }
    busy = false;
  }

  async function saveViaSnag(link, el) {
    busy = true;
    flash("Saving via Snag…");
    try {
      const reply = await chrome.runtime.sendMessage({
        type: "save-url", url: link, pageURL: link, note: noteFor(link, el), account: accountFor(link, el),
      });
      flash(!reply || !reply.ok ? "Failed"
            : reply.duplicate ? "Already saved"
            : reply.folderName ? `Saved to ${reply.folderName} ✓` : "Saved ✓",
            !(reply && reply.ok));
    } catch (e) {
      flash("Failed", true);
    }
    busy = false;
  }

  function flash(text, bad) {
    btn.textContent = text;
    btn.style.background = bad ? "rgba(190,55,55,.92)"
                          : text.startsWith("Saving") ? "rgba(63,110,247,.92)"
                          : "rgba(45,150,90,.92)";
    if (!text.startsWith("Saving")) {
      setTimeout(() => {
        btn.textContent = "Save to Snag";
        btn.style.background = "rgba(0,0,0,.78)";
      }, 1900);
    }
  }

  // ---- profile pictures ----------------------------------------------------
  // Snag can't see Instagram profile pictures without a login. While
  // Instagram is open here, look up the ones it is missing: a profile page's
  // og:image is its picture (a "-19/" path on Instagram's CDN).
  async function fillPictures() {
    let missing = [];
    try { missing = (await chrome.runtime.sendMessage({ type: "missing-avatars", platform: "instagram" })) || []; }
    catch (e) { return; }
    for (const p of missing.slice(0, 25)) {
      try {
        const html = await (await fetch(`/${encodeURIComponent(p.handle)}/`, { credentials: "include" })).text();
        const m = html.match(/<meta[^>]+property="og:image"[^>]+content="([^"]+)"/)
          || html.match(/<meta[^>]+content="([^"]+)"[^>]+property="og:image"/);
        const pic = m && m[1].replace(/&amp;/g, "&");
        if (pic && /-19\//.test(pic)) await chrome.runtime.sendMessage({ type: "set-avatar", id: p.id, avatar: pic });
      } catch (e) {}
      await new Promise((r) => setTimeout(r, 1500)); // gently, one profile at a time
    }
  }
  if (window.top === window) setTimeout(fillPictures, 6000);

  addEventListener("scroll", place, true);
  addEventListener("resize", place);
  setInterval(place, 400);
  place();
})();
