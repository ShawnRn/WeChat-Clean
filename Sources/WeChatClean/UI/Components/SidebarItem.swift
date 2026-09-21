import SwiftUI

public struct LogoHeader: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)

            VStack(spacing: 2) {
                Text("微信存储管理")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)

                Text("细粒度清理 · APFS 去重")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

public struct SidebarItem: View {
    @Environment(\.colorScheme) private var colorScheme
    let category: WeChatCategory
    let isSelected: Bool
    let isHovered: Bool
    let badgeText: String?
    let namespace: Namespace.ID
    let action: () -> Void

    public init(
        category: WeChatCategory,
        isSelected: Bool,
        isHovered: Bool,
        badgeText: String? = nil,
        namespace: Namespace.ID,
        action: @escaping () -> Void
    ) {
        self.category = category
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.badgeText = badgeText
        self.namespace = namespace
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? .white : iconColor(for: category))

                Text(category.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer()

                if let badge = badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(isSelected ? .white.opacity(0.25) : .secondary.opacity(0.12))
                        }
                        .foregroundStyle(isSelected ? .white : .secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    if isHovered && !isSelected {
                        Capsule()
                            .fill(.secondary.opacity(0.08))
                            .transition(.opacity)
                    }

                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "sidebar_selection", in: namespace)
                            .shadow(color: Color.accentColor.opacity(0.35), radius: 8, x: 0, y: 3)
                            .overlay {
                                Capsule()
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                .white.opacity(colorScheme == .dark ? 0.3 : 0.6),
                                                .clear,
                                                .white.opacity(colorScheme == .dark ? 0.1 : 0.2)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1
                                    )
                            }
                    }
                }
            }
        }
        .buttonStyle(SidebarButtonStyle())
    }

    private func iconColor(for category: WeChatCategory) -> Color {
        switch category {
        case .all: return .blue
        case .largeFiles: return .orange
        case .duplicates: return .purple
        case .video: return .red
        case .file: return .teal
        case .attach: return .green
        case .cache: return .gray
        }
    }
}

public struct SidebarButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.interactiveSpring(), value: configuration.isPressed)
    }
}
