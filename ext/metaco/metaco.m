/*
 * Metaco - Native macOS window support with Metal acceleration
 */

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ruby.h>

@interface MetacoMetalView : NSView
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic, assign) int texWidth;
@property (nonatomic, assign) int texHeight;
// Compute shader support
@property (nonatomic, strong) id<MTLComputePipelineState> computePipeline;
@property (nonatomic, strong) id<MTLBuffer> uniformBuffer;
@property (nonatomic, strong) id<MTLTexture> outputTexture;
@property (nonatomic, assign) BOOL hasComputeShader;
@end

@implementation MetacoMetalView

- (void)cleanup {
    // Only cleanup if we have resources
    if (!self.device) return;

    // Wait for GPU to finish before releasing resources
    if (self.commandQueue) {
        @try {
            id<MTLCommandBuffer> syncBuffer = [self.commandQueue commandBuffer];
            if (syncBuffer) {
                [syncBuffer commit];
                [syncBuffer waitUntilCompleted];
            }
        } @catch (NSException *e) {
            // Ignore exceptions during cleanup
        }
    }

    // Clear all Metal resources
    self.computePipeline = nil;
    self.uniformBuffer = nil;
    self.outputTexture = nil;
    self.texture = nil;
    self.commandQueue = nil;
    self.metalLayer = nil;
    self.device = nil;
    self.hasComputeShader = NO;
}

// dealloc is handled automatically by ARC - no manual cleanup needed
// cocoa_window_destroy handles synchronization with GPU before release

- (instancetype)initWithFrame:(NSRect)frame device:(id<MTLDevice>)device width:(int)w height:(int)h {
    self = [super initWithFrame:frame];
    if (self) {
        self.device = device;
        self.texWidth = w;
        self.texHeight = h;

        self.wantsLayer = YES;
        self.metalLayer = [CAMetalLayer layer];
        self.metalLayer.device = device;
        self.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        self.metalLayer.framebufferOnly = NO;
        self.metalLayer.displaySyncEnabled = NO;  // Disable VSync for max FPS
        self.metalLayer.frame = frame;
        self.metalLayer.drawableSize = CGSizeMake(w, h);
        self.layer = self.metalLayer;

        self.commandQueue = [device newCommandQueue];

        // Create texture for pixel data
        MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:w
                                                                                          height:h
                                                                                       mipmapped:NO];
        texDesc.usage = MTLTextureUsageShaderRead;
        self.texture = [device newTextureWithDescriptor:texDesc];
    }
    return self;
}

- (void)updatePixels:(const uint8_t *)data {
    MTLRegion region = MTLRegionMake2D(0, 0, self.texWidth, self.texHeight);
    [self.texture replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:self.texWidth * 4];
}

- (void)present {
    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) return;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];

    // Blit texture to drawable
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];

    [blitEncoder copyFromTexture:self.texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(self.texWidth, self.texHeight, 1)
                       toTexture:drawable.texture
                destinationSlice:0
                destinationLevel:0
               destinationOrigin:MTLOriginMake(0, 0, 0)];

    [blitEncoder endEncoding];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

#pragma mark - Compute Shader Support

- (BOOL)compileComputeShader:(NSString *)mslSource error:(NSError **)error {
    // Compile MSL source to library
    id<MTLLibrary> library = [self.device newLibraryWithSource:mslSource
                                                       options:nil
                                                         error:error];
    if (!library) return NO;

    // Get compute function
    id<MTLFunction> computeFunc = [library newFunctionWithName:@"compute_shader"];
    if (!computeFunc) {
        if (error) *error = [NSError errorWithDomain:@"Metaco" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"compute_shader function not found"}];
        return NO;
    }

    // Create compute pipeline
    self.computePipeline = [self.device newComputePipelineStateWithFunction:computeFunc error:error];
    if (!self.computePipeline) return NO;

    // Create output texture (writable)
    MTLTextureDescriptor *texDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:self.texWidth
                                    height:self.texHeight
                                 mipmapped:NO];
    texDesc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    self.outputTexture = [self.device newTextureWithDescriptor:texDesc];

    // Create uniform buffer (256 bytes should be enough for most shaders)
    self.uniformBuffer = [self.device newBufferWithLength:256
                                                  options:MTLResourceStorageModeShared];

    self.hasComputeShader = YES;
    return YES;
}

