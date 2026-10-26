// showcase.js — drives Showcase through `simrun eval`, checking the scripting API on the way; exits 1 at the first
// step that fails. Start from Showcase's home page, freshly launched:
//
//   simrun run build/apps/Showcase.app &
//   simrun eval Showcase -f tests/scripts/showcase.js

const step = async (name, f) => {
  const t = Date.now();
  await f();
  console.log(`ok  ${name} (${Date.now() - t} ms)`);
};
// f must throw an error whose message matches re
const throwsMatching = async (f, re) => {
  try {
    await f();
  } catch (e) {
    if (re.test(e.message))
      return;
    throw e;
  }
  throw new Error(`expected an error matching ${re}`);
};
const back = () => app.getByTestId('BackButton').tap();

await step('home page snapshot', async () => {
  await expect(app.getByRole('heading', { name: 'Showcase' })).toBeVisible();
  const s = await app.snapshot();
  if (!/^- navigationBar:/.test(s) || !s.includes('button "Keyboard'))
    throw new Error(`unexpected snapshot:\n${s}`);
});

await step('open a page', async () => {
  await app.getByRole('button', { name: 'Keyboard' }).tap();
  await expect(app.getByRole('heading', { name: 'Keyboard' })).toBeVisible();
  await expect(app.getByRole('button', { name: 'Multi-Touch' })).toHaveCount(0);   // the home page is gone
});

await step('fill a text field', async () => {
  await app.getByRole('textbox').fill('hello from a test');
  await expect(app.getByRole('textbox')).toHaveValue('hello from a test');
  await expect(app.getByText('4 words')).toBeVisible();
  await app.getByRole('textbox').fill('replaced');
  await expect(app.getByText('1 words')).toBeVisible();
});

await step('tap a button, then its keyboard shortcut', async () => {
  await app.getByRole('button', { name: 'Jump', exact: true }).tap();
  await expect(app.getByRole('text', { name: '1', exact: true })).toBeVisible();
  await app.press('Meta+j');
  await expect(app.getByRole('text', { name: '2', exact: true })).toBeVisible();
});

await step('errors: strict, near matches, timeouts', async () => {
  await throwsMatching(() => app.getByRole('image').tap({ timeout: 500 }), /matches \d+ elements/);
  await throwsMatching(() => app.getByRole('button', { name: 'Jmp' }).tap({ timeout: 500 }), /Similar: button "Jump"/);
  await throwsMatching(() => expect(app.getByText('Nope')).toBeVisible({ timeout: 300 }), /received: no element/);
  await throwsMatching(() => app.getByRole('nope'), /there is no role/);
});

await step('go back', async () => {
  await back();
  await expect(app.getByRole('heading', { name: 'Showcase' })).toBeVisible();
});

await step('tap a button that is off screen (scrolls it into view)', async () => {
  await app.getByRole('button', { name: 'Network' }).tap();
  await expect(app.getByRole('button', { name: 'Run All Requests' })).toBeVisible();
  await back();
});

await step('refs from a snapshot', async () => {
  const ref = (await app.snapshot({ all: true })).match(/button "Keyboard[^\n]*\[ref=(e\d+)\]/)[1];
  await app.ref(ref).tap();
  await expect(app.getByRole('textbox')).toBeVisible();
  await back();
  await expect(app.ref(ref)).toBeVisible();   // the same element, still under the same ref
});

return 'all steps passed';
