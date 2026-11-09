/*
 * AdBlock YouTube – page script (runs in the page's own JavaScript world).
 *
 * YouTube ships its ads inside the same JSON that describes the video
 * (`adPlacements`, `playerAds`, `adSlots`...) and inside the feed data
 * (`adSlotRenderer`, promoted videos...). Blocking network requests can't
 * remove them, so – like Brave and uBlock Origin – we strip those fields
 * before YouTube's player reads them:
 *
 *  1. `JSON.parse` and `Response.prototype.json` (API responses while you
 *     browse: /youtubei/v1/player, /next, /browse, /search...)
 *  2. `ytInitialPlayerResponse` / `ytInitialData` (data embedded in the
 *     first page load)
 */
(() => {
  'use strict';

  const root = typeof window !== 'undefined' ? window : globalThis;
  if (root.__adblockYouTube) return;
  try {
    Object.defineProperty(root, '__adblockYouTube', { value: true });
  } catch (_) {
    return;
  }

  /** Keys holding ads (or the anti-adblock popup), removed wherever found. */
  const AD_KEYS = [
    'adPlacements',
    'adSlots',
    'playerAds',
    'adBreakHeartbeatParams',
    'adBreakParams',
    'enforcementMessageViewModel',
  ];

  /** Feed / search / watch-next items that are ads. */
  const AD_RENDERERS = [
    'adSlotRenderer',
    'displayAdRenderer',
    'promotedSparklesWebRenderer',
    'promotedSparklesTextSearchRenderer',
    'promotedVideoRenderer',
    'compactPromotedVideoRenderer',
    'compactPromotedItemRenderer',
    'searchPyvRenderer',
    'inFeedAdLayoutRenderer',
    'bannerPromoRenderer',
    'statementBannerRenderer',
    'brandVideoShelfRenderer',
    'brandVideoSingletonRenderer',
    'adsEngagementPanelContentRenderer',
    'movieOfferModuleRenderer',
  ];

  const MAX_DEPTH = 40;

  const isObject = (value) => value !== null && typeof value === 'object';

  const hasAdRenderer = (item) => {
    if (!isObject(item)) return false;
    for (const key of AD_RENDERERS) {
      if (key in item) return true;
    }
    // Home feed: { richItemRenderer: { content: { adSlotRenderer: {...} } } }
    const wrapped = item.richItemRenderer || item.richSectionRenderer;
    if (wrapped && isObject(wrapped.content)) {
      for (const key of AD_RENDERERS) {
        if (key in wrapped.content) return true;
      }
    }
    return false;
  };

  /** Removes ads in place. Returns the number of removed entries. */
  const prune = (node, depth = 0) => {
    if (!isObject(node) || depth > MAX_DEPTH) return 0;
    let removed = 0;

    if (Array.isArray(node)) {
      for (let i = node.length - 1; i >= 0; i--) {
        if (hasAdRenderer(node[i])) {
          node.splice(i, 1);
          removed++;
        } else {
          removed += prune(node[i], depth + 1);
        }
      }
      return removed;
    }

    for (const key of AD_KEYS) {
      if (key in node) {
        delete node[key];
        removed++;
      }
    }
    for (const key in node) {
      if (Object.prototype.hasOwnProperty.call(node, key) && isObject(node[key])) {
        removed += prune(node[key], depth + 1);
      }
    }
    return removed;
  };

  /** Cheap check so we only walk YouTube data, not every JSON on the page. */
  const looksLikeYouTubeData = (value) => {
    if (!isObject(value)) return false;
    if (Array.isArray(value)) {
      return value.some((part) => isObject(part) && ('playerResponse' in part || 'response' in part));
    }
    return (
      'responseContext' in value ||
      'playerResponse' in value ||
      'adPlacements' in value ||
      'playerAds' in value ||
      'adSlots' in value
    );
  };

  const pruneIfNeeded = (value) => {
    try {
      if (looksLikeYouTubeData(value)) prune(value);
    } catch (_) {
      /* never break the page */
    }
    return value;
  };

  // 1a. JSON.parse
  const originalParse = JSON.parse;
  const patchedParse = function parse() {
    return pruneIfNeeded(originalParse.apply(this, arguments));
  };
  try {
    Object.defineProperty(patchedParse, 'toString', { value: () => originalParse.toString() });
  } catch (_) {}
  JSON.parse = patchedParse;

  // 1b. fetch(...).then(r => r.json())
  if (typeof root.Response === 'function' && root.Response.prototype.json) {
    const originalJSON = root.Response.prototype.json;
    root.Response.prototype.json = function json() {
      return originalJSON.apply(this, arguments).then(pruneIfNeeded);
    };
  }

  // 2. Data embedded in the HTML of the first page load.
  const trapGlobal = (name) => {
    let value = root[name];
    pruneIfNeeded(value);
    try {
      Object.defineProperty(root, name, {
        configurable: true,
        enumerable: true,
        get: () => value,
        set: (newValue) => {
          value = pruneIfNeeded(newValue);
        },
      });
    } catch (_) {
      /* property already locked by the page */
    }
  };
  ['ytInitialPlayerResponse', 'ytInitialData', 'ytInitialReelWatchSequenceResponse'].forEach(trapGlobal);

  // Exposed for the unit tests only.
  try {
    Object.defineProperty(root, '__adblockYouTubePrune', { value: prune });
  } catch (_) {}
})();
