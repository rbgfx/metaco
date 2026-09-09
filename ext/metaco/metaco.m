/*
 * Metaco - Native macOS window support with Metal acceleration
 */

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ruby.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>

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

@interface MetacoWindow : NSWindow <NSWindowDelegate>
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
        self.releasedWhenClosed = NO;
        self.shouldClose = NO;
        self.pendingEvents = [NSMutableArray array];
        [self setTitle:title];
        [self setDelegate:self];

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

- (void)rightMouseDown:(NSEvent *)event { [self mouseDown:event]; }
- (void)rightMouseUp:(NSEvent *)event { [self mouseUp:event]; }
- (void)otherMouseDown:(NSEvent *)event { [self mouseDown:event]; }
- (void)otherMouseUp:(NSEvent *)event { [self mouseUp:event]; }
- (void)mouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)rightMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)otherMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }

- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
@end

typedef struct {
    void *window;
    int width;
    int height;
    size_t byte_length;
    BOOL busy;
} MetacoHandle;

static VALUE cMetacoWindow;

static void require_main_thread(void) {
    if (!pthread_main_np()) rb_raise(rb_eThreadError, "Metaco must be called on the main thread");
}

static size_t pixel_byte_length(int width, int height) {
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384) {
        rb_raise(rb_eArgError, "Width and height must be between 1 and 16384");
    }
    if ((size_t)width > SIZE_MAX / 4 / (size_t)height ||
        (size_t)width * 4 * (size_t)height > LONG_MAX) {
        rb_raise(rb_eArgError, "Pixel buffer size is too large");
    }
    return (size_t)width * (size_t)height * 4;
}

static void release_window(void *ptr) {
    @autoreleasepool {
        MetacoWindow *window = (__bridge_transfer MetacoWindow *)ptr;
        [window.metalView cleanup];
        window.delegate = nil;
        [window close];
    }
}

static void handle_free(void *ptr) {
    MetacoHandle *handle = ptr;
    if (handle->window) {
        if (pthread_main_np()) release_window(handle->window);
        else dispatch_async_f(dispatch_get_main_queue(), handle->window, release_window);
    }
    ruby_xfree(handle);
}

static size_t handle_size(const void *ptr) { return sizeof(MetacoHandle); }

static const rb_data_type_t handle_type = {
    .wrap_struct_name = "Metaco::Window",
    .function = {.dfree = handle_free, .dsize = handle_size},
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static MetacoHandle *get_handle(VALUE value, BOOL allow_closed) {
    require_main_thread();
    MetacoHandle *handle;
    TypedData_Get_Struct(value, MetacoHandle, &handle_type, handle);
    if (!allow_closed && !handle->window) rb_raise(rb_eArgError, "Window is closed");
    if (handle->busy) rb_raise(rb_eRuntimeError, "Window is busy");
    return handle;
}

static VALUE cocoa_init(VALUE self) {
    require_main_thread();
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activateIgnoringOtherApps:YES];
    }
    return Qnil;
}

static VALUE cocoa_window_create(VALUE self, VALUE width, VALUE height, VALUE title) {
    require_main_thread();
    int w = NUM2INT(width);
    int h = NUM2INT(height);
    size_t length = pixel_byte_length(w, h);
    Check_Type(title, T_STRING);
    if (!NSApp) rb_raise(rb_eRuntimeError, "Call Metaco.init before creating a window");

    MetacoHandle *handle;
    VALUE result = TypedData_Make_Struct(cMetacoWindow, MetacoHandle, &handle_type, handle);
    handle->width = w;
    handle->height = h;
    handle->byte_length = length;
    BOOL valid_title;
    @autoreleasepool {
        NSString *text = [[NSString alloc] initWithBytes:RSTRING_PTR(title)
                                                length:RSTRING_LEN(title)
                                              encoding:NSUTF8StringEncoding];
        valid_title = text != nil;
        if (valid_title) {
            MetacoWindow *window = [[MetacoWindow alloc] initWithWidth:w height:h title:text];
            handle->window = (__bridge_retained void *)window;
        }
    }
    RB_GC_GUARD(title);
    if (!valid_title) rb_raise(rb_eArgError, "Title must contain valid UTF-8");
    if (!handle->window) rb_raise(rb_eRuntimeError, "Failed to create window resources");
    return result;
}

static VALUE cocoa_window_destroy(VALUE self, VALUE value) {
    MetacoHandle *handle = get_handle(value, YES);
    void *ptr = handle->window;
    handle->window = NULL;
    if (ptr) release_window(ptr);
    RB_GC_GUARD(value);
    return Qnil;
}

static VALUE cocoa_set_pixels(VALUE self, VALUE value, VALUE buffer, VALUE width, VALUE height) {
    require_main_thread();
    int w = NUM2INT(width);
    int h = NUM2INT(height);
    size_t length = pixel_byte_length(w, h);
    Check_Type(buffer, T_STRING);
    MetacoHandle *handle = get_handle(value, NO);
    if (w != handle->width || h != handle->height) {
        rb_raise(rb_eArgError, "Pixel dimensions must match the window");
    }
    if ((size_t)RSTRING_LEN(buffer) < length) rb_raise(rb_eArgError, "Buffer too small");

    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        if (window.useMetal) {
            [window.metalView updatePixels:(const uint8_t *)RSTRING_PTR(buffer)];
        } else {
            memcpy(window.bitmapRep.bitmapData, RSTRING_PTR(buffer), handle->byte_length);
        }
    }
    RB_GC_GUARD(buffer);
    RB_GC_GUARD(value);
    return Qnil;
}

