// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN

/// Isolates optional Xcode runtime interfaces from the app and its mobile builds.
@interface NativeSimulatorConnection : NSObject
@property(nonatomic, copy, nullable) void (^controlFailureHandler)(NSError *error);
- (nullable instancetype)initWithDeveloperDirectory:(NSString *)directory deviceID:(NSString *)deviceID error:(NSError **)error;
- (BOOL)startWithFrameHandler:(void (^)(id surface, CGSize pixels, NSInteger orientation))handler error:(NSError **)error;
- (void)stop;
- (void)releaseInputs;
- (void)prepareInputWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (BOOL)setHingeAngle:(double)angle;
- (BOOL)setFoldableOrientation:(NSInteger)orientation;
- (BOOL)touchAtPoint:(CGPoint)point phase:(NSInteger)phase;
- (BOOL)pressButton:(NSUInteger)usage;
- (BOOL)keyEvent:(NSEvent *)event pressed:(BOOL)pressed;
- (BOOL)sendKeyUsage:(NSUInteger)usage pressed:(BOOL)pressed;
@property(nonatomic, readonly) unsigned int displayID;
@property(nonatomic, readonly) BOOL needsReconnect;
- (BOOL)setOrientation:(NSInteger)orientation;
@end
NS_ASSUME_NONNULL_END
#endif
