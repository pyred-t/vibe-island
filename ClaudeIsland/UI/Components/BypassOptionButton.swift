//
//  BypassOptionButton.swift
//  ClaudeIsland
//
//  Bypass button with double-check confirmation for permission prompts.
//  "Don't ask again for this command"
//

import SwiftUI

/// A bypass option button with a double-check confirmation flow.
/// First click: expands to full width, shows confirmation prompt.
/// Second click: confirms and executes the bypass action.
struct BypassOptionButton: View {
    let option: InteractionOption
    let onConfirm: () -> Void
    var fontSize: CGFloat = 11
    var verticalPadding: CGFloat = 8
    var cornerRadius: CGFloat = 10

    @State private var confirmMode = false
    @State private var confirmed = false

    var body: some View {
        if confirmMode {
            HStack(spacing: 6) {
                // Confirm button - full width
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        confirmed = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onConfirm()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: confirmed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: fontSize, weight: .medium))
                        Text(confirmed ? "Bypassing..." : "Don't ask again?")
                            .font(.system(size: fontSize, weight: .semibold))
                    }
                    .foregroundColor(confirmed ? .white : .black.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, verticalPadding)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(confirmed
                                ? TerminalColors.green.opacity(0.8)
                                : TerminalColors.amber.opacity(0.95))
                    )
                }
                .buttonStyle(.plain)
                .disabled(confirmed)

                // Cancel button
                if !confirmed {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            confirmMode = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: max(8, fontSize - 3), weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(verticalPadding)
                            .background(
                                RoundedRectangle(cornerRadius: cornerRadius)
                                    .fill(Color.white.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .transition(.asymmetric(
                insertion: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity),
                removal: .opacity
            ))
        } else {
            // Normal bypass button
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    confirmMode = true
                }
            } label: {
                Text(option.label)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(TerminalColors.amber)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, verticalPadding)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(TerminalColors.amber.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(TerminalColors.amber.opacity(0.3), lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}
