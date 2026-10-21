import SwiftUI

struct MenuRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let highlighted = isEnabled && (hovering || configuration.isPressed)
        configuration.label
            .foregroundStyle(isEnabled ? (highlighted ? Color.white : Color.primary) : Color.secondary)
            .background(highlighted ? Color.accentColor : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}
