// The page's light/dark theme before anything paints (templates/theme.html): loaded without
// defer, ahead of the stylesheets, so a dark choice never flashes light first.
try {
  var theme = localStorage.getItem('hmt_theme');
  if (theme === 'light' || theme === 'dark') document.documentElement.dataset.theme = theme;
} catch (e) {}
