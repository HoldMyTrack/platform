import { useEffect, useRef, useState, type RefObject } from 'react';
import { centredScrollTop, listWindow } from './listWindow.ts';

/** How far down the list's scrolled content the rows start: 0 when the list is the rows. */
function rowsOffset(list: HTMLElement, rows: HTMLElement): number {
  if (rows === list) return 0;
  return rows.getBoundingClientRect().top - list.getBoundingClientRect().top + list.scrollTop;
}

/**
 * The window of a long list's rows to render (listWindow.ts), for the Tracks tab's list and an
 * open Trip's. `listRef` is the element that scrolls; `rowsRef` holds the rows, the list itself
 * or an element inside it below other content (a Trip's rows sit under the inbox, the folders and
 * its description). Either may come and go: the Tracks list unmounts in Fog, a Trip's rows
 * when it folds. Where the rows start and how tall one is are read on scroll and resize, not on
 * every render, which would force a layout per scroll frame.
 *
 * A newly focused row is centred, by its index, since it may not be drawn, once the rows are
 * shown, measured and hold it. Only the list scrolls, not every ancestor as `scrollIntoView` would:
 * on a phone the collapsed sheet is one, and scrolling it pushed its header out of reach. The
 * rows reloading under a focus leave the scroll where it is.
 */
export function useListWindow(
  listRef: RefObject<HTMLElement | null>,
  rowsRef: RefObject<HTMLElement | null>,
  count: number,
  focused: { id: string | null; index: number },
): { start: number; end: number; rowHeight: number } {
  const [els, setEls] = useState<{ list: HTMLElement | null; rows: HTMLElement | null }>({ list: null, rows: null });
  useEffect(() => {
    const list = listRef.current;
    const rows = rowsRef.current;
    if (list !== els.list || rows !== els.rows) setEls({ list, rows });
  });

  const [view, setView] = useState({ top: 0, height: 600 });
  const [rowHeight, setRowHeight] = useState(0);
  const measureRow = (rows: HTMLElement | null) => {
    const row = rows?.querySelector<HTMLElement>('li[data-track-id]');
    if (row) setRowHeight(row.offsetHeight);
  };
  useEffect(() => {
    const { list, rows } = els;
    if (!list) return;
    const read = () => {
      setView({ top: list.scrollTop - (rows ? rowsOffset(list, rows) : 0), height: list.clientHeight });
      measureRow(rows);
    };
    read();
    list.addEventListener('scroll', read, { passive: true });
    const observer = new ResizeObserver(read);
    observer.observe(list);
    if (rows && rows !== list) observer.observe(rows);
    return () => {
      list.removeEventListener('scroll', read);
      observer.disconnect();
    };
  }, [els]);
  // The first rows to arrive, in a list that hasn't scrolled or resized since.
  useEffect(() => {
    if (rowHeight === 0) measureRow(els.rows);
  });

  const scrolledFor = useRef<string | null>(null);
  useEffect(() => {
    const { list, rows } = els;
    if (focused.id === null) {
      scrolledFor.current = null;
      return;
    }
    if (focused.id === scrolledFor.current || !list || !rows || focused.index < 0 || rowHeight === 0) return;
    scrolledFor.current = focused.id;
    list.scrollTo({ top: centredScrollTop(focused.index, rowsOffset(list, rows), rowHeight, list.clientHeight), behavior: 'smooth' });
  }, [els, focused.id, focused.index, rowHeight]);

  return { ...listWindow(count, rowHeight, view.top, view.height), rowHeight };
}
