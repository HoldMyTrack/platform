import WebKit

/// Settings' avatar made small before the page sends it, as Android's AvatarImage: at most 512
/// pixels on its long side, as JPEG, so a camera photo isn't past the server's limit. iOS hands the
/// picked file to the page itself, so this runs in it, ahead of the page's own listener, which
/// submits the form. An image the page can't decode goes as picked, for the server to judge.
enum AvatarScript {
    static let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)

    static let source = """
    (() => {
      let small = null;
      document.addEventListener('change', (event) => {
        const input = event.target;
        if (!input.matches || !input.matches('#avatar-form input[type=file]')) return;
        const file = input.files[0];
        if (!file || file === small) return;
        event.stopImmediatePropagation();
        const send = () => input.dispatchEvent(new Event('change', { bubbles: true }));
        createImageBitmap(file).then((image) => {
          const scale = Math.min(1, 512 / Math.max(image.width, image.height));
          const canvas = document.createElement('canvas');
          canvas.width = Math.max(1, Math.round(image.width * scale));
          canvas.height = Math.max(1, Math.round(image.height * scale));
          const context = canvas.getContext('2d');
          context.fillStyle = '#fff';
          context.fillRect(0, 0, canvas.width, canvas.height);
          context.drawImage(image, 0, 0, canvas.width, canvas.height);
          return new Promise((done) => canvas.toBlob(done, 'image/jpeg', 0.9));
        }).then((blob) => {
          const files = new DataTransfer();
          files.items.add(new File([blob], 'avatar.jpg', { type: 'image/jpeg' }));
          input.files = files.files;
        }).catch(() => {}).finally(() => {
          small = input.files[0];
          send();
        });
      }, true);
    })();
    """
}
