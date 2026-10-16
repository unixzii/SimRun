// app.js — the globals scripts see: app, expect, objc and sleep (plus setTimeout, clearTimeout and console from
// context.m). They can't be reassigned, so a script can't break the next one by accident.

const { locators, waitForIdle, defaults } = internal;

const app = Object.freeze({
  // finding elements (locator.js)
  getByRole: (role, options) => locators.getByRole(role, options),
  getByText: (text, options) => locators.getByText(text, options),
  getByLabel: (text, options) => locators.getByLabel(text, options),
  getByTestId: id => locators.getByTestId(id),
  ref: ref => locators.ref(ref),
  // the screen as text, with refs (snapshot.js); await it
  snapshot: options => internal.snapshot(options),

  // input at scene points, and keys; each resolves once the UI has settled
  tap: async (x, y) => { await internal.tapAt(x, y); await waitForIdle(); },
  longPress: async (x, y, { duration = 800 } = {}) => { await internal.tapAt(x, y, duration); await waitForIdle(); },
  swipe: async (x0, y0, x1, y1, { duration = 300 } = {}) => { await internal.swipe(x0, y0, x1, y1, duration); await waitForIdle(); },
  crown: async (delta, { duration = 300 } = {}) => { await internal.crown(delta, duration); await waitForIdle(); },
  type: async text => { await internal.type('type', text); await waitForIdle(); },
  typeBoundAvailable: () => typeof native.ui.typeBound === 'function',
  typeBound: async (text, { keyboardFocusRef } = {}) => {
    const receipt = await internal.typeBound(text, keyboardFocusRef);
    await waitForIdle();
    return receipt;
  },
  press: async key => { internal.press(key); await waitForIdle(); },

  // waitForIdle({ quiet, timeout }): until no frame has been drawn for `quiet` ms (true), or `timeout` ms (false)
  waitForIdle: options => waitForIdle(options),
  // the screen in points: { width, height, scale }
  screen: () => native.ui.screen(),
  // how long actions, waitFor and expect wait (ms; 5000 to start with)
  setDefaultTimeout: ms => { defaults.timeout = ms; },

  // what's underneath: the accessibility elements as records, the raw accessibility tree, the view hierarchy
  ax: Object.freeze({
    elements: async ({ all = false } = {}) => { await internal.ready(); return internal.collect().filter(e => all || e.visible); },
    tree: async ({ all = false } = {}) => { await internal.ready(); return native.ax.tree(!!all); },
  }),
  views: () => native.ui.views(),
});

const objc = Object.freeze({
  // send(target, "selector:with:", ...args): target is an object from an earlier call, or a class name
  send: (...args) => native.objc.send(...args),
  class: name => native.objc.cls(name),
  describe: object => native.objc.describe(object),
  methods: (className, filter) => native.objc.methods(className, filter),
  classes: filter => native.objc.classes(filter ?? ''),
});

for (const [name, value] of Object.entries({ app, expect: internal.expect, objc, sleep: internal.sleep }))
  Object.defineProperty(globalThis, name, { value, writable: false, enumerable: false, configurable: false });
