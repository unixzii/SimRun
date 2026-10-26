// sui.js — drives the SwiftUI test app (a List with a stepper, a text field, a toggle and navigation links) through
// `simrun eval`; exits 1 at the first step that fails. Start from a fresh launch:
//
//   simrun run build/apps/SUI.app &
//   simrun eval SUI -f tests/scripts/sui.js

const step = async (name, f) => {
  const t = Date.now();
  await f();
  console.log(`ok  ${name} (${Date.now() - t} ms)`);
};

await step('reading order: navigation bar, then each section header before its rows', async () => {
  const lines = (await app.snapshot()).split('\n');
  const at = s => lines.findIndex(l => l.includes(s));
  if (!(at('navigationBar') === 0 && at('"Counter"') < at('Increment') && at('Increment') < at('"Rows"') && at('"Rows"') < at('"Row 0"'))) {
    throw new Error(`unexpected order:\n${lines.join('\n')}`);
  }
});

await step('stepper buttons', async () => {
  await app.getByTestId('Increment').tap();
  await app.getByTestId('Increment').tap();
  await app.getByTestId('Decrement').tap();
  await expect(app.getByTestId('Increment')).toHaveValue('1');
});

await step('toggle (taps its switch, not the middle of its row)', async () => {
  const toggle = app.getByRole('switch', { name: 'A toggle' });
  await expect(toggle).toHaveValue('on');
  await toggle.tap();
  await expect(toggle).toHaveValue('off');
  await toggle.tap();
  await expect(toggle).toHaveValue('on');
});

await step('text field', async () => {
  await app.getByRole('textbox').fill('typed by sui.js');
  await expect(app.getByRole('textbox')).toHaveValue('typed by sui.js');
  await expect(app.getByRole('textbox')).toBeFocused();
});

await step('navigation link and back', async () => {
  await app.getByRole('button', { name: 'Row 3' }).tap();
  await expect(app.getByText('Detail 3')).toBeVisible();
  await app.getByTestId('BackButton').tap();
  await expect(app.getByText('Detail 3')).toBeHidden();
});

return 'all steps passed';
