// ==============================================================================
//  SiriAIOverhaul — Tweak.x  (versione corretta)
//  Logos / Objective-C
//
//  Gruppi hook:
//    %group SpringBoard  → Glow-border UI + ricezione notifiche Darwin
//    %group AssistantD   → Intercettazione Hey Siri in assistantd
// ==============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>

// ── Costanti ───────────────────────────────────────────────────────────────────
static NSString *const kPrefsDomain      = @"com.tuonome.siriaioverhaul";
static NSString *const kPrefsPath        =
    @"/var/jb/var/mobile/Library/Preferences/com.tuonome.siriaioverhaul.plist";
static NSString *const kHerySiriDidStart = @"com.tuonome.siriaioverhaul.heySiriStart";
static NSString *const kHerySiriDidStop  = @"com.tuonome.siriaioverhaul.heySiriStop";

static const CGFloat       kBorderWidth  = 6.0f;
static const CFTimeInterval kGlowDuration = 2.8;

// ==============================================================================
#pragma mark - Preferenze
// ==============================================================================

typedef NS_ENUM(NSInteger, SAOAIProvider) {
    SAOAIProviderChatGPT = 0,
    SAOAIProviderGemini  = 1,
};

static NSDictionary *_SAOLoadPrefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: @{};
}
static NSString   *SAOAPIKey(void)    { return _SAOLoadPrefs()[@"apiKey"] ?: @""; }
static SAOAIProvider SAOProvider(void){ return (SAOAIProvider)[_SAOLoadPrefs()[@"aiProvider"] integerValue]; }
static BOOL        SAOIsEnabled(void) { return [_SAOLoadPrefs()[@"enabled"] boolValue]; }
static BOOL        SAOGlowEnabled(void){ NSNumber *v = _SAOLoadPrefs()[@"glowEnabled"]; return v ? v.boolValue : YES; }

// ==============================================================================
#pragma mark - SAOGlowBorderView
// ==============================================================================

@interface SAOGlowBorderView : UIView
- (void)startGlow;
- (void)stopGlow;
@end

@implementation SAOGlowBorderView {
    CAShapeLayer *_topLayer;
    CAShapeLayer *_bottomLayer;
    CAShapeLayer *_leftLayer;
    CAShapeLayer *_rightLayer;
    BOOL          _isGlowing;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor        = [UIColor clearColor];
    _topLayer    = [self _layerForEdge:UIRectEdgeTop    bounds:frame];
    _bottomLayer = [self _layerForEdge:UIRectEdgeBottom bounds:frame];
    _leftLayer   = [self _layerForEdge:UIRectEdgeLeft   bounds:frame];
    _rightLayer  = [self _layerForEdge:UIRectEdgeRight  bounds:frame];
    [self.layer addSublayer:_topLayer];
    [self.layer addSublayer:_bottomLayer];
    [self.layer addSublayer:_leftLayer];
    [self.layer addSublayer:_rightLayer];
    return self;
}

- (CAShapeLayer *)_layerForEdge:(UIRectEdge)edge bounds:(CGRect)b {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor  = nil;
    l.lineWidth  = kBorderWidth;
    l.opacity    = 0.0f;
    CGFloat w = b.size.width, h = b.size.height, hw = kBorderWidth / 2.0f;
    UIBezierPath *p = [UIBezierPath bezierPath];
    switch (edge) {
        case UIRectEdgeTop:
            [p moveToPoint:CGPointMake(0,hw)]; [p addLineToPoint:CGPointMake(w,hw)]; break;
        case UIRectEdgeBottom:
            [p moveToPoint:CGPointMake(0,h-hw)]; [p addLineToPoint:CGPointMake(w,h-hw)]; break;
        case UIRectEdgeLeft:
            [p moveToPoint:CGPointMake(hw,0)]; [p addLineToPoint:CGPointMake(hw,h)]; break;
        case UIRectEdgeRight:
            [p moveToPoint:CGPointMake(w-hw,0)]; [p addLineToPoint:CGPointMake(w-hw,h)]; break;
        default: break;
    }
    l.path = p.CGPath;
    return l;
}

