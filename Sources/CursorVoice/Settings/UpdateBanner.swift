import SwiftUI

/// Banner shown at the top of the Settings window when a newer release
/// is available on GitHub. One click installs and relaunches.
struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let release = checker.availableUpdate {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(checker.currentVersion) → \(release.version)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Release notes") { checker.openReleaseNotes() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button {
                    checker.installNow()
                } label: {
                    if checker.installing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Installing…")
                        }
                    } else {
                        Text("Install & relaunch")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(checker.installing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.separator), alignment: .bottom)
        }
    }
}
