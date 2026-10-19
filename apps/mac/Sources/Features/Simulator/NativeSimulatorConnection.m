// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#import "NativeSimulatorConnection.h"
#if TARGET_OS_OSX
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <xpc/xpc.h>

// Xcode owns these interfaces. They are loaded only when attaching a device,
// checked before use and never linked into the application at build time.
@protocol TSRuntime <NSObject>
@optional
+ (id)sharedServiceContextForDeveloperDir:(NSString *)path error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSArray *)availableDevices;
- (NSUUID *)UDID;
- (id)io;
- (id)runtime;
- (NSString *)versionString;
- (NSArray *)ioPorts;
- (id)descriptor;
- (NSString *)portIdentifier;
- (id)screenProperties;
- (NSString *)deviceName;
- (unsigned int)uiOrientation;
- (unsigned int)screenID;
- (unsigned long long)bootGeneration;
- (id)framebufferSurface;
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid callbackQueue:(dispatch_queue_t)queue frameCallback:(void (^)(void))frame surfacesChangedCallback:(void (^)(void))surfaces propertiesChangedCallback:(void (^)(void))properties;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
- (id)initWithDevice:(id)device error:(NSError **)error;
- (void)sendWithMessage:(void *)message freeWhenDone:(BOOL)freeWhenDone completionQueue:(nullable dispatch_queue_t)queue completion:(nullable void (^)(NSError *))completion;
- (mach_port_t)lookup:(NSString *)service error:(NSError **)error;
- (BOOL)setHardwareKeyboardEnabled:(BOOL)enabled keyboardType:(unsigned char)type error:(NSError **)error;
@end

// Framework images remain loaded for Objective-C/Swift runtime safety, once
// per selected Xcode path, instead of leaking another dlopen reference on attach.
static void *TSOpenFramework(NSString *path) {
    static NSMutableDictionary<NSString *, NSValue *> *images;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ images = [NSMutableDictionary dictionary]; });
    @synchronized(images) {
        void *image = images[path].pointerValue;
        if (!image) {
            image = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            if (image) images[path] = [NSValue valueWithPointer:image];
        }
        return image;
    }
}

// Loading a second SimulatorKit would register the same Objective-C classes
// from another Xcode image. Keep one installation for the process lifetime.
static void *TSOpenSimulatorKit(NSArray<NSString *> *paths, BOOL *changedInstallation) {
    static NSString *loadedPath;
    @synchronized(NativeSimulatorConnection.class) {
        for (NSString *path in paths) {
            NSString *canonical = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
            if (![NSFileManager.defaultManager fileExistsAtPath:canonical]) continue;
            if (loadedPath && ![loadedPath isEqualToString:canonical]) {
                *changedInstallation = YES;
                return NULL;
            }
            void *image = TSOpenFramework(canonical);
            if (image) { loadedPath = canonical; return image; }
        }
        return NULL;
    }
}

