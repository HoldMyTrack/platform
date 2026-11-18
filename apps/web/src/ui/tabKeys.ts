import type { KeyboardEvent } from 'react';

/** Which tab an arrow, Home or End key moves to among `count`, from `current`; null for any
 *  other key. The ends wrap, as WAI-ARIA's tabs pattern has them. */
export function nextTab(key: string, current: number, count: number): number | null {
  if (count === 0) return null;
  switch (key) {
    case 'ArrowRight':
      return (current + 1) % count;
    case 'ArrowLeft':
      return (current - 1 + count) % count;
    case 'Home':
      return 0;
    case 'End':
      return count - 1;
    default:
      return null;
  }
}

/** A tab's keys, set on each tab of a tablist: the arrows, Home and End move to a tab and select
 *  it, skipping disabled ones. Tab itself then leaves the list, since only the selected tab is in
 *  the Tab order. */
export function onTabListKeyDown(event: KeyboardEvent<HTMLElement>): void {
  const list = event.currentTarget.closest('[role="tablist"]');
  if (!list) return;
  const tabs = [...list.querySelectorAll<HTMLButtonElement>('[role="tab"]:not(:disabled)')];
  const current = tabs.findIndex((tab) => tab === document.activeElement);
  const next = nextTab(event.key, current < 0 ? 0 : current, tabs.length);
  if (next === null) return;
  event.preventDefault();
  tabs[next]?.focus();
  tabs[next]?.click();
}
