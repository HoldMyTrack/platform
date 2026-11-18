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
  // One Tab stop per year, not one per active day: the arrows move between a year's days with
  // activity, Home and End to its first and last, and Tab leaves the grid. The stop is today,
  // when it had activity, else the year's last active day.
  document.querySelectorAll('.year-grid').forEach(function (grid) {
    var days = Array.prototype.slice.call(grid.querySelectorAll('button.year-grid__cell'));
    if (days.length === 0) return;
    var stop = grid.querySelector('button.year-grid__cell[data-today]') || days[days.length - 1];
    days.forEach(function (day) { day.tabIndex = day === stop ? 0 : -1; });
    grid.addEventListener('keydown', function (event) {
      var at = days.indexOf(document.activeElement);
      if (at < 0) return;
      var next = { ArrowLeft: at - 1, ArrowUp: at - 1, ArrowRight: at + 1, ArrowDown: at + 1, Home: 0, End: days.length - 1 }[event.key];
      if (next === undefined || next < 0 || next >= days.length) return;
      event.preventDefault();
      days[at].tabIndex = -1;
      days[next].tabIndex = 0;
      days[next].focus();
    });
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
