import Foundation
import UIKit
import Display
import ComponentFlow
import GlassBackgroundComponent

private let enableCustomLiquidGlass: Bool = true

private final class RestingBackgroundView: UIVisualEffectView {
    var isDark: Bool?

    static func colorMatrix(isDark: Bool) -> [Float32] {
        if isDark {
            return [1.082, -0.113, -0.011, 0.0, 0.135, -0.034, 1.003, -0.011, 0.0, 0.135, -0.034, -0.113, 1.105, 0.0, 0.135, 0.0, 0.0, 0.0, 1.0, 0.0]
        } else {
            return [1.185, -0.05, -0.005, 0.0, -0.2, -0.015, 1.15, -0.005, 0.0, -0.2, -0.015, -0.05, 1.195, 0.0, -0.2, 0.0, 0.0, 0.0, 1.0, 0.0]
        }
    }

    init() {
        let effect = UIBlurEffect(style: .light)
        super.init(effect: effect)
        
        for subview in self.subviews {
            if subview.description.contains("VisualEffectSubview") {
                subview.isHidden = true
            }
        }
        
        self.clipsToBounds = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(isDark: Bool) {
        if self.isDark == isDark {
            return
        }
        self.isDark = isDark
        
        if let sublayer = self.layer.sublayers?[0], let _ = sublayer.filters {
            sublayer.backgroundColor = nil
            sublayer.isOpaque = false
            
            if let classValue = NSClassFromString("CAFilter") as AnyObject as? NSObjectProtocol {
                let makeSelector = NSSelectorFromString("filterWithName:")
                let filter = classValue.perform(makeSelector, with: "colorMatrix").takeUnretainedValue() as? NSObject
                
                if let filter {
                    var matrix: [Float32] = RestingBackgroundView.colorMatrix(isDark: isDark)
                    filter.setValue(NSValue(bytes: &matrix, objCType: "{CAColorMatrix=ffffffffffffffffffff}"), forKey: "inputColorMatrix")
                    sublayer.filters = [filter]
                    sublayer.setValue(1.0, forKey: "scale")
                }
            }
        }
    }
}

public final class LiquidLensView: UIView {
    private struct Params: Equatable {
        var size: CGSize
        var selectionX: CGFloat
        var selectionWidth: CGFloat
        var isDark: Bool
        var isLifted: Bool

        init(size: CGSize, selectionX: CGFloat, selectionWidth: CGFloat, isDark: Bool, isLifted: Bool) {
            self.size = size
            self.selectionX = selectionX
            self.selectionWidth = selectionWidth
            self.isLifted = isLifted
            self.isDark = isDark
        }
    }

    private struct LensParams: Equatable {
        var baseFrame: CGRect
        var isLifted: Bool

        init(baseFrame: CGRect, isLifted: Bool) {
            self.baseFrame = baseFrame
            self.isLifted = isLifted
        }
    }

    public static var enableSolidColorBackdrop: Bool = true

    private let containerView: UIView
    private let backgroundContainerContainer: UIView
    private var solidColorBackdropView: UIView?
    private let backgroundContainer: GlassBackgroundContainerView
    private let backgroundView: GlassBackgroundView
    private var lensView: UIView?
    private let liftedContainerView: UIView
    public let contentView: UIView
    private let restingBackgroundView: RestingBackgroundView
    
    private var legacySelectionView: GlassBackgroundView.ContentImageView?
    private var legacyContentMaskView: UIView?
    private var legacyContentMaskBlobView: UIImageView?
    private var legacyLiftedContentBlobMaskView: UIImageView?
    private var liftedContentMaskView: UIView?

    public var selectedContentView: UIView {
        return self.liftedContainerView
    }

    public var usesCustomLiquidGlass: Bool {
        return self.lensView is LegacyLiquidLensView
    }

    private var params: Params?
    private var appliedLensParams: LensParams?
    private var isApplyingLensParams: Bool = false
    private var pendingLensParams: LensParams?

    private var liftedDisplayLink: SharedDisplayLinkDriver.Link?

    public var selectionX: CGFloat? {
        return self.params?.selectionX
    }

    public var selectionWidth: CGFloat? {
        return self.params?.selectionWidth
    }

