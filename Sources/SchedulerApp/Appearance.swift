import SwiftUI

// Static native surfaces: no blur, image assets, timers, or offscreen rendering.
enum AppStyle {
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
}

extension View {
    func appCard(border: Color = AppStyle.border, radius: CGFloat = 12) -> some View {
        background(AppStyle.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border, lineWidth: 0.5))
    }
}

struct ToolbarIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .frame(width: 28, height: 28)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct SuggestionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.16 : 0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(contrast == .increased ? Color.primary : Color.accentColor.opacity(0.2), lineWidth: 0.5))
            .contentShape(Capsule())
    }
}

struct SettingsCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 8)
            configuration.content
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).appCard()
    }
}
