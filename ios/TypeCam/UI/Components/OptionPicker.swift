//
//  OptionPicker.swift
//  TypeCam
//

import SwiftUI

/// A settings row showing the current value that pushes a full-width checkmark list,
/// like iOS Settings. Each option can carry a subtitle; the page can carry a footer.
struct OptionPicker<Value: Hashable>: View {
    let title: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var detail: (Value) -> String? = { _ in nil }
    var footer: String?

    var body: some View {
        NavigationLink {
            OptionList(
                title: title,
                options: options,
                selection: $selection,
                label: label,
                detail: detail,
                footer: footer
            )
        } label: {
            LabeledContent(title, value: label(selection))
        }
    }
}

private struct OptionList<Value: Hashable>: View {
    let title: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    let detail: (Value) -> String?
    let footer: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(option))
                                    .foregroundStyle(.primary)
                                if let detail = detail(option) {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if option == selection {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                if let footer { Text(footer) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
