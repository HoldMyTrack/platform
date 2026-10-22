// Writes the "generated" section of the geometric and numeric rule files in
// testdata/client-rules/: seeded random inputs inside each rule's domain, with the expected value
// the web implementation computes. They catch rounding and boundary differences between the
// platforms that no hand-written case reaches. Run by hand after a deliberate rule change, never
// in CI: `npm run gen:rule-cases`. The same seed always writes the same cases.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { rules } from '../tests/clientRuleAdapters.mjs';
import { foldEdit } from '../src/ui/editTrackOps.ts';

const dir = new URL('../../../testdata/client-rules/', import.meta.url);
const COUNT = 200;

/** mulberry32: a small, fast PRNG that is the same everywhere, unlike Math.random. */
function prng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Random helpers over one generator. */
function draw(random) {
  const int = (lo, hi) => lo + Math.floor(random() * (hi - lo + 1));
  const pick = (items) => items[int(0, items.length - 1)];
  const chance = (p) => random() < p;
  const round6 = (v) => Math.round(v * 1e6) / 1e6;
  /** A track as the server sends it: [lon, lat, t], t in epoch ms, rising, coordinates to 1e-6°. */
  const track = (min, max) => {
    const points = [];
    let lon = 13 + random();
    let lat = 52 + random();
    let t = 1788249600000 + int(0, 86400) * 1000;
    for (let i = int(min, max); i > 0; i--) {
      points.push([round6(lon), round6(lat), t]);
      lon += (random() - 0.5) * 4e-4;
      lat += (random() - 0.5) * 4e-4;
      t += int(1, 30) * 1000;
    }
    return points;
  };
  /** Ops over `points`' timestamps, as a session commits them. */
  const ops = (points, max, splits = true) => {
    const times = points.map((p) => p[2]);
    const span = () => {
      const i = int(0, times.length - 1);
      const j = int(i, times.length - 1);
      return [times[i], times[j]];
    };
    const out = [];
    let split = false;
    for (let n = int(0, max); n > 0; n--) {
      const kind = pick(['chop', 'cut', 'drop', 'drop', 'move', 'move', 'reset', 'split']);
      if (kind === 'chop') out.push({ kind, keep: span() });
      else if (kind === 'cut') out.push({ kind, remove: span() });
      else if (kind === 'drop') out.push({ kind, t: pick(times) });
      else if (kind === 'move') out.push({ kind, t: pick(times), to: [round6(13 + random()), round6(52 + random())] });
      else if (kind === 'reset') out.push({ kind });
      else if (splits && !split) {
        split = true;
        out.push({ kind, t: pick(times) });
      }
    }
    return out;
  };
  /** Ascending, distinct activity-days, starting near 2026-09-01. */
  const days = (min, max) => {
    const out = [];
    let day = Date.UTC(2026, 8, int(1, 28));
    for (let n = int(min, max); n > 0; n--) {
      out.push(new Date(day).toISOString().slice(0, 10));
      day += int(1, 6) * 86400000;
    }
    return out;
  };
  /** A date range near `list` (2026-09-01 when empty), from ≤ to. */
  const range = (list) => {
    const first = Date.parse(list[0] ?? '2026-09-01');
    const last = Date.parse(list.at(-1) ?? '2026-09-01');
    const at = () => new Date(first + int(-10, Math.round((last - first) / 86400000) + 10) * 86400000).toISOString().slice(0, 10);
    const [a, b] = [at(), at()].sort();
    return { from: a, to: b };
  };
  /** Photo-track points: { lon, lat, t }, t in epoch seconds, never falling; some legs stand still. */
  const timed = (min, max) => {
    const out = [];
    let lon = 10 + random() * 0.1;
    let lat = 50 + random() * 0.1;
    let t = 1780000000 + int(0, 86400);
    for (let n = int(min, max); n > 0; n--) {
      out.push({ lon: round6(lon), lat: round6(lat), t });
      if (!chance(0.2)) {
        lon += (random() - 0.5) * 0.02;
        lat += (random() - 0.5) * 0.02;
      }
      t += int(0, 600);
    }
    return out;
  };
  /** Screen points with ids p0.., some outside a width × height frame. */
  const screen = (max, width = 300, height = 300) =>
    Array.from({ length: int(0, max) }, (_, i) => ({ id: `p${i}`, x: int(-60, width + 60), y: int(-60, height + 60) }));
  return { int, pick, chance, random, round6, track, ops, days, range, timed, screen };
}

