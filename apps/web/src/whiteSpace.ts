/** `text` without the leading and trailing characters of Unicode's White_Space, as both apps trim
 *  them, so the shared rules' cases hold on every client: `String.prototype.trim` also strips
 *  U+FEFF and keeps U+0085. */
export function trimWhiteSpace(text: string): string {
  return text.replace(/^\p{White_Space}+|\p{White_Space}+$/gu, '');
}