    override public init(frame: CGRect) {
        self.containerView = UIView()
        
        self.backgroundContainerContainer = UIView()
        self.backgroundContainer = GlassBackgroundContainerView()
        
        self.backgroundView = GlassBackgroundView()
        
        self.contentView = UIView()
        self.liftedContainerView = UIView()

        self.restingBackgroundView = RestingBackgroundView()

        super.init(frame: frame)

        if LiquidLensView.enableSolidColorBackdrop {
            let solidView = UIView()
            solidView.backgroundColor = UIColor(white: 0.5, alpha: 1.0)
            solidView.clipsToBounds = true
            self.solidColorBackdropView = solidView
            self.backgroundContainerContainer.addSubview(solidView)
        }
        self.backgroundContainerContainer.addSubview(self.backgroundContainer)
        self.addSubview(self.backgroundContainerContainer)
        
        self.backgroundContainer.contentView.addSubview(self.backgroundView)
        self.backgroundView.contentView.addSubview(self.containerView)
        self.containerView.isUserInteractionEnabled = false

        if #available(iOS 26.0, *) {
            if let viewClass = NSClassFromString("_UILiquidLensView") as AnyObject as? NSObjectProtocol {
                let allocSelector = NSSelectorFromString("alloc")
                let initSelector = NSSelectorFromString("initWithRestingBackground:")
                let objcAlloc = viewClass.perform(allocSelector).takeUnretainedValue()
                let instance = objcAlloc.perform(initSelector, with: UIView()).takeUnretainedValue()
                self.lensView = instance as? UIView
            }
        } else if enableCustomLiquidGlass {
            let customLens = LegacyLiquidLensView(frame: .zero, restingBackgroundView: restingBackgroundView)
            self.lensView = customLens
        }

