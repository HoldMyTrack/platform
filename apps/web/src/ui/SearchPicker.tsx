import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { ChevronDown, Search } from 'lucide-react';
import { t } from '../i18n/index.ts';
import { useDismiss } from './useDismiss.ts';
import { searchRows } from './pickerSearch.ts';

/** One row of a SearchPicker: `leading` · `label` · `detail` (muted, right-aligned). */
export interface PickerOption {
  value: string;
  label: string;
  detail: string;
  /** Rendered before the label — a flag, a GMT offset. Also shown in the closed trigger. */
  leading?: ReactNode;
  /** Extra search terms beyond the label, already folded (see `fold`). */
  keywords?: string[];
  /** Terms that, typed exactly, float this option to the top — a country's ISO code. */
  exact?: string[];
}

interface SearchPickerProps {
  options: PickerOption[];
  value: string;
  onChange: (value: string) => void;
  /** The id of the visible field label, for the trigger's and list's accessible name. */
  labelledBy: string;
  /** The search input's accessible name, e.g. "Search countries". */
  searchLabel: string;
  /** What the list says when nothing matches the search, given the search text — e.g.
   *  "No type matches “x”". A function, not a noun to build it from, since that sentence
   *  doesn't translate word by word. */
  noMatches: (query: string) => string;
  /** The search input's placeholder; "Search" unless the list is open-ended. */
  placeholder?: string;
  /** An extra first row whose value is `''`, for a field that can be left unset. Shown while
   *  browsing the whole list, left out of search results. */
  unsetOption?: PickerOption;
  /** What the closed picker shows while `value` is `''` and no row carries that value — a
   *  prompt for a required field (Country's "Choose a country"), never itself selectable. */
  emptyLabel?: string;
  /** Makes the list open-ended: while the search text doesn't exactly match an existing
   *  option, this builds an extra last row from it (the Edit window's "Add “Solowheel”"),
   *  so the search field doubles as the field for entering a new value. Returns null for text
   *  that can't be a value (empty, too long). */
  createOption?: (text: string) => PickerOption | null;
}

/**
 * A searchable combobox (trigger button + popover with a search input over a listbox), in
 * place of a native `<select>`, which can't show a right-aligned detail and offers no
 * type-to-filter beyond first-letter jumping. The Edit route dialog's Type field uses it;
 * the server-rendered Settings page's Country and Timezone use its plain-script port
 * (services/server/internal/web/static/search-picker.js — keep the two in step, except that this one never searches a row's detail, a type's count there), and both
 * are styled by that directory's search-picker.css. Follows the WAI-ARIA combobox pattern: focus stays in
 * the search input while ↑/↓ move the active option (`aria-activedescendant`), Enter picks
 * it, Escape closes and returns focus to the trigger. Dismisses on an outside `pointerdown`,
 * like the Tracks panel's Type dropdown. TrackTypePicker.tsx builds the option list,
 * open-ended (`createOption`), since track types are free-form text rather than a fixed
 * vocabulary.
 */
