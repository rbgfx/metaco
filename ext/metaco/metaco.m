/*
 * Metaco - Native macOS window support with Metal acceleration
 */

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ruby.h>
#import <ruby/thread.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>

static void native_error(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"Metaco" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface MetacoMetalView : NSView
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic, strong) id<MTLRenderPipelineState> renderPipeline;
@property (nonatomic, assign) int texWidth;
@property (nonatomic, assign) int texHeight;
@property (nonatomic, strong) id<MTLComputePipelineState> computePipeline;
@property (nonatomic, strong) id<MTLBuffer> uniformBuffer;
@property (nonatomic, strong) id<MTLTexture> outputTexture;
@property (nonatomic, readonly) BOOL hasComputeShader;
@end

@implementation MetacoMetalView

- (BOOL)hasComputeShader { return self.computePipeline != nil; }

- (instancetype)initWithFrame:(NSRect)frame device:(id<MTLDevice>)device width:(int)w height:(int)h {
    self = [super initWithFrame:frame];
    if (self) {
        self.device = device;
        self.texWidth = w;
        self.texHeight = h;
        self.commandQueue = [device newCommandQueue];
        if (!self.commandQueue) return nil;

        // A render pass preserves RGBA channel meaning when writing a BGRA drawable.
        NSString *source = @"#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "vertex float4 metaco_vertex(uint i [[vertex_id]]) {\n"
            "  const float2 p[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};\n"
            "  return float4(p[i], 0, 1);\n"
            "}\n"
            "fragment float4 metaco_fragment(float4 p [[position]],\n"
            "  texture2d<float> input [[texture(0)]]) { return input.read(uint2(p.xy)); }\n";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:nil];
        if (!library) return nil;
        MTLRenderPipelineDescriptor *pipeline = [MTLRenderPipelineDescriptor new];
        pipeline.vertexFunction = [library newFunctionWithName:@"metaco_vertex"];
        pipeline.fragmentFunction = [library newFunctionWithName:@"metaco_fragment"];
        pipeline.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        if (!pipeline.vertexFunction || !pipeline.fragmentFunction) return nil;
        self.renderPipeline = [device newRenderPipelineStateWithDescriptor:pipeline error:nil];
        if (!self.renderPipeline) return nil;

        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeManaged;
        if (@available(macOS 10.15, *)) {
            if (device.hasUnifiedMemory) desc.storageMode = MTLStorageModeShared;
        }
        self.texture = [device newTextureWithDescriptor:desc];
        if (!self.texture) return nil;

        self.wantsLayer = YES;
        self.metalLayer = [CAMetalLayer layer];
        if (!self.metalLayer) return nil;
        self.metalLayer.device = device;
        self.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        self.metalLayer.framebufferOnly = YES;
        self.metalLayer.displaySyncEnabled = NO;
        self.metalLayer.frame = frame;
        self.metalLayer.drawableSize = CGSizeMake(w, h);
        self.layer = self.metalLayer;
    }
    return self;
}

- (void)updatePixels:(const uint8_t *)data {
    [self.texture replaceRegion:MTLRegionMake2D(0, 0, self.texWidth, self.texHeight)
                    mipmapLevel:0 withBytes:data bytesPerRow:(size_t)self.texWidth * 4];
}

- (BOOL)renderTexture:(id<MTLTexture>)source toTexture:(id<MTLTexture>)target
       commandBuffer:(id<MTLCommandBuffer>)commandBuffer error:(NSError **)error {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        native_error(error, @"Failed to create render encoder");
        return NO;
    }
    [encoder setRenderPipelineState:self.renderPipeline];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return YES;
}

- (id<MTLCommandBuffer>)presentTexture:(id<MTLTexture>)texture error:(NSError **)error {
    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) return nil; // An occluded window can temporarily have no drawable.
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) {
        native_error(error, @"Failed to create render command buffer");
        return nil;
    }
    if (![self renderTexture:texture toTexture:drawable.texture commandBuffer:commandBuffer error:error]) return nil;
    [commandBuffer presentDrawable:drawable];
    return commandBuffer;
}