static NSError *TSConnectionError(NSString *message) {
    return [NSError errorWithDomain:@"ai.tokenstat.simulator" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSError *TSStartingError(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:@"ai.tokenstat.simulator" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}

@implementation NativeSimulatorConnection {
    id<TSRuntime> _device;
    id<TSRuntime> _io;
    id<TSRuntime> _screen;
    NSArray<id<TSRuntime>> *_screens;
    id<TSRuntime> _hid;
    NSUUID *_callbackID;
    void (^_frameHandler)(id, CGSize, NSInteger);
    BOOL _active;
    uint32_t _touchID;
    uint8_t _edge;
    BOOL _touchDown;
    CGPoint _lastTouchPoint;
    unsigned int _touchScreenID;
    void *_simulatorKit;
    xpc_connection_t _digitizer;
    xpc_connection_t _vendor;
    BOOL _inputReady;
    NSMutableSet<NSNumber *> *_pressedKeys;
    BOOL _modernExpected;
    BOOL _legacyServices;
    BOOL _vendorReady;
    NSMutableDictionary<NSString *, id> *_pendingVendorEvents;
    unsigned int _currentDisplayID;
    NSUInteger _inputChannelGeneration;
    NSUInteger _vendorChannelGeneration;
    unsigned long long _bootGeneration;
    BOOL _displayFailed;
}

// The guest HID daemon decodes typed XPC values, including unsigned integers.
// Keep that wire conversion here rather than relying on JSON coercion.
static xpc_object_t TSXPCValue(id object) {
    if ([object isKindOfClass:NSString.class]) return xpc_string_create([object UTF8String]);
    if ([object isKindOfClass:NSData.class]) return xpc_data_create([object bytes], [object length]);
    if ([object isKindOfClass:NSDictionary.class]) {
        xpc_object_t value = xpc_dictionary_create(NULL, NULL, 0);
        for (NSString *key in object) xpc_dictionary_set_value(value, key.UTF8String, TSXPCValue(object[key]));
        return value;
    }
    if (CFGetTypeID((__bridge CFTypeRef)object) == CFBooleanGetTypeID()) return xpc_bool_create([object boolValue]);
    if (strcmp([object objCType], @encode(double)) == 0) return xpc_double_create([object doubleValue]);
    return xpc_uint64_create([object unsignedLongLongValue]);
}

- (xpc_connection_t)channel:(NSString *)service {
    typedef xpc_endpoint_t (*Endpoint)(mach_port_t,uint64_t,uint64_t);
    typedef void (*SimulatorPeer)(xpc_connection_t);
    Endpoint endpoint = (Endpoint)dlsym(RTLD_DEFAULT,"xpc_endpoint_create_mach_port_4sim");
    SimulatorPeer mark = (SimulatorPeer)dlsym(RTLD_DEFAULT,"xpc_connection_enable_sim2host_4sim");
    if (!endpoint || !mark) return nil;
    if (![_device respondsToSelector:@selector(lookup:error:)]) return nil;
    mach_port_t port;
    @try { port = [_device lookup:service error:nil]; } @catch (NSException *exception) { return nil; }
    if (!port) return nil;
    xpc_endpoint_t address = endpoint(port,0,0);
    if (!address) { mach_port_deallocate(mach_task_self(),port); return nil; }
    xpc_connection_t channel = xpc_connection_create_from_endpoint(address);
    if (!channel) return nil;
    mark(channel);
    xpc_connection_set_target_queue(channel,dispatch_get_main_queue());
    BOOL vendor = [service hasSuffix:@"vendordefined"];
    NSUInteger generation = vendor ? ++_vendorChannelGeneration : ++_inputChannelGeneration;
    __weak NativeSimulatorConnection *weakSelf = self;
    xpc_connection_set_event_handler(channel, ^(xpc_object_t event) {
        NativeSimulatorConnection *owner = weakSelf;
        if (!owner || xpc_get_type(event) != XPC_TYPE_ERROR) return;
        if (vendor) {
            if (generation != owner->_vendorChannelGeneration || !owner->_vendor) return;
            xpc_connection_cancel(owner->_vendor); owner->_vendor = nil;
            owner->_vendorReady = NO; owner->_pendingVendorEvents = nil;
        } else {
            if (generation != owner->_inputChannelGeneration) return;
            owner->_inputReady = NO;
        }
        if (owner->_active && owner.controlFailureHandler) owner.controlFailureHandler(TSConnectionError(@"The device input service disconnected. Reattach the simulator to retry."));
    });
    xpc_connection_resume(channel);
    return channel;
}

- (xpc_object_t)envelope:(NSString *)type payload:(NSDictionary *)payload vendor:(BOOL)vendor barrier:(BOOL)barrier {
    return TSXPCValue(@{@"messageType":type,@"isBarrier":@(barrier),
        @"featureIdentifier":vendor ? @"com.apple.coredevice.feature.remote.hid.vendordefined" : @"com.apple.coredevice.feature.remote.hid.digitizer",
        @"payload":payload});
}

- (void)prepareInputWithCompletion:(void (^)(NSError *))completion {
    if (_digitizer) xpc_connection_cancel(_digitizer);
    _digitizer = _modernExpected ? [self channel:@"com.apple.coredevice.feature.remote.hid.digitizer"] : nil;
    if (!_digitizer) {
        if (_modernExpected) { completion(TSStartingError(@"The simulator input service is still starting.",11)); return; }
        if (!_hid) {
            TSOpenFramework(@"/System/Library/Frameworks/IOKit.framework/IOKit");
            Class hidClass = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient") ?: NSClassFromString(@"SimDeviceLegacyHIDClient");
            @try {
                if ([hidClass instancesRespondToSelector:@selector(initWithDevice:error:)]) _hid = [(id<TSRuntime>)[hidClass alloc] initWithDevice:_device error:nil];
            } @catch (NSException *exception) {
                completion(TSConnectionError(@"Device input is unavailable in this runtime. Open the simulator in Xcode or try another runtime."));
                return;
            }
        }
        if (!_legacyServices && _hid) {
            typedef void *(*Service)(void);
            for (NSString *name in @[@"IndigoHIDMessageToCreatePointerService",@"IndigoHIDMessageToCreateMouseService"]) {
                Service create = (Service)dlsym(_simulatorKit,name.UTF8String);
                if (create) [self send:create()];
            }
            _legacyServices = YES;
        }
        // Legacy guests ignore key reports until a hardware keyboard is
        // connected. Use the host layout type from the same message encoder.
        if (_hid && [_device respondsToSelector:@selector(setHardwareKeyboardEnabled:keyboardType:error:)]) {
            typedef unsigned int (*KeyboardType)(void);
            KeyboardType type = (KeyboardType)dlsym(_simulatorKit,"IndigoHIDGetKeyboardType");
            NSError *error = nil;
            @try {
                if (type && ![_device setHardwareKeyboardEnabled:YES keyboardType:(unsigned char)type() error:&error]) {
                    completion(error ?: TSConnectionError(@"The simulator keyboard could not connect. Retry attaching the device."));
                    return;
                }
            } @catch (NSException *exception) {
                completion(TSConnectionError(@"The simulator keyboard could not connect. Retry attaching the device."));
                return;
            }
        }
        _inputReady = _hid != nil;
        completion(_inputReady ? nil : TSConnectionError(@"Device input is unavailable in this runtime."));
        return;
    }
    __block BOOL finished = NO;
    __block BOOL receivedReply = NO;
    __weak NativeSimulatorConnection *weakSelf = self;
    void (^finish)(NSError *) = ^(NSError *error) {
        if (finished) return;
        finished = YES;
        NativeSimulatorConnection *owner = weakSelf;
        if (owner) owner->_inputReady = error == nil;
        completion(error);
    };
    xpc_object_t barrier = [self envelope:@"IndigoKeyboardButtonEvent" payload:@{@"usageCode":@0,@"state":@2} vendor:NO barrier:YES];
    xpc_connection_send_message_with_reply(_digitizer,barrier,dispatch_get_main_queue(),^(xpc_object_t reply) {
        receivedReply = YES;
        if (xpc_get_type(reply) == XPC_TYPE_ERROR) finish(TSStartingError(@"The device input service disconnected. Retry attaching the simulator.",11));
        else dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200 * NSEC_PER_MSEC),dispatch_get_main_queue(),^{ finish(nil); });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (!receivedReply) finish(TSStartingError(@"The simulator input service is still starting. Retry attaching after boot completes.",11));
    });
}

