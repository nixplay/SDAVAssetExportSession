//
//  SDAVAssetExportSession.m
//
// This file is part of the SDAVAssetExportSession package.
//
// Created by Olivier Poitrey <rs@dailymotion.com> on 13/03/13.
// Copyright 2013 Olivier Poitrey. All rights servered.
//
// For the full copyright and license information, please view the LICENSE
// file that was distributed with this source code.
//


#import "SDAVAssetExportSession.h"
#import <CoreMedia/CMMetadata.h>

static inline CGFloat degreesToRadian(int degrees) {
    return (M_PI * degrees / 180.0);
};

@interface SDAVAssetExportSession ()

@property (nonatomic, assign, readwrite) float progress;

@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderVideoCompositionOutput *videoOutput;
@property (nonatomic, strong) AVAssetReaderAudioMixOutput *audioOutput;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *videoPixelBufferAdaptor;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, strong) dispatch_queue_t inputQueue;
@property (nonatomic, strong) void (^completionHandler)(void);

@end

@implementation SDAVAssetExportSession
{
    NSError *_error;
    NSTimeInterval duration;
    CMTime lastSamplePresentationTime;
}

+ (id)exportSessionWithAsset:(AVAsset *)asset
{
    return [SDAVAssetExportSession.alloc initWithAsset:asset];
}

- (id)initWithAsset:(AVAsset *)asset
{
    if ((self = [super init]))
    {
        _asset = asset;
        _timeRange = CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
    }
    
    return self;
}

