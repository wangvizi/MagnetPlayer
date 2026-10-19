import SwiftUI

struct SettingsView: View {
    @State private var server = Config.serverURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("填写你部署后端服务的服务器地址，例如 http://123.45.67.89:8000")) {
                    TextField("服务器地址", text: $server)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("服务器设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Config.serverURL = server
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}