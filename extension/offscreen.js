// A hidden extension page that only plays sounds. A service worker has no
// audio, and a sound played from inside a web page can be blocked by its
// autoplay rules, so the background worker asks this page instead.
const pop = new Audio("sounds/pop.mp3");
pop.volume = 0.7;

chrome.runtime.onMessage.addListener((msg) => {
  if (msg && msg.target === "offscreen" && msg.type === "play-pop") {
    pop.currentTime = 0;
    pop.play().catch(() => {});
  }
});