- (BOOL)modernEvent:(NSString *)type payload:(NSDictionary *)payload {
    BOOL release = [payload[@"state"] unsignedIntegerValue] == 2;
    if (!_digitizer || !_inputReady || (!_active && !release)) return NO;
    xpc_connection_send_message(_digitizer,[self envelope:type payload:payload vendor:NO barrier:NO]);
    return YES;
}

- (BOOL)vendorControl:(NSString *)source kind:(NSString *)kind value:(id)value {
    if (!_active) return NO;
    typedef CFDataRef (*Serialize)(CFTypeRef,CFOptionFlags);
    TSOpenFramework(@"/System/Library/Frameworks/IOKit.framework/IOKit");
    Serialize serialize = (Serialize)dlsym(RTLD_DEFAULT,"IOCFSerialize");
    if (!serialize) return NO;
    NSDictionary *report = @{@"provider":@"com.apple.Virtualization.VirtualMachines",@"source":source,@"type":kind,@"value":value};
    NSData *data = CFBridgingRelease(serialize((__bridge CFTypeRef)report,1));
    if (!data) return NO;
    NSDictionary *payload = @{@"usagePage":@0xff61,@"usage":@0x5b,@"version":@0,@"data":data};
    xpc_object_t event = [self envelope:@"IndigoVendorDefinedEvent" payload:payload vendor:YES barrier:NO];
    if (_vendor && _vendorReady) { xpc_connection_send_message(_vendor,event); return YES; }
    if (!_pendingVendorEvents) _pendingVendorEvents = [NSMutableDictionary dictionary];
    _pendingVendorEvents[source] = event;
    if (_vendor) return YES;
    _vendor = [self channel:@"com.apple.coredevice.feature.remote.hid.vendordefined"];
    if (!_vendor) { _pendingVendorEvents = nil; return NO; }
    xpc_connection_t channel = _vendor;
    __weak NativeSimulatorConnection *weakSelf = self;
    xpc_object_t barrier = [self envelope:@"IndigoKeyboardButtonEvent" payload:@{@"usageCode":@0,@"state":@2} vendor:YES barrier:YES];
    xpc_connection_send_message_with_reply(channel,barrier,dispatch_get_main_queue(),^(xpc_object_t reply) {
        NativeSimulatorConnection *owner = weakSelf;
        if (!owner || owner->_vendor != channel) return;
        if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
            owner->_vendor = nil; owner->_pendingVendorEvents = nil;
            xpc_connection_cancel(channel);
            if (owner.controlFailureHandler) owner.controlFailureHandler(TSConnectionError(@"The foldable device control disconnected. Retry the control."));
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200 * NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            NativeSimulatorConnection *current = weakSelf;
            if (!current || current->_vendor != channel) return;
            current->_vendorReady = YES;
            if (current->_active) for (id pending in current->_pendingVendorEvents.allValues) xpc_connection_send_message(channel,(xpc_object_t)pending);
            current->_pendingVendorEvents = nil;
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4 * NSEC_PER_SEC),dispatch_get_main_queue(),^{
        NativeSimulatorConnection *owner = weakSelf;
        if (!owner || owner->_vendor != channel || owner->_vendorReady) return;
        owner->_vendor = nil; owner->_pendingVendorEvents = nil; xpc_connection_cancel(channel);
        if (owner.controlFailureHandler) owner.controlFailureHandler(TSConnectionError(@"The foldable device control did not respond. Retry the control."));
    });
    return YES;
}
- (BOOL)setHingeAngle:(double)angle {
    return isfinite(angle) && angle >= 0 && angle <= 180 && [self vendorControl:@"hinge-slider-control" kind:@"range" value:@(angle)];
}
- (BOOL)setFoldableOrientation:(NSInteger)orientation {
    NSArray *values = @[@"portrait",@"pud",@"landscape-left",@"landscape-right"];
    return orientation >= 1 && orientation <= 4 && [self vendorControl:@"orientation-picker-control" kind:@"enum" value:values[orientation - 1]];
}

