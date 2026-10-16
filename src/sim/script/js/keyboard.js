// keyboard.js — key names, as Playwright spells them ("Enter", "Meta+A", "Shift+Tab"), to HID key presses; and text,
// typed or filled in through the app's input method.

const usages = {
  Enter: 0x28, Escape: 0x29, Backspace: 0x2a, Tab: 0x2b, Space: 0x2c, ' ': 0x2c, Delete: 0x4c,
  ArrowRight: 0x4f, ArrowLeft: 0x50, ArrowDown: 0x51, ArrowUp: 0x52, Home: 0x4a, PageUp: 0x4b, End: 0x4d, PageDown: 0x4e,
  '-': 0x2d, '=': 0x2e, '[': 0x2f, ']': 0x30, '\\': 0x31, ';': 0x33, "'": 0x34, '`': 0x35, ',': 0x36, '.': 0x37, '/': 0x38,
};
for (let i = 0; i < 26; i++) usages[String.fromCharCode(97 + i)] = 0x04 + i;   // a-z
for (let i = 1; i <= 9; i++) usages[String(i)] = 0x1e + i - 1;                 // 1-9
usages['0'] = 0x27;
for (let i = 1; i <= 12; i++) usages[`F${i}`] = 0x3a + i - 1;
const modifiers = { Shift: 0xe1, Control: 0xe0, Alt: 0xe2, Option: 0xe2, Meta: 0xe3, Command: 0xe3, ControlOrMeta: 0xe3 };

// press("Meta+A"): the modifiers down, the key down and up, the modifiers up.
internal.press = spec => {
  const parts = String(spec).split('+');
  const keyName = parts.pop() || '+';
  const mods = parts.map(m => {
    if (!(m in modifiers)) throw new Error(`press: unknown modifier "${m}" in "${spec}" (${Object.keys(modifiers).join(', ')})`);
    return modifiers[m];
  });
  const key = usages[keyName] ?? (keyName.length === 1 ? usages[keyName.toLowerCase()] : undefined);
  if (key === undefined) throw new Error(`press: unknown key "${keyName}" (keys are named like Enter, Tab, ArrowDown, a, 1, F1)`);
  for (const m of mods) native.ui.key(m, true);
  native.ui.key(key, true);
  native.ui.key(key, false);
  for (const m of mods.reverse()) native.ui.key(m, false);
};

// type(action, text) / fill(action, text): text into the focused text input through the app's input method
// (textinput.md), once the keys sent before it have reached the app: keys go through UIKit's event queue, text goes in
// at once. type commits one character at a time, as typed, with Enter and Tab as keys; fill replaces all the text.
const keysHandled = () => new Promise(resolve => native.ui.afterKeys(resolve));
const noFocus = action => new Error(`${action}: no text input has keyboard focus`);
internal.type = async (action, text) => {
  for (const part of String(text).split(/([\n\t])/)) {
    if (part === '\n' || part === '\t') internal.press(part === '\n' ? 'Enter' : 'Tab');
    else if (part) { await keysHandled(); if (!native.ui.type(part)) throw noFocus(action); }
  }
};
internal.fill = async (action, text) => {
  await keysHandled();
  if (!native.ui.fill(String(text))) throw noFocus(action);
};

// Bound typing is literal text, not Enter/Tab HID routing. Legacy type/fill keep
// their existing behavior. Check native capability before doing anything.
internal.typeBound = async (text, keyboardFocusRef) => {
  if (typeof native.ui.typeBound !== 'function')
    return { ok: false, code: 'BOUND_TYPE_UNAVAILABLE', inserted_count: 0, partial: false };
  await keysHandled();
  return native.ui.typeBound(String(text), String(keyboardFocusRef ?? ''));
};