        if let lensView = self.lensView {
            self.backgroundContainer.layer.zPosition = 1
            lensView.layer.zPosition = 10.0

            self.containerView.addSubview(self.contentView)          // Black icons (bottom, visible everywhere)
            self.containerView.addSubview(self.liftedContainerView)  // Blue icons (masked to lens shape)
            self.containerView.addSubview(lensView)                   // Glass effect on top

            if let customLens = lensView as? LegacyLiquidLensView {
                customLens.liftedContainerView = self.backgroundContainer.contentView
                customLens.liftedContentView = self.liftedContainerView

                // Create mask for lifted content - clips blue icons to lens shape
                let maskView = UIView()
                maskView.backgroundColor = .white
                self.liftedContainerView.mask = maskView
                self.liftedContentMaskView = maskView
            } else {
                self.liftedContainerView.addSubview(self.restingBackgroundView)
                lensView.perform(NSSelectorFromString("setLiftedContainerView:"), with: self.backgroundContainer.contentView)
                lensView.perform(NSSelectorFromString("setLiftedContentView:"), with: self.liftedContainerView)
                lensView.perform(NSSelectorFromString("setOverridePunchoutView:"), with: self.contentView)

                do {
                    let selector = NSSelectorFromString("setLiftedContentMode:")
                    if let method = lensView.method(for: selector) {
                        typealias ObjCMethod = @convention(c) (AnyObject, Selector, Int32) -> Void
                        let function = unsafeBitCast(method, to: ObjCMethod.self)
                        function(lensView, selector, 1)
                    }
                }

                do {
                    let selector = NSSelectorFromString("setStyle:")
                    if let method = lensView.method(for: selector) {
                        typealias ObjCMethod = @convention(c) (AnyObject, Selector, Int32) -> Void
                        let function = unsafeBitCast(method, to: ObjCMethod.self)
                        function(lensView, selector, 1)
                    }
                }

                do {
                    let selector = NSSelectorFromString("setWarpsContentBelow:")
                    if let method = lensView.method(for: selector) {
                        typealias ObjCMethod = @convention(c) (AnyObject, Selector, Bool) -> Void
                        let function = unsafeBitCast(method, to: ObjCMethod.self)
                        function(lensView, selector, true)
                    }
                }

                lensView.setValue(UIColor(white: 0.0, alpha: 0.1), forKey: "restingBackgroundColor")
            }
        } else {
            let legacySelectionView = GlassBackgroundView.ContentImageView()
            self.legacySelectionView = legacySelectionView
            self.backgroundView.contentView.insertSubview(legacySelectionView, at: 0)

            self.setupContentMasks()
            self.containerView.addSubview(self.contentView)
            self.containerView.addSubview(self.liftedContainerView)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContentMasks() {
        let legacyContentMaskView = UIView()
        legacyContentMaskView.backgroundColor = .white
        self.legacyContentMaskView = legacyContentMaskView
        self.contentView.mask = legacyContentMaskView

        if let filter = CALayer.luminanceToAlpha() {
            legacyContentMaskView.layer.filters = [filter]
        }

        let legacyContentMaskBlobView = UIImageView()
        self.legacyContentMaskBlobView = legacyContentMaskBlobView
        legacyContentMaskView.addSubview(legacyContentMaskBlobView)

        let legacyLiftedContentBlobMaskView = UIImageView()
        self.legacyLiftedContentBlobMaskView = legacyLiftedContentBlobMaskView
        self.liftedContainerView.mask = legacyLiftedContentBlobMaskView
    }

    public func update(size: CGSize, selectionX: CGFloat, selectionWidth: CGFloat, isDark: Bool, isLifted: Bool, transition: ComponentTransition) {
        let params = Params(size: size, selectionX: selectionX, selectionWidth: selectionWidth, isDark: isDark, isLifted: isLifted)
        if self.params == params {
            return
        }
        self.update(params: params, transition: transition)
    }

    private func update(transition: ComponentTransition) {
        guard let params = self.params else {
            return
        }
        self.update(params: params, transition: transition)
    }

    private func updateLens(params: LensParams, animated: Bool) {
        guard let lensView = self.lensView else {
            return
        }

        if self.isApplyingLensParams {
            self.pendingLensParams = params
            return
        }
        self.isApplyingLensParams = true
        let previousParams = self.appliedLensParams

        let transition: ComponentTransition = animated ? .easeInOut(duration: 0.3) : .immediate

        if let customLens = lensView as? LegacyLiquidLensView {
            customLens.activate()

            let previousX = previousParams?.baseFrame.midX ?? params.baseFrame.midX
            let isPositionChange = abs(previousX - params.baseFrame.midX) > 1.0
            let wasPreviouslyLifted = previousParams?.isLifted ?? false

            print("[LiquidLensView.updateLens] previousX=\(previousX), newX=\(params.baseFrame.midX), isPositionChange=\(isPositionChange), wasPreviouslyLifted=\(wasPreviouslyLifted), isLifted=\(params.isLifted)")

            // Tap scenario: position changed while STARTING a new lift (tap on different tab)
            if isPositionChange && !wasPreviouslyLifted && params.isLifted {
                print("[LiquidLensView.updateLens] >>> TRANSITION PATH - hiding mask, calling transitionToFrame")
                // Hide mask during transition
                self.liftedContentMaskView?.isHidden = true

                customLens.transitionToFrame(params.baseFrame, animated: !transition.animation.isImmediate, delay: 0) { [weak self] in
                    guard let self else { return }
                    print("[LiquidLensView.updateLens] >>> TRANSITION COMPLETE - showing mask")
                    // Show mask on completion - use lens frame directly to avoid any mismatch
                    if let maskView = self.liftedContentMaskView, let customLens = self.lensView as? LegacyLiquidLensView {
                        let maskFrame = customLens.frame.insetBy(dx: 4.0, dy: 4.0)
                        maskView.frame = maskFrame
                        maskView.layer.cornerRadius = maskFrame.height / 2
                    }
                    self.liftedContentMaskView?.isHidden = false
                }
            } else if customLens.isTransitioning {
                // If position changes during transition, it's a drag not a tap - cancel transition
                if isPositionChange && params.isLifted {
                    print("[LiquidLensView.updateLens] >>> TRANSITIONING but position changed (DRAG detected) - cancelling transition")
                    customLens.cancelTransition()
                    self.liftedContentMaskView?.isHidden = false
                    // Continue with normal drag behavior below
                    customLens.baseFrame = params.baseFrame
                } else {
                    // Ignore simple lift state changes while transitioning
                    print("[LiquidLensView.updateLens] >>> TRANSITIONING - ignoring lift state change")
                }
            } else {
                print("[LiquidLensView.updateLens] >>> NORMAL PATH - setting baseFrame directly")
                // Normal behavior (drag, simple lift/collapse)
                customLens.baseFrame = params.baseFrame
                if previousParams?.isLifted != params.isLifted {
                    customLens.setLifted(params.isLifted, animated: !transition.animation.isImmediate, alongsideAnimations: nil, completion: nil)
                }
            }

            self.appliedLensParams = params
            self.isApplyingLensParams = false
            return
        }

        if previousParams?.isLifted != params.isLifted {
            let selector = NSSelectorFromString("setLifted:animated:alongsideAnimations:completion:")
            var shouldScheduleUpdate = false
            var didProcessUpdate = false
            self.pendingLensParams = params
            if let method = lensView.method(for: selector) {
                typealias ObjCMethod = @convention(c) (AnyObject, Selector, Bool, Bool, @escaping () -> Void, AnyObject?) -> Void
                let function = unsafeBitCast(method, to: ObjCMethod.self)
                function(lensView, selector, params.isLifted, !transition.animation.isImmediate, { [weak self] in
                    guard let self else {
                        return
                    }
                    let liftedInset: CGFloat = params.isLifted ? 4.0 : -4.0
                    lensView.bounds = CGRect(origin: CGPoint(), size: CGSize(width: params.baseFrame.width + liftedInset * 2.0, height: params.baseFrame.height + liftedInset * 2.0))
                    didProcessUpdate = true
                    if shouldScheduleUpdate {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, let pendingLensParams = self.pendingLensParams else {
                                return
                            }
                            self.isApplyingLensParams = false
                            self.pendingLensParams = nil
                            self.updateLens(params: pendingLensParams, animated: !transition.animation.isImmediate)
                        }
                    }
                }, nil)
            }
            if didProcessUpdate {
                transition.animateView {
                    lensView.center = CGPoint(x: params.baseFrame.midX, y: params.baseFrame.midY)
                }
                self.pendingLensParams = nil
                self.isApplyingLensParams = false
            } else {
                shouldScheduleUpdate = true
            }
        } else {
            transition.animateView {
                let liftedInset: CGFloat = params.isLifted ? 4.0 : -4.0
                lensView.bounds = CGRect(origin: CGPoint(), size: CGSize(width: params.baseFrame.width + liftedInset * 2.0, height: params.baseFrame.height + liftedInset * 2.0))
                lensView.center = CGPoint(x: params.baseFrame.midX, y: params.baseFrame.midY)
            }
            self.isApplyingLensParams = false
        }
    }

