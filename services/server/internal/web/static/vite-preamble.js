// @vitejs/plugin-react's preamble, loaded only under the Vite dev server (templates/app/app.html):
// its dev server injects this into an index.html it serves itself, and Fast Refresh needs it
// when the HTML comes from a backend (https://vite.dev/guide/backend-integration). A file, not
// an inline script, so dev runs under the production Content-Security-Policy.
import RefreshRuntime from '/@react-refresh';
RefreshRuntime.injectIntoGlobalHook(window);
window.$RefreshReg$ = () => {};
window.$RefreshSig$ = () => (type) => type;
window.__vite_plugin_react_preamble_installed__ = true;
