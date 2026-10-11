//
//  AboutView.swift
//  TypeCam
//

import SwiftUI
import UIKit

struct AboutView: View {
    @State private var copiedCommit = false

    var body: some View {
        List {
            header

            Section("Build") {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Build", value: AppInfo.build)
                commitRow
            }

            Section {
                linkRow("Send Feedback on X", systemImage: "bubble.left.and.text.bubble.right", url: AppInfo.feedbackURL)
                linkRow("Follow @\(AppInfo.authorHandle)", systemImage: "person.crop.circle.badge.plus",
                        url: AppInfo.authorProfileURL)
                linkRow("Report an Issue", systemImage: "ladybug", url: AppInfo.newIssueURL)
            } header: {
                Text("Feedback")
            } footer: {
                Text("Feedback opens a post to @\(AppInfo.authorHandle) with your app version and iPhone model filled in.")
            }

            Section {
                linkRow("Source Code", systemImage: "chevron.left.forwardslash.chevron.right",
                        url: AppInfo.repositoryURL, detail: "GitHub")
                linkRow("Website", systemImage: "globe", url: AppInfo.websiteURL)
            } header: {
                Text("Open Source")
            } footer: {
                Text("TypeCam is open source under the MIT License. Made by \(AppInfo.authorName).")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        Section {
            VStack(spacing: 6) {
                Image("AppLogo")
                    .resizable()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
                    .padding(.bottom, 6)
                    .accessibilityHidden(true)
                Text("TypeCam")
                    .font(.title2.weight(.semibold))
                Text("Your iPhone as a wired camera for OBS")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var commitRow: some View {
        if let commit = AppInfo.commit {
            Button {
                UIPasteboard.general.string = commit
                withAnimation { copiedCommit = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation { copiedCommit = false }
                }
            } label: {
                LabeledContent("Commit") {
                    HStack(spacing: 6) {
                        Text(copiedCommit ? "Copied" : commit)
                            .monospaced()
                            .contentTransition(.opacity)
                        Image(systemName: copiedCommit ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .foregroundStyle(Theme.secondaryText)
                }
                .foregroundStyle(.white)
            }
            .contextMenu {
                Button("Copy Commit", systemImage: "doc.on.doc") { UIPasteboard.general.string = commit }
                if let url = AppInfo.commitURL {
                    Link(destination: url) { Label("View on GitHub", systemImage: "arrow.up.right") }
                }
            }
            .accessibilityHint("Copies the commit hash")
        } else {
            LabeledContent("Commit", value: "Development build")
        }
    }

    private func linkRow(_ title: String, systemImage: String, url: URL, detail: String? = nil) -> some View {
        Link(destination: url) {
            HStack {
                Label {
                    Text(title).foregroundStyle(.white)
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(Theme.accent)
                }
                Spacer()
                if let detail {
                    Text(detail).foregroundStyle(Theme.secondaryText)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}
