'use strict';
for (const block of document.querySelectorAll('.code-example')) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'copy-code';
  button.textContent = '复制代码';
  let heading = block.querySelector('.code-heading');
  if (!heading) {
    heading = document.createElement('div');
    heading.className = 'code-heading';
    const title = document.createElement('span');
    title.textContent = '终端命令';
    heading.append(title);
    block.prepend(heading);
  }
  heading.append(button);
  button.addEventListener('click', async () => {
    const status = document.querySelector('#copy-status');
    try {
      if (!navigator.clipboard?.writeText) throw new Error('Clipboard unavailable');
      await navigator.clipboard.writeText(block.querySelector('code').textContent);
      button.textContent = '已复制 ✓';
      if (status) status.textContent = '代码已复制到剪贴板。';
    } catch {
      const selection = getSelection();
      const range = document.createRange();
      range.selectNodeContents(block.querySelector('code'));
      selection.removeAllRanges();
      selection.addRange(range);
      button.textContent = '请手动复制';
      if (status) status.textContent = '已选中代码，请使用系统复制功能。';
    }
    setTimeout(() => {button.textContent = '复制代码';}, 2200);
  });
}
const headings = [...document.querySelectorAll('.docs-article h2[id]')];
const tocLinks = [...document.querySelectorAll('.docs-toc a')];
if (matchMedia('(max-width: 820px)').matches) {
  const toc = document.querySelector('.docs-toc');
  if (toc) toc.open = false;
}
function highlightSection(id) {
  for (const link of tocLinks) {
    if (link.hash === '#' + id) link.setAttribute('aria-current', 'location');
    else link.removeAttribute('aria-current');
  }
}
if (headings.length && 'IntersectionObserver' in window) {
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) if (entry.isIntersecting) highlightSection(entry.target.id);
  }, {rootMargin:'-8% 0px -70% 0px'});
  for (const heading of headings) observer.observe(heading);
}
for (const link of tocLinks) link.addEventListener('click', () => highlightSection(link.hash.slice(1)));
