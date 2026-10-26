// locator.js — Playwright-style locators over the accessibility elements: app.getByRole("button", { name: "Save" }).
//
// A locator is a query, run again each time it is used, so it keeps working while the UI re-renders. Actions wait for
// their element: it must exist, be the only match (strict), be on screen (scrolled into view if it isn't), be
// enabled, and have stopped moving; then they act through real touches and keys, and wait for the UI to settle.

const { poll, waitForIdle, defaults } = internal;

const normalize = s => String(s).replace(/\s+/g, ' ').trim();
// Names match case-insensitively by substring, exactly with { exact: true }, or by a RegExp.
const matches = (actual, expected, exact) => {
  actual = normalize(actual);
  if (expected instanceof RegExp)
    return expected.test(actual);
  return exact ? actual === normalize(expected) : actual.toLowerCase().includes(normalize(expected).toLowerCase());
};
const show = v => v instanceof RegExp ? String(v) : typeof v === 'string' ? `'${v.replace(/'/g, "\\'")}'` : String(v);
const showOptions = o => {
  const parts = Object.entries(o).filter(([, v]) => v !== undefined).map(([k, v]) => `${k}: ${show(v)}`);
  return parts.length ? `, { ${parts.join(', ')} }` : '';
};
const tapPoint = e => [e.tapPoint.x, e.tapPoint.y];   // ax.m: the activation point, on screen
const isTextbox = e => e.role === 'textbox' || e.role === 'searchbox';

const roles = ['button', 'link', 'image', 'heading', 'text', 'textbox', 'searchbox', 'switch', 'slider', 'tab', 'key', 'element'];

const levenshtein = (a, b) => {
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++)
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    prev = cur;
  }
  return prev[b.length];
};

class Locator {
  // select(elements) -> the matching elements, in reading order. query: what was asked for ({ role, text }), to
  // suggest near matches when nothing matches.
  constructor(description, select, query = {}) {
    this._description = description;
    this._select = select;
    this._query = query;
  }
  toString() {
    return this._description;
  }
  async _find() {
    await internal.ready();
    const elements = internal.collect();
    return { elements, found: this._select(elements) };
  }
  _narrow(suffix, f) {
    const select = this._select;
    return new Locator(this._description + suffix, els => f(select(els)), this._query);
  }

  first() {
    return this._narrow('.first()', m => m.slice(0, 1));
  }
  last() {
    return this._narrow('.last()', m => m.slice(-1));
  }
  nth(i) {
    return this._narrow(`.nth(${i})`, m => (i < 0 ? m.slice(m.length + i) : m.slice(i)).slice(0, 1));
  }
  // filter({ hasText, hasNotText, visible }): hasText matches the name or the value
  filter({ hasText, hasNotText, visible } = {}) {
    const has = (e, t) => matches(e.name, t) || matches(e.value, t);
    return this._narrow(`.filter(${showOptions({ hasText, hasNotText, visible }).slice(2)})`, m => m.filter(e =>
      (hasText === undefined || has(e, hasText)) && (hasNotText === undefined || !has(e, hasNotText)) &&
      (visible === undefined || e.visible === visible)));
  }

  // ---- reading (no waiting, except info/text/value, which wait for the element to exist)
  async count() {
    return (await this._find()).found.length;
  }
  async all() {
    return Array.from({ length: await this.count() }, (_, i) => this.nth(i));
  }
  async isVisible() {
    const { found } = await this._find();
    return found.length > 0 && found[0].visible;
  }
  async isEnabled() {
    const { found } = await this._find();
    return found.length > 0 && !found[0].disabled;
  }
  // info(): the element's record: { ref, role, name, value, id, traits, selected, disabled, focused, frame, visible, … }
  async info(opts = {}) {
    return this._one('info', { ...opts, visible: false, enabled: false, stable: false });
  }
  async text(opts) {
    return (await this.info(opts)).name;
  }
  async value(opts) {
    return (await this.info(opts)).value;
  }

