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
                Text(banner.alert.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                title: "claude on mac-studio", body: "Blocked: waiting for your input"))
    ) {}
}
