import { useRef, useState, type ReactNode } from 'react';
import { ChevronDown } from 'lucide-react';
import { useDismiss } from './useDismiss.ts';

interface PickMenuProps {
  /** The `data-testid` of the whole control, which the tour anchors on. */
  testId: string;
  label: string;
  icon: ReactNode;
  /** How many are picked, shown on the button, greyed while the checkbox is off. */
  count: number;
  /** The checkbox before the button: the picks are drawn only while it's on. */
  enabled: boolean;
  onEnabledChange: (on: boolean) => void;
  masterId: string;
  masterLabel: string;
  /** The checkbox's hint while nothing is picked and it has nothing to show. */
  emptyHint: string;
  /** Held open from outside, whatever the button says: the tour's step on this menu. */
  forceOpen?: boolean;
  children: ReactNode;
}

/**
 * A dropdown of picks beside the map-mode toggle, the shell of the Layers and Places menus: the
 * same open/close rules as the Activities panel's Type dropdown, the button toggling it and a
 * press outside or Escape closing it. The button shows how many are picked, and the checkbox
 * before it shows or hides all of them at once, keeping the picks.
 */
export function PickMenu({ testId, label, icon, count, enabled, onEnabledChange, masterId, masterLabel, emptyHint, forceOpen = false, children }: PickMenuProps) {
  const [picked, setOpen] = useState(false);
  const open = picked || forceOpen;
  const ref = useRef<HTMLDivElement>(null);

  useDismiss(ref, open, setOpen);

  const shown = enabled && count > 0;
  return (
    <div className="map-mode-toggle overlays-menu" ref={ref} data-testid={testId}>
      <label className="overlays-menu__master" title={count === 0 ? emptyHint : undefined}>
        <input id={masterId} type="checkbox" aria-label={masterLabel} checked={enabled} disabled={count === 0} onChange={() => onEnabledChange(!enabled)} />
      </label>
      <button
        type="button"
        className={shown ? 'map-mode-toggle__btn map-mode-toggle__btn--active' : 'map-mode-toggle__btn'}
        aria-haspopup="true"
        aria-expanded={open}
        onClick={() => !forceOpen && setOpen((o) => !o)}
      >
        {icon}
        {label}
        {count > 0 && <span className={shown ? 'overlays-menu__count' : 'overlays-menu__count overlays-menu__count--off'}>{count}</span>}
        <ChevronDown size={14} aria-hidden="true" />
      </button>
      {open && (
        <div className="overlays-menu__panel" role="dialog" aria-label={label}>
          {children}
        </div>
      )}
    </div>
  );
}

/** One pick in a PickMenu's panel, with what follows its label (a line sample) in `after`. */
export function PickItem({ id, label, checked, onToggle, after }: { id: string; label: string; checked: boolean; onToggle: () => void; after?: ReactNode }) {
  return (
    <label htmlFor={id} className="overlays-menu__item">
      <input id={id} type="checkbox" checked={checked} onChange={onToggle} />
      <span>{label}</span>
      {after}
    </label>
  );
}