- (void)startGlow {
    if (_isGlowing || !SAOGlowEnabled()) return;
    _isGlowing = YES;

    NSArray *colors = @[
        (__bridge id)[UIColor colorWithRed:0.40 green:0.60 blue:1.00 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.70 green:0.40 blue:1.00 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:1.00 green:0.45 blue:0.70 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.40 green:0.85 blue:0.75 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.40 green:0.60 blue:1.00 alpha:1.0].CGColor,
    ];
    NSArray *keyTimes = @[@0.0, @0.25, @0.50, @0.75, @1.0];
    NSArray *layers   = @[_topLayer, _bottomLayer, _leftLayer, _rightLayer];
    NSArray *offsets  = @[@0.0, @0.5, @0.25, @0.75];

    for (NSUInteger i = 0; i < layers.count; i++) {
        CAShapeLayer *layer  = layers[i];
        double        offset = [offsets[i] doubleValue];

        CAKeyframeAnimation *colorAnim   = [CAKeyframeAnimation animationWithKeyPath:@"strokeColor"];
        colorAnim.values                 = colors;
        colorAnim.keyTimes               = keyTimes;
        colorAnim.duration               = kGlowDuration;
        colorAnim.repeatCount            = HUGE_VALF;
        colorAnim.calculationMode        = kCAAnimationLinear;
        colorAnim.fillMode               = kCAFillModeForwards;
        colorAnim.removedOnCompletion    = NO;
        colorAnim.timeOffset             = offset * kGlowDuration;

        CAKeyframeAnimation *opacityAnim = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        opacityAnim.values               = @[@0.6, @1.0, @0.6];
        opacityAnim.keyTimes             = @[@0.0, @0.5, @1.0];
        opacityAnim.duration             = kGlowDuration * 1.5;
        opacityAnim.repeatCount          = HUGE_VALF;
        opacityAnim.calculationMode      = kCAAnimationLinear;
        opacityAnim.fillMode             = kCAFillModeForwards;
        opacityAnim.removedOnCompletion  = NO;

        CAAnimationGroup *grp            = [CAAnimationGroup animation];
        grp.animations                   = @[colorAnim, opacityAnim];
        grp.duration                     = kGlowDuration * 1.5;
        grp.repeatCount                  = HUGE_VALF;
        grp.fillMode                     = kCAFillModeForwards;
        grp.removedOnCompletion          = NO;

        [layer addAnimation:grp forKey:@"saoGlow"];
        layer.opacity = 0.8f;
    }
}

- (void)stopGlow {
    if (!_isGlowing) return;
    _isGlowing = NO;
    NSArray *layers = @[_topLayer, _bottomLayer, _leftLayer, _rightLayer];
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.4];
    [CATransaction setCompletionBlock:^{
        for (CAShapeLayer *l in layers) {
            [l removeAnimationForKey:@"saoGlow"];
            l.opacity = 0.0f;
        }
    }];
    for (CAShapeLayer *l in layers) l.opacity = 0.0f;
    [CATransaction commit];
}

@end


// ==============================================================================
#pragma mark - SAOAIEngine
// ==============================================================================

@interface SAOAIEngine : NSObject <SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate>
+ (instancetype)shared;
- (void)beginListeningWithCompletion:(void(^)(void))done;
- (void)cancelAll;
@end

@implementation SAOAIEngine {
    SFSpeechRecognizer                    *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_recognitionRequest;
    SFSpeechRecognitionTask               *_recognitionTask;
    AVAudioEngine                         *_audioEngine;
    AVSpeechSynthesizer                   *_synthesizer;
    dispatch_queue_t                       _workQueue;
    NSURLSession                          *_urlSession;
    void (^_doneCallback)(void);
}

+ (instancetype)shared {
    static SAOAIEngine *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _recognizer           = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale currentLocale]];
    _recognizer.delegate  = self;
    _synthesizer          = [[AVSpeechSynthesizer alloc] init];
    _synthesizer.delegate = self;
    _workQueue = dispatch_queue_create(
        "com.tuonome.siriaioverhaul.worker",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    NSURLSessionConfiguration *cfg        = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest          = 15.0;
    cfg.timeoutIntervalForResource         = 30.0;
    cfg.HTTPMaximumConnectionsPerHost      = 1;
    _urlSession = [NSURLSession sessionWithConfiguration:cfg];
    return self;
}

- (BOOL)_configureAudioSession {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *e;
    [s setCategory:AVAudioSessionCategoryPlayAndRecord
       withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                   AVAudioSessionCategoryOptionMixWithOthers error:&e];
    if (e) return NO;
    [s setMode:AVAudioSessionModeVoiceChat error:&e];
    [s setActive:YES error:&e];
    return e == nil;
}

