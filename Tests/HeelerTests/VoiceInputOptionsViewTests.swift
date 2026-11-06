import Observation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Voice Input options UI", .serialized)
struct VoiceInputOptionsViewTests {
    @Test func languagesCanSelectMixedSpeechAndReturnToAutomatic() async throws {
        let state = VoiceOptionsViewState()
        let controller = UIHostingController(rootView: VoiceOptionsTestView(state: state, custom: false))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { window in
            try await activate("Languages", in: window)
            try await activate(VoiceInputLanguage.name("zh"), in: window)
            try await activate(VoiceInputLanguage.name("en"), in: window)
            try await waitUntil { state.languages == ["zh", "en"] }
            try await activate("Automatic", in: window)
            try await waitUntil { state.languages.isEmpty }
        }
    }

    @Test func customFieldsCanBeAddedAndEditedWithMultipleValues() async throws {
        let state = VoiceOptionsViewState()
        let controller = UIHostingController(rootView: VoiceOptionsTestView(state: state, custom: true))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { window in
            try await activate("Add Field", in: window)
            try await waitUntil { state.fields.count == 1 }
            try await activate("New Field", in: window)
            try await waitUntil { !views(UITextField.self, in: window).isEmpty }
            let name = try #require(views(UITextField.self, in: window).first)
            name.text = "languages[]"
            name.sendActions(for: .editingChanged)
            try await waitUntil { state.fields.first?.name == "languages[]" }
            try await waitUntil { !views(UITextView.self, in: window).isEmpty }
            let first = try #require(views(UITextView.self, in: window).first)
            first.text = "zh"
            first.delegate?.textViewDidChange?(first)
            try await activate("Add Value", in: window)
            try await waitUntil { views(UITextView.self, in: window).count == 2 }
            let second = try #require(views(UITextView.self, in: window).last)
            second.text = "en"
            second.delegate?.textViewDidChange?(second)
            try await waitUntil { state.fields.first?.values == ["zh", "en"] }
            let endpoint = VoiceInputEndpoint.custom(
                baseURL: try #require(URL(string: "https://asr.example.com")), model: "asr")
            try VoiceInputRequestOptions(fields: state.fields).validate(for: endpoint)
        }
    }

    private func activate(_ label: String, in window: UIWindow) async throws {
        var budget = PollBudget(.seconds(3))
        while accessibleElement(labeled: label, in: window) == nil, budget.hasTimeLeft {
            try await Task.sleep(for: .milliseconds(20))
            budget.charge()
        }
        #expect(accessibleElement(labeled: label, in: window) != nil,
                "Missing \(label); labels: \(accessibleElements(in: window).compactMap(\.accessibilityLabel))")
        let element = try #require(accessibleElement(labeled: label, in: window))
        #expect(element.accessibilityActivate(), "Could not activate \(label)")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        var budget = PollBudget(.seconds(3))
        while !condition(), budget.hasTimeLeft {
            try await Task.sleep(for: .milliseconds(20))
            budget.charge()
        }
        try #require(condition())
    }

    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
    }
}

@MainActor @Observable
private final class VoiceOptionsViewState {
    var languages: [String] = []
    var fields: [VoiceInputCustomField] = []
}

private struct VoiceOptionsTestView: View {
    @Bindable var state: VoiceOptionsViewState
    let custom: Bool

    var body: some View {
        NavigationStack {
            Form {
                if custom {
                    VoiceInputCustomFieldsSection(fields: $state.fields)
                } else {
                    VoiceInputLanguagesSection(preset: .openAI, languages: $state.languages)
                }
            }
        }
    }
}
