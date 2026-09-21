// Compile the production implementation into a separate test-only extension.
// Fault injection and GPU readback never become part of the public gem API.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <ruby.h>
#include <stdatomic.h>
#include <unistd.h>

typedef enum {
    NoFailure, NoDevice, CommandQueueFailure, TextureFailure, RenderPipelineFailure,
    ComputePipelineFailure, UniformFailure, CommandBufferFailure,
    ComputeEncoderFailure, RenderEncoderFailure, GPUFailure, SlowGPU, EventFailure
} TestFailure;
static TestFailure test_failure;
static atomic_bool gpu_waiting;
static id<MTLDevice> test_device(void);
static VALUE test_utf8_string(const char *bytes, long length);
#define MTLCreateSystemDefaultDevice test_device
#undef rb_utf8_str_new
#define rb_utf8_str_new test_utf8_string
#include "../../ext/metaco/metaco.m"
#undef MTLCreateSystemDefaultDevice
#undef rb_utf8_str_new

@interface TestProxy : NSProxy
@property (strong) id target;
@end
@implementation TestProxy
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [self.target methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:self.target]; }
@end

@interface TestDevice : TestProxy
@end
@implementation TestDevice
- (id<MTLCommandQueue>)newCommandQueue {
    return test_failure == CommandQueueFailure ? nil : [self.target newCommandQueue];
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc {
    return test_failure == TextureFailure ? nil : [self.target newTextureWithDescriptor:desc];
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)desc error:(NSError **)error {
    return test_failure == RenderPipelineFailure ? nil : [self.target newRenderPipelineStateWithDescriptor:desc error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError **)error {
    return test_failure == ComputePipelineFailure ? nil : [self.target newComputePipelineStateWithFunction:function error:error];
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    return test_failure == UniformFailure ? nil : [self.target newBufferWithLength:length options:options];
}
@end

@interface TestCommand : TestProxy
@end
@implementation TestCommand
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
    return test_failure == ComputeEncoderFailure ? nil : [self.target computeCommandEncoder];
}
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)desc {
    return test_failure == RenderEncoderFailure ? nil : [self.target renderCommandEncoderWithDescriptor:desc];
}
- (void)waitUntilCompleted {
    if (test_failure == SlowGPU) {
        atomic_store(&gpu_waiting, true);
        usleep(100000);
    }
    [self.target waitUntilCompleted];
    atomic_store(&gpu_waiting, false);
}
- (MTLCommandBufferStatus)status {
    return test_failure == GPUFailure ? MTLCommandBufferStatusError : [(id<MTLCommandBuffer>)self.target status];
}
- (NSError *)error {
    if (test_failure != GPUFailure) return [self.target error];
    return [NSError errorWithDomain:@"MetacoTest" code:1
                          userInfo:@{NSLocalizedDescriptionKey:
                              [@"Injected GPU failure: " stringByPaddingToLength:2048 withString:@"故障" startingAtIndex:0]}];
}
@end

@interface TestQueue : TestProxy
@end
@implementation TestQueue
- (id<MTLCommandBuffer>)commandBuffer {
    if (test_failure == CommandBufferFailure) return nil;
    TestCommand *command = [TestCommand alloc];
    command.target = [self.target commandBuffer];
    return (id<MTLCommandBuffer>)command;
}
@end

static id<MTLDevice> test_device(void) {
    if (test_failure == NoDevice) return nil;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (test_failure == CommandQueueFailure || test_failure == TextureFailure || test_failure == RenderPipelineFailure) {
        TestDevice *proxy = [TestDevice alloc];
        proxy.target = device;
        return (id<MTLDevice>)proxy;
    }
    return device;
}

static VALUE test_utf8_string(const char *bytes, long length) {
    if (test_failure == EventFailure) rb_raise(rb_eRuntimeError, "Injected event conversion failure");
    return rb_utf8_str_new(bytes, length);
}

