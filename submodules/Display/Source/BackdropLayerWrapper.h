#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface BackdropLayerWrapper : NSObject

/// Check if CABackdropLayer is available on this device/OS
+ (BOOL)isAvailable;

/// Create a CABackdropLayer with blur and saturation filters
/// @param frame The layer frame
/// @param blur Blur intensity (0-1, multiplied by 45 for radius)
/// @param saturation Saturation multiplier (1.0 = normal, 1.4 = boosted)
/// @param scale Render scale (0.5 = half resolution for performance)
+ (nullable CALayer *)createBackdropLayerWithFrame:(CGRect)frame
                                     blurIntensity:(CGFloat)blur
                                        saturation:(CGFloat)saturation
                                             scale:(CGFloat)scale;

/// Update blur intensity on existing backdrop layer
+ (void)updateBlurIntensity:(CGFloat)blur onLayer:(CALayer *)layer;

/// Update saturation on existing backdrop layer
+ (void)updateSaturation:(CGFloat)saturation onLayer:(CALayer *)layer;

@end

NS_ASSUME_NONNULL_END
