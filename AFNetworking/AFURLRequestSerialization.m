// AFURLRequestSerialization.m
// Copyright (c) 2011–2016 Alamofire Software Foundation ( http://alamofire.org/ )
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFURLRequestSerialization.h"

#if TARGET_OS_IOS || TARGET_OS_WATCH || TARGET_OS_TV
#import <MobileCoreServices/MobileCoreServices.h>
#else
#import <CoreServices/CoreServices.h>
#endif

#import <CocoaLumberjack/CocoaLumberjack.h>

#ifdef DEBUG
static const NSUInteger ddLogLevel = DDLogLevelAll;
#else
static const NSUInteger ddLogLevel = DDLogLevelInfo;
#endif

NSString * const AFURLRequestSerializationErrorDomain = @"com.alamofire.error.serialization.request";

#pragma mark -

@interface AFStreamDelegate : NSObject <NSStreamDelegate>

@property (atomic) BOOL hadError;

@end

#pragma mark -

@implementation AFStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    if (eventCode == NSStreamEventErrorOccurred) {
        self.hadError = YES;
    }
}

@end

#pragma mark -

static NSString * AFCreateMultipartFormBoundary() {
    return [NSString stringWithFormat:@"Boundary+%08X%08X", arc4random(), arc4random()];
}

static NSString * const kAFMultipartFormCRLF = @"\r\n";

static inline NSString * AFMultipartFormInitialBoundary(NSString *boundary) {
    return [NSString stringWithFormat:@"--%@%@", boundary, kAFMultipartFormCRLF];
}

static inline NSString * AFMultipartFormEncapsulationBoundary(NSString *boundary) {
    return [NSString stringWithFormat:@"%@--%@%@", kAFMultipartFormCRLF, boundary, kAFMultipartFormCRLF];
}

static inline NSString * AFMultipartFormFinalBoundary(NSString *boundary) {
    return [NSString stringWithFormat:@"%@--%@--%@", kAFMultipartFormCRLF, boundary, kAFMultipartFormCRLF];
}

#pragma mark -

@implementation AFMultipartBody

+  (NSStringEncoding)stringEncoding {
    return NSUTF8StringEncoding;
}

