/**
 * Whether the rows read for `loadedKey` still stand for `queryKey` (both serialised ListRequests)
 * while its own read is in flight. A move of the map keeps the last area's rows until the new
 * ones land; a Trip opened, closed or switched shows none of the last list's, which belong to
 * something else.
 */
export function rowsStandFor(queryKey: string | null, loadedKey: string | null): boolean {
  if (loadedKey === queryKey) return true;
  if (queryKey === null || loadedKey === null) return false;
  return isArea(queryKey) && isArea(loadedKey);
}

function isArea(key: string): boolean {
  return 'area' in (JSON.parse(key) as object);
}
