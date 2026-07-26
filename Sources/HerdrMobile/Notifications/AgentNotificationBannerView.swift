import SwiftUI

/// The in-app Agent Notification banner (#77): a thin top overlay rendering
/// the push copy. Every decision — when to show, suppress, and dismiss —
/// lives in `AgentNotificationBannerStore`; this view only draws the alert
/// and forwards the tap.
struct AgentNotificationBannerView: View {
    let banner: AgentNotificationBanner
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.alert.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle = banner.alert.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(banner.alert.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    AgentNotificationBannerView(
        banner: AgentNotificationBanner(
            target: AgentNotificationTarget(hostID: UUID(), paneID: "%5"),
            alert: AgentNotificationAlert(
                title: "herdr-mobile", subtitle: "claude on mac-studio",
                body: "Blocked · 排查修复 split 按钮 UI 结构问题"))
    ) {}
}
