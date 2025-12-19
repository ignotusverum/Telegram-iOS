import Foundation
import UIKit
import Display
import AsyncDisplayKit
import ComponentFlow
import TelegramPresentationData

public final class SwitchComponent: Component {
    public typealias EnvironmentType = Empty

    public static var enableCustomLiquidGlass: Bool = true

    public let tintColor: UIColor?
    public let offTintColor: UIColor?
    public let value: Bool
    public let enableLiquidGlass: Bool
    public let valueUpdated: (Bool) -> Void

    public init(
        tintColor: UIColor? = nil,
        offTintColor: UIColor? = nil,
        value: Bool,
        enableLiquidGlass: Bool? = nil,
        valueUpdated: @escaping (Bool) -> Void
    ) {
        self.tintColor = tintColor
        self.offTintColor = offTintColor
        self.value = value
        self.enableLiquidGlass = enableLiquidGlass ?? SwitchComponent.enableCustomLiquidGlass
        self.valueUpdated = valueUpdated
    }

    public static func ==(lhs: SwitchComponent, rhs: SwitchComponent) -> Bool {
        if lhs.tintColor != rhs.tintColor {
            return false
        }
        if lhs.offTintColor != rhs.offTintColor {
            return false
        }
        if lhs.value != rhs.value {
            return false
        }
        if lhs.enableLiquidGlass != rhs.enableLiquidGlass {
            return false
        }
        return true
    }

    public final class View: UIView {
        private var switchView: UISwitch?
        private var liquidGlassSwitchView: LiquidGlassSwitchView?

        private var component: SwitchComponent?

        override init(frame: CGRect) {
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc func valueChanged(_ sender: Any) {
            if let switchView = self.switchView {
                self.component?.valueUpdated(switchView.isOn)
            } else if let glassSwitch = self.liquidGlassSwitchView {
                self.component?.valueUpdated(glassSwitch.isOn)
            }
        }

        func update(component: SwitchComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
            self.component = component

            if component.enableLiquidGlass {
                self.switchView?.removeFromSuperview()
                self.switchView = nil

                let glassSwitch: LiquidGlassSwitchView
                if let current = self.liquidGlassSwitchView {
                    glassSwitch = current
                } else {
                    glassSwitch = LiquidGlassSwitchView()
                    glassSwitch.addTarget(self, action: #selector(self.valueChanged(_:)), for: .valueChanged)
                    self.addSubview(glassSwitch)
                    self.liquidGlassSwitchView = glassSwitch
                }

                if let tintColor = component.tintColor {
                    glassSwitch.onTintColor = tintColor
                }
                if let offTintColor = component.offTintColor {
                    glassSwitch.offTintColor = offTintColor
                }
                glassSwitch.setOn(component.value, animated: !transition.animation.isImmediate)

                let size = glassSwitch.intrinsicContentSize
                glassSwitch.frame = CGRect(origin: .zero, size: size)
                return size
            } else {
                self.liquidGlassSwitchView?.removeFromSuperview()
                self.liquidGlassSwitchView = nil

                let uiSwitch: UISwitch
                if let current = self.switchView {
                    uiSwitch = current
                } else {
                    uiSwitch = UISwitch()
                    uiSwitch.addTarget(self, action: #selector(self.valueChanged(_:)), for: .valueChanged)
                    self.addSubview(uiSwitch)
                    self.switchView = uiSwitch
                }

                uiSwitch.onTintColor = component.tintColor
                uiSwitch.setOn(component.value, animated: !transition.animation.isImmediate)

                uiSwitch.sizeToFit()
                uiSwitch.frame = CGRect(origin: .zero, size: uiSwitch.frame.size)
                return uiSwitch.frame.size
            }
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

public func setupLiquidGlassSwitchFactory() {
    SwitchNode.glassViewFactory = {
        LiquidGlassSwitchView()
    }
    SwitchNode.glassViewConfigurer = { view, isOn, contentColor, frameColor in
        guard let glassSwitch = view as? LiquidGlassSwitchView else { return }
        glassSwitch.onTintColor = contentColor
        glassSwitch.offTintColor = frameColor
        glassSwitch.setOn(isOn, animated: false)
    }
    SwitchNode.glassViewValueGetter = { view in
        guard let glassSwitch = view as? LiquidGlassSwitchView else { return false }
        return glassSwitch.isOn
    }
    SwitchNode.glassViewValueSetter = { view, value, animated in
        guard let glassSwitch = view as? LiquidGlassSwitchView else { return }
        glassSwitch.setOn(value, animated: animated)
    }
}