    private func updateLiftedLensPosition() {
        // Without this, the lens won't update its bouncing animations unless it's being moved
        if self.isApplyingLensParams {
            return
        }
        guard let lensView = self.lensView else {
            return
        }
        guard let params = self.appliedLensParams else {
            return
        }

        // For custom lens during transition, position is handled internally by positionAnimator
        if lensView is LegacyLiquidLensView {
            // Only update mask when visible (not during transition)
            if let maskView = self.liftedContentMaskView, !maskView.isHidden {
                print("[LiquidLensView.updateLiftedLensPosition] updating mask frame to \(lensView.frame.insetBy(dx: 4.0, dy: 4.0))")
                maskView.frame = lensView.frame.insetBy(dx: 4.0, dy: 4.0)
                maskView.layer.cornerRadius = maskView.frame.height / 2
            }
            return
        }

        lensView.center = CGPoint(x: params.baseFrame.midX, y: params.baseFrame.midY)

        // Update mask positions to follow lens in real-time
        if let legacyContentMaskBlobView = self.legacyContentMaskBlobView,
           let legacyLiftedContentBlobMaskView = self.legacyLiftedContentBlobMaskView {
            let lensFrame = lensView.frame.insetBy(dx: 4.0, dy: 4.0)
            let isLifted = self.params?.isLifted ?? false
            let effectiveLensFrame = lensFrame.insetBy(dx: isLifted ? -2.0 : 0.0, dy: isLifted ? -2.0 : 0.0)
            legacyContentMaskBlobView.frame = effectiveLensFrame
            legacyLiftedContentBlobMaskView.frame = effectiveLensFrame
        }

        // Update liftedContentMaskView to follow lens (clips blue icons to pill shape)
        if let maskView = self.liftedContentMaskView {
            maskView.frame = lensView.frame
            maskView.layer.cornerRadius = lensView.frame.height / 2
        }
    }

