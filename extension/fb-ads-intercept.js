// Runs in the PAGE's world at document_start on the Meta Ad Library.
// Wraps fetch/XHR and harvests video URLs from GraphQL responses, then
// hands them to the isolated content script via postMessage.
(() => {
  if (window.__snagIntercept) return;
  window.__snagIntercept = true;

  const seen = new Set();

  function harvestVideos(text) {
    if (!text || (!text.includes("playable_url") && !text.includes("video_sd_url"))) return;
    const entries = [];

    // Pattern A: ad library snapshots — video_{sd,hd}_url + preview image
    const reA = /"video_sd_url":"([^"]*)","video_hd_url":"([^"]*)"(?:,"[^"]+":"[^"]*")*?,"video_preview_image_url":"([^"]*)"/g;
    let m;
    while ((m = reA.exec(text)) !== null) {
      entries.push({ sd: m[1], hd: m[2], poster: m[3] });
    }
    // Pattern A2: fields in other orders — do a loose pass
    if (entries.length === 0 && text.includes("video_preview_image_url")) {
      const sds = [...text.matchAll(/"video_sd_url":"([^"]*)"/g)].map((x) => x[1]);
      const hds = [...text.matchAll(/"video_hd_url":"([^"]*)"/g)].map((x) => x[1]);
      const posters = [...text.matchAll(/"video_preview_image_url":"([^"]*)"/g)].map((x) => x[1]);
      for (let i = 0; i < Math.max(sds.length, hds.length); i++) {
        entries.push({ sd: sds[i] || "", hd: hds[i] || "", poster: posters[i] || "" });
      }
    }
    // Pattern B: generic playable_url pairs
    const reB = /"playable_url":"([^"]*)"|"playable_url_quality_hd":"([^"]*)"/g;
    let last = null;
    while ((m = reB.exec(text)) !== null) {
      if (m[1]) {
        last = { sd: m[1], hd: "", poster: "" };
        entries.push(last);
      } else if (m[2] && last) {
        last.hd = m[2];
      }
    }

    const decoded = [];
    for (const e of entries) {
      try {
        const video = JSON.parse('"' + (e.hd || e.sd) + '"');
        if (!video || !video.startsWith("http") || seen.has(video)) continue;
        seen.add(video);
        decoded.push({
          video,
          poster: e.poster ? JSON.parse('"' + e.poster + '"') : "",
        });
      } catch (err) { /* skip malformed */ }
    }
    if (decoded.length) {
      window.postMessage({ __snagVideos: decoded }, "*");
    }
  }

  // Image ads: each card shows Facebook's 600px "resized_image_url" preview,
  // while the same image object carries the full-size "original_image_url"
  // (for example 1152x2048 against 338x600). Pair them so a save gets the
  // original, keyed by the preview the card actually displays.
  const seenImages = new Set();
  function harvestImages(text) {
    if (!text || !text.includes("original_image_url")) return;
    const dec = (r) => { try { return JSON.parse('"' + r + '"'); } catch (e) { return null; } };
    const pairs = [];
    for (const m of text.matchAll(/\{[^{}]*"original_image_url":"[^"]+"[^{}]*\}/g)) {
      const o = m[0];
      const orig = dec((o.match(/"original_image_url":"([^"]+)"/) || [])[1] || "");
      const rez = dec((o.match(/"resized_image_url":"([^"]+)"/) || [])[1] || "");
      if (orig && rez && !seenImages.has(rez)) { seenImages.add(rez); pairs.push({ orig, rez }); }
    }
    if (pairs.length) window.postMessage({ __snagImages: pairs }, "*");
  }

  // Who ran each ad and what it said, keyed by Library ID: the advertiser
  // (the page paying for it), the page it is shown as when that differs
  // (creator and branded ads), its text, headline, call to action and link,
  // its format and when it ran.
  const seenAds = new Set();
  function adsIn(n, out, d) {
    if (!n || typeof n !== "object" || d > 80) return;
    if (Array.isArray(n)) { n.forEach((c) => adsIn(c, out, d + 1)); return; }
    if (n.ad_archive_id && n.snapshot && typeof n.snapshot === "object") {
      const s = n.snapshot;
      const card = (s.cards && s.cards[0]) || {};
      const text = (v) => (v && typeof v === "object" ? v.text : v) || "";
      out.push({
        id: String(n.ad_archive_id),
        advertiser: n.page_name || s.page_name || "",
        advertiserId: String(n.page_id || s.page_id || ""),
        shownAs: s.page_name || "",
        shownAsURL: s.page_profile_uri || "",
        shownAsPic: s.page_profile_picture_url || "",
        body: text(s.body) || text(card.body),
        title: s.title || card.title || "",
        caption: s.caption || card.caption || "",
        linkDescription: s.link_description || card.link_description || "",
        ctaText: s.cta_text || card.cta_text || "",
        ctaType: s.cta_type || card.cta_type || "",
        link: s.link_url || card.link_url || "",
        format: s.display_format || "",
        start: n.start_date || null,
        end: n.end_date || null,
        platforms: n.publisher_platform || [],
      });
      return;
    }
    for (const k of Object.keys(n)) adsIn(n[k], out, d + 1);
  }

  function harvestAds(text) {
    if (!text || !text.includes("ad_archive_id")) return;
    const out = [];
    for (let line of text.split("\n")) {
      line = line.replace(/^for \(;;\);/, "").trim();
      if (!line || (line[0] !== "{" && line[0] !== "[")) continue;
      try { adsIn(JSON.parse(line), out, 0); } catch (e) {}
    }
    const fresh = out.filter((a) => !seenAds.has(a.id));
    fresh.forEach((a) => seenAds.add(a.id));
    if (fresh.length) window.postMessage({ __snagAds: fresh }, "*");
  }

  // fb-ads.js may start after the first ads arrived; it asks for a replay.
  const allAds = [];
  window.addEventListener("message", (e) => {
    if (e.source === window && e.data && e.data.__snagAds && !e.data.__replay) allAds.push(...e.data.__snagAds);
    if (e.source === window && e.data && e.data.__snagAdsReplay && allAds.length) {
      window.postMessage({ __snagAds: allAds.slice(), __replay: true }, "*");
    }
  });

  function harvest(text) {
    harvestVideos(text);
    harvestImages(text);
    harvestAds(text);
  }

  // initial server-rendered scripts
  addEventListener("DOMContentLoaded", () => {
    for (const s of document.querySelectorAll("script")) harvest(s.textContent);
  });

  const origFetch = window.fetch;
  window.fetch = async function (...args) {
    const res = await origFetch.apply(this, args);
    try {
      res.clone().text().then(harvest).catch(() => {});
    } catch (e) { /* opaque */ }
    return res;
  };

  const origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function (...args) {
    this.addEventListener("load", () => {
      try {
        if (typeof this.responseText === "string") harvest(this.responseText);
      } catch (e) { /* non-text */ }
    });
    return origSend.apply(this, args);
  };
})();