- (void)beginListeningWithCompletion:(void(^)(void))done {
    if (!SAOIsEnabled()) return;
    _doneCallback = done;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            if (done) done(); return;
        }
        dispatch_async(self->_workQueue, ^{ [self _startRecognition]; });
    }];
}

- (void)_startRecognition {
    [_recognitionTask cancel];
    _recognitionTask = nil;
    _recognitionRequest = nil;
    if (![self _configureAudioSession]) { if (_doneCallback) _doneCallback(); return; }

    _audioEngine        = [[AVAudioEngine alloc] init];
    _recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    if (@available(iOS 13.0, *)) _recognitionRequest.requiresOnDeviceRecognition = YES;
    _recognitionRequest.shouldReportPartialResults = NO;

    AVAudioInputNode *input = _audioEngine.inputNode;
    AVAudioFormat    *fmt   = [input outputFormatForBus:0];
    [input installTapOnBus:0 bufferSize:4096 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *t) {
        [self->_recognitionRequest appendAudioPCMBuffer:buf];
    }];

    NSError *err;
    [_audioEngine prepare];
    [_audioEngine startAndReturnError:&err];
    if (err) { if (_doneCallback) _doneCallback(); return; }

    __weak typeof(self) weak = self;
    _recognitionTask = [_recognizer recognitionTaskWithRequest:_recognitionRequest
        resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
            __strong typeof(weak) s = weak; if (!s) return;
            if (result.isFinal) {
                NSString *text = result.bestTranscription.formattedString;
                [s _stopAudioEngine];
                if (text.length > 0) dispatch_async(s->_workQueue, ^{ [s _callAPI:text]; });
                else if (s->_doneCallback) s->_doneCallback();
            }
            if (error && error.code != 301) { [s _stopAudioEngine]; if (s->_doneCallback) s->_doneCallback(); }
        }];
}

- (void)_stopAudioEngine {
    if (_audioEngine.isRunning) {
        [_audioEngine.inputNode removeTapOnBus:0];
        [_audioEngine stop];
    }
    [_recognitionRequest endAudio];
}

- (void)_callAPI:(NSString *)prompt {
    NSString *key = SAOAPIKey();
    if (!key.length) { [self _speak:@"Configura la chiave API nelle impostazioni."]; return; }
    NSURLRequest *req = (SAOProvider() == SAOAIProviderChatGPT)
        ? [self _openAIRequest:prompt key:key]
        : [self _geminiRequest:prompt key:key];
    if (!req) return;
    __weak typeof(self) weak = self;
    [[_urlSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        __strong typeof(weak) s = weak; if (!s) return;
        if (e) { [s _speak:@"Errore di rete."]; return; }
        NSString *reply = (SAOProvider() == SAOAIProviderChatGPT)
            ? [s _parseOpenAI:d] : [s _parseGemini:d];
        [s _speak:reply ?: @"Nessuna risposta."];
    }] resume];
}

- (NSURLRequest *)_openAIRequest:(NSString *)p key:(NSString *)k {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/chat/completions"]];
    r.HTTPMethod = @"POST";
    [r setValue:[@"Bearer " stringByAppendingString:k] forHTTPHeaderField:@"Authorization"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"model": @"gpt-4o-mini", @"max_tokens": @256,
        @"messages": @[@{@"role":@"system",@"content":@"Rispondi in massimo 3 frasi."},
                       @{@"role":@"user",@"content":p}]
    } options:0 error:nil];
    return r;
}

- (NSURLRequest *)_geminiRequest:(NSString *)p key:(NSString *)k {
    NSString *url = [NSString stringWithFormat:
        @"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=%@", k];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.HTTPMethod = @"POST";
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"contents": @[@{@"parts": @[@{@"text": p}]}],
        @"generationConfig": @{@"maxOutputTokens": @256, @"temperature": @0.7}
    } options:0 error:nil];
    return r;
}

- (NSString *)_parseOpenAI:(NSData *)d {
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return j[@"choices"][0][@"message"][@"content"];
}

- (NSString *)_parseGemini:(NSData *)d {
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    return j[@"candidates"][0][@"content"][@"parts"][0][@"text"];
}