- (instancetype)initWithDeveloperDirectory:(NSString *)directory deviceID:(NSString *)deviceID error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    NSString *bundlePath = directory.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    _modernExpected = [[[NSBundle bundleWithPath:bundlePath] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] integerValue] >= 27;
    @try {
        if (!TSOpenFramework(@"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator")) {
            if (error) *error = TSConnectionError(@"CoreSimulator is unavailable. Install Xcode and select its developer directory.");
            return nil;
        }
        NSArray *paths = @[
            [directory stringByAppendingPathComponent:@"../SharedFrameworks/SimulatorKit.framework/SimulatorKit"],
            [directory stringByAppendingPathComponent:@"Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"]
        ];
        BOOL changedInstallation = NO;
        _simulatorKit = TSOpenSimulatorKit(paths, &changedInstallation);
        if (!_simulatorKit) {
            if (error) *error = TSConnectionError(changedInstallation
                ? @"The selected Xcode installation changed. Restart Tokenstat to attach using the new installation."
                : @"This Xcode installation does not provide SimulatorKit. Select a full Xcode installation.");
            return nil;
        }
        Class<TSRuntime> contextClass = (Class<TSRuntime>)NSClassFromString(@"SimServiceContext");
        if (![contextClass respondsToSelector:@selector(sharedServiceContextForDeveloperDir:error:)]) return [self fail:error];
        id<TSRuntime> context = [contextClass sharedServiceContextForDeveloperDir:directory error:error];
        if (![context respondsToSelector:@selector(defaultDeviceSetWithError:)]) return [self fail:error];
        id<TSRuntime> set = [context defaultDeviceSetWithError:error];
        if (![set respondsToSelector:@selector(availableDevices)]) return [self fail:error];
        for (id<TSRuntime> candidate in [set availableDevices]) {
            if ([[[candidate UDID] UUIDString] caseInsensitiveCompare:deviceID] == NSOrderedSame) { _device = candidate; break; }
        }
        if (!_device || ![_device respondsToSelector:@selector(io)]) return [self fail:error];
        if ([_device respondsToSelector:@selector(runtime)]) {
            id<TSRuntime> runtime = [_device runtime];
            if ([runtime respondsToSelector:@selector(versionString)] && [runtime versionString].integerValue > 0)
                _modernExpected = [runtime versionString].integerValue >= 27;
        }
        _io = [_device io];
        return self;
    } @catch (NSException *exception) {
        if (error) *error = TSConnectionError(@"The selected Xcode runtime cannot attach this device. Open it in Xcode and retry.");
        return nil;
    }
}