- (void)dispatchComputeWithUniforms:(const void *)uniformData length:(NSUInteger)length {
    if (!self.hasComputeShader) return;

    // Update uniform buffer
    memcpy(self.uniformBuffer.contents, uniformData, MIN(length, 256));

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];

    [computeEncoder setComputePipelineState:self.computePipeline];
    [computeEncoder setTexture:self.outputTexture atIndex:0];
    [computeEncoder setBuffer:self.uniformBuffer offset:0 atIndex:0];

    // Calculate optimal thread group size
    NSUInteger threadGroupSize = self.computePipeline.maxTotalThreadsPerThreadgroup;
    NSUInteger threadGroupWidth = 16;
    NSUInteger threadGroupHeight = 16;

    if (threadGroupWidth * threadGroupHeight > threadGroupSize) {
        threadGroupWidth = 8;
        threadGroupHeight = 8;
    }

    MTLSize threadsPerGroup = MTLSizeMake(threadGroupWidth, threadGroupHeight, 1);
    MTLSize threadGroups = MTLSizeMake(
        (self.texWidth + threadGroupWidth - 1) / threadGroupWidth,
        (self.texHeight + threadGroupHeight - 1) / threadGroupHeight,
        1
    );

    [computeEncoder dispatchThreadgroups:threadGroups threadsPerThreadgroup:threadsPerGroup];
    [computeEncoder endEncoding];

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
}

- (void)presentCompute {
    if (!self.hasComputeShader) return;

    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) return;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];

    // Blit from compute output to drawable
    [blitEncoder copyFromTexture:self.outputTexture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(self.texWidth, self.texHeight, 1)
                       toTexture:drawable.texture
                destinationSlice:0
                destinationLevel:0
               destinationOrigin:MTLOriginMake(0, 0, 0)];

    [blitEncoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end

@interface MetacoWindow : NSWindow
@property (nonatomic, assign) BOOL shouldClose;
@property (nonatomic, strong) NSMutableArray *pendingEvents;
@property (nonatomic, strong) MetacoMetalView *metalView;
@property (nonatomic, assign) BOOL useMetal;
// Fallback for non-Metal
@property (nonatomic, strong) NSBitmapImageRep *bitmapRep;
@property (nonatomic, strong) NSImageView *imageView;
@end

@implementation MetacoWindow

- (instancetype)initWithWidth:(int)width height:(int)height title:(NSString *)title {
    NSRect frame = NSMakeRect(100, 100, width, height);
    self = [super initWithContentRect:frame
                            styleMask:(NSWindowStyleMaskTitled |
                                      NSWindowStyleMaskClosable |
                                      NSWindowStyleMaskMiniaturizable)
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        self.shouldClose = NO;
        self.pendingEvents = [NSMutableArray array];
        [self setTitle:title];
        [self setDelegate:(id<NSWindowDelegate>)self];

        // Try to use Metal
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device) {
            self.useMetal = YES;
            self.metalView = [[MetacoMetalView alloc] initWithFrame:NSMakeRect(0, 0, width, height)
                                                           device:device
                                                            width:width
                                                           height:height];
            [self setContentView:self.metalView];
        } else {
            // Fallback to bitmap
            self.useMetal = NO;
            self.bitmapRep = [[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:NULL
                              pixelsWide:width
                              pixelsHigh:height
                           bitsPerSample:8
                         samplesPerPixel:4
                                hasAlpha:YES
                                isPlanar:NO
                          colorSpaceName:NSDeviceRGBColorSpace
                             bytesPerRow:width * 4
                            bitsPerPixel:32];

            NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
            [image addRepresentation:self.bitmapRep];

            self.imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
            [self.imageView setImage:image];
            [self.imageView setImageScaling:NSImageScaleAxesIndependently];
            [self setContentView:self.imageView];
        }

        [self setAcceptsMouseMovedEvents:YES];
        [self makeKeyAndOrderFront:nil];
    }
    return self;
}

- (BOOL)windowShouldClose:(id)sender {
    self.shouldClose = YES;
    return NO;
}

- (void)keyDown:(NSEvent *)event {
    NSDictionary *eventDict = @{
        @"type": @"key_press",
        @"key": @([event keyCode]),
        @"char": [event characters] ?: @""
    };
    [self.pendingEvents addObject:eventDict];
}

- (void)keyUp:(NSEvent *)event {
    NSDictionary *eventDict = @{
        @"type": @"key_release",
        @"key": @([event keyCode])
    };
    [self.pendingEvents addObject:eventDict];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint loc = [event locationInWindow];
    NSDictionary *eventDict = @{
        @"type": @"mouse_press",
        @"x": @(loc.x),
        @"y": @(loc.y),
        @"button": @([event buttonNumber])
    };
    [self.pendingEvents addObject:eventDict];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint loc = [event locationInWindow];
    NSDictionary *eventDict = @{
        @"type": @"mouse_release",
        @"x": @(loc.x),
        @"y": @(loc.y),
        @"button": @([event buttonNumber])
    };
    [self.pendingEvents addObject:eventDict];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint loc = [event locationInWindow];
    NSDictionary *eventDict = @{
        @"type": @"mouse_move",
        @"x": @(loc.x),
        @"y": @(loc.y)
    };
    [self.pendingEvents addObject:eventDict];
}

- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
@end

static VALUE cocoa_init(VALUE self) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activateIgnoringOtherApps:YES];
    }
    return Qnil;
}