+ (BOOL)writeMultipartBodyForInputFileURL:(NSURL *)inputFileURL
                            outputFileURL:(NSURL *)outputFileURL
                                     name:(NSString *)name
                                 fileName:(NSString *)fileName
                                 mimeType:(NSString *)mimeType
                                 boundary:(NSString *)boundary
                          additionalParts:(NSDictionary<NSString *, NSString *> *)additionalParts
                                    error:(NSError * __autoreleasing *)error
{
    NSParameterAssert(inputFileURL);
    NSParameterAssert(outputFileURL);
    NSParameterAssert(name);
    NSParameterAssert(fileName);
    NSParameterAssert(mimeType);
    
    if (![outputFileURL isFileURL]) {
        NSDictionary *userInfo = @{NSLocalizedFailureReasonErrorKey: NSLocalizedStringFromTable(@"Expected URL to be a file URL", @"AFNetworking", nil)};
        if (error) {
            *error = [[NSError alloc] initWithDomain:AFURLRequestSerializationErrorDomain code:NSURLErrorBadURL userInfo:userInfo];
        }
        return NO;
    }
    
    // TODO: Audit streamStatus
    NSOutputStream *outputStream = [NSOutputStream outputStreamWithURL:outputFileURL append:NO];
    AFStreamDelegate *outputStreamDelegate = [AFStreamDelegate new];
    outputStream.delegate = outputStreamDelegate;
    [outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [outputStream open];

    DDLogInfo(@"outputFileURL: %@", outputFileURL);
    DDLogInfo(@"outputStream.streamStatus: %lu", (unsigned long) outputStream.streamStatus);
    [DDLog flushLog];                                                                                              \
    
    if (outputStream.streamStatus != NSStreamStatusOpen) {
        NSDictionary *userInfo = @{NSLocalizedFailureReasonErrorKey: NSLocalizedStringFromTable(@"File URL not reachable.", @"AFNetworking", nil)};
        if (error) {
            *error = [[NSError alloc] initWithDomain:AFURLRequestSerializationErrorDomain code:NSURLErrorBadURL userInfo:userInfo];
        }
        return NO;
    }
    
    void (^closeOutputStream)(void) = ^{
        [outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        [outputStream close];
    };

    BOOL isFirstPart = YES;
    for (NSString *additionalPartKey in additionalParts) {
        NSString *additionalPartValue = additionalParts[additionalPartKey];
        if (![self writeTextPartWithValue:additionalPartValue
                                     name:additionalPartKey
                                 boundary:boundary
                       hasInitialBoundary:isFirstPart
                         hasFinalBoundary:NO
                             outputStream:outputStream
                                    error:error]) {
            closeOutputStream();
            return NO;
        }
        isFirstPart = NO;
    }

    if (![self writeBodyPartWithInputFileURL:inputFileURL
                                        name:name
                                    fileName:fileName
                                    mimeType:mimeType
                                    boundary:boundary
                          hasInitialBoundary:isFirstPart
                            hasFinalBoundary:YES
                                outputStream:outputStream
                                       error:error]) {
        closeOutputStream();
        return NO;
    }

    closeOutputStream();

    if (outputStreamDelegate.hadError) {
        if (error) {
            *error = [[NSError alloc] initWithDomain:AFURLRequestSerializationErrorDomain code:NSURLErrorBadURL userInfo:nil];
        }
        return NO;
    }
    
    return YES;
}

+ (NSString *)createMultipartFormBoundary
{
    return AFCreateMultipartFormBoundary();
}

+ (BOOL)writeBodyPartWithInputFileURL:(NSURL *)inputFileURL
                                 name:(NSString *)name
                             fileName:(NSString *)fileName
                             mimeType:(NSString *)mimeType
                             boundary:(NSString *)boundary
                   hasInitialBoundary:(BOOL)hasInitialBoundary
                     hasFinalBoundary:(BOOL)hasFinalBoundary
                         outputStream:(NSOutputStream *)outputStream
                                error:(NSError * __autoreleasing *)error
{
    NSParameterAssert(inputFileURL);
    NSParameterAssert(name);
    NSParameterAssert(fileName);
    NSParameterAssert(mimeType);
    
    if (![inputFileURL isFileURL]) {
        NSDictionary *userInfo = @{NSLocalizedFailureReasonErrorKey: NSLocalizedStringFromTable(@"Expected URL to be a file URL", @"AFNetworking", nil)};
        if (error) {
            *error = [[NSError alloc] initWithDomain:AFURLRequestSerializationErrorDomain code:NSURLErrorBadURL userInfo:userInfo];
        }
        return NO;
    } else if ([inputFileURL checkResourceIsReachableAndReturnError:error] == NO) {
        NSDictionary *userInfo = @{NSLocalizedFailureReasonErrorKey: NSLocalizedStringFromTable(@"File URL not reachable.", @"AFNetworking", nil)};
        if (error) {
            *error = [[NSError alloc] initWithDomain:AFURLRequestSerializationErrorDomain code:NSURLErrorBadURL userInfo:userInfo];
        }
        return NO;
    }
    
    NSDictionary *inputFileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[inputFileURL path] error:error];
    if (!inputFileAttributes) {
        return NO;
    }
    
    NSStringEncoding stringEncoding = self.stringEncoding;
    
    NSMutableDictionary *mutableHeaders = [NSMutableDictionary dictionary];
    [mutableHeaders setValue:[NSString stringWithFormat:@"form-data; name=\"%@\"; filename=\"%@\"", name, fileName] forKey:@"Content-Disposition"];
    [mutableHeaders setValue:mimeType forKey:@"Content-Type"];
    
    NSInputStream *inputStream = [NSInputStream inputStreamWithURL:inputFileURL];
    AFStreamDelegate *inputStreamDelegate = [AFStreamDelegate new];
    inputStream.delegate = inputStreamDelegate;
    [inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [inputStream open];
    if (inputStream.streamStatus != NSStreamStatusOpen) {
        NSDictionary *userInfo = @{NSLocalizedFailureReasonErrorKey: NSLocalizedStringFromTable(@"File URL not reachable.", @"AFNetworking", nil)};
        if (error) {
            *error = [[NSError alloc] initWithDomain:AFURLRequestSerializationErrorDomain code:NSURLErrorBadURL userInfo:userInfo];
        }
        return NO;
    }
    
    void (^closeInputStream)(void) = ^{
        [inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        [inputStream close];
    };

    NSData *encapsulationBoundaryData = [(hasInitialBoundary
                                          ? AFMultipartFormInitialBoundary(boundary)
                                          : AFMultipartFormEncapsulationBoundary(boundary)) dataUsingEncoding:stringEncoding];
    if (![self writeData:encapsulationBoundaryData outputStream:outputStream error:error]) {
        closeInputStream();
        return NO;
    }
    
    NSDictionary *headers = [self headersForBodyWithName:name
                                                fileName:fileName
                                                mimeType:mimeType];
    NSString *headersString = [self stringForHeaders:headers];
    NSData *headersData = [headersString dataUsingEncoding:stringEncoding];
    if (![self writeData:headersData outputStream:outputStream error:error]) {
        closeInputStream();
        return NO;
    }
    
    if (![self writeBodyInputStream:inputStream
                       outputStream:outputStream
                              error:error]) {
        closeInputStream();
        return NO;
    }
    
    NSData *closingBoundaryData = (hasFinalBoundary
                                   ? [AFMultipartFormFinalBoundary(boundary) dataUsingEncoding:stringEncoding]
                                   : [NSData data]);
    if (![self writeData:closingBoundaryData outputStream:outputStream error:error]) {
        closeInputStream();
        return NO;
    }
    
    closeInputStream();

    if (inputStreamDelegate.hadError) {
        if (error) {
            *error = [[NSError alloc] initWithDomain:AFURLRequestSerializationErrorDomain code:NSURLErrorBadURL userInfo:nil];
        }
        return NO;
    }

    return YES;
}

+ (BOOL)writeTextPartWithValue:(NSString *)value
                          name:(NSString *)name
                      boundary:(NSString *)boundary
            hasInitialBoundary:(BOOL)hasInitialBoundary
              hasFinalBoundary:(BOOL)hasFinalBoundary
                  outputStream:(NSOutputStream *)outputStream
                         error:(NSError * __autoreleasing *)error
{
    NSParameterAssert(value.length > 0);
    NSParameterAssert(name.length > 0);

    NSStringEncoding stringEncoding = self.stringEncoding;
    
    NSData *encapsulationBoundaryData = [(hasInitialBoundary
                                          ? AFMultipartFormInitialBoundary(boundary)
                                          : AFMultipartFormEncapsulationBoundary(boundary)) dataUsingEncoding:stringEncoding];
    if (![self writeData:encapsulationBoundaryData outputStream:outputStream error:error]) {
        return NO;
    }
    
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary new];
    [headers setValue:[NSString stringWithFormat:@"form-data; name=\"%@\"", name] forKey:@"Content-Disposition"];
    NSString *headersString = [self stringForHeaders:headers];
    NSData *headersData = [headersString dataUsingEncoding:stringEncoding];
    if (![self writeData:headersData outputStream:outputStream error:error]) {
        return NO;
    }

    NSData *valueData = [value dataUsingEncoding:stringEncoding];
    if (![self writeData:valueData outputStream:outputStream error:error]) {
        return NO;
    }
    
    NSData *closingBoundaryData = (hasFinalBoundary
                                   ? [AFMultipartFormFinalBoundary(boundary) dataUsingEncoding:stringEncoding]
                                   : [NSData data]);
    if (![self writeData:closingBoundaryData outputStream:outputStream error:error]) {
        return NO;
    }
    
    return YES;
}

+ (BOOL)writeBodyInputStream:(NSInputStream *)inputStream
                outputStream:(NSOutputStream *)outputStream
                       error:(NSError * __autoreleasing *)error
{
    NSInteger bufferSize = 16 * 1024;
    uint8_t buffer[bufferSize];
    
    NSInteger totalBytesReadCount = 0;
    while ([inputStream hasBytesAvailable]) {
        if (![outputStream hasSpaceAvailable]) {
            if (error) {
                *error = [[NSError alloc] initWithDomain:AFURLRequestSerializationErrorDomain code:NSURLErrorBadURL userInfo:nil];
            }
            return NO;
        }
        
        NSInteger numberOfBytesRead = [inputStream read:buffer maxLength:bufferSize];
        if (numberOfBytesRead < 0) {
            if (error) {
                *error = [[NSError alloc] initWithDomain:AFURLRequestSerializationErrorDomain code:NSURLErrorBadURL userInfo:nil];
            }
            return NO;
        }
        if (numberOfBytesRead == 0) {
            return YES;
        }
        totalBytesReadCount += numberOfBytesRead;
        
        NSInteger totalBytesWrittenCount = 0;
        while (totalBytesWrittenCount < numberOfBytesRead) {
            NSInteger writeSize = numberOfBytesRead - totalBytesWrittenCount;
            NSInteger bytesWrittenCount = [outputStream write:&buffer[totalBytesWrittenCount] maxLength:writeSize];
            if (bytesWrittenCount < 1) {
                *error = [[NSError alloc] initWithDomain:AFURLRequestSerializationErrorDomain code:NSURLErrorBadURL userInfo:nil];
                return NO;
            }
            totalBytesWrittenCount += bytesWrittenCount;
        }
    }
    return YES;
}

+ (BOOL)writeData:(NSData *)data
     outputStream:(NSOutputStream *)outputStream
            error:(NSError * __autoreleasing *)error
{
    NSInteger totalBytesCount = data.length;
    NSInteger bufferSize = 16 * 1024;
    uint8_t buffer[bufferSize];
    
    NSInteger totalBytesWrittenCount = 0;
    while (totalBytesWrittenCount < totalBytesCount) {
        NSInteger blockSize = MIN((totalBytesCount - totalBytesWrittenCount), bufferSize);
        NSRange range = NSMakeRange((NSUInteger)totalBytesWrittenCount, blockSize);
        [data getBytes:buffer range:range];
        NSInteger bytesWrittenCount = [outputStream write:buffer maxLength:blockSize];
        if (bytesWrittenCount < 1) {
            *error = [[NSError alloc] initWithDomain:AFURLRequestSerializationErrorDomain code:NSURLErrorBadURL userInfo:nil];
            return NO;
        }
        totalBytesWrittenCount += bytesWrittenCount;
    }
    return YES;
}

+ (NSDictionary *)headersForBodyWithName:(NSString *)name
                                fileName:(NSString *)fileName
                                mimeType:(NSString *)mimeType
{
    NSMutableDictionary *mutableHeaders = [NSMutableDictionary dictionary];
    [mutableHeaders setValue:[NSString stringWithFormat:@"form-data; name=\"%@\"; filename=\"%@\"", name, fileName] forKey:@"Content-Disposition"];
    [mutableHeaders setValue:mimeType forKey:@"Content-Type"];
    return mutableHeaders;
}

+ (NSString *)stringForHeaders:(NSDictionary *)headers {
    NSMutableString *headerString = [NSMutableString string];
    for (NSString *field in [headers allKeys]) {
        [headerString appendString:[NSString stringWithFormat:@"%@: %@%@",
                                    field,
                                    [headers valueForKey:field],
                                    kAFMultipartFormCRLF]];
    }
    [headerString appendString:kAFMultipartFormCRLF];
    return [NSString stringWithString:headerString];
}

@end
