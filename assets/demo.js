'use strict';
const imageDialog = document.querySelector('.image-dialog');
const imagePreview = document.querySelector('[data-image-preview]');
if (imageDialog && imagePreview && typeof imageDialog.showModal === 'function') {
  imagePreview.addEventListener('click', event => {
    // Keep native Ctrl/Cmd-click and the no-JS link to the original image usable.
    if (event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    imageDialog.showModal();
    document.body.classList.add('dialog-open');
  });
  imageDialog.querySelector('.dialog-close').addEventListener('click', () => imageDialog.close());
  imageDialog.addEventListener('click', event => {
    const box = imageDialog.getBoundingClientRect();
    if (event.target === imageDialog && (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom)) imageDialog.close();
  });
  imageDialog.addEventListener('close', () => {
    document.body.classList.remove('dialog-open');
    imagePreview.focus({preventScroll: true});
  });
}
