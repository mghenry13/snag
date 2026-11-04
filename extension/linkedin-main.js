// Runs in the PAGE's world on LinkedIn. The 2026 feed renders posts on the
// server with randomised class names and no post id anywhere in the markup;
// the id survives only in React's props (the like button is bound to
// "reactionState-urn:li:activity:<id>"). Read it from there and write it onto
// the post as data-snag-urn, where the isolated content script (linkedin.js)
// can see it.
(() => {
  if (window.__snagLinkedInMain) return;
  window.__snagLinkedInMain = true;

  const URN = /urn:li:(?:activity|ugcPost|share):\d+/;

  function props(fiber) {
    try {
      return JSON.stringify(fiber.memoizedProps, (k, v) =>
        k === "children" || k === "_owner" || typeof v === "function" || (v && v.nodeType)
          ? undefined : v) || "";
    } catch (e) { return ""; }
  }

  // A video post's like button is bound to its ugcPost id and its activity
  // id at different depths. Prefer the activity id: it is the one the
  // post's public link uses, and the only one yt-dlp accepts.
  function urnFrom(el) {
    const key = Object.keys(el).find((k) => k.startsWith("__reactFiber$"));
    let f = key && el[key];
    let other = null;
    for (let i = 0; f && i < 20; i++, f = f.return) {
      const s = props(f);
      const act = s.match(/urn:li:activity:\d+/);
      if (act) return act[0];
      if (!other) { const m = s.match(URN); if (m) other = m[0]; }
    }
    return other;
  }

  function tag() {
    for (const card of document.querySelectorAll('[role="listitem"][componentkey^="update-card"]:not([data-snag-urn])')) {
      // Every post has one reaction button; ads and suggestions have none.
      const like = [...card.querySelectorAll("button")]
        .find((b) => /^Reaction button state/.test(b.getAttribute("aria-label") || ""));
      const urn = like && urnFrom(like);
      card.setAttribute("data-snag-urn", urn || "");
    }
  }

  new MutationObserver(tag).observe(document.documentElement, { childList: true, subtree: true });
  setInterval(tag, 1500);
})();
