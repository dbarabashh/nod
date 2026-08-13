import SwiftUI

/// The list of microphones to record from, shared by the meeting bar and
/// Settings.
///
/// "System default" is a real row, not the absence of a pick: it is what an
/// unset `preferredInputUID` means, and the service follows macOS live while it
/// is unset — including when a pinned device is unplugged. Without a row of its
/// own there is no way back to that once anything is chosen.
struct MicrophoneInputPicker: View {
    let devices: [AudioInputDevice]
    let selectedUID: String?
    let onSelect: (String?) -> Void

    var body: some View {
        Picker("Microphone", selection: Binding(get: { selectedUID }, set: onSelect)) {
            Text(systemDefaultTitle).tag(String?.none)
            ForEach(devices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
        }
    }

    private var systemDefaultTitle: String {
        guard let name = devices.systemDefaultName else { return "System default" }
        return "System default (\(name))"
    }
}

#Preview("Microphone picker") {
    MicrophoneInputPicker(
        devices: [
            AudioInputDevice(id: 1, uid: "built-in", name: "MacBook Pro Microphone", isDefault: true),
            AudioInputDevice(id: 2, uid: "earpods", name: "EarPods", isDefault: false)
        ],
        selectedUID: nil,
        onSelect: { _ in }
    )
    .pickerStyle(.inline)
    .padding()
}
