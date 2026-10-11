//
//  ConnectionView.swift
//  TypeCam
//

import SwiftUI

struct ConnectionView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        List {
            Section {
                LabeledContent("Name in OBS") {
                    TextField(UIDevice.current.name, text: $store.settings.deviceName)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .autocorrectionDisabled()
                }
                LabeledContent("Port", value: "\(Wire.port)")
                LabeledContent("Protocol", value: "v\(Wire.protocolVersion)")
            } footer: {
                Text("iOS only tells apps this phone is called \"\(UIDevice.current.name)\". Set a name to tell phones apart in OBS.")
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Connect the iPhone to your Mac with a USB cable.")
                    step(2, "Tap Trust on the iPhone if asked.")
                    step(3, "In OBS, add a TypeCam (iPhone) source and pick this device.")
                    step(4, "Keep TypeCam open. Use dim mode instead of locking the phone.")
                }
                .padding(.vertical, 4)
            } header: {
                Text("How to connect")
            } footer: {
                // LocalizedStringKey(String) parses the whole string as Markdown, so the link works.
                Text(LocalizedStringKey("The OBS plugin and setup guide are on [GitHub](\(AppInfo.repositoryURL.absoluteString))."))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accent))
            Text(text).font(.subheadline)
        }
    }
}