- (id)fail:(NSError **)error {
    if (error && !*error) *error = TSConnectionError(@"The simulator connection is unavailable. Refresh the devices and retry after boot completes.");
    return nil;
}

- (BOOL)startWithFrameHandler:(void (^)(id, CGSize, NSInteger))handler error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Simulator display ownership belongs to the main thread");
    [self stop];
    @try {
        if (![_io respondsToSelector:@selector(ioPorts)]) { [self fail:error]; return NO; }
        NSMutableArray *screens = [NSMutableArray array];
        for (id<TSRuntime> port in [_io ioPorts]) {
            if (![port respondsToSelector:@selector(descriptor)]) continue;
            id<TSRuntime> descriptor = [port descriptor];
            if (![descriptor respondsToSelector:@selector(framebufferSurface)] ||
                ![descriptor respondsToSelector:@selector(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)]) continue;
            if ([descriptor respondsToSelector:@selector(screenProperties)]) {
                id<TSRuntime> properties = [descriptor screenProperties];
                NSString *name = [properties respondsToSelector:@selector(deviceName)] ? [properties deviceName] : nil;
                if (name.length && ![name hasPrefix:@"primary"] && ![name isEqualToString:@"PurpleMain"] && ![name isEqualToString:@"LCD"]) continue;
            }
            [screens addObject:descriptor];
        }
        _screens = screens;
        _screen = screens.firstObject;
        if (!_screen) {
            if (error) *error = TSStartingError(@"Waiting for the simulator display to finish starting.",10);
            return NO;
        }
        _callbackID = NSUUID.UUID;
        _bootGeneration = [_io respondsToSelector:@selector(bootGeneration)] ? [_io bootGeneration] : 0;
        _displayFailed = NO;
        _frameHandler = [handler copy];
        _active = YES;
        __weak NativeSimulatorConnection *weakSelf = self;
        for (id<TSRuntime> descriptor in screens) {
            __weak id<TSRuntime> weakDescriptor = descriptor;
            void (^frame)(void) = ^{ [weakSelf publishFromScreen:weakDescriptor]; };
            void (^properties)(void) = ^{ [weakSelf refreshVisibleScreen]; };
            [descriptor registerScreenCallbacksWithUUID:_callbackID callbackQueue:dispatch_get_main_queue() frameCallback:frame surfacesChangedCallback:properties propertiesChangedCallback:properties];
        }
        [self refreshVisibleScreen];
        return YES;
    } @catch (NSException *exception) {
        [self stop];
        if (error) *error = TSConnectionError(@"This runtime does not support the embedded display. Open the device in Xcode or try another runtime.");
        return NO;
    }
}

- (BOOL)screenHasContent:(id<TSRuntime>)screen {
    id image = [screen framebufferSurface];
    if (!image || CFGetTypeID((__bridge CFTypeRef)image) != IOSurfaceGetTypeID()) return NO;
    IOSurfaceRef surface = (__bridge IOSurfaceRef)image;
    if (IOSurfaceGetBytesPerElement(surface) != 4) return YES;
    if (IOSurfaceLock(surface,kIOSurfaceLockReadOnly,NULL) != KERN_SUCCESS) return NO;
    const uint8_t *base = IOSurfaceGetBaseAddress(surface);
    size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface), stride = IOSurfaceGetBytesPerRow(surface);
    BOOL content = NO;
    if (base && width && height && stride >= width * 4) for (size_t y = 0; y < 32 && !content; y++) for (size_t x = 0; x < 32; x++) {
        const uint8_t *pixel = base + (height * y / 32) * stride + (width * x / 32) * 4;
        if (pixel[0] || pixel[1] || pixel[2]) { content = YES; break; }
    }
    IOSurfaceUnlock(surface,kIOSurfaceLockReadOnly,NULL);
    return content;
}

