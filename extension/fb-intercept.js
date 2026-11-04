// Runs in the PAGE's world at document_start on Facebook (not the Ad Library,
// which has its own scripts). Facebook strips React's internals from the page
// and scrambles post links until hovered, so the post data comes from its own
// payloads instead: the JSON blobs in the first page and the /api/graphql/
// responses that load more as you scroll. Each Story there carries its id,
// link, author, text, full-size photos and, for video, complete MP4s with
// sound (progressive_urls, HD and SD). Hand them to fb.js.
(() => {
  if (window.__snagFbIntercept || location.pathname.startsWith("/ads/library")) return;
  window.__snagFbIntercept = true;

  const stories = new Map(); // post_id -> story

  function send(list) {
    if (list.length) window.postMessage({ __snagFbStories: list }, "*");
  }
  window.addEventListener("message", (e) => {
    if (e.source === window && e.data && e.data.__snagFbReplay) send([...stories.values()]);
  });

  const fileOf = (u) => { try { return new URL(u).pathname.split("/").pop(); } catch (e) { return ""; } };

  // Tracking parameters make every copy of a link different; permalink.php
  // needs its own story_fbid and id.
  function cleanURL(u) {
    try {
      const url = new URL(u);
      for (const k of [...url.searchParams.keys()]) {
        if (!["story_fbid", "id", "v", "fbid", "set"].includes(k)) url.searchParams.delete(k);
      }
      return url.toString();
    } catch (e) { return u || ""; }
  }

  // The post's own words; a shared post's text sits under attached_story.
  function firstText(o, d) {
    if (!o || typeof o !== "object" || d > 30) return "";
    if (Array.isArray(o)) {
      for (const c of o) { const t = firstText(c, d + 1); if (t) return t; }
      return "";
    }
    if (o.message && typeof o.message.text === "string" && o.message.text) return o.message.text;
    for (const k of Object.keys(o)) {
      if (k === "attached_story" || k === "feedback") continue;
      const t = firstText(o[k], d + 1);
      if (t) return t;
    }
    return "";
  }

  function bestVideo(list) {
    const ok = list.filter((p) => p && typeof p.progressive_url === "string" && p.progressive_url);
    const hd = ok.find((p) => p.metadata && p.metadata.quality === "HD");
    return (hd || ok[0] || {}).progressive_url || null;
  }

  // Photos and video anywhere inside one story.
  function mediaOf(o, out, d) {
    if (!o || typeof o !== "object" || d > 60) return;
    if (Array.isArray(o)) { o.forEach((c) => mediaOf(c, out, d + 1)); return; }
    if (o.__typename === "Video") out.hasVideo = true;
    if (Array.isArray(o.progressive_urls) && !out.video) out.video = bestVideo(o.progressive_urls);
    if (o.__typename === "Photo") {
      for (const key of ["viewer_image", "photo_image", "image"]) {
        const im = o[key];
        if (im && typeof im.uri === "string") {
          const f = fileOf(im.uri);
          const had = out.photos.get(f);
          if (!had || (im.width || 0) > had.w) out.photos.set(f, { uri: im.uri, w: im.width || 0 });
        }
      }
    }
    for (const k of Object.keys(o)) {
      if (k === "feedback" || k === "actors") continue;
      mediaOf(o[k], out, d + 1);
    }
  }

  // The author's picture: the object in the story that is the actor itself.
  function pictureOf(o, actorId, d) {
    if (!o || typeof o !== "object" || d > 40 || !actorId) return "";
    if (Array.isArray(o)) {
      for (const c of o) { const p = pictureOf(c, actorId, d + 1); if (p) return p; }
      return "";
    }
    if (o.id === actorId && o.profile_picture && typeof o.profile_picture.uri === "string") return o.profile_picture.uri;
    for (const k of Object.keys(o)) {
      if (k === "attachments" || k === "feedback") continue;
      const p = pictureOf(o[k], actorId, d + 1);
      if (p) return p;
    }
    return "";
  }

  function collect(n, d, fresh) {
    if (!n || typeof n !== "object" || d > 100) return;
    if (Array.isArray(n)) { n.forEach((c) => collect(c, d + 1, fresh)); return; }
    if (n.__typename === "Story" && n.post_id && (n.permalink_url || n.actors || n.attachments)) {
      const m = { hasVideo: false, video: null, photos: new Map() };
      mediaOf(n.attachments, m, 0);
      if (!m.video) mediaOf(n.comet_sections, m, 0);
      const actor = (n.actors || [])[0] || {};
      const prev = stories.get(n.post_id) || {};
      const next = {
        id: n.post_id,
        url: prev.url || (n.permalink_url ? cleanURL(n.permalink_url) : ""),
        author: prev.author || actor.name || "",
        authorUrl: prev.authorUrl || (actor.url ? cleanURL(actor.url) : ""),
        authorPic: prev.authorPic || pictureOf(n.comet_sections || n, actor.id, 0),
        text: prev.text || firstText(n.comet_sections || n, 0),
        hasVideo: prev.hasVideo || m.hasVideo,
        video: prev.video || m.video,
        photos: (prev.photos && prev.photos.length) ? prev.photos : [...m.photos.values()].map((p) => p.uri),
      };
      const changed = JSON.stringify(next) !== JSON.stringify(stories.get(n.post_id) || null);
      stories.set(n.post_id, next);
      if (changed) fresh.push(next);
    }
    for (const k of Object.keys(n)) collect(n[k], d + 1, fresh);
  }

  function harvest(text) {
    if (!text || !text.includes('"Story"')) return;
    const fresh = [];
    // GraphQL answers stream several JSON documents, one per line.
    for (let line of text.split("\n")) {
      line = line.replace(/^for \(;;\);/, "").trim();
      if (!line) continue;
      try { collect(JSON.parse(line), 0, fresh); } catch (e) {}
    }
    send(fresh);
  }

  const seenScripts = new WeakSet();
  function scanScripts() {
    for (const s of document.querySelectorAll('script[type="application/json"]')) {
      if (seenScripts.has(s)) continue;
      seenScripts.add(s);
      harvest(s.textContent);
    }
  }
  document.addEventListener("DOMContentLoaded", scanScripts);
  addEventListener("load", scanScripts);
  setTimeout(scanScripts, 3000);

  const isGraphQL = (u) => /\/api\/graphql\//.test(String(u || ""));

  const origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    if (isGraphQL(url)) {
      this.addEventListener("load", () => {
        try {
          if (this.responseType === "" || this.responseType === "text") harvest(this.responseText);
        } catch (e) {}
      });
    }
    return origOpen.call(this, method, url, ...rest);
  };

  const origFetch = window.fetch;
  window.fetch = async function (...args) {
    const res = await origFetch.apply(this, args);
    try {
      const u = args[0] && (args[0].url || args[0]);
      if (isGraphQL(u)) res.clone().text().then(harvest).catch(() => {});
    } catch (e) {}
    return res;
  };
})();
