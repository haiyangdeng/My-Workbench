// App-style previews change the preview, while this page keeps its Pixel identity.
const looks = {
  pixel: { title: 'PIXEL / A LITTLE ARCADE ENERGY', tag: '8-BIT SPIRIT', icon: 'icon-pixel.png', alt: 'Workbench in the Pixel look: indigo night, arcade colors and stepped corners', description: 'Indigo nights, bright little pixels, and a matching pixel W. A creative space with a playful side.' },
  ink: { title: 'INK / A QUIETER KIND OF FOCUS', tag: 'THE DEFAULT LOOK', icon: 'icon-512.png', alt: 'Workbench in the Ink look: deep navy surfaces and glowing artwork', description: 'Deep navy, glowing workspaces, and the original sculpted W. Settle in for a little focused work.' },
  paper: { title: 'PAPER / LET A LITTLE LIGHT IN', tag: 'ROOM TO BREATHE', icon: 'icon-512.png', alt: 'Workbench in the Paper look: airy blue and white with pastel illustrations', description: 'Clear skies, soft colors, and the original sculpted W. For the ideas that need a little daylight.' }
};
const tabs = [...document.querySelectorAll('[data-look]')];
function selectLook(tab) {
  const key = tab.dataset.look;
  const look = looks[key];
  if (!look) return;
  tabs.forEach(item => {
    item.setAttribute('aria-selected', String(item === tab));
    item.tabIndex = item === tab ? 0 : -1;
  });
  document.getElementById('look-preview').setAttribute('aria-labelledby', tab.id);
  document.getElementById('look-image').src = `assets/screens/home-${key}.jpg`;
  document.getElementById('look-image').alt = look.alt;
  document.getElementById('look-icon').src = `assets/${look.icon}`;
  document.getElementById('look-name').textContent = look.title;
  document.getElementById('look-tag').textContent = look.tag;
  document.getElementById('look-description').textContent = look.description;
  document.getElementById('look-zoom').dataset.zoom = `assets/screens/home-${key}.jpg`;
  document.getElementById('look-zoom').dataset.caption = `Workbench in the ${key[0].toUpperCase() + key.slice(1)} look`;
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectLook(tab));
  tab.addEventListener('keydown', event => {
    const indices = { ArrowRight: (index + 1) % tabs.length, ArrowLeft: (index + tabs.length - 1) % tabs.length, Home: 0, End: tabs.length - 1 };
    if (!(event.key in indices)) return;
    event.preventDefault();
    const next = tabs[indices[event.key]];
    selectLook(next);
    next.focus();
  });
});

const dialog = document.querySelector('.image-dialog');
let zoomTrigger;
document.querySelectorAll('[data-zoom]').forEach(button => {
  button.addEventListener('click', () => {
    const image = document.getElementById('dialog-image');
    image.src = button.dataset.zoom;
    image.alt = button.querySelector('img').alt;
    document.getElementById('dialog-caption').textContent = button.dataset.caption;
    zoomTrigger = button;
    dialog.showModal();
  });
});
document.querySelector('.dialog-close').addEventListener('click', () => dialog.close());
dialog.addEventListener('click', event => { if (event.target === dialog) dialog.close(); });
dialog.addEventListener('close', () => zoomTrigger?.focus());

// The visible label changes; the status region tells screen readers what happened.
document.querySelectorAll('[data-copy]').forEach(button => {
  const label = button.querySelector('.copy-label');
  const status = button.parentElement.querySelector('[data-copy-status]');
  let reset;
  button.addEventListener('click', async () => {
    const source = document.getElementById(button.dataset.copy);
    if (!source) return;
    try {
      await navigator.clipboard.writeText(source.textContent.trim());
      label.textContent = 'Copied';
      status.textContent = 'Command copied to the clipboard.';
    } catch {
      const range = document.createRange();
      range.selectNodeContents(source);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      label.textContent = 'Selected';
      status.textContent = 'Command selected. Press Command-C to copy it.';
    }
    clearTimeout(reset);
    reset = setTimeout(() => { label.textContent = 'Copy'; status.textContent = ''; }, 1800);
  });
});
