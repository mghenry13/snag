// Snag on Facebook: a "Snag" button next to Share on every post with photos
// or video. It saves the post's media at full size (video as its HD MP4) with
// the post's link, author and text as the item's note, from what
// fb-intercept.js read out of Facebook's own data. Facebook's class names are
// randomised, so posts are found by their "Actions for this post" menu.
(() => {
  if (window.__snagFb || location.pathname.startsWith("/ads/library")) return;
  window.__snagFb = true;

  const stories = new Map();
  window.addEventListener("message", (e) => {
    if (e.source !== window || !e.data || !e.data.__snagFbStories) return;
    for (const s of e.data.__snagFbStories) stories.set(s.id, s);
  });
  window.postMessage({ __snagFbReplay: true }, "*");

  const MENU = '[aria-label^="Actions for this post"]';
  const label = (el) => (el.getAttribute("aria-label") || "").trim();
  const fileOf = (u) => { try { return new URL(u).pathname.split("/").pop(); } catch (e) { return ""; } };
  const norm = (s) => (s || "").replace(/\s+/g, " ").trim();

  // The largest element around a post's menu that holds no other post.
  function postOf(menu) {
    let el = menu, best = menu;
    for (let i = 0; el && i < 40; i++, el = el.parentElement) {
      if (el.querySelectorAll(MENU).length > 1) break;
      best = el;
    }
    return best;
  }

  const authorOnMenu = (post) =>
    (label(post.querySelector(MENU) || document.body).match(/^Actions for this post by (.+)$/) || [])[1] || "";

  // Photos as shown, for a post whose data had none: big fbcdn images only,
  // which leaves out avatars and reaction icons.
  function pagePhotos(post) {
    const out = [];
    for (const img of post.querySelectorAll("img")) {
      const src = img.currentSrc || img.src || "";
      if (!/fbcdn\.net|scontent/.test(src)) continue;
      if ((img.naturalWidth || 0) < 300 || (img.naturalHeight || 0) < 200) continue;
      if (!out.includes(src)) out.push(src);
    }
    return out;
  }

  // Which story this post is: a shared photo file first, then the post's
  // opening words, then an author with only one post on the page.
  function storyOf(post) {
    const all = [...stories.values()];
    const files = new Set([...post.querySelectorAll("img")].map((i) => fileOf(i.currentSrc || i.src)));
    let hit = all.find((s) => s.photos.some((u) => files.has(fileOf(u))));
    if (hit) return hit;
    const text = norm(post.innerText);
    hit = all.find((s) => s.text && norm(s.text).length >= 12 && text.includes(norm(s.text).slice(0, 50)));
    if (hit) return hit;
    const author = authorOnMenu(post);
    const theirs = author ? all.filter((s) => s.author === author) : [];
    return theirs.length === 1 ? theirs[0] : null;
  }

  function noteFor(s, post) {
    const author = (s && s.author) || authorOnMenu(post);
    const who = author ? `— ${author}${s && s.authorUrl ? ` (${s.authorUrl})` : ""}` : "";
    return [s && s.text, who, s && s.url].filter(Boolean).join("\n\n");
  }

  // facebook.com/movieweb → movieweb; profile.php?id=123 → 123.
  function accountFor(s, post) {
    const name = (s && s.author) || authorOnMenu(post);
    const url = (s && s.authorUrl) || "";
    let handle = "";
    try {
      const u = new URL(url);
      handle = u.searchParams.get("id") || u.pathname.split("/").filter(Boolean).pop() || "";
    } catch (e) {}
    if (!name && !handle) return null;
    return { platform: "facebook", handle: handle || name, name, url: url || null,
             avatar: (s && s.authorPic) || "" };
  }

  function nameFor(s, post, index, count) {
    const author = (s && s.author) || authorOnMenu(post) || "Facebook";
    const text = norm(s && s.text).slice(0, 60);
    const base = text ? `${author} — ${text}` : author;
    return count > 1 ? `${base} (${index + 1})` : base;
  }

  const extOf = (u) => {
    const m = (u.split("?")[0].match(/\.(jpe?g|png|webp|gif)$/i) || [])[1];
    return m ? (m.toLowerCase() === "jpeg" ? "jpg" : m.toLowerCase()) : "jpg";
  };

  async function save(post, btn) {
    const s = storyOf(post);
    const note = noteFor(s, post);
    const link = (s && s.url) || location.href;
    const isVideo = (s && s.hasVideo) || !!post.querySelector("video");
    flash(btn, "Saving…");
    try {
      let reply;
      if (isVideo && s && s.video) {
        reply = await chrome.runtime.sendMessage({
          type: "save-remote", pageURL: link, note, account: accountFor(s, post),
          items: [{ url: s.video, ext: "mp4", name: nameFor(s, post, 0, 1) }],
        });
      } else if (isVideo) {
        // No file in the data (yet): let the app try the post link.
        if (!s || !s.url) { flash(btn, "Play it, then save", true); return; }
        reply = await chrome.runtime.sendMessage({ type: "save-url", url: s.url, pageURL: s.url, note, account: accountFor(s, post) });
      } else {
        const photos = (s && s.photos.length) ? s.photos : pagePhotos(post);
        if (!photos.length) { flash(btn, "Nothing to save", true); return; }
        reply = await chrome.runtime.sendMessage({
          type: "save-remote", pageURL: link, note, account: accountFor(s, post),
          items: photos.map((u, i) => ({ url: u, ext: extOf(u), name: nameFor(s, post, i, photos.length) })),
        });
      }
      if (!reply || !reply.ok) { flash(btn, "Failed", true); return; }
      flash(btn, reply.duplicate ? "Already saved" : "Saved ✓");
    } catch (e) {
      flash(btn, "Failed", true);
    }
  }

  function flash(btn, text, bad) {
    btn.textContent = text;
    btn.style.color = bad ? "#e41e3f" : text === "Saving…" ? "#0866ff" : "#31a24c";
    if (text !== "Saving…") setTimeout(() => { btn.textContent = "Snag"; btn.style.color = ""; }, 1900);
  }

  // The row with React and Share: the first ancestor of Share that also
  // holds the reaction button.
  function actionRow(post) {
    const share = [...post.querySelectorAll('[role="button"][aria-label^="Share"]')].pop();
    if (!share) return null;
    const react = post.querySelector('[role="button"][aria-label^="React"], [role="button"][aria-label^="Like"]');
    let row = share.parentElement;
    while (row && row !== post && !(react && row.contains(react))) row = row.parentElement;
    return row && row !== post ? row : share.parentElement;
  }

  const hasMedia = (post) => !!post.querySelector("video") || pagePhotos(post).length > 0;

  function addButton(menu) {
    const post = postOf(menu);
    if (post.__snagFb || !hasMedia(post)) return;
    const row = actionRow(post);
    if (!row) return;
    post.__snagFb = true;
    const btn = document.createElement("div");
    btn.setAttribute("role", "button");
    btn.tabIndex = 0;
    btn.textContent = "Snag";
    btn.title = "Save to Snag";
    Object.assign(btn.style, {
      cursor: "pointer", padding: "0 12px", display: "flex", alignItems: "center",
      font: "600 15px -apple-system, system-ui, sans-serif", color: "#65686c",
      minHeight: "36px", flex: "0 0 auto", userSelect: "none",
    });
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      save(post, btn);
    }, true);
    row.appendChild(btn);
  }

  function scan() {
    for (const menu of document.querySelectorAll(MENU)) addButton(menu);
  }

  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
  setInterval(scan, 1500);
  scan();
})();
