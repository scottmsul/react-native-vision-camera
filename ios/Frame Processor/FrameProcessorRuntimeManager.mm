//
//  FrameProcessorRuntimeManager.m
//  VisionCamera
//
//  Created by Marc Rousavy on 23.03.21.
//  Copyright © 2021 mrousavy. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "FrameProcessorRuntimeManager.h"
#import "FrameProcessorPluginRegistry.h"
#import "FrameProcessorPlugin.h"
#import "FrameHostObject.h"

#import <memory>

#import <React/RCTBridge.h>
#import <ReactCommon/RCTTurboModule.h>
#import <React/RCTBridge+Private.h>
#import <React/RCTUIManager.h>
#import <ReactCommon/RCTTurboModuleManager.h>

#import "WKTJsiWorkletContext.h"
#import "WKTJsiWorkletApi.h"
#import "WKTJsiWorklet.h"
#import "WKTJsiHostObject.h"

#import "FrameProcessorUtils.h"
#import "FrameProcessorCallback.h"
#import "../React Utils/JSIUtils.h"
#import "../../cpp/JSITypedArray.h"

#import <TensorFlowLiteObjC/TFLTensorFlowLite.h>
#import <TensorFlowLiteObjC/TFLMetalDelegate.h>
#import <TensorFlowLiteObjC/TFLCoreMLDelegate.h>
#import <Accelerate/Accelerate.h>
#import "../../cpp/JSITypedArray.h"

// Forward declarations for the Swift classes
__attribute__((objc_runtime_name("_TtC12VisionCamera12CameraQueues")))
@interface CameraQueues : NSObject
@property (nonatomic, class, readonly, strong) dispatch_queue_t _Nonnull videoQueue;
@end
__attribute__((objc_runtime_name("_TtC12VisionCamera10CameraView")))
@interface CameraView : UIView
@property (nonatomic, copy) FrameProcessorCallback _Nullable frameProcessorCallback;
@end

using namespace vision;

@implementation FrameProcessorRuntimeManager {
  // Running Frame Processors on camera's video thread (synchronously)
  std::shared_ptr<RNWorklet::JsiWorkletContext> workletContext;
}

- (instancetype)init {
    if (self = [super init]) {
        // Initialize self
    }
    return self;
}

