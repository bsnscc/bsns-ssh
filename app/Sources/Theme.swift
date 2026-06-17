import SwiftUI

/// Shared UI tokens + components for a refined-native look with brand accents.
/// Screens stay built on SwiftUI `Form`/`List` (familiar, intuitive); these add
/// consistent spacing, a brand primary button, and one pill/tag so chrome reads
/// as one designed product. Mirrors the Android `Design.kt` vocabulary.
enum Layout {
    static let gutter: CGFloat = 16
    static let fieldSpacing: CGFloat = 12
    static let cardCorner: CGFloat = 14
    /// Max width of the saved-hosts pane in the iPad two-column Connect layout.
    static let sidebarWidth: CGFloat = 340
}

/// A full-width call-to-action. `prominent` = filled brand accent (Connect,
/// Enroll); otherwise a tinted outline (secondary actions).
struct BrandButtonStyle: ButtonStyle {
    var prominent: Bool = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                if !isEnabled {
                    shape.fill(Color.gray.opacity(0.16))
                } else if prominent {
                    shape.fill(Brand.accent)
                } else {
                    shape.fill(Brand.accent.opacity(0.12)).overlay(shape.strokeBorder(Brand.accent.opacity(0.45)))
                }
            }
            .foregroundStyle(!isEnabled ? Color.secondary : (prominent ? Brand.background : Brand.accent))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BrandButtonStyle {
    static var brand: BrandButtonStyle { BrandButtonStyle(prominent: true) }
    static var brandOutline: BrandButtonStyle { BrandButtonStyle(prominent: false) }
}

/// A compact status/category pill (mosh, via-jump, key kind, …).
struct Tag: View {
    let text: String
    var color: Color = Brand.accent
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.18), in: Capsule())
        .foregroundStyle(color)
    }
}

/// A labelled field row used in compact forms: a leading caption + the field,
/// so several short fields read clearly without one full-width row each.
struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            content
        }
    }
}
