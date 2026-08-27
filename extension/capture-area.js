// Injected on demand: draws a drag-select overlay, then asks the background
// worker to capture and crop.
(() => {
  if (document.getElementById("__snag_overlay")) return;

  const overlay = document.createElement("div");
  overlay.id = "__snag_overlay";
  Object.assign(overlay.style, {
    position: "fixed", inset: "0", zIndex: "2147483647",
    cursor: "crosshair", background: "rgba(0,0,0,0.25)",
  });
  const box = document.createElement("div");
  Object.assign(box.style, {
    position: "fixed", border: "2px solid #3F6EF7",
    background: "rgba(63,110,247,0.15)", display: "none", zIndex: "2147483647",
    pointerEvents: "none",
  });
  document.documentElement.appendChild(overlay);
  document.documentElement.appendChild(box);

  let sx = 0, sy = 0, dragging = false;

  function cleanup() {
    overlay.remove();
    box.remove();
    document.removeEventListener("keydown", onKey, true);
  }
  function onKey(e) {
    if (e.key === "Escape") { e.preventDefault(); cleanup(); }
  }
  document.addEventListener("keydown", onKey, true);

  overlay.addEventListener("mousedown", (e) => {
    dragging = true; sx = e.clientX; sy = e.clientY;
    box.style.display = "block";
    e.preventDefault();
  });
  overlay.addEventListener("mousemove", (e) => {
    if (!dragging) return;
    const x = Math.min(sx, e.clientX), y = Math.min(sy, e.clientY);
    const w = Math.abs(e.clientX - sx), h = Math.abs(e.clientY - sy);
    Object.assign(box.style, { left: x + "px", top: y + "px", width: w + "px", height: h + "px" });
  });
  overlay.addEventListener("mouseup", (e) => {
    dragging = false;
    const x = Math.min(sx, e.clientX), y = Math.min(sy, e.clientY);
    const w = Math.abs(e.clientX - sx), h = Math.abs(e.clientY - sy);
    cleanup();
    if (w < 5 || h < 5) return;
    // Give the page a beat to repaint without the overlay before capture.
    setTimeout(() => {
      chrome.runtime.sendMessage({
        type: "capture-area",
        rect: { x, y, w, h },
        scale: window.devicePixelRatio || 1,
        name: document.title ? `${document.title} (area)` : "Area Capture",
        pageURL: location.href,
      });
    }, 120);
  });
})();
