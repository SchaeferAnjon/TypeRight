//
//  TRShortcutRecorder.swift
//  TypeRight
//
//  A shortcut picker drawn as a key cap (DESIGN.md): a dashed 选一个键 while nothing is set, the
//  keys once set, a green cap while recording. The recording itself is KeyboardShortcuts'
//  RecorderCocoa, unchanged: it sits invisible under the cap, the cap only makes it first
//  responder, and it keeps its rules (needs a modifier, warns about keys the system or a menu
//  already uses, Esc or a click elsewhere stops, Delete clears).
//

import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

struct TRShortcutRecorder: View {
    let name: KeyboardShortcuts.Name
    @StateObject private var model: Model

    init(name: KeyboardShortcuts.Name) {
        self.name = name
        _model = StateObject(wrappedValue: Model(name: name))
    }

    var body: some View {
        Button { model.startRecording() } label: {
            KeyCap(label: model.label, look: model.look)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RecorderField(model: model))
        .help(model.shortcut == nil ? "点一下，再按下想用的组合键" : "点一下重新设；设的时候按 Delete 清掉")
        .accessibilityLabel(Text(verbatim: model.shortcut.map { "快捷键 \($0.description)" } ?? "快捷键没设"))
    }

    @MainActor
    final class Model: ObservableObject {
        let name: KeyboardShortcuts.Name
        @Published private(set) var shortcut: KeyboardShortcuts.Shortcut?
        @Published private(set) var isRecording = false
        fileprivate weak var field: KeyboardShortcuts.RecorderCocoa?
        private var observers: [NSObjectProtocol] = []

        /// KeyboardShortcuts posts these (internal names, stable in 2.x): a recorder started or
        /// stopped, and a shortcut changed from anywhere (another recorder, a reset).
        private static let recorderActive = Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange")
        private static let shortcutChanged = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")

        init(name: KeyboardShortcuts.Name) {
            self.name = name
            shortcut = KeyboardShortcuts.getShortcut(for: name)
            observers.append(NotificationCenter.default.addObserver(forName: Self.recorderActive, object: nil, queue: .main) { [weak self] note in
                let active = note.userInfo?["isActive"] as? Bool ?? false
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Only one recorder records at a time; ours is the one whose field is being edited.
                    self.isRecording = active && self.field?.currentEditor() != nil
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: Self.shortcutChanged, object: nil, queue: .main) { [weak self] note in
                let changed = note.userInfo?["name"] as? KeyboardShortcuts.Name
                MainActor.assumeIsolated {
                    guard let self, changed == self.name else { return }
                    self.shortcut = KeyboardShortcuts.getShortcut(for: self.name)
                }
            })
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        var look: KeyCap.Look {
            if isRecording { return .recording }
            return shortcut == nil ? .unset : .set
        }

        var label: String {
            if isRecording { return "按下新的组合键…" }
            return shortcut?.description ?? "选一个键"
        }

        func startRecording() {
            guard let field, let window = field.window else {
                Logger.warning("Shortcut recorder for \(name.rawValue) is not in a window yet", category: Logger.ui)
                return
            }
            window.makeFirstResponder(field)
        }

        fileprivate func changed(_ shortcut: KeyboardShortcuts.Shortcut?) {
            self.shortcut = shortcut
        }
    }
}

/// The package's recorder, the same size as the cap and fully transparent: it records, the cap draws.
private struct RecorderField: NSViewRepresentable {
    let model: TRShortcutRecorder.Model

    func makeNSView(context _: Context) -> KeyboardShortcuts.RecorderCocoa {
        let field = KeyboardShortcuts.RecorderCocoa(for: model.name) { [weak model] shortcut in
            MainActor.assumeIsolated { model?.changed(shortcut) }
        }
        field.alphaValue = 0
        field.focusRingType = .none
        model.field = field
        return field
    }

    func updateNSView(_ field: KeyboardShortcuts.RecorderCocoa, context _: Context) {
        field.shortcutName = model.name
        model.field = field
    }

    /// Exactly the cap's size, so the recorder's "clicked outside, stop" check matches what is drawn.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: KeyboardShortcuts.RecorderCocoa, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 30, height: proposal.height ?? 28)
    }
}