  // waitFor({ state: "visible" | "hidden" | "attached" | "detached", timeout })
  async waitFor({ state = 'visible', timeout = defaults.timeout } = {}) {
    const reached = { visible: f => f.length === 1 && f[0].visible, hidden: f => !f.some(e => e.visible),
                      attached: f => f.length > 0, detached: f => f.length === 0 }[state];
    if (!reached)
      throw new Error(`waitFor: state is "visible", "hidden", "attached" or "detached", not ${show(state)}`);
    const r = await poll(async () => {
      const { found } = await this._find();
      if (state === 'visible' && found.length > 1)
        return { done: true, error: this._strictError('waitFor', found) };
      return { done: reached(found) };
    }, timeout);
    if (r.error)
      throw r.error;
    if (!r.done)
      throw new Error(`waitFor: timed out after ${timeout} ms waiting for ${this} to be ${state}`);
  }

  // ---- acting
  async tap(opts = {}) {
    const e = await this._one('tap', opts);
    await internal.tapAt(...tapPoint(e));
    await waitForIdle();
  }
  async longPress({ duration = 800, ...opts } = {}) {
    const e = await this._one('longPress', opts);
    await internal.tapAt(...tapPoint(e), duration);
    await waitForIdle();
  }
  // fill(text): focus the text field, replace what is in it with text
  async fill(text, opts = {}) {
    await this._focus('fill', opts);
    await internal.fill('fill', text);
    await waitForIdle();
  }
  // type(text): focus the text field, type text where the cursor is
  async type(text, opts = {}) {
    await this._focus('type', opts);
    await internal.type('type', text);
    await waitForIdle();
  }
  // press(key): a key (Playwright's names: "Enter", "Meta+A"…), into the element if it is a text field
  async press(key, opts = {}) {
    const e = await this._one('press', opts);
    if (isTextbox(e) && !e.focused)
      await this._focus('press', opts);
    internal.press(key);
    await waitForIdle();
  }
  async scrollIntoView(opts = {}) {
    await this._one('scrollIntoView', { ...opts, enabled: false, stable: false });
  }
  // activate(): the element's accessibility action (what a VoiceOver double tap does), for when a tap can't reach it
  async activate(opts = {}) {
    const e = await this._one('activate', { ...opts, visible: false });
    if (!native.ax.activate(e.ref))
      throw new Error(`activate: ${internal.describe(e)} has no accessibility action`);
    await waitForIdle();
  }

  // ---- waiting for the one element this locator names, until it is ready for `action`
  async _one(action, { timeout = defaults.timeout, visible = true, enabled = true, stable = true } = {}) {
    let scrolls = 0, lastFrame;
    const r = await poll(async () => {
      const { elements, found } = await this._find();
      if (!found.length)
        return { done: false, why: 'no element matches', elements };
      if (found.length > 1)
        return { done: true, error: this._strictError(action, found) };
      const e = found[0];
      if (visible && !e.visible) {
        if (scrolls < 3 && native.ax.scrollIntoView(e.ref)) {
          scrolls++;
          await waitForIdle({ timeout: 1000 });
        }
        return { done: false, why: `${internal.describe(e)} is off screen` + (scrolls ? ' (scrolling didn\'t bring it on screen)' : '') };
      }
      if (enabled && e.disabled)
        return { done: false, why: `${internal.describe(e)} is disabled` };
      if (stable) {   // the same frame twice in a row
        const f = JSON.stringify(e.visibleFrame);
        if (f !== lastFrame) {
          lastFrame = f;
          return { done: false, why: `${internal.describe(e)} keeps moving` };
        }
      }
      return { done: true, element: e };
    }, timeout);
    if (r.error)
      throw r.error;
    if (r.done)
      return r.element;
    throw new Error(`${action}: timed out after ${timeout} ms waiting for ${this}: ${r.why}` + (r.elements ? this._suggestions(r.elements) : ''));
  }