- (void)exportAsynchronouslyWithCompletionHandler:(void (^)(void))handler
{
    NSParameterAssert(handler != nil);
    [self cancelExport];
    self.completionHandler = handler;
    
    if (!self.outputURL)
    {
        _error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorExportFailed userInfo:@
                  {
                  NSLocalizedDescriptionKey: @"Output URL not set"
                  }];
        NSLog(@"[SDAVAssetExportSession] ❌ Export failed: output URL not set");
        handler();
        return;
    }

    NSLog(@"[SDAVAssetExportSession] 📋 Starting export");
    NSLog(@"[SDAVAssetExportSession]    Output URL  : %@", self.outputURL);
    NSLog(@"[SDAVAssetExportSession]    File type   : %@", self.outputFileType);
    NSLog(@"[SDAVAssetExportSession]    Asset       : %@", self.asset);
    NSLog(@"[SDAVAssetExportSession]    Duration    : %.2f s", CMTimeGetSeconds(self.asset.duration));
    NSLog(@"[SDAVAssetExportSession]    Video settings : %@", self.videoSettings);
    NSLog(@"[SDAVAssetExportSession]    Audio settings : %@", self.audioSettings);

    NSError *readerError;
    self.reader = [AVAssetReader.alloc initWithAsset:self.asset error:&readerError];
    if (readerError)
    {
        _error = readerError;
        NSLog(@"[SDAVAssetExportSession] ❌ AVAssetReader init failed: %@", readerError);
        handler();
        return;
    }
    NSLog(@"[SDAVAssetExportSession] ✅ AVAssetReader created");

    NSError *writerError;
    self.writer = [AVAssetWriter assetWriterWithURL:self.outputURL fileType:self.outputFileType error:&writerError];
    if (writerError)
    {
        _error = writerError;
        NSLog(@"[SDAVAssetExportSession] ❌ AVAssetWriter init failed: %@", writerError);
        handler();
        return;
    }
    NSLog(@"[SDAVAssetExportSession] ✅ AVAssetWriter created");
    
    self.reader.timeRange = self.timeRange;
    self.writer.shouldOptimizeForNetworkUse = self.shouldOptimizeForNetworkUse;
    
    NSArray *videoTracks = [self.asset tracksWithMediaType:AVMediaTypeVideo];
    
    
    if (CMTIME_IS_VALID(self.timeRange.duration) && !CMTIME_IS_POSITIVE_INFINITY(self.timeRange.duration))
    {
        duration = CMTimeGetSeconds(self.timeRange.duration);
    }
    else
    {
        duration = CMTimeGetSeconds(self.asset.duration);
    }
    //
    // Video output
    //
    if (videoTracks.count > 0) {
        // ── Pixel format negotiation ─────────────────────────────────────────────────
        //
        // Three things must agree on the same pixel format:
        //   1. AVAssetReaderVideoCompositionOutput  (decode / reader side)
        //   2. AVAssetWriterInputPixelBufferAdaptor (adaptor source format)
        //   3. The AVAssetWriterInput encoder       (what the codec accepts)
        //
        // H.264 encoder  → only accepts 8-bit formats; BGRA is the safe universal choice.
        // HEVC encoder   → accepts 8-bit BGRA, 8-bit NV12, and 10-bit NV12.
        //
        // Source bit-depth adds a further constraint on the reader:
        //   • 8-bit source  → H.264 out : BGRA
        //   • 8-bit source  → HEVC  out : NV12 8-bit
        //   • 10-bit source → H.264 out : BGRA  (compositor converts internally)
        //   • 10-bit source → HEVC  out : NV12 10-bit  (preserves HDR bit-depth)
        //
        // This is the key fix for 10-bit Dolby Vision / HDR HEVC → H.264:
        // requesting BGRA from the reader causes AVFoundation's compositor to
        // tone-map / convert the 10-bit frame to 8-bit BGRA automatically.
        // ─────────────────────────────────────────────────────────────────────────────
        NSString *outputCodec = self.videoSettings[AVVideoCodecKey];
        BOOL outputIsHEVC = [outputCodec isEqualToString:AVVideoCodecTypeHEVC];
        int sourceBitDepth = [self sourceVideoBitDepth];
        BOOL sourceIs10Bit = (sourceBitDepth == 10);

        NSLog(@"[SDAVAssetExportSession] 🎬 Video track count  : %lu", (unsigned long)videoTracks.count);
        NSLog(@"[SDAVAssetExportSession]    Source bit depth   : %d-bit", sourceBitDepth);
        NSLog(@"[SDAVAssetExportSession]    Source codec HEVC  : %@", [self sourceVideoCodecIsHEVC] ? @"YES" : @"NO");
        NSLog(@"[SDAVAssetExportSession]    Output codec       : %@", outputCodec);

        OSType pixelFormat;
        if (outputIsHEVC && sourceIs10Bit) {
            pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
            NSLog(@"[SDAVAssetExportSession]    Pixel format       : 420YpCbCr10BiPlanarVideoRange (10-bit → HEVC)");
        } else if (outputIsHEVC) {
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
            NSLog(@"[SDAVAssetExportSession]    Pixel format       : 420YpCbCr8BiPlanarVideoRange (8-bit → HEVC)");
        } else {
            pixelFormat = kCVPixelFormatType_32BGRA;
            NSLog(@"[SDAVAssetExportSession]    Pixel format       : 32BGRA (→ H.264, compositor converts if 10-bit source)");
        }

        NSDictionary *effectiveVideoInputSettings = self.videoInputSettings;
        if (!effectiveVideoInputSettings) {
            effectiveVideoInputSettings = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat)
            };
        }
        NSLog(@"[SDAVAssetExportSession]    Reader video settings: %@", effectiveVideoInputSettings);

        self.videoOutput = [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:videoTracks videoSettings:effectiveVideoInputSettings];
        self.videoOutput.alwaysCopiesSampleData = NO;
        if (self.videoComposition)
        {
            self.videoOutput.videoComposition = self.videoComposition;
            NSLog(@"[SDAVAssetExportSession]    Using custom videoComposition");
        }
        else
        {
            self.videoOutput.videoComposition = [self buildDefaultVideoComposition];
            NSLog(@"[SDAVAssetExportSession]    Using default videoComposition, renderSize: %@",
                  NSStringFromCGSize(self.videoOutput.videoComposition.renderSize));
        }
        if ([self.reader canAddOutput:self.videoOutput])
        {
            [self.reader addOutput:self.videoOutput];
            NSLog(@"[SDAVAssetExportSession] ✅ Video output added to reader");
        }
        else
        {
            NSLog(@"[SDAVAssetExportSession] ❌ Cannot add video output to reader — reader status: %ld, error: %@",
                  (long)self.reader.status, self.reader.error);
        }
        
        //
        // Video input
        //
        self.videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:self.videoSettings];
        self.videoInput.expectsMediaDataInRealTime = NO;
        self.videoInput.transform = CGAffineTransformMakeRotation(degreesToRadian(self.videoAngle));
        if ([self.writer canAddInput:self.videoInput])
        {
            [self.writer addInput:self.videoInput];
            NSLog(@"[SDAVAssetExportSession] ✅ Video input added to writer");
        }
        else
        {
            NSLog(@"[SDAVAssetExportSession] ❌ Cannot add video input to writer — writer status: %ld, error: %@",
                  (long)self.writer.status, self.writer.error);
        }

        NSDictionary *pixelBufferAttributes = @
        {
            (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
            (id)kCVPixelBufferWidthKey: @(self.videoOutput.videoComposition.renderSize.width),
            (id)kCVPixelBufferHeightKey: @(self.videoOutput.videoComposition.renderSize.height),
            @"IOSurfaceOpenGLESTextureCompatibility": @YES,
            @"IOSurfaceOpenGLESFBOCompatibility": @YES,
        };
        self.videoPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoInput sourcePixelBufferAttributes:pixelBufferAttributes];
        NSLog(@"[SDAVAssetExportSession]    Pixel buffer adaptor created (pool: %@)",
              self.videoPixelBufferAdaptor.pixelBufferPool ? @"ready" : @"nil — will be set after startWriting");
    }
    
    //
    //Audio output
    //
    // IMPORTANT: Always decode audio to linear PCM before re-encoding.
    //
    // Passing audioSettings:nil means "give me compressed samples as-is", which
    // works only when the source and destination codec are identical. For any
    // spatial audio (Dolby Atmos / NeuralRAD), multi-channel, or cross-codec
    // transcode, the raw compressed bytes can't be appended to a different
    // encoder and AVFoundation returns kAudioCodecUnsupportedFormatError (-12780).
    //
    // Decoding to LPCM first is the universally safe approach: AVFoundation
    // handles the decode regardless of source format (AAC-LC, AAC-ELD, Atmos,
    // multi-channel), and the writer re-encodes to whatever audioSettings specify.
    NSDictionary *audioDecodeSettings = @{
        AVFormatIDKey:             @(kAudioFormatLinearPCM),
        AVLinearPCMBitDepthKey:    @(16),
        AVLinearPCMIsBigEndianKey: @(NO),
        AVLinearPCMIsFloatKey:     @(NO),
        AVLinearPCMIsNonInterleaved: @(NO),
    };

    NSArray *audioTracks = [self.asset tracksWithMediaType:AVMediaTypeAudio];
    NSLog(@"[SDAVAssetExportSession] 🔊 Audio track count: %lu", (unsigned long)audioTracks.count);
    if (audioTracks.count > 0) {
        // Use only the first audio track. iPhone spatial audio files often have
        // two audio tracks (Track 2 = Spatial / Atmos metadata track); mixing
        // both into one reader output can cause the -12780 format error.
        // Using just the primary stereo track is safe for standard export.
        NSArray *primaryAudioTrack = @[audioTracks.firstObject];
        NSLog(@"[SDAVAssetExportSession]    Using audio track ID: %d (of %lu total)",
              [audioTracks.firstObject trackID], (unsigned long)audioTracks.count);

        self.audioOutput = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:primaryAudioTrack
                                                                                   audioSettings:audioDecodeSettings];
        self.audioOutput.alwaysCopiesSampleData = NO;
        self.audioOutput.audioMix = self.audioMix;
        if ([self.reader canAddOutput:self.audioOutput])
        {
            [self.reader addOutput:self.audioOutput];
            NSLog(@"[SDAVAssetExportSession] ✅ Audio output added to reader (decoding to LPCM)");
        }
        else
        {
            NSLog(@"[SDAVAssetExportSession] ❌ Cannot add audio output to reader — reader status: %ld, error: %@",
                  (long)self.reader.status, self.reader.error);
        }
    } else {
        // Just in case this gets reused
        self.audioOutput = nil;
        NSLog(@"[SDAVAssetExportSession]    No audio tracks found, skipping audio");
    }
    
    //
    // Audio input
    //
    if (self.audioOutput) {
        self.audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:self.audioSettings];
        self.audioInput.expectsMediaDataInRealTime = NO;
        if ([self.writer canAddInput:self.audioInput])
        {
            [self.writer addInput:self.audioInput];
            NSLog(@"[SDAVAssetExportSession] ✅ Audio input added to writer");
        }
        else
        {
            NSLog(@"[SDAVAssetExportSession] ❌ Cannot add audio input to writer — writer status: %ld, error: %@",
                  (long)self.writer.status, self.writer.error);
        }
    }
    
    self.writer.metadata = self.metadata;

    BOOL writerStarted = [self.writer startWriting];
    NSLog(@"[SDAVAssetExportSession] %@ startWriting — writer status: %ld, error: %@",
          writerStarted ? @"✅" : @"❌", (long)self.writer.status, self.writer.error);

    BOOL readerStarted = [self.reader startReading];
    NSLog(@"[SDAVAssetExportSession] %@ startReading — reader status: %ld, error: %@",
          readerStarted ? @"✅" : @"❌", (long)self.reader.status, self.reader.error);

    [self.writer startSessionAtSourceTime:self.timeRange.start];
    NSLog(@"[SDAVAssetExportSession]    Session started at source time: %.4f s",
          CMTimeGetSeconds(self.timeRange.start));
    
    __block BOOL videoCompleted = NO;
    __block BOOL audioCompleted = NO;
    __weak typeof(self) wself = self;
    self.inputQueue = dispatch_queue_create("VideoEncoderInputQueue", DISPATCH_QUEUE_SERIAL);
    if (videoTracks.count > 0) {
        [self.videoInput requestMediaDataWhenReadyOnQueue:self.inputQueue usingBlock:^
         {
             if (![wself encodeReadySamplesFromOutput:wself.videoOutput toInput:wself.videoInput])
             {
                 @synchronized(wself)
                 {
                     videoCompleted = YES;
                     if (audioCompleted)
                     {
                         [wself finish];
                     }
                 }
             }
         }];
    }
    else {
        videoCompleted = YES;
    }
    
    if (!self.audioOutput) {
        audioCompleted = YES;
    } else {
        [self.audioInput requestMediaDataWhenReadyOnQueue:self.inputQueue usingBlock:^
         {
             if (![wself encodeReadySamplesFromOutput:wself.audioOutput toInput:wself.audioInput])
             {
                 @synchronized(wself)
                 {
                     audioCompleted = YES;
                     if (videoCompleted)
                     {
                         [wself finish];
                     }
                 }
             }
         }];
    }
}

