// Draws the Play listing's callouts over raw device captures.
// Usage, from the repository root: node brand/play/source/render.mjs brand/play/source/phone.json brand/play/en
// Each shot: { name, raw, callouts: [{ x, y, w, title, body, to: [x, y] }] }, raw relative to the JSON file.
// Coordinates are the capture's own pixels; the output keeps its size. Needs apps/web's Playwright.
import { createRequire } from "node:module";
import { readFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const { chromium } = createRequire(resolve(root, "apps/web/package.json"))("playwright");
const fontDir = resolve(root, "apps/android/holdmytrack/app/src/main/res/font");

const [specPath, outDir] = process.argv.slice(2);
const shots = JSON.parse(readFileSync(specPath, "utf8"));
const base = dirname(resolve(specPath));
mkdirSync(outDir, { recursive: true });

const b64 = (f) => readFileSync(f).toString("base64");
const sizeOf = (png) => {
  const b = readFileSync(png);
  return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) };
};

function page(shot, img, { w, h }) {
  const s = Math.min(w, h) / 1080; // sizes below are for a 1080 px short side, so landscape tablets match portrait
  const boxes = shot.callouts.map((c, i) => `<div class="c" id="c${i}" style="left:${c.x}px;top:${c.y}px;width:${c.w}px">
      <div class="t">${c.title}</div>${c.body ? `<div class="b">${c.body}</div>` : ""}</div>`);
  return `<!doctype html><html><head><style>
    @font-face { font-family: I; src: url(data:font/ttf;base64,${b64(fontDir + "/inter.ttf")}); }
    html, body { margin: 0; width: ${w}px; height: ${h}px; overflow: hidden; }
    img, svg { position: absolute; inset: 0; }
    img { width: ${w}px; height: ${h}px; }
    .c { position: absolute; box-sizing: border-box; background: #FFFFFF; color: #141414;
         border: ${4 * s}px solid #141414; border-radius: ${22 * s}px; padding: ${20 * s}px ${26 * s}px ${22 * s}px;
         box-shadow: 0 ${8 * s}px ${28 * s}px rgba(0,0,0,.30); }
    .t { font: 800 ${36 * s}px/1.15 I; letter-spacing: -0.01em; }
    .b { font: 500 ${25 * s}px/1.32 I; color: #4A4A4A; margin-top: ${6 * s}px; }
  </style></head><body><img src="data:image/png;base64,${b64(img)}">
  <svg width="${w}" height="${h}" id="lines"></svg>
  ${boxes.join("")}
  </body></html>`;
}

const browser = await chromium.launch();
for (const shot of shots) {
  const img = resolve(base, shot.raw);
  const size = sizeOf(img);
  const p = await browser.newPage({ viewport: { width: size.w, height: size.h } });
  await p.setContent(page(shot, img, size), { waitUntil: "load" });
  await p.evaluate(() => document.fonts.ready);
  // A dashed arrow with a white halo, from the card's edge nearest its target.
  await p.evaluate(({ callouts, s }) => {
    const svg = document.getElementById("lines");
    callouts.forEach((c, i) => {
      if (!c.to) return;
      const r = document.getElementById("c" + i).getBoundingClientRect();
      const [tx, ty] = c.to;
      const ax = Math.min(Math.max(tx, r.left + 40 * s), r.right - 40 * s);
      const ay = ty > r.bottom ? r.bottom : ty < r.top ? r.top : r.top + r.height / 2;
      const fx = ty > r.bottom || ty < r.top ? ax : tx < r.left ? r.left : r.right;
      const ang = Math.atan2(ty - ay, tx - fx), L = 26 * s, W = 0.5;
      const h1 = [tx - L * Math.cos(ang - W), ty - L * Math.sin(ang - W)];
      const h2 = [tx - L * Math.cos(ang + W), ty - L * Math.sin(ang + W)];
      const arrow = (stroke, width, dash) =>
        `<line x1="${fx}" y1="${ay}" x2="${tx}" y2="${ty}" stroke="${stroke}" stroke-width="${width}" stroke-linecap="round" stroke-dasharray="${dash}"/>` +
        `<polyline points="${h1} ${tx},${ty} ${h2}" fill="none" stroke="${stroke}" stroke-width="${width}" stroke-linecap="round" stroke-linejoin="round"/>`;
      svg.insertAdjacentHTML("beforeend", arrow("#FFFFFF", 14 * s, "") + arrow("#141414", 6 * s, `${10 * s} ${9 * s}`));
    });
  }, { callouts: shot.callouts, s: Math.min(size.w, size.h) / 1080 });
  await p.screenshot({ path: resolve(outDir, shot.name + ".png") });
  await p.close();
}
await browser.close();