/** Input generators by rule, each inside the domain its implementations accept. */
const inputs = {
  editTrackFold: (d) => {
    const points = d.track(2, 12);
    return { base: d.chance(0.4) ? foldEdit(null, d.ops(points, 4, false)) : null, ops: d.ops(points, 8) };
  },
  editTrackApply: (d) => {
    const points = d.track(0, 15);
    return { points, edit: points.length ? foldEdit(null, d.ops(points, 6, false)) : {} };
  },
  editTrackChop: (d) => knobs(d),
  editTrackCut: (d) => knobs(d),
  editTrackSplitIndex: (d) => knobs(d),
  editTrackSplitPoint: (d) => ({ ops: d.ops(d.track(2, 12), 8) }),
  editTrackMove: (d) => ({ t: 1788249600000 + d.int(0, 1e9), lon: (d.random() - 0.5) * 360, lat: (d.random() - 0.5) * 170 }),
  editTrackDistances: (d) => ({ points: d.track(0, 20) }),
  photoClusters: (d) => ({ points: d.screen(15), radius: d.pick([18, 32, d.int(5, 60)]) }),
  photoMarkerLayout: (d) => {
    const width = d.int(80, 400);
    const height = d.int(80, 400);
    const points = d.screen(12, width, height);
    const id = () => (points.length && d.chance(0.4) ? d.pick(points).id : null);
    return { points, zoom: d.round6(d.random() * 16), activeId: id(), loneId: id(), width, height, scale: d.pick([1, 1.5, 2, 3]) };
  },
  photoTrackPoint: (d) => ({ points: d.timed(1, 10), fraction: d.chance(0.1) ? d.pick([0, 1]) : d.random() }),
  photoTrackFraction: (d) => {
    const points = d.timed(1, 10);
    return { points, t: d.int(points[0].t - 200, points.at(-1).t + 200) };
  },
  photoTrackStart: (d) => {
    const points = d.timed(1, 8);
    const t = () => ({ t: d.int(points[0].t - 100, points.at(-1).t + 100) });
    const ids = ['a', 'b', 'c', 'd', 'e'].slice(0, d.int(0, 5));
    const anchors = {};
    const placed = {};
    ids.forEach((id, i) => {
      anchors[id] = i > 0 && d.chance(0.5) ? { waiting: ids[d.int(0, i - 1)] } : d.chance(0.5) ? t() : null;
      placed[id] = d.chance(0.6) ? d.random() : null;
    });
    const anchor = ids.length && d.chance(0.6) ? { waiting: d.pick(ids) } : d.chance(0.5) ? t() : null;
    return { points, anchor, placed, anchors };
  },
  sliderLayout: (d) => ({ width: d.int(120, 1400), finePointer: d.chance(0.5) }),
  sliderBoundaries: (d) => window(d),
  sliderMoveKnob: (d) => {
    const input = window(d);
    const lo = input.canPanEarlier ? -1 : 0;
    const hi = input.days.length + (input.canPanLater ? 1 : 0);
    return { ...input, knob: d.pick(['start', 'end']), boundary: d.int(lo, hi) };
  },
  sliderTicks: (d) => ({ days: d.days(0, 25) }),
  sliderPanLand: (d) => {
    const days = d.days(0, 12);
    return { days, range: d.range(days), start: d.chance(0.5), end: d.chance(0.5) };
  },
  sliderWindowFit: (d) => {
    const count = d.int(1, 120);
    const windowDays = d.int(7, 31);
    const first = d.int(0, count - 1);
    return { count, windowDays, left: d.int(0, Math.max(0, count - windowDays)), first, last: d.int(first, count - 1), dir: d.pick([-1, 1]) };
  },
};

function knobs(d) {
  const visible = d.track(1, 15);
  const lo = d.int(0, visible.length - 1);
  return { visible, lo, hi: d.int(lo, visible.length - 1) };
}

function window(d) {
  const days = d.days(0, 15);
  return { days, canPanEarlier: d.chance(0.5), canPanLater: d.chance(0.5), range: d.range(days) };
}

/** A stable seed per rule, so adding a rule leaves the others' cases as they were. */
const seedOf = (rule) => [...rule].reduce((h, c) => Math.imul(h ^ c.charCodeAt(0), 16777619) >>> 0, 2166136261);

for (const name of readdirSync(dir).filter((n) => n.endsWith('.json'))) {
  const url = new URL(name, dir);
  const text = readFileSync(url, 'utf8');
  const { rule } = JSON.parse(text);
  const make = inputs[rule];
  if (!make) continue;
  const d = draw(prng(seedOf(rule)));
  const lines = [];
  for (let i = 1; i <= COUNT; i++) {
    const input = make(d);
    const expected = JSON.parse(JSON.stringify(rules[rule](input) ?? null));
    lines.push(`    ${JSON.stringify({ name: `generated ${i}`, input, expected })}`);
  }
  // The hand-written part stays byte for byte; only the generated section is rewritten.
  const cut = text.indexOf(',\n  "generated": [');
  const head = cut >= 0 ? text.slice(0, cut) : text.slice(0, text.lastIndexOf('}')).trimEnd();
  writeFileSync(url, `${head},\n  "generated": [\n${lines.join(',\n')}\n  ]\n}\n`);
  console.log(`${name}: ${COUNT} cases`);
}
