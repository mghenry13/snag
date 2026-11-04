// Runs in the PAGE's world at document_start on X (Twitter).
// X plays video from blob: URLs and shows photos at reduced sizes, but its
// own GraphQL responses (timelines, tweet pages, profiles, search) describe
// every tweet's media in full: each video's MP4 variants with bitrates, and
// each photo's original. Read those as they arrive and hand them, keyed by
// tweet id, to the isolated content script (x.js).
(() => {
  if (window.__snagXIntercept) return;
  window.__snagXIntercept = true;

  const all = new Map(); // tweetId -> entry

  function emit(entries) {
    const fresh = [];
    for (const e of entries) {
      if (all.has(e.id)) continue;
      all.set(e.id, e);
      fresh.push(e);
    }
    if (fresh.length) window.postMessage({ __snagXTweets: fresh }, "*");
  }

  // x.js loads after the first responses (a tweet opened directly), so it
  // asks once it is listening and gets everything seen so far.
  window.addEventListener("message", (e) => {
    if (e.source === window && e.data && e.data.__snagXReplay && all.size) {
      window.postMessage({ __snagXTweets: [...all.values()] }, "*");
    }
  });

  function bestVideo(media) {
    const variants = (media.video_info && media.video_info.variants) || [];
    const mp4s = variants.filter((v) => v.content_type === "video/mp4" && v.url);
    if (!mp4s.length) return null;
    mp4s.sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0));
    return mp4s[0].url;
  }

  // name=orig is the uploaded original; the page shows "small" or "medium".
  function bestPhoto(media) {
    const base = media.media_url_https || media.media_url;
    if (!base) return null;
    return base.split("?")[0] + "?name=orig";
  }

  function mediaOf(legacy) {
    const list = (legacy.extended_entities && legacy.extended_entities.media)
      || (legacy.entities && legacy.entities.media) || [];
    const out = [];
    for (const m of list) {
      if (m.type === "video" || m.type === "animated_gif") {
        const url = bestVideo(m);
        if (url) out.push({ kind: "video", url });
      } else if (m.type === "photo") {
        const url = bestPhoto(m);
        if (url) out.push({ kind: "image", url });
      }
    }
    return out;
  }

  function displayName(tweet) {
    const u = tweet.core && tweet.core.user_results && tweet.core.user_results.result;
    return (u && ((u.core && u.core.name) || (u.legacy && u.legacy.name))) || "";
  }

  // X serves 48px "_normal" avatars; the same picture exists at 400px.
  function avatarOf(tweet) {
    const u = tweet.core && tweet.core.user_results && tweet.core.user_results.result;
    const raw = u && ((u.avatar && u.avatar.image_url) || (u.legacy && u.legacy.profile_image_url_https));
    return raw ? raw.replace(/_normal(\.\w+)$/, "_400x400$1") : "";
  }

  function screenName(tweet) {
    const u = tweet.core && tweet.core.user_results && tweet.core.user_results.result;
    if (!u) return "";
    return (u.core && u.core.screen_name) || (u.legacy && u.legacy.screen_name) || "";
  }

  // Tweets sit at varying depths (timeline entries, conversation threads,
  // quoted and retweeted tweets inside others). Any object with a rest_id
  // and a legacy block carrying media is one.
  function walk(node, out, depth) {
    if (!node || typeof node !== "object" || depth > 60) return;
    if (Array.isArray(node)) {
      for (const child of node) walk(child, out, depth + 1);
      return;
    }
    if (typeof node.rest_id === "string" && node.legacy && typeof node.legacy === "object") {
      const media = mediaOf(node.legacy);
      if (media.length) {
        out.push({
          id: node.rest_id,
          user: screenName(node),
          name: displayName(node),
          avatar: avatarOf(node),
          text: (node.legacy.full_text || "").replace(/\s*https:\/\/t\.co\/\S+$/g, "").trim(),
          media,
        });
      }
    }
    for (const key of Object.keys(node)) {
      const v = node[key];
      if (v && typeof v === "object") walk(v, out, depth + 1);
    }
  }

  function harvest(text) {
    if (!text || !text.includes('"extended_entities"') && !text.includes('"media_url_https"')) return;
    const out = [];
    try { walk(JSON.parse(text), out, 0); } catch (e) { return; }
    emit(out);
  }

  const isGraphQL = (u) => /\/graphql\/[^/]+\/[A-Za-z]+/.test(String(u || ""));

  const origFetch = window.fetch;
  window.fetch = async function (...args) {
    const res = await origFetch.apply(this, args);
    try {
      const u = args[0] && (args[0].url || args[0]);
      if (isGraphQL(u)) res.clone().text().then(harvest).catch(() => {});
    } catch (e) {}
    return res;
  };

  const origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    if (isGraphQL(url)) {
      this.addEventListener("load", () => {
        try {
          if (this.status === 200 && (this.responseType === "" || this.responseType === "text")) {
            harvest(this.responseText);
          }
        } catch (e) {}
      });
    }
    return origOpen.call(this, method, url, ...rest);
  };
})();
