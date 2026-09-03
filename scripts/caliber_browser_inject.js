// Paste into browser DevTools console on the Caliber submission form.
// Fetches attempt-3 pack + notes from GitHub raw; adds 11 Cursor prompt logs.
(async () => {
  const REF = 'a0830fb'; // round3 pack + notes
  const setVal = (el, val) => {
    const d = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value');
    d.set.call(el, val);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };
  const findTa = (hint) =>
    [...document.querySelectorAll('textarea')].find((t) => (t.placeholder || '').includes(hint));

  const [code, notes] = await Promise.all([
    fetch(`https://raw.githubusercontent.com/vikasoffical86/ridgepost-infra/${REF}/RIDGEPOST_SUBMIT.tf`).then((r) => r.text()),
    fetch(`https://raw.githubusercontent.com/vikasoffical86/ridgepost-infra/${REF}/SUBMISSION_NOTES.md`).then((r) => r.text()),
  ]);

  const codeEl = findTa('Paste your code');
  const notesEl = findTa('Describe your approach');
  if (!codeEl || !notesEl) throw new Error('form textareas not found');
  setVal(codeEl, code);
  setVal(notesEl, notes);

  const logs = await fetch(`https://raw.githubusercontent.com/vikasoffical86/ridgepost-infra/${REF}/PROMPT_LOGS.json`).then((r) => r.json());
  const sel = document.querySelector('select');
  const promptEl = findTa('What did you actually ask');
  const respEl = findTa('Response (optional');
  const addBtn = [...document.querySelectorAll('button')].find((b) => b.textContent.trim() === 'Add to log');
  if (!promptEl || !respEl || !addBtn) throw new Error('prompt log fields not found');
  for (const log of logs) {
    if (sel) {
      sel.value = 'cursor';
      sel.dispatchEvent(new Event('change', { bubbles: true }));
    }
    setVal(promptEl, log.promptText);
    setVal(respEl, log.responseText || '');
    addBtn.disabled = false;
    addBtn.click();
  }
  return { codeLen: code.length, notesLen: notes.length, logs: logs.length, codeStart: code.slice(0, 60) };
})();
