import { useEffect, useRef, useState } from 'react';
import { ChevronDown } from 'lucide-react';
import { t } from '../i18n/index.ts';
import { useDismiss } from './useDismiss.ts';

interface CheckAllMenuProps {
  /** How many rows there are to check, and how many of them are. */
  total: number;
  checkedCount: number;
  onAll: () => void;
  onNone: () => void;
  onInvert: () => void;
}

/**
 * A toolbar's master checkbox and its ▾ menu (All, None, Invert): the Tracks panel's
 * (TracksToolbar.tsx) and Library's. The checkbox checks every row, or clears them once all are.
 */
export function CheckAllMenu({ total, checkedCount, onAll, onNone, onInvert }: CheckAllMenuProps) {
  // The ▾ menu, dismissed on outside click or Escape.
  const [open, setOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  useDismiss(menuRef, open, setOpen);

  // `indeterminate` is a DOM property with no JSX prop, hence the ref and effect.
  const boxRef = useRef<HTMLInputElement>(null);
  const allChecked = total > 0 && checkedCount === total;
  const someChecked = checkedCount > 0 && !allChecked;
  useEffect(() => {
    if (boxRef.current) boxRef.current.indeterminate = someChecked;
  }, [someChecked]);

  return (
    <>
      <input
        ref={boxRef}
        type="checkbox"
        className="tracks-panel__checkbox"
        checked={allChecked}
        disabled={total === 0}
        aria-label={allChecked ? t('tracks.uncheck_all_label') : t('tracks.check_all_label')}
        title={allChecked ? t('tracks.uncheck_all') : t('tracks.check_all')}
        onChange={() => (allChecked ? onNone() : onAll())}
      />
      <div className="select-menu" ref={menuRef}>
        <button
          type="button"
          className="select-menu__trigger"
          data-testid="select-menu"
          disabled={total === 0}
          aria-haspopup="menu"
          aria-expanded={open}
          aria-label={t('tracks.select_menu')}
          title={t('tracks.select_menu')}
          onClick={() => setOpen((o) => !o)}
        >
          <ChevronDown size={12} />
        </button>
        {open && (
          <div className="trip-menu__panel select-menu__panel" role="group" aria-label={t('tracks.select_menu')}>
            {(
              [
                ['all', t('tracks.select_all'), allChecked, onAll],
                ['none', t('tracks.select_none'), checkedCount === 0, onNone],
                ['invert', t('tracks.select_invert'), false, onInvert],
              ] as const
            ).map(([key, label, disabled, run]) => (
              <button
                key={key}
                type="button"
                className="trip-menu__item"
                data-testid={`select-${key}`}
                disabled={disabled}
                onClick={() => {
                  setOpen(false);
                  run();
                }}
              >
                <span className="trip-menu__name">{label}</span>
              </button>
            ))}
          </div>
        )}
      </div>
    </>
  );
}