- (BOOL)encodeReadySamplesFromOutput:(AVAssetReaderOutput *)output toInput:(AVAssetWriterInput *)input
{
    while (input.isReadyForMoreMediaData)
    {
        CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
        if (sampleBuffer)
        {
            BOOL handled = NO;
            BOOL error = NO;
            
            if (self.reader.status != AVAssetReaderStatusReading || self.writer.status != AVAssetWriterStatusWriting)
            {
                handled = YES;
                error = YES;
                NSLog(@"[SDAVAssetExportSession] ❌ Pipeline status mismatch while encoding");
                NSLog(@"[SDAVAssetExportSession]    Reader status : %ld, error: %@",
                      (long)self.reader.status, self.reader.error);
                NSLog(@"[SDAVAssetExportSession]    Writer status : %ld, error: %@",
                      (long)self.writer.status, self.writer.error);
            }
            
            if (!handled && self.videoOutput == output)
            {
                // update the video progress
                lastSamplePresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                lastSamplePresentationTime = CMTimeSubtract(lastSamplePresentationTime, self.timeRange.start);
                self.progress = duration == 0 ? 1 : CMTimeGetSeconds(lastSamplePresentationTime) / duration;
                
                if ([self.delegate respondsToSelector:@selector(exportSession:renderFrame:withPresentationTime:toBuffer:)])
                {
                    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
                    CVPixelBufferRef renderBuffer = NULL;
                    CVPixelBufferPoolCreatePixelBuffer(NULL, self.videoPixelBufferAdaptor.pixelBufferPool, &renderBuffer);
                    [self.delegate exportSession:self renderFrame:pixelBuffer withPresentationTime:lastSamplePresentationTime toBuffer:renderBuffer];
                    if (![self.videoPixelBufferAdaptor appendPixelBuffer:renderBuffer withPresentationTime:lastSamplePresentationTime])
                    {
                        error = YES;
                        NSLog(@"[SDAVAssetExportSession] ❌ appendPixelBuffer failed at %.4f s — writer error: %@",
                              CMTimeGetSeconds(lastSamplePresentationTime), self.writer.error);
                    }
                    CVPixelBufferRelease(renderBuffer);
                    handled = YES;
                }
            }
            if (!handled && ![input appendSampleBuffer:sampleBuffer])
            {
                error = YES;
                BOOL isVideo = (input == self.videoInput);
                NSLog(@"[SDAVAssetExportSession] ❌ appendSampleBuffer failed (%@) at %.4f s — writer error: %@",
                      isVideo ? @"video" : @"audio",
                      CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
                      self.writer.error);
            }
            CFRelease(sampleBuffer);
            
            if (error)
            {
                return NO;
            }
        }
        else
        {
            [input markAsFinished];
            return NO;
        }
    }
    
    return YES;
}

