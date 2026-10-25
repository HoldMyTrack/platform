// The Settings page's avatar and timezone fields (templates/pages/settings.html).

// Picking a file submits the avatar form straight away; without script, its Upload button does.
(function () {
  var form = document.getElementById('avatar-form');
  if (!form) return;
  form.querySelector('input[type=file]').addEventListener('change', function () { if (this.files.length) form.submit(); });
  document.getElementById('avatar-upload').hidden = true;
})();

// The local time beside the timezone, for whichever zone is picked and once a minute, in the
// same shape as web.LocalTime.
(function () {
  var select = document.getElementById('timezone');
  var out = document.getElementById('timezone-local-time');
  if (!select || !out) return;
  function render() {
    try {
      var time = new Intl.DateTimeFormat(document.documentElement.lang || undefined, { timeZone: select.value, month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date());
      out.textContent = out.dataset.template.replace('{time}', time);
      out.hidden = false;
    } catch (e) {
      out.hidden = true;
    }
  }
  select.addEventListener('change', render);
  render();
  setInterval(render, 30000);
})();
