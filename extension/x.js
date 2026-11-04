// Snag on X (Twitter): a "Snag" button in the action bar of every tweet with
// photos or video. It saves the tweet's media at full quality from what
// x-intercept.js read out of X's own responses. A tweet it has no record of
// goes to the Snag app by its link instead, which downloads it with yt-dlp
// signed in through the browser chosen in Snag's settings.
(() => {
  if (window.__snagX) return;
  window.__snagX = true;

  const tweets = new Map(); // id -> {id, user, text, media:[{kind,url}]}
  window.addEventListener("message", (e) => {
    if (e.source !== window || !e.data || !e.data.__snagXTweets) return;
    for (const t of e.data.__snagXTweets) tweets.set(t.id, t);
  });
  window.postMessage({ __snagXReplay: true }, "*");

  // The tweet's own id: the status link around its timestamp. A quoted tweet
  // has its own timestamp further down, so take the first one.
  function tweetIdOf(article) {
    const a = article.querySelector('a[href*="/status/"] time')?.closest("a");
    const m = a && a.getAttribute("href").match(/\/([A-Za-z0-9_]+)\/status\/(\d+)/);
    return m ? { user: m[1], id: m[2] } : null;
  }

  function hasMedia(article) {
    return !!article.querySelector('[data-testid="tweetPhoto"], [data-testid="videoPlayer"], video');
  }

  function nameFor(t, ref, index, count) {
    const who = (t && t.user) || (ref && ref.user) || "X";
    const text = ((t && t.text) || "").replace(/\s+/g, " ").slice(0, 60).trim();
    const base = text ? `@${who} — ${text}` : `@${who} — ${ref ? ref.id : "post"}`;
    return count > 1 ? `${base} (${index + 1})` : base;
  }

  function accountFor(t, ref) {
    const handle = (t && t.user) || (ref && ref.user) || "";
    return handle ? { platform: "x", handle, name: (t && t.name) || "", url: `https://x.com/${handle}`,
                      avatar: (t && t.avatar) || "" } : null;
  }

  function extOf(item) {
    if (item.kind === "video") return "mp4";
    const m = item.url.split("?")[0].match(/\.(jpe?g|png|webp|gif)$/i);
    return m ? (m[1].toLowerCase() === "jpeg" ? "jpg" : m[1].toLowerCase()) : "jpg";
  }

  async function save(article, btn) {
    const ref = tweetIdOf(article);
    if (!ref) { flash(btn, "No link", true); return; }
    const link = `https://x.com/${ref.user}/status/${ref.id}`;
    const t = tweets.get(ref.id);
    flash(btn, "Saving…");
    try {
      let reply;
      if (t && t.media.length) {
        reply = await chrome.runtime.sendMessage({
          type: "save-remote",
          pageURL: link,
          note: [t.text, `— @${t.user || ref.user}`, link].filter(Boolean).join("\n\n"),
          account: accountFor(t, ref),
          items: t.media.map((m, i) => ({
            url: m.url, ext: extOf(m), name: nameFor(t, ref, i, t.media.length),
          })),
        });
      } else {
        // Never seen this tweet's data (rare): let the app fetch the post.
        reply = await chrome.runtime.sendMessage({ type: "save-url", url: link, pageURL: link, account: accountFor(t, ref) });
      }
      if (!reply || !reply.ok) { flash(btn, "Failed", true); return; }
      flash(btn, reply.duplicate ? "Already saved" : "Saved ✓");
    } catch (e) {
      flash(btn, "Failed", true);
    }
  }

  function flash(btn, text, bad) {
    btn.textContent = text;
    btn.style.color = bad ? "rgb(244,33,46)" : text === "Saving…" ? "rgb(29,155,240)" : "rgb(0,186,124)";
    if (text !== "Saving…") {
      setTimeout(() => { btn.textContent = "Snag"; btn.style.color = ""; }, 1900);
    }
  }

  function addButton(article) {
    if (article.__snagX || !hasMedia(article)) return;
    const bar = article.querySelector('[role="group"]');
    if (!bar) return;
    article.__snagX = true;
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = "Snag";
    btn.title = "Save to Snag";
    Object.assign(btn.style, {
      background: "none", border: "none", cursor: "pointer", padding: "0 8px",
      font: "600 13px -apple-system, system-ui, sans-serif",
      color: "rgb(113,118,123)", alignSelf: "center",
    });
    btn.addEventListener("mouseenter", () => { if (btn.textContent === "Snag") btn.style.color = "rgb(29,155,240)"; });
    btn.addEventListener("mouseleave", () => { if (btn.textContent === "Snag") btn.style.color = ""; });
    btn.addEventListener("click", (e) => {
      // The whole tweet is a link to the tweet page; don't navigate.
      e.preventDefault();
      e.stopPropagation();
      save(article, btn);
    }, true);
    bar.appendChild(btn);
  }

  function scan() {
    for (const a of document.querySelectorAll('article[data-testid="tweet"]')) addButton(a);
  }

  // X re-renders tweets as you scroll, and photos load in after the article.
  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
  setInterval(scan, 1000);
  scan();
})();