static VALUE set_failure(VALUE self, VALUE kind) {
    const char *name = StringValueCStr(kind);
    const char *names[] = {"none", "no_device", "queue", "texture", "render_pipeline",
        "compute_pipeline", "uniform", "command_buffer", "compute_encoder", "render_encoder",
        "gpu", "slow_gpu", "event"};
    for (size_t i = 0; i < sizeof(names) / sizeof(*names); i++) {
        if (strcmp(name, names[i]) == 0) { test_failure = (TestFailure)i; return Qnil; }
    }
    rb_raise(rb_eArgError, "Unknown test failure");
}

static VALUE inject_failure(VALUE self, VALUE value, VALUE kind) {
    set_failure(self, kind);
    MetacoHandle *handle = get_handle(value, NO);
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        MetacoMetalView *view = window.metalView;
        id<MTLDevice> device = view.texture.device;
        TestDevice *proxy = [TestDevice alloc];
        proxy.target = device;
        view.device = test_failure == NoFailure ? device : (id<MTLDevice>)proxy;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        TestQueue *queueProxy = [TestQueue alloc];
        queueProxy.target = queue;
        view.commandQueue = test_failure == NoFailure ? queue : (id<MTLCommandQueue>)queueProxy;
    }
    RB_GC_GUARD(value);
    return Qnil;
}

static VALUE read_pixels(VALUE self, VALUE value, VALUE compute, VALUE render) {
    MetacoHandle *handle = get_handle(value, NO);
    VALUE result = rb_str_new(NULL, handle->byte_length);
    char message[1024] = "";
    int state = 0;
    handle->busy = YES;
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        if (!window.useMetal) {
            memcpy(RSTRING_PTR(result), window.bitmapRep.bitmapData, handle->byte_length);
        } else {
            MetacoMetalView *view = window.metalView;
            id<MTLTexture> source = RTEST(compute) ? view.outputTexture : view.texture;
            id<MTLCommandBuffer> command = [view.commandQueue commandBuffer];
            NSError *error = nil;
            if (RTEST(render)) {
                MTLTextureDescriptor *desc = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                    width:handle->width height:handle->height mipmapped:NO];
                desc.usage = MTLTextureUsageRenderTarget;
                desc.storageMode = MTLStorageModePrivate;
                id<MTLTexture> target = [view.device newTextureWithDescriptor:desc];
                [view renderTexture:source toTexture:target commandBuffer:command error:&error];
                source = target;
            }
            NSUInteger stride = ((NSUInteger)handle->width * 4 + 255) & ~(NSUInteger)255;
            id<MTLBuffer> buffer = [view.device newBufferWithLength:stride * handle->height options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
            [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(handle->width, handle->height, 1)
                        toBuffer:buffer destinationOffset:0 destinationBytesPerRow:stride
                destinationBytesPerImage:stride * handle->height];
            [blit endEncoding];
            finish_command(command, &state, &error);
            if (error) snprintf(message, sizeof(message), "%s", error.localizedDescription.UTF8String);
            if (!error && !state) {
                for (int row = 0; row < handle->height; row++) {
                    memcpy(RSTRING_PTR(result) + (size_t)row * handle->width * 4,
                           (uint8_t *)buffer.contents + row * stride, (size_t)handle->width * 4);
                }
            }
        }
    }
    handle->busy = NO;
    RB_GC_GUARD(value);
    if (state) rb_jump_tag(state);
    if (message[0]) rb_raise(rb_eRuntimeError, "%s", message);
    return result;
}

static __weak MetacoWindow *watched_window;
static VALUE watch_window(VALUE self, VALUE value) {
    MetacoHandle *handle = get_handle(value, NO);
    watched_window = (__bridge MetacoWindow *)handle->window;
    return Qnil;
}
static VALUE watched_alive(VALUE self) { return watched_window != nil ? Qtrue : Qfalse; }
static VALUE waiting(VALUE self) { return atomic_load(&gpu_waiting) ? Qtrue : Qfalse; }

