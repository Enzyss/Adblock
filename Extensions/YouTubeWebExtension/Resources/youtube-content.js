/*
 * AdBlock YouTube – content script (Safari's isolated extension world).
 *
 * 1. Makes sure youtube-main.js runs inside the page (older Safari versions
 *    ignore `"world": "MAIN"` in the manifest).
 * 2. Safety net: if an ad still starts playing, it is muted, fast-forwarded
 *    and skipped; the anti-adblock popup is removed and playback resumed.
 */
(() => {
  'use strict';

  if (window.__adblockYouTubeContent) return;
  window.__adblockYouTubeContent = true;

  const api = globalThis.browser || globalThis.chrome;

  // --- 1. Inject the page script (no-op if it already runs in MAIN world) ---
  try {
    const script = document.createElement('script');
    script.src = api.runtime.getURL('youtube-main.js');
    script.async = false;
    script.onload = () => script.remove();
    (document.head || document.documentElement).appendChild(script);
  } catch (_) {
    /* ignore */
  }

  // --- 2. Skip ads that slip through ---
  const SKIP_BUTTONS = [
    '.ytp-ad-skip-button',
    '.ytp-ad-skip-button-modern',
    '.ytp-skip-ad-button',
    '.ytp-ad-skip-button-slot button',
    '.ytm-skip-ad-button',
    'button[class*="skip-ad"]',
  ].join(',');

  const AD_PLAYER = '.html5-video-player.ad-showing, .html5-video-player.ad-interrupting';

  const POPUPS = [
    'ytd-enforcement-message-view-model',
    'tp-yt-paper-dialog:has(ytd-enforcement-message-view-model)',
    'ytm-enforcement-message-view-model',
  ];

  const mutedByUs = new WeakSet();

  const handleAds = () => {
    const player = document.querySelector(AD_PLAYER);
    const video = player ? player.querySelector('video') : null;

    if (player && video) {
      if (!video.muted) {
        video.muted = true;
        mutedByUs.add(video);
      }
      try {
        video.playbackRate = 16;
      } catch (_) {}
      if (Number.isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.25) {
        video.currentTime = video.duration;
      }
      document.querySelectorAll(SKIP_BUTTONS).forEach((button) => button.click());
      return;
    }

    // Ad finished: restore the main video.
    document.querySelectorAll('video').forEach((v) => {
      if (mutedByUs.has(v)) {
        v.muted = false;
        mutedByUs.delete(v);
      }
      if (v.playbackRate > 2) v.playbackRate = 1;
    });

    let removedPopup = false;
    for (const selector of POPUPS) {
      let elements = [];
      try {
        elements = document.querySelectorAll(selector);
      } catch (_) {
        continue; // :has() not supported
      }
      elements.forEach((element) => {
        element.remove();
        removedPopup = true;
      });
    }
    if (removedPopup) {
      document.querySelectorAll('tp-yt-iron-overlay-backdrop').forEach((backdrop) => backdrop.remove());
      const main = document.querySelector('.html5-video-player video');
      if (main && main.paused) main.play().catch(() => {});
    }
  };

  let scheduled = false;
  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      handleAds();
    });
  };

  const start = () => {
    new MutationObserver(schedule).observe(document.documentElement, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['class'],
    });
    setInterval(handleAds, 500);
    handleAds();
  };

  if (document.documentElement) {
    start();
  } else {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  }
})();
