/** The file name in a Content-Disposition header, `filename*` (RFC 5987, `charset'language'value`)
 *  before `filename` (`testdata/client-rules/attachment-name.json`). */
export function attachmentName(header: string | null): string {
  const star = /filename\*=(?:([^';]*)'[^';]*')?([^;]+)/i.exec(header ?? '');
  if (star?.[2] && (star[1] === undefined || star[1].toLowerCase() === 'utf-8')) {
    try {
      return decodeURIComponent(star[2].trim());
    } catch {
      // A malformed escape: fall back to the plain name.
    }
  }
  const plain = /(?:^|;)\s*filename="?([^";]+)"?/i.exec(header ?? '');
  return plain?.[1] ?? 'tracks.gpx';
}