static VALUE resize_window(VALUE self, VALUE value, VALUE width, VALUE height) {
    MetacoHandle *handle = get_handle(value, NO);
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        NSRect content = NSMakeRect(0, 0, NUM2DBL(width), NUM2DBL(height));
        [window setFrame:[window frameRectForContentRect:content] display:YES];
        [window displayIfNeeded];
    }
    RB_GC_GUARD(value);
    return Qnil;
}

static VALUE post_events(VALUE self, VALUE value) {
    MetacoHandle *handle = get_handle(value, NO);
    @autoreleasepool {
        MetacoWindow *window = (__bridge MetacoWindow *)handle->window;
        const char text[] = "あ🎮a\0b";
        NSString *characters = [[NSString alloc] initWithBytes:text length:sizeof(text) - 1 encoding:NSUTF8StringEncoding];
        NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
            modifierFlags:NSEventModifierFlagShift | NSEventModifierFlagCommand
            timestamp:0 windowNumber:window.windowNumber context:nil characters:characters
            charactersIgnoringModifiers:characters isARepeat:NO keyCode:0];
        [window keyDown:key];
        CGEventRef scrollEvent = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, -3, 2);
        CGEventSetFlags(scrollEvent, kCGEventFlagMaskShift);
        [window scrollWheel:[NSEvent eventWithCGEvent:scrollEvent]];
        CFRelease(scrollEvent);
        [window windowDidBecomeKey:[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:window]];
        [window windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:window]];
        NSEventType types[] = {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp,
            NSEventTypeRightMouseDown, NSEventTypeRightMouseUp, NSEventTypeOtherMouseDown,
            NSEventTypeOtherMouseUp, NSEventTypeMouseMoved, NSEventTypeLeftMouseDragged,
            NSEventTypeRightMouseDragged, NSEventTypeOtherMouseDragged};
        SEL handlers[] = {@selector(mouseDown:), @selector(mouseUp:),
            @selector(rightMouseDown:), @selector(rightMouseUp:), @selector(otherMouseDown:),
            @selector(otherMouseUp:), @selector(mouseMoved:), @selector(mouseDragged:),
            @selector(rightMouseDragged:), @selector(otherMouseDragged:)};
        for (size_t i = 0; i < sizeof(types) / sizeof(*types); i++) {
            CGMouseButton button = (types[i] == NSEventTypeRightMouseDown || types[i] == NSEventTypeRightMouseUp ||
                                    types[i] == NSEventTypeRightMouseDragged) ? kCGMouseButtonRight :
                                   (types[i] == NSEventTypeOtherMouseDown || types[i] == NSEventTypeOtherMouseUp ||
                                    types[i] == NSEventTypeOtherMouseDragged) ? kCGMouseButtonCenter : kCGMouseButtonLeft;
            CGEventRef cgEvent = CGEventCreateMouseEvent(NULL, (CGEventType)types[i], CGPointMake(8, 8), button);
            NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];
            CFRelease(cgEvent);
            // Send to the public responder methods without depending on focus or screen position.
            void (*handler)(id, SEL, NSEvent *) = (void *)[window methodForSelector:handlers[i]];
            handler(window, handlers[i], event);
        }
    }
    RB_GC_GUARD(value);
    return Qnil;
}

void Init_metaco_test(void) {
    Init_metaco();
    VALUE support = rb_define_module("MetacoTest");
    rb_define_module_function(support, "failure=", set_failure, 1);
    rb_define_module_function(support, "inject_failure", inject_failure, 2);
    rb_define_module_function(support, "read_pixels", read_pixels, 3);
    rb_define_module_function(support, "watch_window", watch_window, 1);
    rb_define_module_function(support, "watched_alive?", watched_alive, 0);
    rb_define_module_function(support, "gpu_waiting?", waiting, 0);
    rb_define_module_function(support, "resize_window", resize_window, 3);
    rb_define_module_function(support, "post_events", post_events, 1);
}
