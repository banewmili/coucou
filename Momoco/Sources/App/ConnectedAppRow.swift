import SwiftUI

// MARK: - Connected app row

struct ConnectedAppRow: View {
    let name: String
    let detail: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(connected ? "Connected" : "Not connected")
                .font(.system(size: 11))
                .foregroundColor(connected ? .green : .secondary)
        }
    }
}