  async _focus(action, opts) {
    const e = await this._one(action, opts);
    if (!isTextbox(e))
      throw new Error(`${action}: ${this} is ${internal.describe(e)}, not a text field`);
    if (e.focused)
      return;
    await internal.tapAt(...tapPoint(e));
    // the first text focus in an app can block its main thread for seconds (hid.md): wait for the focus to land
    const timeout = opts.timeout ?? defaults.timeout;
    const r = await poll(async () => {
      const { found } = await this._find();
      return { done: found.length === 1 && found[0].focused };
    }, timeout);
    if (!r.done)
      throw new Error(`${action}: tapped ${this}, but it didn't get keyboard focus within ${timeout} ms`);
  }

  _strictError(action, found) {
    const list = found.slice(0, 8).map(e => `  - ${internal.describe(e)}`);
    if (found.length > 8)
      list.push(`  … and ${found.length - 8} more`);
    return new Error(`${action}: ${this} matches ${found.length} elements; narrow it down (exact: true, .filter(), .first(), .nth(i)) ` +
                     `or use app.ref():\n${list.join('\n')}`);
  }

  // ". Similar: …" — elements whose name is close to what was asked for (any role), closest first.
  _suggestions(elements) {
    const { role, text } = this._query;
    if (typeof text !== 'string' || !text)
      return '. app.snapshot() shows what is on screen';
    const q = normalize(text).toLowerCase();
    const near = elements.map(e => {
      const name = normalize(e.name).toLowerCase();
      const d = name.includes(q) ? 0 : Math.min(levenshtein(q, name), levenshtein(q, name.slice(0, q.length + 2)));
      return { e, d: d + (role && e.role !== role ? 0.5 : 0) };
    }).filter(c => c.d <= Math.max(2, q.length * 0.4)).sort((a, b) => a.d - b.d);
    if (!near.length)
      return '. Nothing on screen has a similar name; app.snapshot() shows what is there';
    return `. Similar: ${near.slice(0, 5).map(c => internal.describe(c.e)).join(', ')}`;
  }
}
internal.Locator = Locator;

// The ways to make a locator (app.getByRole and so on).
internal.locators = {
  // getByRole(role, { name, exact, selected, disabled }): roles as app.snapshot() shows them
  getByRole(role, { name, exact, selected, disabled } = {}) {
    if (!roles.includes(role))
      throw new Error(`getByRole: there is no role ${show(role)}; the roles are ${roles.join(', ')}`);
    return new Locator(`getByRole(${show(role)}${showOptions({ name, exact, selected, disabled })})`,
      els => els.filter(e => e.role === role && (name === undefined || matches(e.name, name, exact)) &&
                             (selected === undefined || e.selected === selected) && (disabled === undefined || e.disabled === disabled)),
      { role, text: name });
  },
  // getByText(text, { exact }): elements whose name (accessibility label) matches
  getByText(text, { exact } = {}) {
    return new Locator(`getByText(${show(text)}${showOptions({ exact })})`, els => els.filter(e => matches(e.name, text, exact)), { text });
  },
  // getByLabel(text, { exact }): controls (anything but text and headings) whose name matches
  getByLabel(text, { exact } = {}) {
    return new Locator(`getByLabel(${show(text)}${showOptions({ exact })})`,
      els => els.filter(e => e.role !== 'text' && e.role !== 'heading' && matches(e.name, text, exact)), { text });
  },
  // getByTestId(id): the element with this accessibility identifier (a string, exactly, or a RegExp)
  getByTestId(id) {
    return new Locator(`getByTestId(${show(id)})`, els => els.filter(e => id instanceof RegExp ? id.test(e.id) : e.id === id), {});
  },
  // ref("e4"): the element a snapshot showed with that ref; if it has been replaced, the one that looks the same
  ref(ref) {
    if (!internal.signatureOf(ref))
      throw new Error(`ref: no element has had ref ${show(ref)}; refs come from app.snapshot()`);
    return new Locator(`ref(${show(ref)})`, els => {
      const same = els.filter(e => e.ref === ref);
      if (same.length)
        return same;
      const sig = internal.signatureOf(ref);
      return els.filter(e => internal.signature(e) === sig);
    }, {});
  },
};
