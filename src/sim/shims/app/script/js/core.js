// core.js — what the other modules share: formatting values and errors, waiting, defaults.
// (Each module is the body of `function (native, internal)`; see context.m.)

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
internal.sleep = sleep;
internal.defaults = { timeout: 5000 };

// An Objective-C object from objc.send() is a JavaScriptCore wrapper: neither a plain object nor an array.
const isPlain = v => {
  const p = Object.getPrototypeOf(v);
  return p === null || p === Object.prototype || p === Array.prototype;
};
const jsonReplacer = (key, v) => {
  if (v && typeof v === 'object') {
    if (internal.Locator && v instanceof internal.Locator) {
      return v.toString();
    }
    if (!isPlain(v)) {
      const d = native.objc.describe(v);
      if (d) {
        return d;
      }
    }
  }
  return v;
};

// A value as `simrun eval` prints it: strings as they are, undefined as nothing, the rest as JSON.
internal.formatValue = v => {
  if (v === undefined) {
    return '';
  }
  if (typeof v === 'string') {
    return v;
  }
  if (typeof v === 'function') {
    return v.toString();
  }
  try {
    const s = JSON.stringify(v, jsonReplacer, 2);
    if (s !== undefined) {
      return s;
    }
  } catch (e) {}
  return String(v);
};

// What an exception says: the error and where it came from in the script ("script.js" frames; the API's own frames are
// left out), or what was thrown. prefix: how many characters of wrapper precede the script on its first line.
internal.formatError = (e, prefix) => {
  if (!(e instanceof Error)) {
    return `Uncaught ${internal.formatValue(e)}`;
  }
  const at = (l, c) => `script.js:${l}` + (c === undefined ? '' : `:${l == 1 ? c - prefix : c}`);
  const frames = String(e.stack || '').split('\n')
    .map(f => f.match(/^(.*?)@?script\.js:(\d+):(\d+)$/)).filter(m => m)
    .map(([, fn, l, c]) => `    at ${fn ? `${fn} (${at(l, +c)})` : at(l, +c)}`);
  if (!frames.length && e.line && e.sourceURL === 'script.js') {
    frames.push(`    at ${at(e.line, e.column)}`);
  }
  return [String(e), ...frames].join('\n');
};

// Calls probe() every `interval` ms until it returns { done: true, … } or `timeout` ms have passed; returns its last
// answer either way (callers say what was being waited for when it isn't done).
internal.poll = async (probe, timeout, interval = 60) => {
  // the first look at the elements in an app loads its accessibility support (seconds, once): not part of the wait
  if (internal.ready) {
    await internal.ready();
  }
  const deadline = Date.now() + timeout;
  for (;;) {
    const r = await probe();
    if (r.done || Date.now() >= deadline) {
      return r;
    }
    await sleep(interval);
  }
};

// Resolves once no frame has been presented for `quiet` ms (true), or after `timeout` ms of an ever-changing screen,
// such as a spinner (false). Time the main thread spends blocked doesn't count as quiet: a tap that pushes a page can
// stall it for half a second building the page before the first frame of the transition.
internal.waitForIdle = async ({ quiet = 100, timeout = 2000 } = {}) => {
  let last = native.ui.frameCount();
  if (last < 0) {   // no frame count to go by
    await sleep(quiet);
    return true;
  }
  const start = Date.now();
  let since = start, tick = start;
  while (Date.now() - start < timeout) {
    await sleep(16);
    const now = Date.now(), n = native.ui.frameCount();
    if (n !== last || now - tick > 50) {   // drawing, or the main thread was busy
      last = n;
      since = now;
    } else if (now - since >= quiet) {
      return true;
    }
    tick = now;
  }
  return false;
};

// A tap at scene points: finger down, up `hold` ms later.
internal.tapAt = async (x, y, hold = 50) => {
  native.ui.touch(0, 1, x, y);
  await sleep(hold);
  native.ui.touch(0, 3, x, y);
};

// The Digital Crown turned as a scroll of `delta` points would turn it (> 0: down), over `duration` ms; watchOS only.
internal.crown = async (delta, duration = 300) => {
  const steps = Math.max(1, Math.round(duration / 16));
  for (let i = 0; i < steps; i++) {
    if (!native.ui.crown(-delta / steps)) {
      throw new Error('app.crown: only a watchOS app has a Digital Crown');
    }
    await sleep(duration / steps);
  }
};

// A drag from (x0, y0) to (x1, y1) over `duration` ms.
internal.swipe = async (x0, y0, x1, y1, duration = 300) => {
  const steps = Math.max(2, Math.round(duration / 16));
  native.ui.touch(0, 1, x0, y0);
  for (let i = 1; i <= steps; i++) {
    await sleep(duration / steps);
    native.ui.touch(0, 2, x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps);
  }
  native.ui.touch(0, 3, x1, y1);
};
