// The site header: its scrolled state, the folded menu on narrow screens, and
// smooth in-page links that land clear of the sticky bar.
import { magnet, q, scrollToY } from './motion';

const hd = q('.hd');
const menu = q<HTMLButtonElement>('.mn', hd);

if ('IntersectionObserver' in window) {
  new IntersectionObserver(([entry]) => hd.classList.toggle('is-sc', !entry?.isIntersecting)).observe(q('.sen'));
}

function open(on: boolean) {
  hd.classList.toggle('is-open', on);
  menu.setAttribute('aria-expanded', String(on));
}
menu.addEventListener('click', () => open(!hd.classList.contains('is-open')));
q('.nav', hd).addEventListener('click', (e) => {
  if ((e.target as Element).closest('a')) open(false);
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') open(false);
});
magnet(q('.btn', hd), 4);

// Chrome drops a fragment link clicked while an earlier smooth scroll is still
// running, so in-page links scroll by hand. `#top` has no element: it is the top.
document.addEventListener('click', (e) => {
  const link = (e.target as Element).closest?.<HTMLAnchorElement>('a[href^="#"]');
  if (!link) return;
  const id = link.getAttribute('href')?.slice(1);
  const target = id ? document.getElementById(id) : null;
  if (!target && id !== 'top') return;
  e.preventDefault();
  scrollToY(target ? target.getBoundingClientRect().top + window.scrollY - hd.offsetHeight : 0);
  history.replaceState(null, '', target ? `#${id}` : location.pathname + location.search);
});
