// expect.js — assertions, as in Playwright. On a locator they retry until they hold or the timeout passes:
//   await expect(app.getByText("Saved")).toBeVisible()
//   await expect(app.getByRole("textbox")).toHaveValue("hello", { timeout: 10000 })
//   await expect(app.getByRole("button", { name: "Delete" })).not.toBeVisible()
// On any other value they check once: expect(n).toBe(3). A failed assertion throws, so `simrun eval` exits 1.

const { poll, defaults, Locator } = internal;

const normalize = s => String(s).replace(/\s+/g, ' ').trim();
const textMatches = (actual, expected, substring) => {
  if (expected instanceof RegExp)
    return expected.test(normalize(actual));
  return substring ? normalize(actual).includes(normalize(expected)) : normalize(actual) === normalize(expected);
};
const show = v => v instanceof RegExp ? String(v) : JSON.stringify(v);

// Each locator matcher: what it expects (for the message), and a check of the matching elements returning
// { pass, received } (received: what was there instead, for the message).
const one = (found, f) => found.length === 1 ? f(found[0]) : { pass: false, received: found.length ? `${found.length} elements` : 'no element' };
const locatorMatchers = {
  toBeVisible: () => ({ expected: 'visible', check: found => one(found, e => ({ pass: e.visible, received: 'off screen' })) }),
  toBeHidden: () => ({ expected: 'hidden', check: found => ({ pass: !found.some(e => e.visible), received: 'visible' }) }),
  toBeEnabled: () => ({ expected: 'enabled', check: found => one(found, e => ({ pass: !e.disabled, received: 'disabled' })) }),
  toBeDisabled: () => ({ expected: 'disabled', check: found => one(found, e => ({ pass: e.disabled, received: 'enabled' })) }),
  toBeSelected: () => ({ expected: 'selected', check: found => one(found, e => ({ pass: e.selected, received: 'not selected' })) }),
  toBeFocused: () => ({ expected: 'focused', check: found => one(found, e => ({ pass: e.focused, received: 'not focused' })) }),
  toHaveText: t => ({ expected: `text ${show(t)}`, check: found => one(found, e => ({ pass: textMatches(e.name, t), received: show(e.name) })) }),
  toContainText: t => ({ expected: `text containing ${show(t)}`, check: found => one(found, e => ({ pass: textMatches(e.name, t, true), received: show(e.name) })) }),
  toHaveValue: v => ({ expected: `value ${show(v)}`, check: found => one(found, e => ({ pass: textMatches(e.value, v), received: show(e.value) })) }),
  toHaveCount: n => ({ expected: `${n} elements`, check: found => ({ pass: found.length === n, received: `${found.length}` }) }),
};

const expectLocator = (locator, negated) => {
  const m = {};
  for (const [name, make] of Object.entries(locatorMatchers)) {
    m[name] = async (...args) => {
      // the last argument may be { timeout }
      const opts = args.length > make.length && typeof args[args.length - 1] === 'object' ? args.pop() : {};
      const timeout = opts.timeout ?? defaults.timeout;
      const { expected, check } = make(...args);
      let last;
      const r = await poll(async () => {
        last = check((await locator._find()).found);
        return { done: last.pass !== negated };
      }, timeout);
      if (r.done)
        return;
      throw new Error(`expect(${locator})${negated ? '.not' : ''}.${name}(${args.map(show).join(', ')}) failed after ${timeout} ms\n` +
                      `  expected: ${negated ? 'not ' : ''}${expected}\n  received: ${negated ? expected : last.received}`);
    };
  }
  return m;
};

const sameValue = (a, b) => {
  try {
    return JSON.stringify(a) === JSON.stringify(b);
  } catch (e) {
    return a === b;
  }
};
const valueMatchers = {
  toBe: (v, x) => [Object.is(v, x), show(x)],
  toEqual: (v, x) => [sameValue(v, x), show(x)],
  toContain: (v, x) => [v != null && v.includes(x), `something containing ${show(x)}`],
  toMatch: (v, re) => [typeof v === 'string' && (re instanceof RegExp ? re : new RegExp(re)).test(v), `a string matching ${String(re)}`],
  toBeTruthy: v => [!!v, 'truthy'],
  toBeFalsy: v => [!v, 'falsy'],
  toBeGreaterThan: (v, x) => [v > x, `more than ${x}`],
  toBeLessThan: (v, x) => [v < x, `less than ${x}`],
};
const expectValue = (value, negated) => {
  const m = {};
  for (const [name, check] of Object.entries(valueMatchers))
    m[name] = (...args) => {
      const [pass, expected] = check(value, ...args);
      if (pass === negated)
        throw new Error(`expect(…)${negated ? '.not' : ''}.${name}() failed\n  expected: ${negated ? 'not ' : ''}${expected}\n  received: ${internal.formatValue(value)}`);
    };
  return m;
};

internal.expect = target => {
  const make = target instanceof Locator ? expectLocator : expectValue;
  const m = make(target, false);
  m.not = make(target, true);
  return m;
};