static VALUE cocoa_present(VALUE self, VALUE value) {
    MetacoHandle *handle = get_handle(value, NO);
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        if (window.useMetal) {
            [window.metalView present];
        } else {
            [window.imageView setNeedsDisplay:YES];
            [window displayIfNeeded];
        }
    }
    RB_GC_GUARD(value);
    return Qnil;
}

// Called only via rb_protect: no owning Objective-C locals or autorelease pools
// may live in a frame that Ruby's longjmp can bypass.
static VALUE events_to_ruby(VALUE ptr) {
    __unsafe_unretained NSArray *pending = (__bridge NSArray *)(void *)ptr;
    VALUE events = rb_ary_new();
    for (NSUInteger i = 0; i < pending.count; i++) {
        __unsafe_unretained NSDictionary *dict = pending[i];
        VALUE hash = rb_hash_new();
        rb_hash_aset(hash, ID2SYM(rb_intern("type")),
                     ID2SYM(rb_intern([dict[@"type"] UTF8String])));
        if (dict[@"key"]) {
            rb_hash_aset(hash, ID2SYM(rb_intern("key")), INT2NUM([dict[@"key"] intValue]));
        }
        if (dict[@"char"]) {
            __unsafe_unretained NSString *characters = dict[@"char"];
            rb_hash_aset(hash, ID2SYM(rb_intern("char")),
                         rb_utf8_str_new(characters.UTF8String,
                                         [characters lengthOfBytesUsingEncoding:NSUTF8StringEncoding]));
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
    return events;
}

static VALUE cocoa_poll_events(VALUE self, VALUE value) {
    MetacoHandle *handle = get_handle(value, NO);
    int state = 0;
    VALUE events;
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
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
        events = rb_protect(events_to_ruby, (VALUE)(__bridge void *)window.pendingEvents, &state);
        if (!state) [window.pendingEvents removeAllObjects];
    }
    RB_GC_GUARD(value);
    if (state) rb_jump_tag(state);
    return events;
}

static VALUE cocoa_should_close(VALUE self, VALUE value) {
    MetacoHandle *handle = get_handle(value, NO);
    BOOL result;
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        result = window.shouldClose;
    }
    RB_GC_GUARD(value);
    return result ? Qtrue : Qfalse;
}

static VALUE cocoa_metal_compute_available(VALUE self, VALUE value) {
    MetacoHandle *handle = get_handle(value, NO);
    BOOL result;
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        result = window.useMetal;
    }
    RB_GC_GUARD(value);
    return result ? Qtrue : Qfalse;
}

static VALUE cocoa_compile_compute_shader(VALUE self, VALUE value, VALUE msl_source) {
    Check_Type(msl_source, T_STRING);
    MetacoHandle *handle = get_handle(value, NO);
    char message[1024] = "";
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        NSString *source = [[NSString alloc] initWithBytes:RSTRING_PTR(msl_source)
                                                  length:RSTRING_LEN(msl_source)
                                                encoding:NSUTF8StringEncoding];
        NSError *error = nil;
        if (!window.useMetal) {
            snprintf(message, sizeof(message), "Metal not available");
        } else if (!source) {
            snprintf(message, sizeof(message), "Shader source must contain valid UTF-8");
        } else if (![window.metalView compileComputeShader:source error:&error]) {
            snprintf(message, sizeof(message), "Failed to compile shader: %s",
                     error.localizedDescription.UTF8String ?: "Unknown error");
        }
    }
    RB_GC_GUARD(msl_source);
    RB_GC_GUARD(value);
    if (message[0]) rb_raise(rb_eRuntimeError, "%s", message);
    return Qtrue;
}

static VALUE cocoa_dispatch_compute(VALUE self, VALUE value, VALUE uniform_data) {
    Check_Type(uniform_data, T_STRING);
    MetacoHandle *handle = get_handle(value, NO);
    BOOL compiled;
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        compiled = window.useMetal && window.metalView.hasComputeShader;
        if (compiled) {
            [window.metalView dispatchComputeWithUniforms:RSTRING_PTR(uniform_data)
                                                  length:RSTRING_LEN(uniform_data)];
        }
    }
    RB_GC_GUARD(uniform_data);
    RB_GC_GUARD(value);
    if (!compiled) rb_raise(rb_eRuntimeError, "Compute shader not compiled");
    return Qnil;
}

static VALUE cocoa_present_compute(VALUE self, VALUE value) {
    MetacoHandle *handle = get_handle(value, NO);
    BOOL compiled;
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        compiled = window.useMetal && window.metalView.hasComputeShader;
        if (compiled) [window.metalView presentCompute];
    }
    RB_GC_GUARD(value);
    if (!compiled) rb_raise(rb_eRuntimeError, "Compute shader not compiled");
    return Qnil;
}

static VALUE cocoa_has_compute_shader(VALUE self, VALUE value) {
    MetacoHandle *handle = get_handle(value, NO);
    BOOL result;
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        result = window.useMetal && window.metalView.hasComputeShader;
    }
    RB_GC_GUARD(value);
    return result ? Qtrue : Qfalse;
}

void Init_metaco(void) {
    VALUE mMetaco = rb_define_module("Metaco");
    cMetacoWindow = rb_define_class_under(mMetaco, "Window", rb_cObject);
    rb_global_variable(&cMetacoWindow);
    rb_undef_alloc_func(cMetacoWindow);

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
