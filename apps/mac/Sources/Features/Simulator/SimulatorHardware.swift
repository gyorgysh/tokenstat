// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import Foundation

/// Reusable silhouettes, selected from CoreSimulator's stable type identifier.
/// These are recognizable hardware families, not manufacturer CAD assets.
enum SimulatorHardware: CaseIterable {
    case phone, tablet
    case iPhoneSingle, iPhoneHome, iPhoneHomeDual
    case iPhoneDualVertical, iPhoneDualSquare, iPhoneDualDiagonal
    case iPhonePro, iPhoneProPlateau, iPhoneAir, iPhoneDuo
    case iPad, iPadHome, iPadPro, iPadProDual, iPadProThin

    init(device: SimulatorDevice) {
        guard device.platform == .ios else { self = device.isTablet ? .tablet : .phone; return }
        let type = device.deviceType.replacingOccurrences(of: "com.apple.CoreSimulator.SimDeviceType.", with: "")
        let words = type.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let model = words.dropFirst().first ?? ""
        if words.first == "iphone" {
            if words.contains("duo") { self = .iPhoneDuo }
            else if words.contains("air") { self = .iPhoneAir }
            else if ["16e", "17e", "xr"].contains(model) { self = .iPhoneSingle }
            else if ["se", "6s", "7", "8"].contains(model) {
                self = ["7", "8"].contains(model) && words.contains("plus") ? .iPhoneHomeDual : .iPhoneHome
            } else if words.contains("pro") {
                self = ["17", "18"].contains(model) ? .iPhoneProPlateau : .iPhonePro
            } else if ["13", "14", "15"].contains(model) { self = .iPhoneDualDiagonal }
            else if ["11", "12"].contains(model) { self = .iPhoneDualSquare }
            else if ["16", "17", "x", "xs"].contains(model) { self = .iPhoneDualVertical }
            else { self = .phone }
        } else if words.first == "ipad" {
            let generation = words.first { $0.hasSuffix("nd") || $0.hasSuffix("rd") || $0.hasSuffix("th") }
                .flatMap { Int($0.prefix(while: \.isNumber)) } ?? 1
            if model == "pro" {
                if words.contains("m4") || words.contains("m5") { self = .iPadProThin }
                else if words.contains("11") {
                    self = generation >= 2 ? .iPadProDual : .iPadPro
                } else if words.contains("12") && words.contains("9") && generation >= 3 {
                    self = generation >= 4 ? .iPadProDual : .iPadPro
                } else { self = .iPadHome }
            } else if words.contains("air") {
                self = words.contains("2") || (words.contains("generation") && generation < 4) ? .iPadHome : .iPad
            } else if words.contains("mini") {
                self = words.contains("4") || (words.contains("generation") && generation < 6) ? .iPadHome : .iPad
            } else { self = words.contains("generation") && generation < 10 ? .iPadHome : .iPad }
        } else { self = device.isTablet ? .tablet : .phone }
    }

    var isTablet: Bool {
        switch self { case .tablet, .iPad, .iPadHome, .iPadPro, .iPadProDual, .iPadProThin: return true; default: return false }
    }
    var hasHomeButton: Bool { self == .iPhoneHome || self == .iPhoneHomeDual || self == .iPadHome }
    var depth: Float {
        switch self {
        case .iPhoneAir: return 0.078
        case .iPadProThin: return 0.065
        case .tablet, .iPad, .iPadPro, .iPadProDual: return 0.09
        case .iPadHome: return 0.11
        case .iPhoneDuo: return 0.21
        case .iPhonePro, .iPhoneProPlateau: return 0.12
        default: return 0.11
        }
    }
    enum Cameras { case single, vertical, square, diagonal, horizontal, triple, plateau, air, tablet, tabletPro, tabletDual, duo }
    var cameras: Cameras {
        switch self {
        case .iPhoneSingle, .iPhoneHome: return .single
        case .iPhoneHomeDual: return .horizontal
        case .iPhoneDualSquare: return .square
        case .iPhoneDualDiagonal: return .diagonal
        case .iPhonePro: return .triple
        case .iPhoneProPlateau: return .plateau
        case .iPhoneAir: return .air
        case .iPhoneDuo: return .duo
        case .tablet, .iPad, .iPadHome: return .tablet
        case .iPadPro, .iPadProThin: return .tabletPro
        case .iPadProDual: return .tabletDual
        default: return .vertical
        }
    }
}
#endif