- (void)publishFromScreen:(id<TSRuntime>)screen {
    if (!_active || !screen) return;
    @try {
        // Frame traffic identifies a panel that became active. Never bind a
        // dark panel merely because it still owns a full-size surface.
        if (screen != _screen && [self screenHasContent:screen]) _screen = screen;
        [self publishFrame];
    } @catch (NSException *exception) { }
}

- (void)refreshVisibleScreen {
    if (!_active) return;
    @try {
        if (![self screenHasContent:_screen]) for (id<TSRuntime> screen in _screens) {
            if ([self screenHasContent:screen]) { _screen = screen; break; }
        }
        [self publishFrame];
    } @catch (NSException *exception) { }
    NSUUID *lease = _callbackID;
    __weak NativeSimulatorConnection *weakSelf = self;
    for (NSNumber *delay in @[@0.12,@0.4,@0.9]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue * NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            NativeSimulatorConnection *owner = weakSelf;
            if (!owner || !owner->_active || owner->_callbackID != lease) return;
            @try {
                if (![owner screenHasContent:owner->_screen]) for (id<TSRuntime> screen in owner->_screens) {
                    if ([owner screenHasContent:screen]) { owner->_screen = screen; break; }
                }
                [owner publishFrame];
            } @catch (NSException *exception) { }
        });
    }
}

- (void)publishFrame {
    if (!_active || !_frameHandler) return;
    @try {
        id surface = [_screen framebufferSurface];
        if (!surface || CFGetTypeID((__bridge CFTypeRef)surface) != IOSurfaceGetTypeID()) return;
        IOSurfaceRef pixels = (__bridge IOSurfaceRef)surface;
        if (!IOSurfaceGetWidth(pixels) || !IOSurfaceGetHeight(pixels)) return;
        NSInteger orientation = 1;
        id<TSRuntime> properties = [_screen respondsToSelector:@selector(screenProperties)] ? [_screen screenProperties] : nil;
        if ([properties respondsToSelector:@selector(uiOrientation)]) orientation = [properties uiOrientation];
        if ([properties respondsToSelector:@selector(screenID)]) _currentDisplayID = [properties screenID];
        _frameHandler(surface, CGSizeMake(IOSurfaceGetWidth(pixels), IOSurfaceGetHeight(pixels)), orientation);
    } @catch (NSException *exception) { _displayFailed = YES; }
}

- (void)releaseInputs {
    if (_touchDown && _active) [self touchAtPoint:_lastTouchPoint phase:2];
    for (NSNumber *usage in _pressedKeys.copy) [self sendKeyUsage:usage.unsignedIntegerValue pressed:NO];
}
- (void)stop {
    [self releaseInputs];
    _active = NO;
    _pendingVendorEvents = nil;
    _frameHandler = nil;
    for (id<TSRuntime> screen in _screens) {
        @try {
            if (_callbackID && [screen respondsToSelector:@selector(unregisterScreenCallbacksWithUUID:)]) [screen unregisterScreenCallbacksWithUUID:_callbackID];
        } @catch (NSException *exception) { }
    }
    _callbackID = nil; _screen = nil; _screens = nil;
}
- (void)dealloc {
    [self stop];
    if (_digitizer) {
        // Flush the final touch/key releases before cancelling the transport.
        xpc_connection_t channel = _digitizer;
        xpc_connection_send_barrier(channel, ^{ xpc_connection_cancel(channel); });
    }
    if (_vendor) xpc_connection_cancel(_vendor);
    typedef void *(*Service)(void);
    if (_legacyServices) for (NSString *name in @[@"IndigoHIDMessageToRemovePointerService",@"IndigoHIDMessageToRemoveMouseService"]) {
        Service remove = _simulatorKit ? (Service)dlsym(_simulatorKit,name.UTF8String) : NULL;
        if (remove) [self send:remove()];
    }
}

