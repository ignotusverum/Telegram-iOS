import Foundation
import DeviceModel

public final class CustomLiquidGlassCapability {
    public static var isEnabledBySettings: Bool = true

    public static var isSupported: Bool {
        if #available(iOS 26.0, *) {
            return false
        }
        return isEnabledBySettings && DeviceModel.current.hasA14OrNewerChip
    }
}
