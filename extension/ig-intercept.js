// Runs in the PAGE's world at document_start on Instagram.
// Reels play from blob: URLs, so the real mp4 must come from Instagram's own
// JSON traffic. Every harvested URL is tagged with ITS shortcode — the feed
// preloads neighbouring reels, so an untagged list saves the wrong video.
(() => {
  if (window.__snagIgIntercept) return;
  window.__snagIgIntercept = true;

  const sent = new Set();
  const all = [];

  function emit(entries) {
    const fresh = entries.filter((e) => e.url && !sent.has(e.shortcode + e.url));
    fresh.forEach((e) => { sent.add(e.shortcode + e.url); all.push(e); });
    if (fresh.length) window.postMessage({ __snagIgVideos: fresh }, "*");
  }

  // Who posted each post and what it says, keyed by shortcode, so a save can
  // carry its caption and account into the item's note.
  const meta = new Map();

  function emitMeta(entries) {
    const fresh = [];
    for (const m of entries) {
      const had = meta.get(m.shortcode);
      // A later response can fill in what an earlier one left out.
      const moreSlides = (m.slides?.length || 0) > (had?.slides?.length || 0);
      if (had && (had.caption || !m.caption) && (had.user || !m.user) && !moreSlides) continue;
      const merged = { shortcode: m.shortcode, user: m.user || had?.user || "",
                       name: m.name || had?.name || "", avatar: m.avatar || had?.avatar || "",
                       caption: m.caption || had?.caption || "",
                       slides: moreSlides ? m.slides : (had?.slides || []) };
      meta.set(m.shortcode, merged);
      fresh.push(merged);
    }
    if (fresh.length) window.postMessage({ __snagIgMeta: fresh }, "*");
  }

  // The save button's script loads after the page is parsed, so it misses
  // what was announced before then (the video of a post opened directly).
  // It asks once it is listening, and gets everything found so far.
  window.addEventListener("message", (e) => {
    if (e.source === window && e.data && e.data.__snagIgReplay) {
      if (all.length) window.postMessage({ __snagIgVideos: all.slice() }, "*");
      if (meta.size) window.postMessage({ __snagIgMeta: [...meta.values()] }, "*");
    }
  });

  // Newer responses carry caption.text and user.username; older GraphQL
  // ones edge_media_to_caption and owner.username.
  function metaOf(node, code) {
    if (!code) return null;
    const caption = (node.caption && typeof node.caption.text === "string" && node.caption.text)
      || node.edge_media_to_caption?.edges?.[0]?.node?.text || "";
    const user = node.user?.username || node.owner?.username || "";
    const avatar = node.user?.hd_profile_pic_url_info?.url || node.user?.profile_pic_url
      || node.owner?.profile_pic_url || "";
    const name = node.user?.full_name || node.owner?.full_name || "";
    const slides = slidesOf(node);
    return caption || user || slides.length
      ? { shortcode: code, user, name, avatar, caption, slides } : null;
  }

  function bestImage(node) {
    const c = node.image_versions2?.candidates
      || (node.display_resources && node.display_resources.map((r) => ({
        url: r.src, width: r.config_width })))
      || [];
    const best = [...c].sort((a, b) => (b.width || 0) - (a.width || 0))[0];
    return (best && best.url) || node.display_url || null;
  }

  // Every slide of a carousel at full size, in order: newer responses list
  // them in carousel_media, older ones in edge_sidecar_to_children.
  function slidesOf(node) {
    const list = node.carousel_media
      || node.edge_sidecar_to_children?.edges?.map((e) => e.node) || [];
    const out = [];
    for (const s of list) {
      const video = pickURL(s);
      if (video) out.push({ kind: "video", url: video });
      else {
        const img = bestImage(s);
        if (img) out.push({ kind: "image", url: img });
      }
    }
    return out;
  }

  // Best-quality mp4 on a media node.
  function pickURL(node) {
    if (Array.isArray(node.video_versions) && node.video_versions.length) {
      const best = [...node.video_versions].sort(
        (a, b) => (b.width || 0) - (a.width || 0)
      )[0];
      if (best && best.url) return best.url;
    }
    if (typeof node.video_url === "string") return node.video_url;
    if (typeof node.playback_url === "string") return node.playback_url;
    return null;
  }

  // Walk a parsed response, pairing each video with the shortcode it belongs to.
  function walk(node, inheritedCode, out, depth, metas) {
    // A post page nests its own video about 15 levels down; 12 missed it.
    if (!node || typeof node !== "object" || depth > 40) return;
    if (Array.isArray(node)) {
      for (const child of node) walk(child, inheritedCode, out, depth + 1, metas);
      return;
    }
    // Only a post's own code describes it; an inherited one belongs to the
    // parent (a carousel slide has no caption of its own).
    const own = node.code || node.shortcode;
    const code = own || inheritedCode;
    const url = pickURL(node);
    if (url && code) out.push({ shortcode: code, url });
    else if (url) out.push({ shortcode: "", url });
    if (own && metas) {
      const m = metaOf(node, own);
      if (m) metas.push(m);
    }
    for (const key of Object.keys(node)) {
      const v = node[key];
      if (v && typeof v === "object") walk(v, code, out, depth + 1, metas);
    }
  }

  function harvest(text) {
    if (!text) return;
    const hasVideo = text.includes("video_versions") || text.includes("video_url")
      || text.includes("playback_url");
    const hasMeta = text.includes('"caption"') || text.includes("edge_media_to_caption")
      || text.includes("carousel_media") || text.includes("edge_sidecar_to_children");
    if (!hasVideo && !hasMeta) return;
    const out = [];
    const metas = [];
    try {
      walk(JSON.parse(text), "", out, 0, metas);
      emitMeta(metas);
    } catch (e) {
      if (!hasVideo) return;
      // Not pure JSON (inline script blob) — fall back to regex, still trying
      // to keep a nearby shortcode with each URL.
      const re = /"code"\s*:\s*"([A-Za-z0-9_-]+)"|"(?:video_url|playback_url)"\s*:\s*"([^"]+)"/g;
      let m, lastCode = "";
      while ((m = re.exec(text)) !== null) {
        if (m[1]) lastCode = m[1];
        else if (m[2]) {
          try { out.push({ shortcode: lastCode, url: JSON.parse('"' + m[2] + '"') }); }
          catch (err) { /* skip */ }
        }
      }
    }
    emit(out.filter((e) => e.url && e.url.startsWith("http")));
  }

  addEventListener("DOMContentLoaded", () => {
    for (const s of document.querySelectorAll("script")) harvest(s.textContent);
  });

  const origFetch = window.fetch;
  window.fetch = async function (...args) {
    const res = await origFetch.apply(this, args);
    try { res.clone().text().then(harvest).catch(() => {}); } catch (e) {}
    return res;
  };

  const origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function (...args) {
    this.addEventListener("load", () => {
      try { if (typeof this.responseText === "string") harvest(this.responseText); } catch (e) {}
    });
    return origSend.apply(this, args);
  };
})();