- (void) setupWorkletContext:(jsi::Runtime&)runtime {
  NSLog(@"FrameProcessorBindings: Creating Worklet Context...");

  auto callInvoker = RCTBridge.currentBridge.jsCallInvoker;

  auto runOnJS = [callInvoker](std::function<void()>&& f) {
    // Run on React JS Runtime
    callInvoker->invokeAsync(std::move(f));
  };
  auto runOnWorklet = [](std::function<void()>&& f) {
    // Run on Frame Processor Worklet Runtime
    dispatch_async(CameraQueues.videoQueue, [f = std::move(f)](){
      f();
    });
  };

  workletContext = std::make_shared<RNWorklet::JsiWorkletContext>("VisionCamera",
                                                                  &runtime,
                                                                  runOnJS,
                                                                  runOnWorklet);

  NSLog(@"FrameProcessorBindings: Worklet Context Created!");

  NSLog(@"FrameProcessorBindings: Installing Frame Processor plugins...");

  jsi::Object frameProcessorPlugins(runtime);

  // Iterate through all registered plugins (+init)
  for (NSString* pluginKey in [FrameProcessorPluginRegistry frameProcessorPlugins]) {
    auto pluginName = [pluginKey UTF8String];

    NSLog(@"FrameProcessorBindings: Installing Frame Processor plugin \"%s\"...", pluginName);
    // Get the Plugin
    FrameProcessorPlugin* plugin = [[FrameProcessorPluginRegistry frameProcessorPlugins] valueForKey:pluginKey];

    // Create the JSI host function
    auto function = [plugin, callInvoker](jsi::Runtime& runtime,
                                          const jsi::Value& thisValue,
                                          const jsi::Value* arguments,
                                          size_t count) -> jsi::Value {
      // Get the first parameter, which is always the native Frame Host Object.
      auto frameHostObject = arguments[0].asObject(runtime).asHostObject(runtime);
      auto frame = static_cast<FrameHostObject*>(frameHostObject.get());

      // Convert any additional parameters to the Frame Processor to ObjC objects
      auto args = convertJSICStyleArrayToNSArray(runtime,
                                                 arguments + 1, // start at index 1 since first arg = Frame
                                                 count - 1, // use smaller count
                                                 callInvoker);
      // Call the FP Plugin, which might return something.
      id result = [plugin callback:frame->frame withArguments:args];

      // Convert the return value (or null) to a JS Value and return it to JS
      return convertObjCObjectToJSIValue(runtime, result);
    };

    // Assign it to the Proxy.
    // A FP Plugin called "example_plugin" can be now called from JS using "FrameProcessorPlugins.example_plugin(frame)"
    frameProcessorPlugins.setProperty(runtime,
                                      pluginName,
                                      jsi::Function::createFromHostFunction(runtime,
                                                                            jsi::PropNameID::forAscii(runtime, pluginName),
                                                                            1, // frame
                                                                            function));
  }

  // global.FrameProcessorPlugins Proxy
  runtime.global().setProperty(runtime, "FrameProcessorPlugins", frameProcessorPlugins);
  
  
  
  auto func = jsi::Function::createFromHostFunction(runtime,
                                                    jsi::PropNameID::forAscii(runtime, "loadTensorflowModel"),
                                                    1,
                                                    [](jsi::Runtime& runtime,
                                                       const jsi::Value& thisValue,
                                                       const jsi::Value* arguments,
                                                       size_t count) -> jsi::Value {
    auto modelPath = arguments[0].asString(runtime);
    
    auto delegates = [[NSMutableArray alloc] init];
    
    if (count > 1 && arguments[1].isString()) {
      // user passed a custom delegate command
      auto delegate = arguments[1].asString(runtime).utf8(runtime);
      if (delegate == "core-ml") {
        [delegates addObject:[[TFLCoreMLDelegate alloc] init]];
      } else if (delegate == "metal") {
        [delegates addObject:[[TFLMetalDelegate alloc] init]];
      }
    }
    
    NSString* modelPath2 = [[NSBundle mainBundle] pathForResource:@"model"
                                                          ofType:@"tflite"];
    NSError* error;
    TFLInterpreter* interpreter = [[TFLInterpreter alloc] initWithModelPath:modelPath2
                                                                    options:[[TFLInterpreterOptions alloc] init]
                                                                  delegates:delegates
                                                                      error:&error];
    if (error != nil) {
      std::string str = std::string("Failed to load model \"") + modelPath.utf8(runtime) + "\"! Error: " + [error.description UTF8String];
      throw jsi::JSError(runtime, str);
    }

    // Allocate memory for the model's input `TFLTensor`s.
    [interpreter allocateTensorsWithError:&error];
    if (error != nil) {
      std::string str = std::string("Failed to allocate memory for the model's input tensors! Error: ") + [error.description UTF8String];
      throw jsi::JSError(runtime, str);
    }
    
    
    auto runModel = jsi::Function::createFromHostFunction(runtime,
                                                          jsi::PropNameID::forAscii(runtime, "loadTensorflowModel"),
                                                          1,
                                                          [=](jsi::Runtime& runtime,
                                                                             const jsi::Value& thisValue,
                                                                             const jsi::Value* arguments,
                                                                             size_t count) -> jsi::Value {
      auto frame = arguments[0].asObject(runtime).asHostObject<FrameHostObject>(runtime);
      
      NSError* error;
      
      // Get the input `TFLTensor`
      TFLTensor* inputTensor = [interpreter inputTensorAtIndex:0 error:&error];
      if (error != nil) {
        throw jsi::JSError(runtime, std::string("Failed to find input sensor for model! Error: ") + [error.description UTF8String]);
      }
      
      auto shape = [inputTensor shapeWithError:&error];
      if (error != nil) {
        throw jsi::JSError(runtime, std::string("Failed to get input sensor shape! Error: ") + [error.description UTF8String]);
      }
      
      unsigned long tensorStride_IDK = shape[0].unsignedLongValue;
      unsigned long tensorWidth = shape[1].unsignedLongValue;
      unsigned long tensorHeight = shape[2].unsignedLongValue;
      unsigned long tensorChannels = shape[3].unsignedLongValue;
      
      CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(frame->frame.buffer);
      CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

      size_t width = CVPixelBufferGetWidth(pixelBuffer);
      size_t height = CVPixelBufferGetHeight(pixelBuffer);
      size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
      OSType pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer);

      size_t tensorBytesPerRow = tensorWidth * tensorChannels;

      // Get a pointer to the pixel buffer data
      CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
      void* baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);

      // Create a vImage buffer referencing the pixel buffer data
      vImage_Buffer srcBuffer = {
          .data = baseAddress,
          .width = width,
          .height = height,
          .rowBytes = bytesPerRow
      };
      
      void* data = malloc(tensorBytesPerRow * tensorHeight);

      // Create a vImage buffer for the destination (input tensor) data
      vImage_Buffer destBuffer = {
          .data = data,
          .width = tensorWidth,
          .height = tensorHeight,
          .rowBytes = tensorBytesPerRow
      };

      // Perform the color conversion (if needed) and copy the pixel data to the input tensor buffer
      if (pixelFormatType == kCVPixelFormatType_32BGRA) {
          // Convert 32BGRA to RGB
          vImage_Error error = vImageConvert_BGRA8888toRGB888(&srcBuffer, &destBuffer, kvImageNoFlags);
          
          if (error == kvImageNoError) {
              // Data conversion successful
          } else {
            throw jsi::JSError(runtime, std::string("Failed to convert Frame to Data! Error: ") + std::to_string(error));
          }
      } else {
        throw jsi::JSError(runtime, std::string("Frame has invalid Pixel Format! Expected: kCVPixelFormatType_32BGRA, received: ") + std::to_string(pixelFormatType));
      }
      
      // Copy the input data to the input `TFLTensor`.
      auto nsData = [NSData dataWithBytes:data length:tensorBytesPerRow * tensorHeight];
      [inputTensor copyData:nsData error:&error];
      if (error != nil) {
        throw jsi::JSError(runtime, std::string("Failed to copy input data to model! Error: ") + [error.description UTF8String]);
      }
      
      // Run inference by invoking the `TFLInterpreter`.
      [interpreter invokeWithError:&error];
      if (error != nil) {
        throw jsi::JSError(runtime, std::string("Failed to run model! Error: ") + [error.description UTF8String]);
      }
      
      // Get the output `TFLTensor`
      TFLTensor* outputTensor = [interpreter outputTensorAtIndex:0 error:&error];
      if (error != nil) {
        throw jsi::JSError(runtime, std::string("Failed to get output sensor for model! Error: ") + [error.description UTF8String]);
      }
      
      auto outputShape = [outputTensor shapeWithError:&error];
      if (error != nil) {
        throw jsi::JSError(runtime, std::string("Failed to get output tensor shape! Error: ") + [error.description UTF8String]);
      }
      
      // Copy output to `NSData` to process the inference results.
      NSData* outputData = [outputTensor dataWithError:&error];
      if (error != nil) {
        throw jsi::JSError(runtime, std::string("Failed to copy output data from model! Error: ") + [error.description UTF8String]);
      }
      
      CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
      
      jsi::Array result(runtime, outputShape.count);
      size_t offset = 0;
      for (size_t i = 0; i < outputShape.count; i++) {
        size_t size = outputShape[i].intValue;
        auto data = TypedArray<TypedArrayKind::Int32Array>(runtime, size);
        NSData* slice = [outputData subdataWithRange:NSMakeRange(offset, size)];
        data.updateUnsafe(runtime, (int*)slice.bytes, slice.length);
        result.setValueAtIndex(runtime, i, data);
        
        offset += size;
      }
      
      return result;
    });
    return runModel;
  });
  
  runtime.global().setProperty(runtime, "loadTensorflowModel", func);

  NSLog(@"FrameProcessorBindings: Frame Processor plugins installed!");
}

