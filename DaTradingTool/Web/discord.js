/* Da Trading Tool as a Discord Activity.
   Does nothing unless the page is running inside Discord (served from <app id>.discordsays.com).
   Inside Discord:
   - every call to an outside service goes through Discord's proxy, using the URL mappings set in the
     Discord Developer Portal (the list below must match them),
   - links open in the browser (or the app that owns them) through Discord, since the Activity can't open pages itself,
   - window.DaDiscord tells the rest of the page it runs in Discord.
   Follows the protocol of Discord's Embedded App SDK (github.com/discord/embedded-app-sdk, v2.5.0). */
(() => {
  'use strict';
  if (!/\.discordsays\.com$/i.test(location.hostname)) return;

  // outside host -> proxy path. Keep in sync with Developer Portal > Activities > URL Mappings.
  const MAPPINGS = {
    'api.geckoterminal.com': '/gt',
    'api.dexscreener.com': '/ds',
    'dd.dexscreener.com': '/dsimg',
    'cdn.dexscreener.com': '/dscdn',
    'api.rugcheck.xyz': '/rc',
    'api.jup.ag': '/jup',
    'lite-api.jup.ag': '/jupl',
    'solana-rpc.publicnode.com': '/rpc',
    'api.x.ai': '/xai',
    'publish.twitter.com': '/xo',
    'ipfs.filebase.io': '/ipfs1',
    '4everland.io': '/ipfs2',
    'gateway.pinata.cloud': '/ipfs3',
    'fonts.googleapis.com': '/gf',
    'fonts.gstatic.com': '/gs',
  };

  const remap = raw => {
    let u;
    try { u = new URL(String(raw), location.href); } catch (e) { return raw; }
    const prefix = MAPPINGS[u.hostname.toLowerCase()];
    if (!prefix) return raw;
    const out = new URL(location.origin);
    const secure = location.protocol === 'https:';
    out.protocol = u.protocol === 'ws:' || u.protocol === 'wss:' ? (secure ? 'wss:' : 'ws:') : location.protocol;
    out.pathname = prefix + (u.pathname === '/' ? '/' : u.pathname);
    out.search = u.search; out.hash = u.hash;
    return out.toString();
  };

  // network: fetch, XMLHttpRequest, WebSocket
  const realFetch = window.fetch.bind(window);
  window.fetch = function (input, init) {
    if (input instanceof Request) {
      const to = remap(input.url);
      return to === input.url ? realFetch(input, init) : realFetch(new Request(to, input), init);
    }
    return realFetch(remap(input instanceof URL ? input.href : input), init);
  };
  const realOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url, ...rest) { return realOpen.call(this, method, remap(url), ...rest); };
  const RealWS = window.WebSocket;
  window.WebSocket = class extends RealWS { constructor(url, protocols) { super(remap(url), protocols); } };

  // images (token logos): rewrite src when it is set, plus anything already in the page
  const imgSrc = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
  Object.defineProperty(HTMLImageElement.prototype, 'src', {
    configurable: true, enumerable: true,
    get() { return imgSrc.get.call(this); },
    set(v) { imgSrc.set.call(this, remap(v)); },
  });
  const realSetAttr = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (name, value) {
    if (this instanceof HTMLImageElement && String(name).toLowerCase() === 'src') value = remap(value);
    return realSetAttr.call(this, name, value);
  };

  // fonts: Discord blocks the Google Fonts stylesheet, so load it through the proxy instead
  const loadFonts = () => {
    const link = document.querySelector('link[rel="stylesheet"][href*="fonts.googleapis.com"]');
    if (!link) return;
    window.fetch(link.href).then(r => (r.ok ? r.text() : '')).then(css => {
      if (!css) return;
      const style = document.createElement('style');
      style.textContent = css.replace(/https:\/\/fonts\.gstatic\.com\//g, location.origin + '/gs/');
      document.head.append(style);
    }).catch(() => { /* fall back to the built-in fonts */ });
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', loadFonts); else loadFonts();

  // talking to the Discord client (Embedded App SDK protocol: postMessage [opcode, payload])
  const q = new URLSearchParams(location.search);
  const clientId = location.hostname.split('.')[0];
  const platform = q.get('platform') === 'mobile' ? 'mobile' : 'desktop';
  const target = window.parent.opener || window.parent;
  const targetOrigin = document.referrer || '*';
  const ALLOWED = new Set([location.origin, 'https://discord.com', 'https://discordapp.com', 'https://ptb.discord.com',
    'https://ptb.discordapp.com', 'https://canary.discord.com', 'https://canary.discordapp.com', 'null']);
  const pending = new Map(); const queued = [];
  let ready = false; let seq = 0;

  const send = (cmd, args) => new Promise((resolve, reject) => {
    const nonce = Date.now().toString(36) + '-' + (++seq) + '-' + Math.random().toString(36).slice(2);
    pending.set(nonce, { resolve, reject });
    const go = () => target.postMessage([1, { cmd, args, nonce }], targetOrigin);
    if (ready) go(); else queued.push(go);
  });

  window.addEventListener('message', e => {
    if (!ALLOWED.has(e.origin) || !Array.isArray(e.data)) return;
    const [op, data] = e.data;
    if (op !== 1 || !data) return;
    if (data.cmd === 'DISPATCH') {
      if (data.evt === 'READY' && !ready) { ready = true; queued.splice(0).forEach(go => go()); }
      return;
    }
    const p = data.nonce != null && pending.get(data.nonce);
    if (!p) return;
    pending.delete(data.nonce);
    if (data.evt === 'ERROR') p.reject(data.data); else p.resolve(data.data);
  });

  const frameId = q.get('frame_id');
  if (frameId) {
    const hello = { v: 1, encoding: 'json', client_id: clientId, frame_id: frameId };
    const mobileMajor = parseInt(String(q.get('mobile_app_version') || '').split('.')[0], 10);
    if (platform === 'desktop' || mobileMajor >= 250) hello.sdk_version = '2.5.0';
    target.postMessage([0, hello], targetOrigin);
  }

  const openLink = url => send('OPEN_EXTERNAL_LINK', { url: String(url) }).catch(() => { /* the person closed Discord's link prompt */ });

  // every outside link in the page opens through Discord (the page's own buttons click hidden links too)
  document.addEventListener('click', e => {
    const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!a || e.defaultPrevented) return;
    const href = a.href;
    if (!/^https?:/i.test(href) || new URL(href).origin === location.origin) return;
    e.preventDefault();
    openLink(href);
  }, true);

  document.documentElement.dataset.discord = platform;
  window.DaDiscord = { platform, open: openLink, isReady: () => ready };
})();