    private func update(params: Params, transition: ComponentTransition) {
        let isFirstTime = self.params == nil
        let transition: ComponentTransition = isFirstTime ? .immediate : transition

        self.params = params

        transition.setFrame(view: self.containerView, frame: CGRect(origin: CGPoint(), size: params.size))
        transition.setFrame(view: self.backgroundContainerContainer, frame: CGRect(origin: CGPoint(), size: params.size))

        if let solidView = self.solidColorBackdropView {
            solidView.backgroundColor = UIColor(white: params.isDark ? 0.15 : 0.85, alpha: 1)
            solidView.layer.cornerRadius = params.size.height * 0.5
            transition.setFrame(view: solidView, frame: CGRect(origin: CGPoint(), size: params.size))
        }
        transition.setFrame(view: self.backgroundContainer, frame: CGRect(origin: CGPoint(), size: params.size))
        self.backgroundContainer.update(size: params.size, isDark: params.isDark, transition: transition)

        transition.setFrame(view: self.backgroundView, frame: CGRect(origin: CGPoint(), size: params.size))
        self.backgroundView.update(size: params.size, cornerRadius: params.size.height * 0.5, isDark: params.isDark, tintColor: GlassBackgroundView.TintColor.init(kind: .panel, color: UIColor(white: params.isDark ? 0.0 : 1.0, alpha: 0.9)), isInteractive: true, transition: transition)

        transition.setFrame(view: self.contentView, frame: CGRect(origin: CGPoint(), size: params.size))
        transition.setFrame(view: self.liftedContainerView, frame: CGRect(origin: CGPoint(), size: params.size))

        let baseLensFrame = CGRect(origin: CGPoint(x: max(0.0, min(params.selectionX, params.size.width - params.selectionWidth)), y: 0.0), size: CGSize(width: params.selectionWidth, height: params.size.height))
        self.updateLens(params: LensParams(baseFrame: baseLensFrame, isLifted: params.isLifted), animated: !transition.animation.isImmediate)
        
        if let legacyContentMaskView = self.legacyContentMaskView {
            transition.setFrame(view: legacyContentMaskView, frame: CGRect(origin: CGPoint(), size: params.size))
        }
        if let legacyContentMaskBlobView = self.legacyContentMaskBlobView, let legacyLiftedContentBlobMaskView = self.legacyLiftedContentBlobMaskView {
            let lensFrame = baseLensFrame.insetBy(dx: 4.0, dy: 4.0)
            let effectiveLensFrame = lensFrame.insetBy(dx: params.isLifted ? -2.0 : 0.0, dy: params.isLifted ? -2.0 : 0.0)

            if legacyContentMaskBlobView.image?.size.height != lensFrame.height {
                legacyContentMaskBlobView.image = generateStretchableFilledCircleImage(diameter: lensFrame.height, color: .black)
                legacyLiftedContentBlobMaskView.image = legacyContentMaskBlobView.image
            }
            transition.setFrame(view: legacyContentMaskBlobView, frame: effectiveLensFrame)
            transition.setFrame(view: legacyLiftedContentBlobMaskView, frame: effectiveLensFrame)

            if let legacySelectionView {
                if legacySelectionView.image?.size.height != lensFrame.height {
                    legacySelectionView.image = generateStretchableFilledCircleImage(diameter: lensFrame.height, color: .white)?.withRenderingMode(.alwaysTemplate)
                }
                legacySelectionView.tintColor = UIColor(white: params.isDark ? 1.0 : 0.0, alpha: params.isDark ? 0.1 : 0.075)
                transition.setFrame(view: legacySelectionView, frame: effectiveLensFrame)
            }
        }

        // Update liftedContentMaskView for initial frame (display link updates in real-time)
        // Skip if mask is hidden (during transition)
        if let maskView = self.liftedContentMaskView, let _ = self.lensView {
            if maskView.isHidden {
                print("[LiquidLensView.update(params:)] mask is hidden, SKIPPING update")
            } else {
                let maskFrame = baseLensFrame.insetBy(dx: params.isLifted ? -4.0 : 4.0, dy: params.isLifted ? -4.0 : 4.0)
                print("[LiquidLensView.update(params:)] updating mask frame to \(maskFrame)")
                transition.setFrame(view: maskView, frame: maskFrame)
                maskView.layer.cornerRadius = maskFrame.height / 2
            }
        }

        self.restingBackgroundView.update(isDark: params.isDark)
        if !(self.lensView is LegacyLiquidLensView) {
            transition.setFrame(view: self.restingBackgroundView, frame: CGRect(origin: CGPoint(), size: params.size))
            self.restingBackgroundView.isHidden = false
            transition.setAlpha(view: self.restingBackgroundView, alpha: params.isLifted ? 0.0 : 1.0)
        }

        // For custom lens, always run display link to update mask positions
        // For native lens, only run when lifted
        let needsDisplayLink = params.isLifted || (self.lensView is LegacyLiquidLensView)
        if needsDisplayLink {
            if self.liftedDisplayLink == nil {
                self.liftedDisplayLink = SharedDisplayLinkDriver.shared.add(framesPerSecond: .max, { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.updateLiftedLensPosition()
                })
            }
        } else if let liftedDisplayLink = self.liftedDisplayLink {
            self.liftedDisplayLink = nil
            liftedDisplayLink.invalidate()
        }
    }

}