- (BOOL)compileComputeShader:(NSString *)mslSource error:(NSError **)error {
    id<MTLLibrary> library = [self.device newLibraryWithSource:mslSource options:nil error:error];
    if (!library) return NO;
    id<MTLFunction> function = [library newFunctionWithName:@"compute_shader"];
    if (!function) {
        native_error(error, @"compute_shader function not found");
        return NO;
    }
    id<MTLComputePipelineState> pipeline = [self.device newComputePipelineStateWithFunction:function error:error];
    if (!pipeline) return NO;

    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:self.texWidth height:self.texHeight mipmapped:NO];
    desc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> output = [self.device newTextureWithDescriptor:desc];
    id<MTLBuffer> uniforms = [self.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    if (!output || !uniforms || !uniforms.contents) {
        native_error(error, @"Failed to allocate compute resources");
        return NO;
    }

    // Publish the new state only after every resource has been created.
    self.computePipeline = pipeline;
    self.outputTexture = output;
    self.uniformBuffer = uniforms;
    return YES;
}

- (id<MTLCommandBuffer>)dispatchComputeWithUniforms:(const void *)data length:(NSUInteger)length
                                            error:(NSError **)error {
    if (!self.hasComputeShader || length > 256) {
        native_error(error, @"Invalid compute state or uniform size");
        return nil;
    }
    memset(self.uniformBuffer.contents, 0, 256);
    memcpy(self.uniformBuffer.contents, data, length);
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!commandBuffer || !encoder) {
        native_error(error, @"Failed to create compute command buffer or encoder");
        return nil;
    }
    [encoder setComputePipelineState:self.computePipeline];
    [encoder setTexture:self.outputTexture atIndex:0];
    [encoder setBuffer:self.uniformBuffer offset:0 atIndex:0];

    NSUInteger limit = MIN(self.computePipeline.maxTotalThreadsPerThreadgroup,
                           self.device.maxThreadsPerThreadgroup.width);
    if (!limit) {
        [encoder endEncoding];
        native_error(error, @"Compute pipeline has no supported threadgroup size");
        return nil;
    }
    NSUInteger width = MAX((NSUInteger)1, MIN(self.computePipeline.threadExecutionWidth, limit));
    // Use complete rows that divide the image, so even older GPUs dispatch no extra pixels.
    while ((NSUInteger)self.texWidth % width != 0) width--;
    [encoder dispatchThreadgroups:MTLSizeMake(self.texWidth / width, self.texHeight, 1)
           threadsPerThreadgroup:MTLSizeMake(width, 1, 1)];
    [encoder endEncoding];
    return commandBuffer;
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
            self.metalView = [[MetacoMetalView alloc] initWithFrame:NSMakeRect(0, 0, width, height)
                                                           device:device
                                                            width:width
                                                           height:height];
        }
        self.useMetal = self.metalView != nil;
        if (self.useMetal) {
            [self setContentView:self.metalView];
        } else {
            // Device or rendering resource creation failed: use the bitmap path.
            self.bitmapRep = [[NSBitmapImageRep alloc]
                initWithBitmapDataPlanes:NULL
                              pixelsWide:width
                              pixelsHigh:height
                           bitsPerSample:8
                         samplesPerPixel:4
                                hasAlpha:YES
                                isPlanar:NO
                          colorSpaceName:NSDeviceRGBColorSpace
                            bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                             bytesPerRow:(size_t)width * 4
                            bitsPerPixel:32];

            if (!self.bitmapRep || !self.bitmapRep.bitmapData) {
                [self close];
                return nil;
            }
            NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
            [image addRepresentation:self.bitmapRep];

            self.imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
            if (!image || !self.imageView) {
                [self close];
                return nil;
            }
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

static void *submit_command(void *ptr) {
    @autoreleasepool {
        id<MTLCommandBuffer> command = (__bridge id<MTLCommandBuffer>)ptr;
        [command commit];
        [command waitUntilCompleted];
    }
    return NULL;
}

static VALUE submit_without_gvl(VALUE ptr) {
    rb_thread_call_without_gvl(submit_command, (void *)ptr, NULL, NULL);
    return Qnil;
}

static void finish_command(id<MTLCommandBuffer> command, int *state, NSError **error) {
    if (!command) return;
    // ponytail: one frame in flight; add buffering only if synchronous presentation limits throughput.
    // rb_protect also catches interrupts while the GVL is released/reacquired.
    rb_protect(submit_without_gvl, (VALUE)(__bridge void *)command, state);
    if (!*state && command.status != MTLCommandBufferStatusCompleted) {
        if (command.error) *error = command.error;
        else native_error(error, @"GPU command failed");
    }
}

// Only call inside rb_protect (directly or through events_to_ruby).
static VALUE string_to_ruby(VALUE ptr) {
    __unsafe_unretained NSString *text = (__bridge NSString *)(void *)ptr;
    return rb_utf8_str_new(text.UTF8String, [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
}

static VALUE cocoa_present_frame(VALUE value, BOOL compute) {
    MetacoHandle *handle = get_handle(value, NO);
    VALUE message = Qnil;
    int state = 0;
    handle->busy = YES;
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        NSError *error = nil;
        if (compute && (!window.useMetal || !window.metalView.hasComputeShader)) {
            native_error(&error, @"Compute shader not compiled");
        } else if (window.useMetal) {
            id<MTLTexture> texture = compute ? window.metalView.outputTexture : window.metalView.texture;
            id<MTLCommandBuffer> command = [window.metalView presentTexture:texture error:&error];
            finish_command(command, &state, &error);
        } else {
            [window.imageView setNeedsDisplay:YES];
            [window displayIfNeeded];
        }
        if (error && !state) {
            message = rb_protect(string_to_ruby, (VALUE)(__bridge void *)error.localizedDescription, &state);
        }
    }
    handle->busy = NO;
    RB_GC_GUARD(value);
    if (state) rb_jump_tag(state);
    if (!NIL_P(message)) rb_exc_raise(rb_exc_new_str(rb_eRuntimeError, message));
    return Qnil;
}

static VALUE cocoa_present(VALUE self, VALUE value) { return cocoa_present_frame(value, NO); }
static VALUE cocoa_present_compute(VALUE self, VALUE value) { return cocoa_present_frame(value, YES); }

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
                         string_to_ruby((VALUE)(__bridge void *)characters));
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
    handle->busy = YES;
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
    handle->busy = NO;
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
    VALUE message = Qnil;
    int state = 0;
    handle->busy = YES;
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        NSString *source = [[NSString alloc] initWithBytes:RSTRING_PTR(msl_source)
                                                  length:RSTRING_LEN(msl_source)
                                                encoding:NSUTF8StringEncoding];
        NSError *error = nil;
        if (!window.useMetal) {
            native_error(&error, @"Metal not available");
        } else if (!source) {
            native_error(&error, @"Shader source must contain valid UTF-8");
        } else if (![window.metalView compileComputeShader:source error:&error] && !error) {
            native_error(&error, @"Failed to compile shader");
        }
        if (error) {
            message = rb_protect(string_to_ruby, (VALUE)(__bridge void *)error.localizedDescription, &state);
        }
    }
    handle->busy = NO;
    RB_GC_GUARD(msl_source);
    RB_GC_GUARD(value);
    if (state) rb_jump_tag(state);
    if (!NIL_P(message)) rb_exc_raise(rb_exc_new_str(rb_eRuntimeError, message));
    return Qtrue;
}

