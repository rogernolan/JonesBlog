import SwiftUI

enum AppColors {
    private static let productionControlTint = Color(
        red: 0xF5 / 255,
        green: 0x80 / 255,
        blue: 0x25 / 255
    )
    static let locationGreen = Color(red: 0x13 / 255, green: 0x88 / 255, blue: 0x08 / 255)
    static let alertRed = Color(red: 0xED / 255, green: 0x1C / 255, blue: 0x24 / 255)
    /// Amber tint used to highlight rows whose weather or temperature is missing.
    static let weatherMissingTint = Color(red: 0xF0 / 255, green: 0x84 / 255, blue: 0x17 / 255)
    static let controlTint = AppBuildVariant.current == .debug
        ? alertRed
        : productionControlTint
}
