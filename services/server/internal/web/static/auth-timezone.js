// The browser's timezone for an account's start (FR-1.7), on the sign-in and sign-up pages: the
// sign-up form's hidden field, and ?tz= on the Google, Facebook and Apple links
// (templates/auth.html), which plays that field's role for an account a provider creates.
// Without it an account starts on UTC and Settings asks.
(function () {
  try {
    var zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    var field = document.getElementById('signup-timezone');
    if (field) field.value = zone;
    document.querySelectorAll('.auth-card__provider').forEach(function (a) { a.href += '?tz=' + encodeURIComponent(zone); });
  } catch (e) {}
})();