static VALUE cocoa_dispatch_compute(VALUE self, VALUE value, VALUE uniform_data) {
    Check_Type(uniform_data, T_STRING);
    if (RSTRING_LEN(uniform_data) > 256) rb_raise(rb_eArgError, "Uniform data must be at most 256 bytes");
    MetacoHandle *handle = get_handle(value, NO);
    VALUE message = Qnil;
    int state = 0;
    handle->busy = YES;
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        NSError *error = nil;
        if (!window.useMetal || !window.metalView.hasComputeShader) {
            native_error(&error, @"Compute shader not compiled");
        } else {
            id<MTLCommandBuffer> command = [window.metalView dispatchComputeWithUniforms:RSTRING_PTR(uniform_data)
                                                                                length:RSTRING_LEN(uniform_data)
                                                                                 error:&error];
            finish_command(command, &state, &error);
        }
        if (error && !state) {
            message = rb_protect(string_to_ruby, (VALUE)(__bridge void *)error.localizedDescription, &state);
        }
    }
    handle->busy = NO;
    RB_GC_GUARD(uniform_data);
    RB_GC_GUARD(value);
    if (state) rb_jump_tag(state);
    if (!NIL_P(message)) rb_exc_raise(rb_exc_new_str(rb_eRuntimeError, message));
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

