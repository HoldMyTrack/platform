// The About page's screens from the demo account (templates/pages/about.html): a scroll-snap
// strip that swipes and scrolls by itself, given previous and next buttons that wrap round and a
// dot per screen that follows whichever is in view. No autoplay. Without this script the strip
// still scrolls and the controls stay hidden.
(function () {
  'use strict';

  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  // The screen in view: the strip scrolls a whole screen per step.
  function current(track, count) {
    var width = track.clientWidth;
    if (width === 0) return 0;
    return Math.min(count - 1, Math.max(0, Math.round(track.scrollLeft / width)));
  }

  document.querySelectorAll('[data-carousel]').forEach(function (carousel) {
    var track = carousel.querySelector('.page-carousel__track');
    var slides = carousel.querySelectorAll('.page-carousel__slide');
    var dots = carousel.querySelectorAll('[data-carousel-dot]');
    var controls = carousel.querySelector('.page-carousel__controls');
    var count = slides.length;
    if (!track || count < 2) return;

    // The screen last asked for: a press during a smooth scroll steps from it, not from wherever
    // the strip has got to. A swipe sets it once the strip settles.
    var index = current(track, count);

    function show(target) {
      index = ((target % count) + count) % count;
      track.scrollTo({ left: index * track.clientWidth, behavior: reduceMotion.matches ? 'auto' : 'smooth' });
    }

    function mark() {
      var i = current(track, count);
      dots.forEach(function (dot, k) {
        if (k === i) dot.setAttribute('aria-current', 'true');
        else dot.removeAttribute('aria-current');
      });
    }

    carousel.querySelectorAll('[data-carousel-step]').forEach(function (button) {
      button.addEventListener('click', function () {
        show(index + Number(button.getAttribute('data-carousel-step')));
      });
    });
    dots.forEach(function (dot) {
      dot.addEventListener('click', function () {
        show(Number(dot.getAttribute('data-carousel-dot')));
      });
    });

    var pending = 0;
    var settle = 0;
    track.addEventListener('scroll', function () {
      cancelAnimationFrame(pending);
      pending = requestAnimationFrame(mark);
      clearTimeout(settle);
      settle = setTimeout(function () {
        index = current(track, count);
      }, 150);
    });
    mark();
    controls.hidden = false;
  });
})();
