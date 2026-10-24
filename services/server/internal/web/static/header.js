// The header's menus (templates/header.html): <details> dropdowns, which open and close with
// no script. This makes them behave like menus too: opening one closes the others, and a tap
// or click outside, or Escape, closes whichever is open. It listens in the capture phase, so a
// tap the map handles still closes them. Both page shells load it (layout.html, app/app.html).
(function () {
  'use strict';

  var menus = Array.prototype.slice.call(document.querySelectorAll('.page-header details.header-menu'));

  menus.forEach(function (menu) {
    menu.addEventListener('toggle', function () {
      if (!menu.open) return;
      menus.forEach(function (other) {
        if (other !== menu) other.open = false;
      });
    });
  });

  document.addEventListener(
    'click',
    function (event) {
      menus.forEach(function (menu) {
        if (menu.open && !menu.contains(event.target)) menu.open = false;
      });
    },
    true,
  );

  document.addEventListener('keydown', function (event) {
    if (event.key !== 'Escape') return;
    menus.forEach(function (menu) {
      if (!menu.open) return;
      menu.open = false;
      menu.querySelector('summary').focus();
    });
  });
})();
