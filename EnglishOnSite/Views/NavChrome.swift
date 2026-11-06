import SwiftUI
import UIKit

/// Large finger-friendly nav actions (site / gloves).
enum NavChrome {
    /// Hide software keyboard (tap empty / tab change / scroll).
    static func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    static func backToLessons(dismiss: DismissAction) -> some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold))
                Text("Уроки")
                    .font(.body.weight(.semibold))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Назад к урокам")
    }

    static func close(dismiss: DismissAction, title: String = "Закрыть") -> some View {
        Button {
            dismiss()
        } label: {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(minWidth: 72, minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    static func done(action: @escaping () -> Void, title: String = "Готово") -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.bold))
                .frame(minWidth: 80, minHeight: 44)
                .contentShape(Rectangle())
        }
    }
}

extension View {
    /// Tap empty area + interactive scroll dismiss keyboard; does not steal button taps.
    func eosDismissKeyboardOnInteract() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded { NavChrome.dismissKeyboard() }
            )
    }
}
