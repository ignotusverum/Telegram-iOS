import Foundation
import UIKit
import AsyncDisplayKit

private final class SwitchNodeViewLayer: CALayer {
    override func setNeedsDisplay() {
    }
}

private final class SwitchNodeView: UISwitch {
    override class var layerClass: AnyClass {
        if #available(iOS 26.0, *) {
            return super.layerClass
        } else {
            return SwitchNodeViewLayer.self
        }
    }
}

open class SwitchNode: ASDisplayNode {
    public static var enableCustomLiquidGlass: Bool = false
    public static var glassViewFactory: (() -> UIView)?
    public static var glassViewConfigurer: ((UIView, Bool, UIColor, UIColor) -> Void)?
    public static var glassViewValueGetter: ((UIView) -> Bool)?
    public static var glassViewValueSetter: ((UIView, Bool, Bool) -> Void)?

    private var isUsingGlassSwitch: Bool = false

    public var valueUpdated: ((Bool) -> Void)?

    public var frameColor = UIColor(rgb: 0xe0e0e0) {
        didSet {
            if self.isNodeLoaded {
                if oldValue != self.frameColor {
                    if self.isUsingGlassSwitch {
                        SwitchNode.glassViewConfigurer?(self.view, self._isOn, self.contentColor, self.frameColor)
                    } else {
                        (self.view as? UISwitch)?.tintColor = self.frameColor
                    }
                }
            }
        }
    }
    public var handleColor = UIColor(rgb: 0xffffff) {
        didSet {
            if self.isNodeLoaded {
            }
        }
    }
    public var contentColor = UIColor(rgb: 0x42d451) {
        didSet {
            if self.isNodeLoaded {
                if oldValue != self.contentColor {
                    if self.isUsingGlassSwitch {
                        SwitchNode.glassViewConfigurer?(self.view, self._isOn, self.contentColor, self.frameColor)
                    } else {
                        (self.view as? UISwitch)?.onTintColor = self.contentColor
                    }
                }
            }
        }
    }

    private var _isOn: Bool = false
    public var isOn: Bool {
        get {
            return self._isOn
        } set(value) {
            if value != self._isOn {
                self._isOn = value
                if self.isNodeLoaded {
                    if self.isUsingGlassSwitch {
                        SwitchNode.glassViewValueSetter?(self.view, value, false)
                    } else {
                        (self.view as? UISwitch)?.setOn(value, animated: false)
                    }
                }
            }
        }
    }

    override public init() {
        super.init()

        self.setViewBlock({ [weak self] in
            if SwitchNode.enableCustomLiquidGlass,
               let factory = SwitchNode.glassViewFactory {
                self?.isUsingGlassSwitch = true
                return factory()
            } else {
                self?.isUsingGlassSwitch = false
                return SwitchNodeView()
            }
        })
    }

    override open func didLoad() {
        super.didLoad()

        self.view.isAccessibilityElement = false

        if self.isUsingGlassSwitch {
            SwitchNode.glassViewConfigurer?(self.view, self._isOn, self.contentColor, self.frameColor)
            if let control = self.view as? UIControl {
                control.addTarget(self, action: #selector(glassValueChanged(_:)), for: .valueChanged)
            }
        } else if let switchView = self.view as? UISwitch {
            switchView.backgroundColor = self.backgroundColor
            switchView.tintColor = self.frameColor
            switchView.onTintColor = self.contentColor
            switchView.setOn(self._isOn, animated: false)
            switchView.addTarget(self, action: #selector(switchValueChanged(_:)), for: .valueChanged)
        }
    }

    public func setOn(_ value: Bool, animated: Bool) {
        self._isOn = value
        if self.isNodeLoaded {
            if self.isUsingGlassSwitch {
                SwitchNode.glassViewValueSetter?(self.view, value, animated)
            } else {
                (self.view as? UISwitch)?.setOn(value, animated: animated)
            }
        }
    }

    override open func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        if self.isUsingGlassSwitch {
            return CGSize(width: 64.0, height: 28.0)
        } else if #available(iOS 26.0, *) {
            return CGSize(width: 63.0, height: 28.0)
        } else {
            return CGSize(width: 51.0, height: 31.0)
        }
    }

    @objc func switchValueChanged(_ view: UISwitch) {
        self._isOn = view.isOn
        self.valueUpdated?(view.isOn)
    }

    @objc func glassValueChanged(_ control: UIControl) {
        if let value = SwitchNode.glassViewValueGetter?(control) {
            self._isOn = value
            self.valueUpdated?(value)
        }
    }
}