static VALUE cocoa_window_size(VALUE self, VALUE value) {
    MetacoHandle *handle = get_handle(value, NO);
    VALUE dimensions = rb_ary_new_from_args(2, INT2NUM(handle->width), INT2NUM(handle->height));
    RB_GC_GUARD(value);
    return dimensions;
}

static VALUE cocoa_read_pixels_native(VALUE self, VALUE value, VALUE source) {
    if (!SYMBOL_P(source)) rb_raise(rb_eTypeError, "source must be a Symbol");
    ID source_id = SYM2ID(source);
    BOOL compute = source_id == rb_intern("compute");
    if (!compute && source_id != rb_intern("set_pixels")) {
        rb_raise(rb_eArgError, "source must be :compute or :set_pixels");
    }
    MetacoHandle *handle = get_handle(value, NO);
    VALUE output = rb_str_new(NULL, handle->byte_length);
    VALUE message = Qnil;
    int state = 0;
    handle->busy = YES;
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        NSError *error = nil;
        if (!window.useMetal) {
            if (compute) native_error(&error, @"Metal compute is not available");
            else memcpy(RSTRING_PTR(output), window.bitmapRep.bitmapData, handle->byte_length);
        } else {
            id<MTLTexture> sourceTexture = compute ? window.metalView.outputTexture : window.metalView.texture;
            if (!sourceTexture) {
                native_error(&error, @"Pixel source is not available");
            } else {
                MTLTextureDescriptor *desc = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                             width:handle->width height:handle->height mipmapped:NO];
                desc.storageMode = MTLStorageModeManaged;
                if (@available(macOS 10.15, *)) {
                    if (window.metalView.device.hasUnifiedMemory) desc.storageMode = MTLStorageModeShared;
                }
                desc.usage = MTLTextureUsageShaderRead;
                id<MTLTexture> staging = [window.metalView.device newTextureWithDescriptor:desc];
                id<MTLCommandBuffer> command = [window.metalView.commandQueue commandBuffer];
                id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
                if (!staging || !command || !blit) {
                    native_error(&error, @"Failed to allocate readback resources");
                } else {
                    [blit copyFromTexture:sourceTexture sourceSlice:0 sourceLevel:0
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:MTLSizeMake(handle->width, handle->height, 1)
                               toTexture:staging destinationSlice:0 destinationLevel:0
                       destinationOrigin:MTLOriginMake(0, 0, 0)];
                    if (desc.storageMode == MTLStorageModeManaged) [blit synchronizeResource:staging];
                    [blit endEncoding];
                    finish_command(command, &state, &error);
                    if (!state && !error) {
                        [staging getBytes:RSTRING_PTR(output) bytesPerRow:(size_t)handle->width * 4
                               fromRegion:MTLRegionMake2D(0, 0, handle->width, handle->height)
                              mipmapLevel:0];
                    }
                }
            }
        }
        if (error && !state) {
            message = rb_protect(string_to_ruby, (VALUE)(__bridge void *)error.localizedDescription, &state);
        }
    }
    handle->busy = NO;
    RB_GC_GUARD(value);
    if (state) rb_jump_tag(state);
    if (!NIL_P(message)) rb_exc_raise(rb_exc_new_str(rb_eRuntimeError, message));
    return output;
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
    rb_define_module_function(mMetaco, "window_size", cocoa_window_size, 1);
    rb_define_module_function(mMetaco, "framebuffer_size", cocoa_window_size, 1);
    rb_define_module_function(mMetaco, "read_pixels_native", cocoa_read_pixels_native, 2);
}
