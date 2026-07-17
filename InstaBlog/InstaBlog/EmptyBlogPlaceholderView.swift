import SwiftUI

struct EmptyBlogPlaceholderView: View {
    let title: String
    let message: String
    let actionTitle: String
    let onAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 14) {
                Image(systemName: "suitcase")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Empty blog placeholder")

                Text(title)
                    .font(.title3.weight(.semibold))
            }
        } description: {
            Text(message)
        } actions: {
            Button(actionTitle, systemImage: "plus", action: onAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("Empty placeholder \(actionTitle)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
