/** Hands a downloaded file to the browser to save under `name`, as a link to it would. */
export function saveFile(blob: Blob, name: string): void {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  // In the document: some browsers ignore a click on a link that isn't.
  document.body.appendChild(a);
  a.click();
  a.remove();
  // Revoked later rather than now: some browsers read the URL after click() returns.
  setTimeout(() => URL.revokeObjectURL(a.href), 60_000);
}