static VALUE cocoa_window_create(VALUE self, VALUE width, VALUE height, VALUE title) {
    @autoreleasepool {
        int w = NUM2INT(width);
        int h = NUM2INT(height);
        NSString *t = [NSString stringWithUTF8String:StringValueCStr(title)];

        MetacoWindow *window = [[MetacoWindow alloc] initWithWidth:w height:h title:t];
        return ULONG2NUM((unsigned long)(__bridge_retained void *)window);
    }
}

static VALUE cocoa_window_destroy(VALUE self, VALUE window_ptr) {
    void *ptr = (void *)NUM2ULONG(window_ptr);
    if (!ptr) return Qnil;

    // Get window reference without transferring ownership yet
    MetacoWindow *window = (__bridge MetacoWindow *)ptr;

    // Synchronize GPU before cleanup (outside autoreleasepool)
    if (window && window.useMetal && window.metalView) {
        MetacoMetalView *metalView = window.metalView;
        if (metalView.commandQueue) {
            @try {
                id<MTLCommandBuffer> syncBuffer = [metalView.commandQueue commandBuffer];
                if (syncBuffer) {
                    [syncBuffer commit];
                    [syncBuffer waitUntilCompleted];
                }
            } @catch (NSException *e) {
                // Ignore - GPU may already be done
            }
        }
        // Mark that we've cleaned up the compute shader
        metalView.hasComputeShader = NO;
    }

    // Close the window
    if (window) {
        [window close];
    }

    // Now transfer ownership to ARC - this will release the object
    // Do this outside autoreleasepool to avoid double-release issues
    (void)(__bridge_transfer id)ptr;

    return Qnil;
}

static VALUE cocoa_set_pixels(VALUE self, VALUE window_ptr, VALUE buffer, VALUE width, VALUE height) {
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)(void *)NUM2ULONG(window_ptr);
        int w = NUM2INT(width);
        int h = NUM2INT(height);

        Check_Type(buffer, T_STRING);
        const unsigned char *data = (const unsigned char *)RSTRING_PTR(buffer);
        long len = RSTRING_LEN(buffer);

        if (len < w * h * 4) {
            rb_raise(rb_eArgError, "Buffer too small");
        }

        if (window.useMetal) {
            [window.metalView updatePixels:data];
        } else {
            unsigned char *bitmapData = [window.bitmapRep bitmapData];
            memcpy(bitmapData, data, w * h * 4);
        }
    }
    return Qnil;
}

static VALUE cocoa_present(VALUE self, VALUE window_ptr) {
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)(void *)NUM2ULONG(window_ptr);

        if (window.useMetal) {
            [window.metalView present];
        } else {
            [window.imageView setNeedsDisplay:YES];
            [window displayIfNeeded];
        }
    }
    return Qnil;
}

static VALUE cocoa_poll_events(VALUE self, VALUE window_ptr) {
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)(void *)NUM2ULONG(window_ptr);

        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                           untilDate:nil
                                              inMode:NSDefaultRunLoopMode
                                             dequeue:YES])) {
            [NSApp sendEvent:event];
        }

        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
        [NSApp updateWindows];

        VALUE events = rb_ary_new();
        for (NSDictionary *dict in window.pendingEvents) {
            VALUE hash = rb_hash_new();

            NSString *type = dict[@"type"];
            rb_hash_aset(hash, ID2SYM(rb_intern("type")),
                        ID2SYM(rb_intern([type UTF8String])));

            if (dict[@"key"]) {
                rb_hash_aset(hash, ID2SYM(rb_intern("key")), INT2NUM([dict[@"key"] intValue]));
            }
            if (dict[@"char"]) {
                rb_hash_aset(hash, ID2SYM(rb_intern("char")),
                           rb_str_new_cstr([dict[@"char"] UTF8String]));
            }
            if (dict[@"x"]) {
                rb_hash_aset(hash, ID2SYM(rb_intern("x")), DBL2NUM([dict[@"x"] doubleValue]));
            }
            if (dict[@"y"]) {
                rb_hash_aset(hash, ID2SYM(rb_intern("y")), DBL2NUM([dict[@"y"] doubleValue]));
            }
            if (dict[@"button"]) {
                rb_hash_aset(hash, ID2SYM(rb_intern("button")), INT2NUM([dict[@"button"] intValue]));
            }

            rb_ary_push(events, hash);
        }

        [window.pendingEvents removeAllObjects];
        return events;
    }
}

