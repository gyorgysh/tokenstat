// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation

enum SimulatorSetupIssue: Error { case missingXcode, missingAndroidSDK }

struct SimulatorSetupState: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case checking, toolsMissing, noDevices, ready(Int), failed(String)
        var isAuthoritative: Bool {
            switch self { case .noDevices, .ready: true; default: false }
        }
        var failure: String? { if case .failed(let message) = self { message } else { nil } }
    }
    var apple: Status = .checking
    var android: Status = .checking

    func status(for platform: SimulatorDevice.Platform) -> Status { platform == .ios ? apple : android }
    static func status(_ result: Result<[SimulatorDevice], Error>) -> Status {
        switch result {
        case .success(let devices): devices.isEmpty ? .noDevices : .ready(devices.count)
        case .failure(is SimulatorSetupIssue): .toolsMissing
        case .failure(let error): .failed(error.localizedDescription)
        }
    }
}
#endif
