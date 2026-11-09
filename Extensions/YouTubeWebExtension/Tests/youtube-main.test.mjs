// Unit tests for the YouTube page script.  Run with: node --test Extensions/YouTubeWebExtension/Tests
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../Resources/youtube-main.js', import.meta.url), 'utf8');

/** Fresh page-like global with the script installed. */
function makePage() {
  const context = vm.createContext({ Response, Promise });
  vm.runInContext('var window = globalThis;', context);
  vm.runInContext(source, context);
  return context;
}

const playerResponse = () => ({
  responseContext: { serviceTrackingParams: [] },
  playabilityStatus: { status: 'OK' },
  streamingData: { formats: [{ itag: 18 }] },
  videoDetails: { videoId: 'abc', title: 'Video' },
  adPlacements: [{ adPlacementRenderer: { config: {} } }],
  playerAds: [{ playerLegacyDesktopWatchAdsRenderer: {} }],
  adSlots: [{ adSlotRenderer: {} }],
  adBreakHeartbeatParams: 'xyz',
});

const assertNoAds = (data) => {
  assert.equal(data.adPlacements, undefined);
  assert.equal(data.playerAds, undefined);
  assert.equal(data.adSlots, undefined);
  assert.equal(data.adBreakHeartbeatParams, undefined);
  assert.deepEqual(JSON.parse(JSON.stringify(data.streamingData)), { formats: [{ itag: 18 }] });
  assert.equal(data.videoDetails.videoId, 'abc');
};

test('JSON.parse strips video ads from player responses', () => {
  const page = makePage();
  page.input = JSON.stringify(playerResponse());
  const data = vm.runInContext('JSON.parse(input)', page);
  assertNoAds(data);
});

test('nested playerResponse (watch page parts) is cleaned', () => {
  const page = makePage();
  page.input = JSON.stringify([{ page: 'watch', playerResponse: playerResponse(), response: { responseContext: {} } }]);
  const data = vm.runInContext('JSON.parse(input)', page);
  assertNoAds(data[0].playerResponse);
});

test('ytInitialPlayerResponse embedded in the page is cleaned', () => {
  const page = makePage();
  page.input = playerResponse();
  vm.runInContext('var ytInitialPlayerResponse = input;', page);
  const data = vm.runInContext('window.ytInitialPlayerResponse', page);
  assertNoAds(data);
});

test('feed ads are removed and normal videos kept', () => {
  const page = makePage();
  page.input = {
    responseContext: {},
    contents: {
      richGridRenderer: {
        contents: [
          { richItemRenderer: { content: { videoRenderer: { videoId: 'one' } } } },
          { richItemRenderer: { content: { adSlotRenderer: { ad: true } } } },
          { richItemRenderer: { content: { videoRenderer: { videoId: 'two' } } } },
          { promotedSparklesWebRenderer: {} },
          { compactPromotedVideoRenderer: {} },
        ],
      },
    },
  };
  vm.runInContext('var ytInitialData = input;', page);
  const items = vm.runInContext('ytInitialData.contents.richGridRenderer.contents', page);
  assert.deepEqual(
    items.map((item) => item.richItemRenderer.content.videoRenderer.videoId),
    ['one', 'two'],
  );
});

test('anti-adblock popup data is removed', () => {
  const page = makePage();
  page.input = JSON.stringify({
    responseContext: {},
    auxiliaryUi: { messageRenderers: { enforcementMessageViewModel: { title: 'Ad blockers are not allowed' } } },
  });
  const data = vm.runInContext('JSON.parse(input)', page);
  assert.equal(data.auxiliaryUi.messageRenderers.enforcementMessageViewModel, undefined);
});

test('fetch Response.json() is cleaned', async () => {
  const page = makePage();
  const data = await new Response(JSON.stringify(playerResponse())).json();
  assertNoAds(data);
  assert.ok(page.__adblockYouTube);
});

test('unrelated JSON is left untouched', () => {
  const page = makePage();
  page.input = JSON.stringify({ settings: { adSlots: 3, playerAds: true } });
  const data = vm.runInContext('JSON.parse(input)', page);
  assert.equal(data.settings.adSlots, 3);
  assert.equal(data.settings.playerAds, true);
});

test('running the script twice is harmless', () => {
  const page = makePage();
  vm.runInContext(source, page);
  page.input = JSON.stringify(playerResponse());
  assertNoAds(vm.runInContext('JSON.parse(input)', page));
});