export function SearchPicker({
  options,
  value,
  onChange,
  labelledBy,
  searchLabel,
  noMatches,
  placeholder = t('picker.search'),
  unsetOption,
  emptyLabel,
  createOption,
}: SearchPickerProps) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [active, setActive] = useState(0);
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const listRef = useRef<HTMLUListElement>(null);
  const listId = useId();

  const browseList = useMemo(() => (unsetOption ? [unsetOption, ...options] : options), [options, unsetOption]);
  const shown = useMemo(
    () => (query.trim() ? searchRows(options, query, createOption) : browseList),
    [options, browseList, query, createOption],
  );
  const selected = browseList.find((o) => o.value === value);

  function openPicker() {
    setQuery('');
    setActive(Math.max(0, browseList.findIndex((o) => o.value === value)));
    setOpen(true);
  }

  function close(refocus: boolean) {
    setOpen(false);
    if (refocus) triggerRef.current?.focus();
  }

  function pick(next: string) {
    if (next !== value) onChange(next);
    close(true);
  }

  // A press outside closes it where the focus is; Escape closes it from the input, back on the trigger.
  useDismiss(rootRef, open, setOpen);

  // Centres the current selection on open rather than always starting scrolled to the top,
  // then keeps the active row visible as ↑/↓ walk past the list's edge. Sets the list's own
  // scrollTop rather than calling scrollIntoView, which would scroll the page along with it.
  const justOpened = useRef(false);
  useEffect(() => {
    justOpened.current = open;
  }, [open]);
  useEffect(() => {
    const list = listRef.current;
    const row = list?.children[active] as HTMLElement | undefined;
    if (!list || !row) return;
    if (justOpened.current) {
      justOpened.current = false;
      list.scrollTop = row.offsetTop - (list.clientHeight - row.offsetHeight) / 2;
    } else if (row.offsetTop < list.scrollTop) {
      list.scrollTop = row.offsetTop;
    } else if (row.offsetTop + row.offsetHeight > list.scrollTop + list.clientHeight) {
      list.scrollTop = row.offsetTop + row.offsetHeight - list.clientHeight;
    }
  }, [open, active]);

  function onSearchKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    const last = shown.length - 1;
    switch (event.key) {
      case 'ArrowDown':
        setActive((i) => Math.min(last, i + 1));
        break;
      case 'ArrowUp':
        setActive((i) => Math.max(0, i - 1));
        break;
      case 'PageDown':
        setActive((i) => Math.min(last, i + 8));
        break;
      case 'PageUp':
        setActive((i) => Math.max(0, i - 8));
        break;
      case 'Enter': {
        const option = shown[active];
        if (option) pick(option.value);
        break;
      }
      case 'Escape':
        close(true);
        break;
      case 'Tab':
        close(false);
        return;
      default:
        return;
    }
    event.preventDefault();
  }

  return (
    <div className="search-picker" ref={rootRef}>
      <button
        ref={triggerRef}
        type="button"
        className={`search-picker__trigger${open ? ' search-picker__trigger--open' : ''}`}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-labelledby={labelledBy}
        aria-describedby={`${listId}-value`}
        onClick={() => (open ? close(false) : openPicker())}
        onKeyDown={(e) => {
          if (!open && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
            e.preventDefault();
            openPicker();
          }
        }}
      >
        <span id={`${listId}-value`} className="search-picker__value">
          {selected ? (
            <>
              {selected.leading}
              <span className={`search-picker__label${selected.value ? '' : ' search-picker__label--unset'}`}>{selected.label}</span>
              <span className="search-picker__detail">{selected.detail}</span>
            </>
          ) : value === '' && emptyLabel ? (
            <span className="search-picker__label search-picker__label--unset">{emptyLabel}</span>
          ) : (
            // A value the list doesn't carry (e.g. a timezone this browser's tz database
            // doesn't know) — shown as-is rather than blank, like the old <select>'s extra option.
            <span className="search-picker__label">{value}</span>
          )}
        </span>
        <ChevronDown className="search-picker__chevron" size={14} />
      </button>

      {open && (
        <div className="search-picker__panel">
          <div className="search-picker__search">
            <Search size={16} />
            <input
              autoFocus
              type="text"
              role="combobox"
              aria-label={searchLabel}
              aria-expanded="true"
              aria-controls={listId}
              aria-autocomplete="list"
              aria-activedescendant={shown[active] ? `${listId}-${active}` : undefined}
              placeholder={placeholder}
              autoComplete="off"
              spellCheck={false}
              value={query}
              onChange={(e) => {
                setQuery(e.target.value);
                setActive(0);
              }}
              onKeyDown={onSearchKeyDown}
            />
          </div>

          <ul ref={listRef} id={listId} className="search-picker__list" role="listbox" aria-labelledby={labelledBy}>
            {shown.map((o, i) => (
              <li
                key={o.value || 'unset'}
                id={`${listId}-${i}`}
                role="option"
                aria-selected={o.value === value}
                className={`search-picker__option${i === active ? ' search-picker__option--active' : ''}${
                  o.value === value ? ' search-picker__option--selected' : ''
                }`}
                // Keeps focus in the search input (a pointerdown would otherwise move it onto
                // the row); the click that follows is what commits the choice.
                onPointerDown={(e) => e.preventDefault()}
                onPointerMove={() => i !== active && setActive(i)}
                onClick={() => pick(o.value)}
              >
                {o.leading}
                <span className={`search-picker__label${o.value ? '' : ' search-picker__label--unset'}`}>{o.label}</span>
                <span className="search-picker__detail">{o.detail}</span>
              </li>
            ))}
            {shown.length === 0 && (
              <li className="search-picker__empty" role="presentation">
                {noMatches(query.trim())}
              </li>
            )}
          </ul>
        </div>
      )}
    </div>
  );
}