- (BOOL)send:(void *)message {
    if (!message) return NO;
    if (![_hid respondsToSelector:@selector(sendWithMessage:freeWhenDone:completionQueue:completion:)]) { free(message); return NO; }
    @try { [_hid sendWithMessage:message freeWhenDone:YES completionQueue:nil completion:nil]; return YES; }
    @catch (NSException *exception) { return NO; }
}

- (BOOL)touchAtPoint:(CGPoint)point phase:(NSInteger)phase {
    if (!_active || (!_hid && !_digitizer) || phase < 0 || phase > 2 || !isfinite(point.x) || !isfinite(point.y) || point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) return NO;
    if (_digitizer) {
        if (phase == 0) _edge = point.y > .985 ? 3 : point.x < .015 ? 2 : point.x > .985 ? 4 : point.y < .015 ? 1 : 0;
        unsigned int screenID = _currentDisplayID;
        if (phase == 0) { _touchScreenID = screenID; _touchDown = YES; }
        _lastTouchPoint = point;
        if (phase == 2) _touchDown = NO;
        return [self modernEvent:@"IndigoDigitizerEvent" payload:@{@"pointOne":@{@"x":@(point.x),@"y":@(point.y)},
            @"eventType":@(phase),@"edge":@(_edge),@"target":@(_touchScreenID)}];
    }
    // IOHID digitizer parent + finger is the host touch transport. The Indigo
    // trackpad encoder supplies the wire layout; validate its allocation before
    // filling the digitizer routing and edge fields on both event records.
    typedef CFTypeRef (*Parent)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,bool,bool,uint32_t);
    typedef CFTypeRef (*Finger)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,bool,bool,uint32_t);
    typedef void (*Append)(CFTypeRef,CFTypeRef,uint32_t);
    typedef void *(*Encode)(CFTypeRef);
    Parent parent = (Parent)dlsym(RTLD_DEFAULT,"IOHIDEventCreateDigitizerEvent");
    Finger finger = (Finger)dlsym(RTLD_DEFAULT,"IOHIDEventCreateDigitizerFingerEvent");
    Append append = (Append)dlsym(RTLD_DEFAULT,"IOHIDEventAppendEvent");
    Encode encode = (Encode)dlsym(_simulatorKit,"IndigoHIDMessageForTrackpadEventFromHIDEventRef");
    if (!parent || !finger || !append || !encode) return NO;
    if (phase == 0) { _touchID++; _touchDown = YES; _edge = point.y > .985 ? 1 : point.x < .015 ? 2 : point.x > .985 ? 4 : point.y < .015 ? 8 : 0; }
    if (phase == 2) _touchDown = NO;
    bool down = phase != 2;
    uint32_t mask = down ? 7 : 6;
    uint64_t now = mach_absolute_time();
    CFTypeRef p = parent(NULL,now,2,0,_touchID,mask,0,point.x,point.y,0,0,0,down,down,0);
    CFTypeRef f = finger(NULL,now,0,_touchID,mask,point.x,point.y,0,0,0,down,down,0);
    if (!p || !f) { if (p) CFRelease(p); if (f) CFRelease(f); return NO; }
    append(p,f,0);
    void *message = encode(p);
    CFRelease(f); CFRelease(p);
    if (!message) return NO;
    size_t size = malloc_size(message);
    if (size < 0x110) { free(message); return NO; }
    uint8_t *bytes = message;
    for (NSUInteger offset = 0; offset <= 0xa0; offset += 0xa0) {
        uint32_t target = 0x32;
        memcpy(bytes + offset + 0x6c, &target, sizeof(target));
        bytes[offset + 0x3a] = _edge ? 4 : 0;
        bytes[offset + 0x3b] = _edge;
    }
    return [self send:message];
}