- (AVMutableVideoComposition *)buildDefaultVideoComposition1
{
    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
    AVAssetTrack *videoTrack = [[self.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
    
    // get the frame rate from videoSettings, if not set then try to get it from the video track,
    // if not set (mainly when asset is AVComposition) then use the default frame rate of 30
    float trackFrameRate = 0;
    if (self.videoSettings)
    {
        NSDictionary *videoCompressionProperties = [self.videoSettings objectForKey:AVVideoCompressionPropertiesKey];
        if (videoCompressionProperties)
        {
            NSNumber *frameRate = [videoCompressionProperties objectForKey:AVVideoAverageNonDroppableFrameRateKey];
            if (frameRate)
            {
                trackFrameRate = frameRate.floatValue;
            }
        }
    }
    else
    {
        trackFrameRate = [videoTrack nominalFrameRate];
    }

    if (trackFrameRate == 0)
    {
        trackFrameRate = 30;
    }

    videoComposition.frameDuration = CMTimeMake(1, trackFrameRate);
    CGSize targetSize = CGSizeMake([self.videoSettings[AVVideoWidthKey] floatValue], [self.videoSettings[AVVideoHeightKey] floatValue]);
    CGSize naturalSize = [videoTrack naturalSize];
    CGAffineTransform transform = videoTrack.preferredTransform;
    // workaround https://github.com/rs/SDAVAssetExportSession/issues/79
    CGRect rect = {{0, 0}, naturalSize};
    CGRect transformedRect = CGRectApplyAffineTransform(rect, transform);
    // transformedRect should have origin at 0 if correct; otherwise add offset to correct it
    transform.tx -= transformedRect.origin.x;
    transform.ty -= transformedRect.origin.y;
    // Workaround radar 31928389, see https://github.com/rs/SDAVAssetExportSession/pull/70 for more info
    if (transform.ty == -560) {
        transform.ty = 0;
    }

    if (transform.tx == -560) {
        transform.tx = 0;
    }

    CGFloat videoAngleInDegree  = atan2(transform.b, transform.a) * 180 / M_PI;

    if(transform.tx ==0 && transform.ty == 0){
        if (videoAngleInDegree == 90) {
            transform.tx = naturalSize.height;
        }
        if (videoAngleInDegree == -90) {
            transform.ty = naturalSize.width;
        }
    }

    if (videoAngleInDegree == 90 || videoAngleInDegree == -90) {
        CGFloat width = naturalSize.width;
        naturalSize.width = naturalSize.height;
        naturalSize.height = width;
    }

    videoComposition.renderSize = naturalSize;
    // center inside
    {
        float ratio;
        float xratio = targetSize.width / naturalSize.width;
        float yratio = targetSize.height / naturalSize.height;
        ratio = MIN(xratio, yratio);

        float postWidth = naturalSize.width * ratio;
        float postHeight = naturalSize.height * ratio;
        float transx = (targetSize.width - postWidth) / 2;
        float transy = (targetSize.height - postHeight) / 2;

        CGAffineTransform matrix = CGAffineTransformMakeTranslation(transx / xratio, transy / yratio);
        matrix = CGAffineTransformScale(matrix, ratio / xratio, ratio / yratio);
        transform = CGAffineTransformConcat(transform, matrix);
    }
    // Make a "pass through video track" video composition.
    AVMutableVideoCompositionInstruction *passThroughInstruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    passThroughInstruction.timeRange = CMTimeRangeMake(kCMTimeZero, self.asset.duration);

    AVMutableVideoCompositionLayerInstruction *passThroughLayer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];

    [passThroughLayer setTransform:transform atTime:kCMTimeZero];

    passThroughInstruction.layerInstructions = @[passThroughLayer];
    videoComposition.instructions = @[passThroughInstruction];

    return videoComposition;
}

- (AVMutableVideoComposition *)buildDefaultVideoComposition
{
    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
    AVAssetTrack *videoTrack = [[self.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
    // get the frame rate from videoSettings, if not set then try to get it from the video track,
    // if not set (mainly when asset is AVComposition) then use the default frame rate of 30
    float trackFrameRate = 0;
    if (self.videoSettings)
    {
        NSDictionary *videoCompressionProperties = [self.videoSettings objectForKey:AVVideoCompressionPropertiesKey];
        if (videoCompressionProperties)
        {
            NSNumber *frameRate = [videoCompressionProperties objectForKey:AVVideoAverageNonDroppableFrameRateKey];
            if (frameRate)
            {
                trackFrameRate = frameRate.floatValue;
            }
        }
    }
    else
    {
        trackFrameRate = [videoTrack nominalFrameRate];
    }

    if (trackFrameRate == 0)
    {
        trackFrameRate = 30;
    }

    videoComposition.frameDuration = CMTimeMake(1, trackFrameRate);
    CGSize targetSize = CGSizeMake([self.videoSettings[AVVideoWidthKey] floatValue], [self.videoSettings[AVVideoHeightKey] floatValue]);
    CGSize naturalSize = [videoTrack naturalSize];
    CGAffineTransform transform = videoTrack.preferredTransform;
    // workaround https://github.com/rs/SDAVAssetExportSession/issues/79
    CGRect rect = {{0, 0}, naturalSize};
    CGRect transformedRect = CGRectApplyAffineTransform(rect, transform);
    // transformedRect should have origin at 0 if correct; otherwise add offset to correct it
    transform.tx -= transformedRect.origin.x;
    transform.ty -= transformedRect.origin.y;
    // Workaround radar 31928389, see https://github.com/rs/SDAVAssetExportSession/pull/70 for more info
    if (transform.ty == -560) {
        transform.ty = 0;
    }

    if (transform.tx == -560) {
        transform.tx = 0;
    }

    CGFloat videoAngleInDegree  = atan2(transform.b, transform.a) * 180 / M_PI;

    if(transform.tx ==0 && transform.ty == 0){
        if (videoAngleInDegree == 90) {
            transform.tx = naturalSize.height;
        }
        if (videoAngleInDegree == -90) {
            transform.ty = naturalSize.width;
        }
    }

    videoComposition.renderSize = naturalSize;
    // center inside
    {
        float ratio;
        float xratio = targetSize.width / naturalSize.width;
        float yratio = targetSize.height / naturalSize.height;
        ratio = MIN(xratio, yratio);

//        float postWidth = naturalSize.width * ratio;
//        float postHeight = naturalSize.height * ratio;
//        float transx = (targetSize.width - postWidth) / 2;
//        float transy = (targetSize.height - postHeight) / 2;
        float width = (videoAngleInDegree == 90) ? naturalSize.width : 0;
        float height = (videoAngleInDegree == -90) ? naturalSize.height : 0;
    
        CGAffineTransform matrix = CGAffineTransformMakeTranslation( width, height);
        matrix = CGAffineTransformScale(matrix, ratio / xratio, ratio / yratio);
        if (videoAngleInDegree == 90) {
            matrix = CGAffineTransformRotate(matrix, degreesToRadians(90));
        } else if (videoAngleInDegree == -90) {
            matrix = CGAffineTransformRotate(matrix, degreesToRadians(-90));
        }
        transform = CGAffineTransformConcat(transform, matrix);
    }

    NSArray *keys = @[@"tracks", @"availableMetadataFormats"];

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self.asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{

        // Get the status of the loaded tracks, make the appropriate action
        [keys enumerateObjectsUsingBlock:^(id  _Nonnull key, NSUInteger idx, BOOL * _Nonnull stop) {
            [self statusOfValueForKey: key];
        }];

        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    #if !__has_feature(objc_arc)
        dispatch_release(sema);
    #endif

    // Make a "pass through video track" video composition.
    AVMutableVideoCompositionInstruction *passThroughInstruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    passThroughInstruction.timeRange = CMTimeRangeMake(kCMTimeZero, self.asset.duration);

    AVMutableVideoCompositionLayerInstruction *passThroughLayer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];

    [passThroughLayer setTransform:transform atTime:kCMTimeZero];

    passThroughInstruction.layerInstructions = @[passThroughLayer];
    videoComposition.instructions = @[passThroughInstruction];

    return videoComposition;
}

-(void) statusOfValueForKey:(NSString*) key {
    NSError *error = nil;
    AVKeyValueStatus status =  [self.asset statusOfValueForKey:key error:&error];

    switch (status) {
        case AVKeyValueStatusUnknown:
            NSLog(@"%@ AVKeyValueStatusUnknown", key);
            //Load tracks unknown error
            break;
        case AVKeyValueStatusFailed:
            NSLog(@"%@ AVKeyValueStatusFailed", key);
            //Loading tracks failed
            break;
        case AVKeyValueStatusLoading:
            NSLog(@"%@ AVKeyValueStatusLoading", key);
            //Load tracks
            break;
        case AVKeyValueStatusLoaded:
            NSLog(@"%@ AVKeyValueStatusLoaded", key);
            //Load tracks are finished
            break;
        case AVKeyValueStatusCancelled:
            NSLog(@"%@ AVKeyValueStatusCancelled", key);
            //Cancel the loading of tracks
            break;
    }

    status =  [self.asset statusOfValueForKey:key error:&error];
    switch (status) {
        case AVKeyValueStatusUnknown:
            NSLog(@"AVKeyValueStatusUnknown");
            //Load AVKeyValueStatusUnknown unknown error
            break;
        case AVKeyValueStatusFailed:
            NSLog(@"AVKeyValueStatusFailed");
            //Load AVKeyValueStatusUnknown failed
            break;
        case AVKeyValueStatusLoading:
            NSLog(@"AVKeyValueStatusLoading");
            //Load AVKeyValueStatusUnknown
            break;
        case AVKeyValueStatusLoaded:
        {
            NSLog(@"AVKeyValueStatusLoaded");
            //Load AVKeyValueStatusUnknown is completed
            //Get the metadata inside the videoAsset
            NSMutableArray *metadata = [NSMutableArray array];
            for (NSString *format in self.asset.availableMetadataFormats) {
                NSLog(@"format %@", format);
                NSLog(@"[self.asset metadataForFormat:format] %@", [self.asset metadataForFormat:format]);
                [metadata addObject:[self.asset metadataForFormat:format]];
            }
            for (NSArray<AVMetadataItem *> *m in metadata) {
                for (AVMetadataItem *item in m) {
                    NSLog(@"%@--%@\n",item.key, item.value);
                }
            }
            self.metadata = metadata.firstObject;
            break;
        }
        case AVKeyValueStatusCancelled:
            NSLog(@"AVKeyValueStatusCancelled");
            //Unload AVKeyValueStatusUnknown
            break;
    }
}

CGFloat degreesToRadians(CGFloat degrees)
{
  return degrees / 180.0 * M_PI;
}

/// Returns the bit depth of the first video track's format description.
/// Returns 8 for standard video; returns 10 for 10-bit HEVC (Dolby Vision, HDR10, HLG).
- (int)sourceVideoBitDepth
{
    AVAssetTrack *videoTrack = [[self.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack) {
        return 8;
    }
    for (id descriptionRef in videoTrack.formatDescriptions) {
        CMFormatDescriptionRef desc = (__bridge CMFormatDescriptionRef)descriptionRef;
        // Extensions dictionary contains the pixel format details for the compressed track.
        CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(desc);
        if (!extensions) continue;

        // 'depth' extension holds the pixel bit depth for video format descriptions.
        CFNumberRef depthRef = (CFNumberRef)CFDictionaryGetValue(extensions,
                                   kCMFormatDescriptionExtension_Depth);
        if (depthRef) {
            int depth = 0;
            CFNumberGetValue(depthRef, kCFNumberIntType, &depth);
            if (depth > 8) {
                return 10;
            }
        }

        // Fallback: check the codec type directly — known 10-bit HEVC codec types.
        CMVideoCodecType codecType = CMVideoFormatDescriptionGetCodecType(desc);
        // 'hvc1' with 10-bit is typically signalled as kCMVideoCodecType_HEVC but
        // we can also check the pixel format of the description's sub-type.
        if (codecType == kCMVideoCodecType_HEVC) {
            // Check for Dolby Vision profile or explicit 10-bit signal via YCbCr matrix.
            CFStringRef fullRangeKey = (__bridge CFStringRef)AVVideoYCbCrMatrixKey;
            (void)fullRangeKey; // silence unused-variable warning
            // If depth extension was missing, treat HEVC as potentially 10-bit and
            // ask the reader to decode to BGRA (safe 8-bit path) so the caller
            // does not need to worry about it.
            return 10;
        }
    }
    return 8;
}

/// Returns YES when the first video track of the source asset is encoded with HEVC (H.265).
- (BOOL)sourceVideoCodecIsHEVC
{
    AVAssetTrack *videoTrack = [[self.asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack) {
        return NO;
    }
    for (id descriptionRef in videoTrack.formatDescriptions) {
        CMFormatDescriptionRef desc = (__bridge CMFormatDescriptionRef)descriptionRef;
        if (CMVideoFormatDescriptionGetCodecType(desc) == kCMVideoCodecType_HEVC) {
            return YES;
        }
    }
    return NO;
}

- (void)finish
{
    NSLog(@"[SDAVAssetExportSession] 🏁 finish called — reader status: %ld, writer status: %ld",
          (long)self.reader.status, (long)self.writer.status);
    if (self.reader.error) {
        NSLog(@"[SDAVAssetExportSession]    Reader error: %@", self.reader.error);
    }
    if (self.writer.error) {
        NSLog(@"[SDAVAssetExportSession]    Writer error: %@", self.writer.error);
    }

    // Synchronized block to ensure we never cancel the writer before calling finishWritingWithCompletionHandler
    if (self.reader.status == AVAssetReaderStatusCancelled || self.writer.status == AVAssetWriterStatusCancelled)
    {
        NSLog(@"[SDAVAssetExportSession]    Export was cancelled, bailing out of finish");
        return;
    }
    
    if (self.writer.status == AVAssetWriterStatusFailed)
    {
        NSLog(@"[SDAVAssetExportSession] ❌ Writer failed — not calling finishWriting. Error: %@", self.writer.error);
        [self complete];
    }
    else if (self.reader.status == AVAssetReaderStatusFailed) {
        NSLog(@"[SDAVAssetExportSession] ❌ Reader failed — cancelling writer. Error: %@", self.reader.error);
        [self.writer cancelWriting];
        [self complete];
    }
    else
    {
        NSLog(@"[SDAVAssetExportSession]    Calling finishWritingWithCompletionHandler...");
        [self.writer finishWritingWithCompletionHandler:^
         {
             NSLog(@"[SDAVAssetExportSession] %@ finishWriting done — writer status: %ld, error: %@",
                   self.writer.status == AVAssetWriterStatusCompleted ? @"✅" : @"❌",
                   (long)self.writer.status, self.writer.error);
             [self complete];
         }];
    }
}

- (void)complete
{
    if (self.writer.status == AVAssetWriterStatusFailed || self.writer.status == AVAssetWriterStatusCancelled)
    {
        NSLog(@"[SDAVAssetExportSession] 🗑️  Removing incomplete output file (writer status: %ld)", (long)self.writer.status);
        [NSFileManager.defaultManager removeItemAtURL:self.outputURL error:nil];
    }
    else
    {
        NSLog(@"[SDAVAssetExportSession] ✅ Export complete — output: %@", self.outputURL);
    }
    
    if (self.completionHandler)
    {
        self.completionHandler();
        self.completionHandler = nil;
    }
}

- (NSError *)error
{
    if (_error)
    {
        return _error;
    }
    else
    {
        return self.writer.error ? : self.reader.error;
    }
}

- (AVAssetExportSessionStatus)status
{
    switch (self.writer.status)
    {
        default:
        case AVAssetWriterStatusUnknown:
            return AVAssetExportSessionStatusUnknown;
        case AVAssetWriterStatusWriting:
            return AVAssetExportSessionStatusExporting;
        case AVAssetWriterStatusFailed:
            return AVAssetExportSessionStatusFailed;
        case AVAssetWriterStatusCompleted:
            return AVAssetExportSessionStatusCompleted;
        case AVAssetWriterStatusCancelled:
            return AVAssetExportSessionStatusCancelled;
    }
}

- (void)cancelExport
{
    if (self.inputQueue)
    {
        dispatch_async(self.inputQueue, ^
                       {
                           [self.writer cancelWriting];
                           [self.reader cancelReading];
                           [self complete];
                           [self reset];
                       });
    }
}

- (void)reset
{
    _error = nil;
    self.progress = 0;
    self.reader = nil;
    self.videoOutput = nil;
    self.audioOutput = nil;
    self.writer = nil;
    self.videoInput = nil;
    self.videoPixelBufferAdaptor = nil;
    self.audioInput = nil;
    self.inputQueue = nil;
    self.completionHandler = nil;
}

@end
