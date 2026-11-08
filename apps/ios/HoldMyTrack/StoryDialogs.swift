import HoldMyTrackCore
import UIKit

/// The panel's small dialogs: a Story's name and description, sending a copy, a confirmation,
/// and Add to story's menu. Each runs its request after the alert closes and, when it fails,
/// opens again with the server's reason and what was typed.
@MainActor
enum StoryDialogs {
    /// What a dialog's request answers: nil once done, else why it failed.
    typealias Outcome = String?

    static func top(_ view: UIView) -> UIViewController? {
        var top = view.window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    static func name(over view: UIView, title: String, name: String, description: String, action: String, error: String? = nil,
                     run: @escaping (String, String) async -> Outcome) {
        let alert = UIAlertController(title: title, message: error, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = String(localized: "Name")
            $0.text = name
            $0.autocapitalizationType = .sentences
            $0.accessibilityIdentifier = "storyName"
        }
        alert.addTextField {
            $0.placeholder = String(localized: "Description (optional)")
            $0.text = description
            $0.autocapitalizationType = .sentences
            $0.accessibilityIdentifier = "storyDescription"
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .default) { [weak view] _ in
            let typed = (alert.textFields?[0].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let about = (alert.textFields?[1].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                guard let failure = await run(typed, about), let view else { return }
                Self.name(over: view, title: title, name: typed, description: about, action: action, error: failure, run: run)
            }
        })
        top(view)?.present(alert, animated: true)
    }

    /// FR-14.7: a copy to an email address; the server never says whether it has an account.
    static func sendCopy(over view: UIView, story: Story, email: String = "", error: String? = nil, run: @escaping (String) async -> Outcome) {
        let message = error ?? String(localized: "If the address has a HoldMyTrack account, it gets a copy of “\(story.name)” to accept.")
        let alert = UIAlertController(title: String(localized: "Send a copy"), message: message, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = String(localized: "Email")
            $0.text = email
            $0.keyboardType = .emailAddress
            $0.textContentType = .emailAddress
            $0.autocapitalizationType = .none
            $0.accessibilityIdentifier = "sendEmail"
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Send"), style: .default) { [weak view] _ in
            let typed = (alert.textFields?[0].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                let failure = await run(typed)
                guard let view else { return }
                if let failure {
                    Self.sendCopy(over: view, story: story, email: typed, error: failure, run: run)
                } else {
                    Self.inform(over: view, String(localized: "Sent. If \(typed) has an account, the copy waits on their Stories tab."))
                }
            }
        })
        top(view)?.present(alert, animated: true)
    }

    /// A destructive action confirmed first; a failure is shown with the chance to try again.
    static func confirm(over view: UIView, title: String, message: String, action: String, run: @escaping () async -> Outcome) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: .destructive) { [weak view] _ in
            Task {
                guard let failure = await run(), let view else { return }
                Self.confirm(over: view, title: title, message: failure, action: action, run: run)
            }
        })
        top(view)?.present(alert, animated: true)
    }

    static func inform(over view: UIView, _ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        top(view)?.present(alert, animated: true)
    }

    /// Add to story (FR-14.2, FR-14.3): the account's Stories, read as the menu opens, and New
    /// story…; either takes targets() in one request. added reports the Story, and whether it's new.
    static func addToStoryMenu(api: APIClient, over view: UIView, targets: @escaping () -> [String],
                               added: @escaping (Story, _ created: Bool) -> Void) -> UIMenu {
        let create = UIAction(title: String(localized: "New story…"), image: UIImage(resource: .plus)) { [weak view] _ in
            guard let view else { return }
            name(over: view, title: String(localized: "New story"), name: "", description: "", action: String(localized: "Create")) { name, description in
                do {
                    let read = try await api.createStory(name: name, description: description, activityIDs: targets())
                    added(read.story, true)
                    return nil
                } catch {
                    return StoriesPanel.message(error, String(localized: "The Story couldn't be saved."))
                }
            }
        }
        let stories = UIDeferredMenuElement.uncached { [weak view] completion in
            Task { @MainActor in
                guard let read = try? await api.stories() else {
                    completion([UIAction(title: String(localized: "Stories couldn't load."), attributes: .disabled) { _ in }])
                    return
                }
                completion(read.map { item in
                    UIAction(title: item.story.name) { [weak view] _ in
                        Task {
                            do {
                                let changed = try await api.changeStoryActivities(item.story.id, activityIDs: targets(), add: true)
                                added(changed.story, false)
                            } catch {
                                if let view { inform(over: view, StoriesPanel.message(error, String(localized: "The Story couldn't be saved."))) }
                            }
                        }
                    }
                })
            }
        }
        return UIMenu(title: String(localized: "Add to story"), children: [create, UIMenu(options: .displayInline, children: [stories])])
    }
}