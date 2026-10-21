import HeaterKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: HeaterController
    @State private var ip = ""
    @State private var token = ""
    @State private var autoTarget = 20.0
    @State private var price = 0.14
    var onSave: () -> Void = {}

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            card("Connection") {
                LabeledContent("IP") {
                    TextField("IP", text: $ip, prompt: Text("192.168.1.50"))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                Divider()
                LabeledContent("Token") {
                    SecureField("Token", text: $token, prompt: Text("32 hex characters"))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
                connectionFooter.font(.caption)
            }
            card("Auto") {
                stepper("Target temperature", "\(formatTemp(autoTarget)) °C", $autoTarget, 16...26)
            }
            card("Energy") {
                LabeledContent("Price (€/kWh)") {
                    TextField("Price (€/kWh)", value: $price, format: .number.locale(appLocale).precision(.fractionLength(2...4)))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                }
            }

            Button("Save & Connect") {
                UserDefaults.standard.set(ip.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ip")
                TokenStore.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
                controller.autoTarget = autoTarget
                controller.pricePerKWh = max(price, 0)
                Task {
                    await controller.reconnect()
                    if controller.errorMessage == nil { onSave() }
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            ip = UserDefaults.standard.string(forKey: "ip") ?? ""
            token = TokenStore.token() ?? ""
            autoTarget = controller.autoTarget
            price = controller.pricePerKWh
        }
    }

    @ViewBuilder private var connectionFooter: some View {
        if let error = controller.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.secondary)
        } else if let capabilities = controller.capabilities {
            Text("Model: \(capabilities.model)").foregroundStyle(.secondary)
        }
    }

    private func card(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func stepper<V: Strideable>(_ title: String, _ value: String, _ binding: Binding<V>, _ range: ClosedRange<V>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value).monospacedDigit()
                Stepper(title, value: binding, in: range).labelsHidden()
            }
        }
    }
}