- (void) installFrameProcessorBindings {
  NSLog(@"FrameProcessorBindings: Installing Frame Processor Bindings for Bridge...");
  RCTCxxBridge *cxxBridge = (RCTCxxBridge *)[RCTBridge currentBridge];
  if (!cxxBridge.runtime) {
    return;
  }

  jsi::Runtime& jsiRuntime = *(jsi::Runtime*)cxxBridge.runtime;
  
  // HostObject that attaches the cache to the lifecycle of the Runtime. On Runtime destroy, we destroy the cache.
  auto propNameCacheObject = std::make_shared<vision::InvalidateCacheOnDestroy>(jsiRuntime);
  jsiRuntime.global().setProperty(jsiRuntime,
                                  "__visionCameraPropNameCache",
                                  jsi::Object::createFromHostObject(jsiRuntime, propNameCacheObject));

  // Install the Worklet Runtime in the main React JS Runtime
  [self setupWorkletContext:jsiRuntime];

  NSLog(@"FrameProcessorBindings: Installing global functions...");

  // setFrameProcessor(viewTag: number, frameProcessor: (frame: Frame) => void)
  auto setFrameProcessor = JSI_HOST_FUNCTION_LAMBDA {
    NSLog(@"FrameProcessorBindings: Setting new frame processor...");
    auto viewTag = arguments[0].asNumber();
    auto worklet = std::make_shared<RNWorklet::JsiWorklet>(runtime, arguments[1]);

    RCTExecuteOnMainQueue(^{
      auto currentBridge = [RCTBridge currentBridge];
      auto anonymousView = [currentBridge.uiManager viewForReactTag:[NSNumber numberWithDouble:viewTag]];
      auto view = static_cast<CameraView*>(anonymousView);
      auto callback = convertWorkletToFrameProcessorCallback(self->workletContext->getWorkletRuntime(), worklet);
      view.frameProcessorCallback = callback;
    });

    return jsi::Value::undefined();
  };
  jsiRuntime.global().setProperty(jsiRuntime, "setFrameProcessor", jsi::Function::createFromHostFunction(jsiRuntime,
                                                                                                         jsi::PropNameID::forAscii(jsiRuntime, "setFrameProcessor"),
                                                                                                         2,  // viewTag, frameProcessor
                                                                                                         setFrameProcessor));

  // unsetFrameProcessor(viewTag: number)
  auto unsetFrameProcessor = JSI_HOST_FUNCTION_LAMBDA {
    NSLog(@"FrameProcessorBindings: Removing frame processor...");
    auto viewTag = arguments[0].asNumber();

    RCTExecuteOnMainQueue(^{
      auto currentBridge = [RCTBridge currentBridge];
      if (!currentBridge) return;

      auto anonymousView = [currentBridge.uiManager viewForReactTag:[NSNumber numberWithDouble:viewTag]];
      if (!anonymousView) return;

      auto view = static_cast<CameraView*>(anonymousView);
      view.frameProcessorCallback = nil;
    });

    return jsi::Value::undefined();
  };
  jsiRuntime.global().setProperty(jsiRuntime, "unsetFrameProcessor", jsi::Function::createFromHostFunction(jsiRuntime,
                                                                                                           jsi::PropNameID::forAscii(jsiRuntime, "unsetFrameProcessor"),
                                                                                                           1,  // viewTag
                                                                                                           unsetFrameProcessor));

  NSLog(@"FrameProcessorBindings: Finished installing bindings.");
}

@end