- (void)_speak:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_synthesizer.isSpeaking)
            [self->_synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
        u.rate            = AVSpeechUtteranceDefaultSpeechRate;
        u.pitchMultiplier = 1.1f;
        u.volume          = 0.9f;
        u.voice           = [AVSpeechSynthesisVoice voiceWithLanguage:@"it-IT"]
                         ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
        [self->_synthesizer speakUtterance:u];
        if (self->_doneCallback) { self->_doneCallback(); self->_doneCallback = nil; }
    });
}

- (void)cancelAll {
    [_recognitionTask cancel]; _recognitionTask = nil;
    [self _stopAudioEngine];
    if (_synthesizer.isSpeaking)
        [_synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    if (_doneCallback) { _doneCallback(); _doneCallback = nil; }
}

@end


// ==============================================================================
#pragma mark - Helpers SpringBoard
// ==============================================================================

static __weak SAOGlowBorderView *s_glowView = nil;

static void SAOInstallGlowView(void) {
    UIWindow *win = nil;
    if (@available(iOS 15.0, *)) {
        for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) { win = sc.keyWindow; break; }
        }
    } else {
        win = [UIApplication sharedApplication].keyWindow;
    }
    if (!win || s_glowView) return;
    SAOGlowBorderView *glow = [[SAOGlowBorderView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    glow.autoresizingMask   = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [win addSubview:glow];
    [win bringSubviewToFront:glow];
    s_glowView = glow;
}

static void SAOOnHerySiriStart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [s_glowView startGlow];
        [[SAOAIEngine shared] beginListeningWithCompletion:^{
            dispatch_async(dispatch_get_main_queue(), ^{ [s_glowView stopGlow]; });
        }];
    });
}

static void SAOOnHerySiriStop(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SAOAIEngine shared] cancelAll];
        [s_glowView stopGlow];
    });
}


// ==============================================================================
#pragma mark - %group SpringBoard
// ==============================================================================

%group SpringBoard

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SAOInstallGlowView();
        [SAOAIEngine shared];

        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();

        CFNotificationCenterAddObserver(c, NULL,
            ^(CFNotificationCenterRef _, void *__, CFStringRef ___, const void *____, CFDictionaryRef _____) {
                SAOOnHerySiriStart();
            },
            (__bridge CFStringRef)kHerySiriDidStart, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(c, NULL,
            ^(CFNotificationCenterRef _, void *__, CFStringRef ___, const void *____, CFDictionaryRef _____) {
                SAOOnHerySiriStop();
            },
            (__bridge CFStringRef)kHerySiriDidStop, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

%end // %hook SpringBoard

%hook SiriUIUnderstandingOnDeviceHandler

- (void)handleOnDeviceSpeechRecognitionResult:(id)result {
    NSLog(@"[SAO] Intercettato handleOnDeviceSpeechRecognitionResult");
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kHerySiriDidStart,
        NULL, NULL, YES);
}

- (void)presentUI {
    NSLog(@"[SAO] Bloccata presentUI Siri");
}

%end // %hook SiriUIUnderstandingOnDeviceHandler

%hook SiriUIAssistantWindowController

- (void)presentWithAnimation:(BOOL)animated {
    NSLog(@"[SAO] Bloccata presentWithAnimation Siri");
}

%end // %hook SiriUIAssistantWindowController

%end // %group SpringBoard


// ==============================================================================
#pragma mark - %group AssistantD
// ==============================================================================

%group AssistantD

%hook SiriTriggerWordDetector

- (void)detector:(id)detector didDetectTriggerWordWithConfidence:(double)confidence {
    NSLog(@"[SAO] Hey Siri rilevato (confidence: %.2f)", confidence);
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kHerySiriDidStart,
        NULL, NULL, YES);
}

%end // %hook SiriTriggerWordDetector

%end // %group AssistantD


// ==============================================================================
#pragma mark - %ctor
// ==============================================================================

%ctor {
    @autoreleasepool {
        NSString *proc = [NSProcessInfo processInfo].processName;
        NSLog(@"[SAO] Caricato in: %@", proc);
        if ([proc isEqualToString:@"SpringBoard"]) {
            %init(SpringBoard);
        } else if ([proc isEqualToString:@"assistantd"]) {
            if (NSClassFromString(@"SiriTriggerWordDetector")) %init(AssistantD);
        }
    }
}
