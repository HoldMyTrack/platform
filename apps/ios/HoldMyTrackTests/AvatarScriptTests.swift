import Testing
import WebKit

@testable import HoldMyTrack

/// The avatar a page's form sends, with the app's script in it.
@MainActor
struct AvatarScriptTests {
    /// What the form holds when the page's own listener hears of the pick: name, type and size.
    private func sent(_ pick: String, then: String = "") async throws -> [String: Any] {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(AvatarScript.script)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 300), configuration: config)
        web.loadHTMLString("<form id='avatar-form'><input type='file'></form>", baseURL: URL(string: "https://example.test/"))
        while web.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        let result = try await web.callAsyncJavaScript("""
            const input = document.querySelector('input');
            const heard = new Promise((done) => input.addEventListener('change', async () => {
              const file = input.files[0];
              let side = null;
              try { const image = await createImageBitmap(file); side = [image.width, image.height]; } catch {}
              done({ name: file.name, type: file.type, side });
            }));
            const files = new DataTransfer();
            files.items.add(await (async () => { \(pick) })());
            input.files = files.files;
            input.dispatchEvent(new Event('change', { bubbles: true }));
            \(then)
            return await heard;
            """, contentWorld: .page)
        return try #require(result as? [String: Any])
    }

    @Test func aLargePhotoIsShrunk() async throws {
        let sent = try await sent("""
            const canvas = document.createElement('canvas'); canvas.width = 3000; canvas.height = 2000;
            canvas.getContext('2d').fillRect(0, 0, 3000, 2000);
            return new File([await new Promise((d) => canvas.toBlob(d, 'image/png'))], 'photo.png', { type: 'image/png' });
            """)
        #expect(sent["type"] as? String == "image/jpeg")
        #expect(sent["side"] as? [Int] == [512, 341])
    }

    @Test func anImageThatCantBeEncodedGoesAsPicked() async throws {
        let sent = try await sent("""
            const canvas = document.createElement('canvas'); canvas.width = canvas.height = 40;
            const blob = await new Promise((d) => canvas.toBlob(d, 'image/png'));
            HTMLCanvasElement.prototype.toBlob = function (done) { done(null); };
            return new File([blob], 'photo.png', { type: 'image/png' });
            """)
        #expect(sent["name"] as? String == "photo.png")
    }

    @Test func aSecondPickReplacesTheFirst() async throws {
        let sent = try await sent("""
            const canvas = document.createElement('canvas'); canvas.width = 3000; canvas.height = 2000;
            return new File([await new Promise((d) => canvas.toBlob(d, 'image/png'))], 'first.png', { type: 'image/png' });
            """, then: """
            const other = document.createElement('canvas'); other.width = 100; other.height = 60;
            const second = new DataTransfer();
            second.items.add(new File([await new Promise((d) => other.toBlob(d, 'image/png'))], 'second.png', { type: 'image/png' }));
            input.files = second.files;
            input.dispatchEvent(new Event('change', { bubbles: true }));
            """)
        #expect(sent["side"] as? [Int] == [100, 60])
    }

    @Test func aFileItCantReadGoesAsPicked() async throws {
        let sent = try await sent("return new File(['no image'], 'notes.txt', { type: 'text/plain' });")
        #expect(sent["name"] as? String == "notes.txt")
    }
}
