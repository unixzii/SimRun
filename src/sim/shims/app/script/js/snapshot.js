// snapshot.js — the accessibility elements, and the screen as text for agents (app.snapshot()):
//
//   - navigationBar:
//     - button "Showcase" [ref=e1]
//     - heading "Keyboard" [ref=e2]
//   - textbox [ref=e3] value="Type something…" focused
//   - button "Jump" [ref=e4]
//   (6 more off screen: app.snapshot({ all: true }) lists them)
//
// Elements come in reading order, inside the semantic containers they are in (navigation bar, tab bar, toolbar, list,
// table, landmark, labelled group). A ref names the same element in later snapshots for as long as it exists.

// What a ref was last seen as, so that a ref whose element has been replaced (SwiftUI rebuilding a node) still finds
// its successor: ref -> "role\0name\0id".
const signatures = new Map();
const signature = e => `${e.role}\0${e.name}\0${e.id}`;
internal.signatureOf = ref => signatures.get(ref);
internal.signature = signature;

// Before the first look at the elements: load UIKit's accessibility support. When that happens (once per app), UIKit
// goes on loading accessibility bundles in the background for a second or two, and some elements appear only after
// that, later still (UIStepper's buttons, ~0.6 s after the last bundle). So the first look waits until what a script
// would see has stopped changing: the loaded bundles and the elements, unchanged for a second (at most 8 s).
internal.ready = async () => {
  if (!native.ax.ensure())
    return;
  const start = Date.now();
  let seen = '', since = start;
  while (Date.now() - start < 8000) {
    const now = `${native.ax.bundleCount()}|${native.ax.collect().map(signature).join('|')}`;
    if (now !== seen) {
      seen = now;
      since = Date.now();
    } else if (Date.now() - since >= 1000)
      break;
    await internal.sleep(100);
  }
  await internal.waitForIdle();
};

// Every element, on screen or not (records as ax.m describes them). Call internal.ready() first.
internal.collect = () => {
  const elements = native.ax.collect();
  for (const e of elements)
    signatures.set(e.ref, signature(e));
  return elements;
};

const truncate = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;
const quote = s => JSON.stringify(truncate(s.replace(/\s+/g, ' ').trim(), 160));

// One element as a snapshot line (without indentation): role "name" [ref] value id states.
internal.describe = e => {
  let s = e.role;
  if (e.name)
    s += ` ${quote(e.name)}`;
  s += ` [ref=${e.ref}]`;
  if (e.value)
    s += ` value=${quote(e.value)}`;
  if (e.id)
    s += ` id=${quote(e.id)}`;
  for (const state of ['selected', 'disabled', 'focused'])
    if (e[state])
      s += ` ${state}`;
  if (!e.visible)
    s += ' offscreen';
  return s;
};

const groupLine = g => g.name ? `${g.kind} ${quote(g.name)}:` : `${g.kind}:`;
const sameGroup = (a, b) => a.kind === b.kind && a.name === b.name;

internal.snapshot = async ({ all = false } = {}) => {
  await internal.ready();
  const elements = internal.collect();
  const shown = all ? elements : elements.filter(e => e.visible);
  const lines = [];
  let open = [];   // the groups whose header lines have been written, outermost first
  for (const e of shown) {
    let common = 0;
    while (common < open.length && common < e.groups.length && sameGroup(open[common], e.groups[common]))
      common++;
    open = open.slice(0, common);
    for (const g of e.groups.slice(common)) {
      lines.push(`${'  '.repeat(open.length)}- ${groupLine(g)}`);
      open.push(g);
    }
    lines.push(`${'  '.repeat(open.length)}- ${internal.describe(e)}`);
  }
  if (!lines.length)
    lines.push(elements.length ? '(nothing accessible on screen)' : '(no accessibility elements)');
  const hidden = elements.length - shown.length;
  if (hidden)
    lines.push(`(${hidden} more off screen: app.snapshot({ all: true }) lists them)`);
  return lines.join('\n');
};

// --snapshot: the screen once the UI has settled after a script.
internal.afterScript = async () => {
  await internal.waitForIdle();
  return internal.snapshot();
};
