// The Profile page's tap fallbacks for its hover tooltips (templates/pages/profile.html), which
// a touch screen never shows: a tap on a year-grid day or a trends bar shows its title under it,
// and a second tap hides it.
(function () {
  var current = null;
  function select(cell) {
    if (current) {
      current.classList.remove('year-grid__cell--selected');
      current.closest('.year-grid').querySelector('.year-grid__detail').hidden = true;
    }
    current = cell;
    if (!cell) return;
    cell.classList.add('year-grid__cell--selected');
    var detail = cell.closest('.year-grid').querySelector('.year-grid__detail');
    detail.textContent = cell.title;
    detail.hidden = false;
  }
  document.querySelectorAll('.year-grid__cell[title]').forEach(function (cell) {
    cell.addEventListener('click', function () { select(current === cell ? null : cell); });
  });
  // A year is wider than a phone: open this year's on today rather than on January.
  var today = document.querySelector('.year-grid__cell[data-today]');
  if (today) {
    var body = today.closest('.year-grid__body');
    var past = today.getBoundingClientRect().right - body.getBoundingClientRect().right;
    if (past > 0) body.scrollLeft += past + 24;
  }
})();

(function () {
  var detail = document.getElementById('trends-detail'), current = null;
  if (!detail) return;
  document.querySelectorAll('.trends__bar').forEach(function (bar) {
    bar.addEventListener('click', function () {
      current = current === bar ? null : bar;
      detail.textContent = current ? bar.title : '';
      detail.hidden = !current;
    });
  });
})();
