// Snag on Instagram.
// Every post gets Snag as an icon in its own action row, left of the
// bookmark: in the feed, on a post page, in the post a profile grid opens,
// and in the reels column. It is a copy of Instagram's Share button, so it
// looks and lines up like theirs. Where a post has no such row (stories), a
// floating button sits on whichever photo or video is most visible; it
// lives on <html> at the top z-index, because Instagram's player overlay
// covers anything placed inside the post.
//
// What a save takes: the post read from Instagram's own post info (by its
// shortcode, with the page's session), so a carousel saves every slide in
// order, photos and videos, at full size, kept as one group. When that
// can't be read, what the page itself shows is saved instead.
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

  // ---- ads ------------------------------------------------------------------
  // A sponsored post in the feed has no link to its post, so neither the
  // shortcode match nor the address bar can name its video. Its card still
  // shows the advertiser, and Instagram's feed data tagged that advertiser's
  // video (see ig-intercept), so the video is found by account.

  function cardOf(el) {
    return el && el.closest("article, [role='dialog'], [role='presentation']");
  }

  // The card's header reads "account / Ad" (or "Sponsored").
  function isAdCard(el) {
    const head = cardOf(el)?.querySelector("header") || cardOf(el);
    if (!head) return false;
    return (head.innerText || "").split("\n").some((l) => /^(Ad|Sponsored)$/i.test(l.trim()));
  }

  // The harvested video for an ad card, or null when it can't be told apart.
  function adEntryFor(el) {
    const handle = authorOf(el);
    if (!handle) return null;
    const mine = harvested.filter((h) => h.user === handle);
    const ads = mine.filter((h) => h.ad);
    const pick = ads.length ? ads : mine;
    // The latest one: an ad is injected into the feed as you reach it.
    return pick.length ? pick[pick.length - 1] : null;
  }

  // Meta Ad Library search for the advertiser: every ad they run, each with
  // Snag's own save buttons (fb-ads.js).
  function openAdLibrary(el) {
    const handle = authorOf(el);
    const q = encodeURIComponent(handle || "");
    window.open(`https://www.facebook.com/ads/library/?active_status=all&ad_type=all&country=ALL`
      + `&q=${q}&search_type=keyword_unordered&media_type=all`, "_blank", "noopener");
  }

  /// The post link of the item being saved, when the save worked it out
  /// some other way than the card (an ad's shortcode from the feed data).
  const knownLink = new WeakMap();

  function permalink() {
    const m = location.pathname.match(/\/(reels?|p|tv)\/([A-Za-z0-9_-]+)/);
    return m ? `https://www.instagram.com/${m[1] === "reels" ? "reel" : m[1]}/${m[2]}/`
             : location.href.split("?")[0];
  }

  // The post's own address for the item on screen: in the feed the address
  // bar is just instagram.com, which saved every feed item with that as its
  // link and a generic name.
  function linkFor(el) {
    return postLinkFor(el) || (el && knownLink.get(el)) || permalink();
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

  // ---- the post, from Instagram's own data ---------------------------------
  // A shortcode is the post's numeric id in base 64; the media info call
  // takes the number and returns every slide of a carousel at full size,
  // with each video's complete file (sound included). The feed data that
  // ig-intercept reads only covers posts that loaded after the page did.

  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  function mediaIdOf(code) {
    let id = 0n;
    for (const ch of code.slice(0, 11)) {
      const n = B64.indexOf(ch);
      if (n < 0) return "";
      id = id * 64n + BigInt(n);
    }
    return id.toString();
  }

  function bestCandidate(node) {
    const c = node.image_versions2?.candidates || [];
    return [...c].sort((a, b) => (b.width || 0) - (a.width || 0))[0]?.url || "";
  }
  function bestVideoOf(node) {
    const v = node.video_versions || [];
    return [...v].sort((a, b) => (b.width || 0) - (a.width || 0))[0]?.url || "";
  }

  const postCache = new Map(); // shortcode -> {slides, user, …}
  async function fetchPost(code) {
    if (!code) return null;
    if (postCache.has(code)) return postCache.get(code);
    const id = mediaIdOf(code);
    if (!id) return null;
    const csrf = (document.cookie.match(/csrftoken=([^;]+)/) || [])[1] || "";
    const res = await fetch(`/api/v1/media/${id}/info/`, {
      credentials: "include",
      headers: { "X-IG-App-ID": "936619743392459", "X-CSRFToken": csrf, "X-Requested-With": "XMLHttpRequest" },
    });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const it = (await res.json())?.items?.[0];
    if (!it) return null;
    const nodes = Array.isArray(it.carousel_media) && it.carousel_media.length ? it.carousel_media : [it];
    const slides = [];
    for (const n of nodes) {
      const v = bestVideoOf(n);
      if (v) slides.push({ kind: "video", url: v });
      else { const img = bestCandidate(n); if (img) slides.push({ kind: "image", url: img }); }
    }
    const post = {
      shortcode: code, slides,
      user: it.user?.username || "", name: it.user?.full_name || "",
      avatar: it.user?.hd_profile_pic_url_info?.url || it.user?.profile_pic_url || "",
      caption: it.caption?.text || "",
    };
    postCache.set(code, post);
    // noteFor, accountFor and itemName read the post from here.
    const had = metaByCode.get(code) || {};
    metaByCode.set(code, { ...had, ...Object.fromEntries(Object.entries(post).filter(([, v]) => v && (!Array.isArray(v) || v.length))) });
    return post;
  }

  /// Saves the post from its own data: every slide of a carousel, or its one
  /// photo or video. False when the data couldn't be read, so the caller can
  /// fall back to what the page shows.
  async function savePost(link, el, flash) {
    let post = null;
    try { post = await fetchPost(shortcodeOf(link)); } catch (e) { post = null; }
    if (!post || !post.slides.length) return false;
    await saveSlides(post.slides, link, el, flash);
    return true;
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
      if (type === "click") save(currentMedia(), floatFlash);
    }, true);
  }

  function place() {
    const m = currentMedia();
    if (!m || hasRowButton(m.el)) { btn.style.display = "none"; return; }
    const r = m.el.getBoundingClientRect();
    if (r.bottom < 0 || r.top > innerHeight) { btn.style.display = "none"; return; }
    btn.style.display = "block";
    btn.style.top = Math.max(8, r.top + 12) + "px";
    btn.style.left = Math.min(innerWidth - 130, r.right - 128) + "px";
  }

  let busy = false;
  async function save(media, flash) {
    if (busy) return;
    if (!media) { flash("Nothing to save here", true); return; }

    // The post's own data first: a carousel's every slide, a video's
    // complete file. A feed ad has no post link, so it skips this.
    const postURL = postLinkFor(media.el) || (/\/(p|reels?|tv)\//.test(location.pathname) ? permalink() : null);
    if (postURL) {
      busy = true;
      flash("Saving…");
      const done = await savePost(postURL, media.el, flash);
      busy = false;
      if (done) return;
    }
    // A carousel the feed data described.
    const slides = postURL ? (metaByCode.get(shortcodeOf(postURL))?.slides || []) : [];
    if (slides.length > 1) { await saveSlides(slides, postURL, media.el, flash); return; }

    let isVideo = media.kind === "video";
    let url = isVideo ? resolveURL(media.el) : bestImageURL(media.el);
    let postLink = isVideo ? postLinkFor(media.el) : null;

    // A feed ad: no post link on the card. Find its video by advertiser.
    if (isVideo && !postLink && isAdCard(media.el)) {
      const ad = adEntryFor(media.el);
      if (ad) {
        url = url || ad.url;
        if (ad.shortcode) {
          postLink = `https://www.instagram.com/p/${ad.shortcode}/`;
          knownLink.set(media.el, postLink);
        }
      }
    }

    // No complete file on the page: let Snag fetch the post itself. Its
    // downloader signs in with your browser and merges video and sound.
    if (isVideo && !url) {
      if (postLink) { await saveViaSnag(postLink, media.el, flash); return; }
      // A photo post can carry a stray <video> (a suggested clip): save the
      // picture on screen instead of refusing.
      const img = currentImage();
      if (img) { url = bestImageURL(img); isVideo = false; }
    }
    if (!url) {
      // An ad whose video never came through the feed data: Meta's Ad
      // Library has every ad the advertiser runs, with Snag buttons on each.
      if (isAdCard(media.el)) { openAdLibrary(media.el); flash("Opened in Ad Library"); return; }
      flash("Open the post, then save", true);
      return;
    }
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
      if (isVideo && postLink) { busy = false; await saveViaSnag(postLink, media.el, flash); return; }
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
  async function saveSlides(slides, link, el, flash) {
    busy = true;
    flash(slides.length > 1 ? `Saving ${slides.length}…` : "Saving…");
    const base = itemName(link, el);
    try {
      const reply = await chrome.runtime.sendMessage({
        type: "save-remote", pageURL: link, note: noteFor(link, el), account: accountFor(link, el),
        items: slides.map((s, i) => {
          const m = s.url.split("?")[0].match(/\.(jpe?g|png|webp|heic|mp4)$/i);
          const ext = s.kind === "video" ? "mp4"
            : m ? (m[1].toLowerCase() === "jpeg" ? "jpg" : m[1].toLowerCase()) : "jpg";
          return { url: s.url, ext, name: slides.length > 1 ? `${base} (${i + 1})` : base };
        }),
      });
      flash(!reply || !reply.ok ? "Failed"
            : reply.duplicate ? "Already saved"
            : slides.length > 1 ? `Saved ${reply.saved || slides.length} ✓`
            : reply.folderName ? `Saved to ${reply.folderName} ✓` : "Saved ✓", !(reply && reply.ok));
    } catch (e) {
      flash("Failed", true);
    }
    busy = false;
  }

  async function saveViaSnag(link, el, flash) {
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

  function floatFlash(text, bad) {
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


  // ---- Snag in each post's action row --------------------------------------
  // Left of the bookmark, as a copy of the row's own Share button: same size,
  // hover and colour (it follows Instagram's light and dark themes), with an
  // S for an icon. While saving it shows faint dots, then a tick or a cross.

  const SVG_NS = "http://www.w3.org/2000/svg";
  const BOOKMARK = 'svg[aria-label="Save"], svg[aria-label="Remove"]';
  const SHARE = 'svg[aria-label="Share"], svg[aria-label="Share Post"]';

  function icon(model, kind) {
    const s = document.createElementNS(SVG_NS, "svg");
    for (const a of ["class", "width", "height"]) if (model.hasAttribute(a)) s.setAttribute(a, model.getAttribute(a));
    s.setAttribute("viewBox", "0 0 24 24");
    s.setAttribute("role", "img");
    s.setAttribute("aria-label", "Snag");
    s.style.color = getComputedStyle(model).color;
    const add = (tag, attrs) => {
      const e = document.createElementNS(SVG_NS, tag);
      for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
      s.appendChild(e);
      return e;
    };
    if (kind === "S") {
      add("text", { x: "12", y: "19", "text-anchor": "middle", "font-family": "Georgia, 'Times New Roman', serif",
                    "font-weight": "700", "font-size": "21", fill: "currentColor" }).textContent = "S";
    } else if (kind === "busy") {
      for (const x of [6, 12, 18]) add("circle", { cx: x, cy: "12", r: "2", fill: "currentColor", "fill-opacity": "0.4" });
    } else {
      add("path", { d: kind === "ok" ? "M5 12.5l4.5 4.5L19 7.5" : "M6.5 6.5l11 11M17.5 6.5l-11 11",
                    fill: "none", stroke: kind === "ok" ? "#2ba15b" : "#ed4956", "stroke-width": "2.4",
                    "stroke-linecap": "round", "stroke-linejoin": "round" });
    }
    return s;
  }

  // The post's photo or video on screen: the largest visible one in its card.
  function mediaInCard(card) {
    let best = null, area = 0;
    for (const el of (card || document).querySelectorAll("video, img")) {
      if (el.tagName === "IMG" && !/cdninstagram|fbcdn/.test(el.currentSrc || el.src || "")) continue;
      const r = el.getBoundingClientRect();
      if (r.width < 150 || r.height < 150) continue;
      const vis = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0))
                * Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
      if (vis >= area) { area = vis; best = el; }
    }
    return best && { el: best, kind: best.tagName === "VIDEO" ? "video" : "image" };
  }

  // The smallest element holding both the bookmark and a Share button: the
  // action row of one post (or one reel's column).
  function rowOf(bookmark) {
    let n = bookmark.parentElement;
    while (n && n !== document.body) {
      if (n.querySelector(SHARE)) return n;
      n = n.parentElement;
    }
    return null;
  }

  // An element's outermost ancestor inside `row` (the unit to place beside).
  function unitIn(row, el) {
    let n = el;
    while (n.parentElement && n.parentElement !== row) n = n.parentElement;
    return n;
  }

  function addActionButtons() {
    for (const mark of document.querySelectorAll(BOOKMARK)) {
      const row = rowOf(mark);
      if (!row || row.querySelector(".snag-ig-action")) continue;
      const shareSvg = row.querySelector(SHARE);
      const shareBtn = shareSvg.closest('[role="button"], button');
      const markBtn = mark.closest('[role="button"], button');
      if (!shareBtn || !markBtn) continue;

      const copy = shareBtn.cloneNode(true);
      copy.classList.add("snag-ig-action");
      copy.removeAttribute("id");
      copy.setAttribute("aria-label", "Snag");
      copy.title = "Save to Snag";
      const model = copy.querySelector("svg");
      const show = (kind) => {
        const old = copy.querySelector('svg[aria-label="Snag"]') || copy.querySelector("svg");
        old.replaceWith(icon(shareSvg, kind));
      };
      show("S");

      let t = 0, working = false;
      const flash = (text, bad) => {
        clearTimeout(t);
        if (text.startsWith("Saving")) { show("busy"); copy.title = text; return; }
        show(bad ? "bad" : "ok");
        copy.title = text;
        t = setTimeout(() => { show("S"); copy.title = "Save to Snag"; }, 1900);
      };
      for (const type of ["pointerdown", "mousedown", "mouseup", "click", "touchstart"]) {
        copy.addEventListener(type, (e) => {
          e.preventDefault();
          e.stopPropagation();
          e.stopImmediatePropagation();
          if (type !== "click" || working) return;
          const card = row.closest("article, [role='dialog'], main") || document;
          const media = mediaInCard(card);
          working = true;
          save(media, flash).finally(() => { working = false; });
        }, true);
      }

      // In a row (the feed, a post): just left of the bookmark, in its group.
      // In a column (reels): above the bookmark.
      const markUnit = unitIn(row, markBtn);
      const across = Math.abs(shareBtn.getBoundingClientRect().top - markBtn.getBoundingClientRect().top) < 12;
      if (across && markUnit !== markBtn) {
        const holder = markBtn.parentElement.closest("div") === markUnit ? markUnit : markBtn.parentElement;
        holder.style.display = "flex";
        holder.style.alignItems = "center";
        holder.style.width = "auto";
        // The Share copy carries padding for its hover circle; pull it in so
        // the gap to the bookmark matches the gaps in the left group.
        copy.style.margin = "-8px 4px -8px 0";
        holder.insertBefore(copy, holder.firstChild);
      } else {
        row.insertBefore(copy, markUnit);
        // The column's units carry their own spacing and the copy doesn't:
        // give it the gap that sits above it.
        const prev = copy.previousElementSibling;
        const gap = prev ? copy.getBoundingClientRect().top - prev.getBoundingClientRect().bottom : 0;
        if (gap > 0) copy.style.marginBottom = `${Math.round(gap)}px`;
      }
    }
  }

  // The floating button stands in only where a post has no row of its own.
  function hasRowButton(el) {
    const card = el && el.closest("article, [role='dialog'], main");
    return !!(card && card.querySelector(".snag-ig-action"));
  }

  let scanQueued = false;
  new MutationObserver(() => {
    if (scanQueued) return;
    scanQueued = true;
    requestAnimationFrame(() => { scanQueued = false; addActionButtons(); });
  }).observe(document.documentElement, { childList: true, subtree: true });
  addActionButtons();

  addEventListener("scroll", place, true);
  addEventListener("resize", place);
  setInterval(place, 400);
  place();
})();
