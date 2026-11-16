/** `color`, a `#rrggbb` or `rgba(r, g, b, a)`, mixed `amount` toward white, alpha kept. */
export function liftColor(color: string, amount: number): string {
  const up = (c: number) => Math.round(c + (255 - c) * amount);
  const hex = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(color);
  if (hex) return '#' + hex.slice(1).map((h) => up(parseInt(h, 16)).toString(16).padStart(2, '0')).join('');
  const rgba = /^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)$/.exec(color);
  if (rgba) return `rgba(${up(+rgba[1]!)}, ${up(+rgba[2]!)}, ${up(+rgba[3]!)}, ${rgba[4] ?? 1})`;
  return color;
}
