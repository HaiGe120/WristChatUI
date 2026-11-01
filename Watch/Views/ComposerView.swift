//  ComposerView.swift
//  Scroll-positioned reply box for the watch chat. It lives as the
//  final row in ChatView's ScrollView, so it behaves like Messages on
//  Apple Watch: visible at the bottom, out of the way while reading.

import SwiftUI
import WatchKit
import os.log

private let composerLog = Logger(subsystem: "com.wristassistant.app.watchkitapp", category: "ComposerView")

struct ComposerView: View {
    @Binding var text: String
    let isStreaming: Bool
    let canSend: Bool
    let focusTrigger: Int
    let onSend: () -> Void
    let onStop: () -> Void
    let onSubmitText: (String) -> Void

    @State private var isPresentingTextInput = false
    @State private var lastHandledFocusTrigger = 0

    var body: some View {
        HStack(spacing: 6) {
            Button {
                presentTextInput()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(text.isEmpty ? "Message" : text)
                        .font(.caption)
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isStreaming)

            sendButton
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .onChange(of: focusTrigger) { _, _ in
            focusInput()
        }
        .onAppear {
            if focusTrigger > 0 && focusTrigger != lastHandledFocusTrigger {
                focusInput()
            }
        }
    }

    private var sendButton: some View {
        Button {
            composerLog.info("send tapped (canSend=\(self.canSend, privacy: .public), isStreaming=\(self.isStreaming, privacy: .public))")
            if isStreaming { onStop() } else { onSend() }
        } label: {
            Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 26, height: 26)
                .foregroundStyle(.white)
                .background(isStreaming ? Color.red : (canSend ? Color.accentColor : Color.gray.opacity(0.65)))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isStreaming && !canSend)
        .accessibilityLabel(isStreaming ? "Stop response" : "Send message")
        .accessibilityAction(.magicTap) {
            if isStreaming || canSend {
                if isStreaming { onStop() } else { onSend() }
            }
        }
        .handGestureShortcut(.primaryAction, isEnabled: isStreaming || canSend)
    }

    private func focusInput() {
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await MainActor.run {
                presentTextInput()
            }
        }
    }

    private func presentTextInput() {
        guard !isStreaming, !isPresentingTextInput else { return }
        if focusTrigger > 0 {
            lastHandledFocusTrigger = focusTrigger
        }
        guard let controller = WKExtension.shared().visibleInterfaceController else {
            return
        }
        isPresentingTextInput = true
        controller.presentTextInputController(
            withSuggestions: nil,
            allowedInputMode: .allowEmoji
        ) { results in
            Task { @MainActor in
                isPresentingTextInput = false
                guard let value = results?.first as? String else { return }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                text = trimmed
                onSubmitText(trimmed)
            }
        }
    }
}
