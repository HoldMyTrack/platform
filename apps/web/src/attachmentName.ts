/** The file name in a Content-Disposition header, `filename*` (RFC 5987) before `filename`. */
export function attachmentName(header: string | null): string {
  const star = /filename\*=(?:UTF-8'')?([^;]+)/i.exec(header ?? '');
  if (star?.[1]) {
    try {
      return decodeURIComponent(star[1].trim());
    } catch {
      // A malformed escape: fall back to the plain name.
    }
  }
  const plain = /(?:^|;)\s*filename="?([^";]+)"?/i.exec(header ?? '');
  return plain?.[1] ?? 'tracks.gpx';
}
