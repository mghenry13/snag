// Snag on LinkedIn: a "Snag" button next to Repost on every post with photos
// or video. It saves the post's media with its link, author and text as the
// item's note. LinkedIn's class names are randomised, so posts and controls
// are found by role and accessible label; the post id comes from
// linkedin-main.js, which reads it out of React (data-snag-urn).
(() => {
  if (window.__snagLinkedIn) return;
  window.__snagLinkedIn = true;

  const CARDS = '[role="listitem"][componentkey^="update-card"]';

  const label = (el) => (el.getAttribute("aria-label") || el.innerText || "").trim();

  function linkOf(card) {
    const urn = card.getAttribute("data-snag-urn");
    return urn ? `https://www.linkedin.com/feed/update/${urn}/` : "";
  }

  // The poster, not whoever liked or commented on it (their name heads the
  // card too). The post's own controls name its author.
  function authorOf(card) {
    let name = "";
    for (const b of card.querySelectorAll("button")) {
      const m = label(b).match(/^(?:Open control menu for post by|Hide post by|Follow)\s+(.+)$/);
      if (m) { name = m[1].trim(); break; }
    }
    let profile = "";
    for (const a of card.querySelectorAll('a[href*="/in/"], a[href*="/company/"], a[href*="/school/"]')) {
      const text = label(a);
      if (!name || text.includes(name)) {
        try { profile = `https://www.linkedin.com${new URL(a.href).pathname.replace(/\/$/, "")}/`; } catch (e) {}
        if (!name) name = text.replace(/^View\s+|[’']s?\s+profile$/g, "").trim();
        break;
      }
    }
    return { name, profile };
  }

  function textOf(card) {
    const el = card.querySelector('[data-testid="expandable-text-box"]');
    return (el ? el.innerText : "").replace(/\s*…\s*more\s*$/i, "").trim();
  }

  // The post's own photos. Avatars, logos, link previews and video posters
  // are LinkedIn images too; their paths say which they are.
  function imagesOf(card) {
    const out = [];
    for (const img of card.querySelectorAll("img")) {
      const src = img.currentSrc || img.src || "";
      if (!/media\.licdn\.com\/dms\/image/.test(src)) continue;
      if (/profile-|company-logo|school-logo|videocover|articleshare|-displayphoto/.test(src)) continue;
      if ((img.naturalWidth || 0) < 200 || (img.naturalHeight || 0) < 150) continue;
      if (!out.includes(src)) out.push(src);
    }
    return out;
  }

  const hasVideo = (card) => !!card.querySelector("video");

  function noteFor(card, link) {
    const { name, profile } = authorOf(card);
    const who = name ? `— ${name}${profile ? ` (${profile})` : ""}` : "";
    return [textOf(card), who, link].filter(Boolean).join("\n\n");
  }

  function accountFor(card) {
    const { name, profile } = authorOf(card);
    if (!name && !profile) return null;
    // /in/jane-doe/ or /company/acme/: the slug is the stable handle.
    const slug = (profile.match(/\/(?:in|company|school)\/([^/]+)/) || [])[1] || "";
    const pic = [...card.querySelectorAll("img")].find((i) => {
      const src = i.currentSrc || i.src || "";
      return /profile-displayphoto|company-logo|school-logo/.test(src)
        && (!name || (i.alt || "").includes(name));
    });
    return { platform: "linkedin", handle: slug || name, name, url: profile || null,
             avatar: pic ? (pic.currentSrc || pic.src) : "" };
  }

  function nameFor(card, index, count) {
    const { name } = authorOf(card);
    const text = textOf(card).replace(/\s+/g, " ").slice(0, 60).trim();
    const base = [name || "LinkedIn", text].filter(Boolean).join(" — ");
    return count > 1 ? `${base} (${index + 1})` : base;
  }

  async function save(card, btn) {
    const link = linkOf(card);
    const note = noteFor(card, link);
    flash(btn, "Saving…");
    try {
      let reply;
      if (hasVideo(card)) {
        // LinkedIn streams video in pieces; there is no file on the page.
        // The app downloads the post with yt-dlp, signed in through the
        // browser set in Snag's settings.
        if (!link) { flash(btn, "No link", true); return; }
        reply = await chrome.runtime.sendMessage({ type: "save-url", url: link, pageURL: link, note, account: accountFor(card) });
      } else {
        const images = imagesOf(card);
        if (!images.length) { flash(btn, "Nothing to save", true); return; }
        reply = await chrome.runtime.sendMessage({
          type: "save-remote", pageURL: link || location.href, note, account: accountFor(card),
          items: images.map((url, i) => ({ url, ext: "jpg", name: nameFor(card, i, images.length) })),
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
    btn.style.color = bad ? "#cc1016" : text === "Saving…" ? "#0a66c2" : "#057642";
    if (text !== "Saving…") setTimeout(() => { btn.textContent = "Snag"; btn.style.color = ""; }, 1900);
  }

  // The row holding Comment and Repost: the first ancestor of Repost that
  // also contains Comment.
  function actionRow(card) {
    const buttons = [...card.querySelectorAll("button")];
    const repost = buttons.find((b) => label(b) === "Repost");
    const comment = buttons.find((b) => label(b) === "Comment");
    if (!repost) return null;
    let row = repost.parentElement;
    while (row && row !== card && !(comment && row.contains(comment))) row = row.parentElement;
    return row && row !== card ? row : repost.parentElement;
  }

  function addButton(card) {
    if (card.__snagLi) return;
    if (!hasVideo(card) && !imagesOf(card).length) return;
    const row = actionRow(card);
    if (!row) return;
    card.__snagLi = true;
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = "Snag";
    btn.title = "Save to Snag";
    Object.assign(btn.style, {
      background: "none", border: "none", cursor: "pointer", padding: "0 12px",
      font: "600 14px -apple-system, system-ui, sans-serif", color: "rgba(0,0,0,.6)",
      alignSelf: "center", minHeight: "40px", flex: "0 0 auto",
    });
    btn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      save(card, btn);
    }, true);
    row.appendChild(btn);
  }

  function scan() {
    for (const card of document.querySelectorAll(CARDS)) addButton(card);
  }

  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
  setInterval(scan, 1500);
  scan();
})();