- (BOOL)pressButton:(NSUInteger)usage {
    if (_digitizer) {
        NSDictionary *down = @{@"usagePage":@12,@"usageCode":@(usage == 0 ? 0x40 : 0x30),@"state":@1};
        BOOL sent = [self modernEvent:@"IndigoButtonEvent" payload:down];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50 * NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            [self modernEvent:@"IndigoButtonEvent" payload:@{@"usagePage":@12,@"usageCode":@(usage == 0 ? 0x40 : 0x30),@"state":@2}];
        });
        return sent;
    }
    typedef void *(*Button)(uint32_t,uint32_t,uint32_t);
    Button make = (Button)dlsym(_simulatorKit,"IndigoHIDMessageForButton");
    if (!make || !_active) return NO;
    BOOL sent = [self send:make((uint32_t)usage,1,0x33)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self send:make((uint32_t)usage,2,0x33)]; });
    return sent;
}
- (BOOL)keyEvent:(NSEvent *)event pressed:(BOOL)pressed {
    {
        // macOS virtual keycodes -> USB keyboard usages. Unmapped keys stay
        // with the desktop instead of indexing an unchecked private table.
        static const unsigned short codes[128] = {4,22,7,9,11,10,29,27,6,25,0,5,20,26,8,21,28,23,30,31,32,33,35,34,46,38,36,45,37,39,48,18,24,47,12,19,40,15,13,52,14,51,49,54,56,17,16,55,43,44,53,42,0,41,0,0,225,57,226,224,229,230,228,0,108,99,0,85,0,87,0,83,0,0,0,84,88,0,86,0,0,103,98,89,90,91,92,93,94,95,0,96,97,0,0,0,62,63,64,60,65,66,0,68,0,104,107,105,0,67,0,69,0,106,73,74,75,76,61,77,59,78,58,80,79,81,82,0};
        if (event.keyCode >= 128 || codes[event.keyCode] == 0) return NO;
        return [self sendKeyUsage:codes[event.keyCode] pressed:pressed];
    }

}
- (BOOL)sendKeyUsage:(NSUInteger)usage pressed:(BOOL)pressed {
    if (usage == 0 || usage > 255) return NO;
    BOOL delivered;
    if (_digitizer) delivered = [self modernEvent:@"IndigoKeyboardButtonEvent" payload:@{@"usageCode":@(usage),@"state":@(pressed ? 1 : 2)}];
    else {
        typedef void *(*Key)(unsigned int,unsigned int);
        Key make = (Key)dlsym(_simulatorKit,"IndigoHIDMessageForKeyboardArbitrary");
        void *message = make && _active ? make((unsigned int)usage,pressed ? 1 : 2) : NULL;
        // Newer host encoders target source 100. Legacy guests receive their
        // keyboard reports through the workspace source (50), like touch.
        if (message && malloc_size(message) >= 0x44) {
            uint32_t source = 0x32;
            memcpy((uint8_t *)message + 0x38, &source, sizeof(source));
            delivered = [self send:message];
        } else { free(message); delivered = NO; }
    }
    if (delivered) {
        if (!_pressedKeys) _pressedKeys = [NSMutableSet set];
        if (pressed) [_pressedKeys addObject:@(usage)]; else [_pressedKeys removeObject:@(usage)];
    }
    return delivered;
}
- (unsigned int)displayID {
    return _currentDisplayID ?: 1;
}
- (BOOL)needsReconnect {
    if (!_inputReady || _displayFailed) return YES;
    @try {
        return [_io respondsToSelector:@selector(bootGeneration)] && [_io bootGeneration] != _bootGeneration;
    } @catch (NSException *exception) { return YES; }
}
- (BOOL)setOrientation:(NSInteger)orientation {
    if (!_active || orientation < 1 || orientation > 4 || ![_device respondsToSelector:@selector(lookup:error:)]) return NO;
    @try {
        mach_port_t port = [_device lookup:@"PurpleWorkspacePort" error:nil];
        if (!port) return NO;
        uint32_t words[28] = {0};
        words[0] = MACH_MSG_TYPE_COPY_SEND; words[1] = 108; words[2] = port;
        words[5] = 0x7b; words[6] = 50 | 0x20000; words[18] = 4; words[19] = (uint32_t)orientation;
        mach_msg_return_t result = mach_msg((mach_msg_header_t *)words, MACH_SEND_MSG | MACH_SEND_TIMEOUT, 108, 0, MACH_PORT_NULL, 100, MACH_PORT_NULL);
        mach_port_deallocate(mach_task_self(),port);
        return result == MACH_MSG_SUCCESS;
    } @catch (NSException *exception) { return NO; }
}
@end
#endif