static VALUE cocoa_should_close(VALUE self, VALUE window_ptr) {
    MetacoWindow *window = (__bridge MetacoWindow *)(void *)NUM2ULONG(window_ptr);
    return window.shouldClose ? Qtrue : Qfalse;
}

// ========== Compute Shader Bridge Functions ==========

static VALUE cocoa_metal_compute_available(VALUE self, VALUE window_ptr) {
    MetacoWindow *window = (__bridge MetacoWindow *)(void *)NUM2ULONG(window_ptr);
    return (window.useMetal && window.metalView.device) ? Qtrue : Qfalse;
}

static VALUE cocoa_compile_compute_shader(VALUE self, VALUE window_ptr, VALUE msl_source) {
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)(void *)NUM2ULONG(window_ptr);
        if (!window.useMetal) {
            rb_raise(rb_eRuntimeError, "Metal not available");
        }

        Check_Type(msl_source, T_STRING);
        NSString *source = [NSString stringWithUTF8String:StringValueCStr(msl_source)];
        NSError *error = nil;

        if (![window.metalView compileComputeShader:source error:&error]) {
            rb_raise(rb_eRuntimeError, "Failed to compile shader: %s",
                     [[error localizedDescription] UTF8String]);
        }
    }
    return Qtrue;
}

static VALUE cocoa_dispatch_compute(VALUE self, VALUE window_ptr, VALUE uniform_data) {
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)(void *)NUM2ULONG(window_ptr);
        if (!window.useMetal || !window.metalView.hasComputeShader) {
            rb_raise(rb_eRuntimeError, "Compute shader not compiled");
        }

        Check_Type(uniform_data, T_STRING);
        const void *data = RSTRING_PTR(uniform_data);
        long length = RSTRING_LEN(uniform_data);

        [window.metalView dispatchComputeWithUniforms:data length:length];
    }
    return Qnil;
}

static VALUE cocoa_present_compute(VALUE self, VALUE window_ptr) {
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)(void *)NUM2ULONG(window_ptr);
        if (window.useMetal && window.metalView.hasComputeShader) {
            [window.metalView presentCompute];
        }
    }
    return Qnil;
}

static VALUE cocoa_has_compute_shader(VALUE self, VALUE window_ptr) {
    MetacoWindow *window = (__bridge MetacoWindow *)(void *)NUM2ULONG(window_ptr);
    return (window.useMetal && window.metalView.hasComputeShader) ? Qtrue : Qfalse;
}

void Init_metaco(void) {
    VALUE mMetaco = rb_define_module("Metaco");

    rb_define_module_function(mMetaco, "init", cocoa_init, 0);
    rb_define_module_function(mMetaco, "window_create", cocoa_window_create, 3);
    rb_define_module_function(mMetaco, "window_destroy", cocoa_window_destroy, 1);
    rb_define_module_function(mMetaco, "set_pixels", cocoa_set_pixels, 4);
    rb_define_module_function(mMetaco, "present", cocoa_present, 1);
    rb_define_module_function(mMetaco, "poll_events", cocoa_poll_events, 1);
    rb_define_module_function(mMetaco, "should_close?", cocoa_should_close, 1);

    // Compute shader functions
    rb_define_module_function(mMetaco, "metal_compute_available?", cocoa_metal_compute_available, 1);
    rb_define_module_function(mMetaco, "compile_compute_shader", cocoa_compile_compute_shader, 2);
    rb_define_module_function(mMetaco, "dispatch_compute", cocoa_dispatch_compute, 2);
    rb_define_module_function(mMetaco, "present_compute", cocoa_present_compute, 1);
    rb_define_module_function(mMetaco, "has_compute_shader?", cocoa_has_compute_shader, 1);
}
