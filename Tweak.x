// ==============================================================================
//  SiriAIOverhaul — Tweak.x
//  Logos / Objective-C
//
//  Architettura:
//    • %group SpringBoard  → Glow-border UI + osservazione Hey Siri notify
//    • %group AssistantD   → Hook intent handler per bloccare risposta nativa
//
//  Filosofia di ottimizzazione per Apple A9 (iPhone 6s):
//    - Zero blur in tempo reale
//    - CAKeyframeAnimation con fill mode + timing lento (risparmio GPU)
//    - NSURLSession con background configuration (sistema gestisce il thread)
//    - SFSpeechRecognizer on-device (zero banda, zero latenza di rete)
//    - AVSpeechSynthesizer pool riutilizzabile (no alloc ripetuta)
//    - dispatch_queue_t dedicata con QoS .utility (non .userInteractive)
// ==============================================================================

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <substrate.h>

// ── Costanti ──────────────────────────────────────────────────────────────────
static NSString *const kPrefsDomain = @"com.tuonome.siriaioverhaul";
static NSString *const kPrefsPath   =
    @"/var/jb/var/mobile/Library/Preferences/com.tuonome.siriaioverhaul.plist";

// Notifiche Darwin per comunicazione inter-process (SpringBoard ↔ assistantd)
static NSString *const kHerySiriDidStart = @"com.tuonome.siriaioverhaul.heySiriStart";
static NSString *const kHerySiriDidStop  = @"com.tuonome.siriaioverhaul.heySiriStop";

// Spessore bordo glow in punti (sottile = meno area da ridisegnare)
static const CGFloat kBorderWidth = 6.0f;
// Durata animazione fade (lenta = meno frame, meno GPU, meno calore)
static const CFTimeInterval kGlowDuration = 2.8;

// ==============================================================================
#pragma mark - Lettura Preferenze (thread-safe, lazy)
// ==============================================================================

typedef NS_ENUM(NSInteger, SAOAIProvider) {
    SAOAIProviderChatGPT = 0,
    SAOAIProviderGemini  = 1,
};

// Caricamento leggero: legge direttamente il plist senza NSUserDefaults
// (evita la cache di cfprefsd che può rimanere stale in contesti di processo)
static NSDictionary *_SAOLoadPrefs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    return prefs ?: @{};
}

static NSString *SAOAPIKey(void) {
    return _SAOLoadPrefs()[@"apiKey"] ?: @"";
}

static SAOAIProvider SAOProvider(void) {
    NSNumber *val = _SAOLoadPrefs()[@"aiProvider"];
    return val ? (SAOAIProvider)val.integerValue : SAOAIProviderChatGPT;
}

static BOOL SAOIsEnabled(void) {
    NSNumber *val = _SAOLoadPrefs()[@"enabled"];
    return val ? val.boolValue : YES;
}

// ==============================================================================
#pragma mark - SAOGlowBorderView
//
//  UIView iniettata in SpringBoard su keyWindow.
//  Disegna 4 CAShapeLayer (top/bottom/left/right) sui bordi fisici dello schermo.
//  Una sola CAKeyframeAnimation per colore — nessun timer, nessun CADisplayLink.
// ==============================================================================

@interface SAOGlowBorderView : UIView
- (void)startGlow;
- (void)stopGlow;
@end

@implementation SAOGlowBorderView {
    // Un layer per lato: più facile da animare indipendentemente se necessario,
    // ma soprattutto evita un unico huge path che forza re-rasterize dell'intero schermo.
    CAShapeLayer *_topLayer;
    CAShapeLayer *_bottomLayer;
    CAShapeLayer *_leftLayer;
    CAShapeLayer *_rightLayer;

    // Flag per evitare animazioni duplicate
    BOOL _isGlowing;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // ── La view stessa non intercetta tocchi ──────────────────────────────
        self.userInteractionEnabled = NO;
        self.backgroundColor        = [UIColor clearColor];

        // ── Costruisce i 4 layer ──────────────────────────────────────────────
        _topLayer    = [self _makeLayerForSide:UIRectEdgeTop    bounds:frame];
        _bottomLayer = [self _makeLayerForSide:UIRectEdgeBottom bounds:frame];
        _leftLayer   = [self _makeLayerForSide:UIRectEdgeLeft   bounds:frame];
        _rightLayer  = [self _makeLayerForSide:UIRectEdgeRight  bounds:frame];

        [self.layer addSublayer:_topLayer];
        [self.layer addSublayer:_bottomLayer];
        [self.layer addSublayer:_leftLayer];
        [self.layer addSublayer:_rightLayer];
    }
    return self;
}

// ── Costruisce un CAShapeLayer rettilineo per il lato richiesto ───────────────
- (CAShapeLayer *)_makeLayerForSide:(UIRectEdge)side bounds:(CGRect)bounds {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.fillColor   = nil;
    layer.lineWidth   = kBorderWidth;
    layer.opacity     = 0.0f; // parte invisibile

    // Path statico: calcolato una volta sola, non ricalcolato ogni frame
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat w = bounds.size.width;
    CGFloat h = bounds.size.height;
    CGFloat hw = kBorderWidth / 2.0f; // half-width per allineamento preciso

    switch (side) {
        case UIRectEdgeTop:
            [path moveToPoint:CGPointMake(0, hw)];
            [path addLineToPoint:CGPointMake(w, hw)];
            break;
        case UIRectEdgeBottom:
            [path moveToPoint:CGPointMake(0, h - hw)];
            [path addLineToPoint:CGPointMake(w, h - hw)];
            break;
        case UIRectEdgeLeft:
            [path moveToPoint:CGPointMake(hw, 0)];
            [path addLineToPoint:CGPointMake(hw, h)];
            break;
        case UIRectEdgeRight:
            [path moveToPoint:CGPointMake(w - hw, 0)];
            [path addLineToPoint:CGPointMake(w - hw, h)];
            break;
        default: break;
    }

    layer.path = path.CGPath;
    return layer;
}

// ── startGlow: avvia animazione colore+opacità ultra-leggera ─────────────────
//
//  Strategia di risparmio energetico:
//  1. keyTimes ampiamente spaziati → pochi frame interpolati dal Core Animation
//  2. calculationMode = kCAAnimationLinear (nessun ease-in/out computation)
//  3. repeatCount = HUGE_VALF → nessun timer di riavvio, gestito da CA server
//  4. Solo strokeColor + opacity: 2 proprietà scalari, GPU quasi ferma
// ─────────────────────────────────────────────────────────────────────────────
- (void)startGlow {
    if (_isGlowing) return;
    _isGlowing = YES;

    // Palette colori: ispirata ad Apple Intelligence, toni pastello
    // Convertiti in CGColor una sola volta (costoso convertire ogni frame)
    NSArray<id> *colors = @[
        (__bridge id)[UIColor colorWithRed:0.40 green:0.60 blue:1.00 alpha:1.0].CGColor, // blue
        (__bridge id)[UIColor colorWithRed:0.70 green:0.40 blue:1.00 alpha:1.0].CGColor, // violet
        (__bridge id)[UIColor colorWithRed:1.00 green:0.45 blue:0.70 alpha:1.0].CGColor, // pink
        (__bridge id)[UIColor colorWithRed:0.40 green:0.85 blue:0.75 alpha:1.0].CGColor, // teal
        (__bridge id)[UIColor colorWithRed:0.40 green:0.60 blue:1.00 alpha:1.0].CGColor, // blue (loop)
    ];

    NSArray<NSNumber *> *keyTimes = @[@0.0, @0.25, @0.50, @0.75, @1.0];

    // Anima su tutti e 4 i layer con offset di fase per effetto "circolante"
    NSArray<CAShapeLayer *> *layers = @[_topLayer, _bottomLayer, _leftLayer, _rightLayer];
    NSArray<NSNumber *>     *offsets = @[@0.0, @0.5, @0.25, @0.75];

    for (NSUInteger i = 0; i < layers.count; i++) {
        CAShapeLayer *layer = layers[i];
        double offset = [offsets[i] doubleValue];

        // ── Animazione colore ─────────────────────────────────────────────────
        CAKeyframeAnimation *colorAnim  = [CAKeyframeAnimation animationWithKeyPath:@"strokeColor"];
        colorAnim.values                = colors;
        colorAnim.keyTimes              = keyTimes;
        colorAnim.duration              = kGlowDuration;
        colorAnim.repeatCount           = HUGE_VALF;
        colorAnim.calculationMode       = kCAAnimationLinear;
        colorAnim.fillMode              = kCAFillModeForwards;
        colorAnim.removedOnCompletion   = NO;
        colorAnim.timeOffset            = offset * kGlowDuration; // fase sfasata per effetto "viaggio"

        // ── Animazione opacità: respiro lento (0.6↔1.0) ──────────────────────
        CAKeyframeAnimation *opacityAnim = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        opacityAnim.values               = @[@0.6, @1.0, @0.6];
        opacityAnim.keyTimes             = @[@0.0, @0.5, @1.0];
        opacityAnim.duration             = kGlowDuration * 1.5; // periodo più lungo = meno frame
        opacityAnim.repeatCount          = HUGE_VALF;
        opacityAnim.calculationMode      = kCAAnimationLinear;
        opacityAnim.fillMode             = kCAFillModeForwards;
        opacityAnim.removedOnCompletion  = NO;

        // ── Gruppo animazioni per sincronizzazione ────────────────────────────
        CAAnimationGroup *group = [CAAnimationGroup animation];
        group.animations         = @[colorAnim, opacityAnim];
        group.duration           = kGlowDuration * 1.5;
        group.repeatCount        = HUGE_VALF;
        group.fillMode           = kCAFillModeForwards;
        group.removedOnCompletion= NO;

        [layer addAnimation:group forKey:@"saoGlowGroup"];
        layer.opacity = 0.8f; // valore finale visibile
    }
}

// ── stopGlow: fade-out rapido e rimozione animazioni ─────────────────────────
- (void)stopGlow {
    if (!_isGlowing) return;
    _isGlowing = NO;

    NSArray<CAShapeLayer *> *layers = @[_topLayer, _bottomLayer, _leftLayer, _rightLayer];

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.4];
    [CATransaction setCompletionBlock:^{
        // Rimuovi le animazioni pesanti DOPO il fade-out (non durante)
        for (CAShapeLayer *l in layers) {
            [l removeAnimationForKey:@"saoGlowGroup"];
            l.opacity = 0.0f;
        }
    }];
    for (CAShapeLayer *l in layers) {
        l.opacity = 0.0f;
    }
    [CATransaction commit];
}

@end


// ==============================================================================
#pragma mark - SAOAIEngine
//
//  Motore AI: gestisce STT → API call → TTS
//  Singleton leggero, allocato una volta sola.
// ==============================================================================

@interface SAOAIEngine : NSObject <SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate>

@property (nonatomic, strong, readonly) AVSpeechSynthesizer *synthesizer;

+ (instancetype)shared;

/// Avvia riconoscimento vocale; al termine chiama l'API e risponde con TTS
- (void)beginListeningWithCompletion:(void(^)(void))didFinishCallback;

/// Annulla tutto e libera le risorse audio
- (void)cancelAll;

@end

@implementation SAOAIEngine {
    // STT
    SFSpeechRecognizer        *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_recognitionRequest;
    SFSpeechRecognitionTask   *_recognitionTask;
    AVAudioEngine             *_audioEngine;

    // TTS — riutilizzato per evitare alloc ripetute
    AVSpeechSynthesizer       *_synthesizer;

    // Coda di lavoro: QoS utility = sistema può sospenderla sotto pressione termica
    dispatch_queue_t           _workQueue;

    // NSURLSession condivisa: una sola sessione, più request
    NSURLSession              *_urlSession;

    // Callback SpringBoard per nascondere il glow
    void (^_didFinishCallback)(void);
}

+ (instancetype)shared {
    static SAOAIEngine *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // ── Riconoscitore STT on-device (nessuna rete per STT) ─────────────────
        _recognizer          = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale currentLocale]];
        _recognizer.delegate = self;

        // ── TTS: voce di sistema, nessun download extra ────────────────────────
        _synthesizer          = [[AVSpeechSynthesizer alloc] init];
        _synthesizer.delegate = self;

        // ── Coda utente: bassa priorità = risparmio batteria ──────────────────
        _workQueue = dispatch_queue_create(
            "com.tuonome.siriaioverhaul.worker",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                     QOS_CLASS_UTILITY, 0)
        );

        // ── Sessione HTTP condivisa: ephemeral (nessun disco, nessuna cache) ──
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest  = 15.0; // fail veloce su rete lenta
        cfg.timeoutIntervalForResource = 30.0;
        cfg.HTTPMaximumConnectionsPerHost = 1; // una sola connessione: meno radio
        _urlSession = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

// ── Configura sessione audio minimale ─────────────────────────────────────────
- (BOOL)_configureAudioSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;

    // Categoria: PlayAndRecord con defaultToSpeaker + mixWithOthers
    // (mixWithOthers → non interrompe la musica in background)
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
             withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                         AVAudioSessionCategoryOptionMixWithOthers
                   error:&err];
    if (err) {
        NSLog(@"[SAO] AudioSession setCategory error: %@", err.localizedDescription);
        return NO;
    }

    // Modalità: voiceChat ottimizza la pipeline audio per voce (meno DSP)
    [session setMode:AVAudioSessionModeVoiceChat error:&err];
    [session setActive:YES error:&err];
    return err == nil;
}

// ── beginListening: avvia STT → API → TTS pipeline ───────────────────────────
- (void)beginListeningWithCompletion:(void(^)(void))didFinishCallback {
    if (![SAOIsEnabled() boolValue]) return; // guard: tweak disabilitato

    _didFinishCallback = didFinishCallback;

    // Richiesta permesso STT (va chiesta una sola volta, il sistema ricorda)
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            NSLog(@"[SAO] STT authorization denied.");
            if (didFinishCallback) didFinishCallback();
            return;
        }

        dispatch_async(self->_workQueue, ^{
            [self _startRecognition];
        });
    }];
}

- (void)_startRecognition {
    // Cancella task precedente se presente
    [_recognitionTask cancel];
    _recognitionTask    = nil;
    _recognitionRequest = nil;

    if (![self _configureAudioSession]) {
        if (_didFinishCallback) _didFinishCallback();
        return;
    }

    _audioEngine        = [[AVAudioEngine alloc] init];
    _recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];

    // ── ON-DEVICE: non invia audio ai server Apple ─────────────────────────────
    if (@available(iOS 13.0, *)) {
        _recognitionRequest.requiresOnDeviceRecognition = YES;
    }

    // Silenzio rilevato → considera il parlato finito
    _recognitionRequest.taskHint = SFSpeechRecognitionTaskHintDictation;
    _recognitionRequest.shouldReportPartialResults = NO; // solo risultato finale

    AVAudioInputNode *inputNode = _audioEngine.inputNode;
    AVAudioFormat    *fmt       = [inputNode outputFormatForBus:0];

    [inputNode installTapOnBus:0
                    bufferSize:4096 // ~85ms a 48kHz: bilanciamento latenza/CPU
                        format:fmt
                         block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        [self->_recognitionRequest appendAudioPCMBuffer:buf];
    }];

    NSError *startErr = nil;
    [_audioEngine prepare];
    [_audioEngine startAndReturnError:&startErr];

    if (startErr) {
        NSLog(@"[SAO] AudioEngine start error: %@", startErr.localizedDescription);
        if (_didFinishCallback) _didFinishCallback();
        return;
    }

    __weak typeof(self) weakSelf = self;

    _recognitionTask = [_recognizer recognitionTaskWithRequest:_recognitionRequest
                                             resultHandler:^(SFSpeechRecognitionResult *result,
                                                             NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (result.isFinal) {
            NSString *text = result.bestTranscription.formattedString;
            NSLog(@"[SAO] STT finale: %@", text);

            // Ferma motore audio il prima possibile per liberare DSP
            [strongSelf _stopAudioEngine];

            if (text.length > 0) {
                // Chiama API su coda utility (non blocca UI)
                dispatch_async(strongSelf->_workQueue, ^{
                    [strongSelf _callAPIWithPrompt:text];
                });
            } else {
                if (strongSelf->_didFinishCallback) strongSelf->_didFinishCallback();
            }
        }

        if (error && error.code != 301 /*kAFAssistantErrorDomain silence*/) {
            NSLog(@"[SAO] STT error: %@", error.localizedDescription);
            [strongSelf _stopAudioEngine];
            if (strongSelf->_didFinishCallback) strongSelf->_didFinishCallback();
        }
    }];
}

- (void)_stopAudioEngine {
    if (_audioEngine.isRunning) {
        [_audioEngine.inputNode removeTapOnBus:0];
        [_audioEngine stop];
    }
    [_recognitionRequest endAudio];
}

// ── Chiamata API: ChatGPT o Gemini ────────────────────────────────────────────
- (void)_callAPIWithPrompt:(NSString *)prompt {
    NSString *apiKey   = SAOAPIKey();
    if (apiKey.length == 0) {
        NSLog(@"[SAO] API Key mancante. Configurare in Impostazioni.");
        [self _speakText:@"Per favore configura la chiave API nelle impostazioni."];
        return;
    }

    SAOAIProvider provider = SAOProvider();

    NSURLRequest *request = (provider == SAOAIProviderChatGPT)
        ? [self _buildOpenAIRequest:prompt key:apiKey]
        : [self _buildGeminiRequest:prompt key:apiKey];

    if (!request) return;

    // ── Task data: leggero, nessun file su disco ───────────────────────────────
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [_urlSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error) {
                NSLog(@"[SAO] Network error: %@", error.localizedDescription);
                [strongSelf _speakText:@"Errore di rete. Riprova."];
                return;
            }

            NSString *reply = (provider == SAOAIProviderChatGPT)
                ? [strongSelf _parseOpenAIResponse:data]
                : [strongSelf _parseGeminiResponse:data];

            NSLog(@"[SAO] AI reply: %@", reply);
            [strongSelf _speakText:reply ?: @"Nessuna risposta ricevuta."];
        }];
    [task resume];
}

// ── OpenAI: costruisce la request ─────────────────────────────────────────────
- (NSURLRequest *)_buildOpenAIRequest:(NSString *)prompt key:(NSString *)key {
    NSURL *url = [NSURL URLWithString:@"https://api.openai.com/v1/chat/completions"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json"                      forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"model"      : @"gpt-4o-mini",   // modello più leggero = risposta rapida
        @"max_tokens" : @256,              // risposta concisa: meno token = meno latenza
        @"messages"   : @[
            @{@"role": @"system",
              @"content": @"Sei un assistente vocale conciso. Rispondi in massimo 3 frasi."},
            @{@"role": @"user", @"content": prompt}
        ]
    };

    NSError *jsonErr;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr) { NSLog(@"[SAO] JSON error: %@", jsonErr); return nil; }
    return req;
}

// ── Google Gemini: costruisce la request ──────────────────────────────────────
- (NSURLRequest *)_buildGeminiRequest:(NSString *)prompt key:(NSString *)key {
    NSString *urlStr = [NSString stringWithFormat:
        @"https://generativelanguage.googleapis.com/v1beta/models/"
        @"gemini-1.5-flash:generateContent?key=%@", key];
    NSURL *url = [NSURL URLWithString:urlStr];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"contents": @[@{
            @"parts": @[@{@"text": prompt}]
        }],
        @"generationConfig": @{
            @"maxOutputTokens": @256,
            @"temperature"    : @0.7
        }
    };

    NSError *jsonErr;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr) { NSLog(@"[SAO] JSON error: %@", jsonErr); return nil; }
    return req;
}

// ── Parser risposta OpenAI ────────────────────────────────────────────────────
- (NSString *)_parseOpenAIResponse:(NSData *)data {
    NSError *err;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || !json) return nil;
    return json[@"choices"][0][@"message"][@"content"];
}

// ── Parser risposta Gemini ────────────────────────────────────────────────────
- (NSString *)_parseGeminiResponse:(NSData *)data {
    NSError *err;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || !json) return nil;
    return json[@"candidates"][0][@"content"][@"parts"][0][@"text"];
}

// ── TTS: sintetizza testo con voce nativa ─────────────────────────────────────
//  AVSpeechSynthesizer è il componente più leggero disponibile su iOS:
//  usa le voci on-device, zero rete, zero DSP extra.
// ─────────────────────────────────────────────────────────────────────────────
- (void)_speakText:(NSString *)text {
    // Torna sul main thread: AVSpeechSynthesizer è main-thread-only per UI safety
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_synthesizer.isSpeaking) {
            [self->_synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        }

        AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
        utterance.rate               = AVSpeechUtteranceDefaultSpeechRate;
        utterance.pitchMultiplier    = 1.1f; // voce leggermente più alta = più chiara su speaker 6s
        utterance.volume             = 0.9f;

        // Voce italiana se disponibile, altrimenti sistema sceglie
        AVSpeechSynthesisVoice *voice =
            [AVSpeechSynthesisVoice voiceWithLanguage:@"it-IT"] ?:
            [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
        utterance.voice = voice;

        [self->_synthesizer speakUtterance:utterance];

        // Notifica SpringBoard: glow può spegnersi
        if (self->_didFinishCallback) {
            self->_didFinishCallback();
            self->_didFinishCallback = nil;
        }
    });
}

// ── cancelAll: pulizia completa ────────────────────────────────────────────────
- (void)cancelAll {
    [_recognitionTask cancel];
    _recognitionTask = nil;
    [self _stopAudioEngine];
    [_urlSession invalidateAndCancel];
    if (_synthesizer.isSpeaking) {
        [_synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    }
    if (_didFinishCallback) {
        _didFinishCallback();
        _didFinishCallback = nil;
    }
}

@end // SAOAIEngine


// ==============================================================================
#pragma mark - %group SpringBoard
//
//  Iniettato in SpringBoard.app.
//  Responsabilità:
//    1. Aggiungere SAOGlowBorderView al keyWindow all'avvio
//    2. Osservare notifiche Darwin per accendere/spegnere il glow
//    3. Intercettare la visualizzazione dell'UI nativa di Siri
// ==============================================================================

// ── Riferimento debole alla glow view (evita retain cycle) ───────────────────
static __weak SAOGlowBorderView *s_glowView = nil;

// ── Helper: aggiunge la glow view se non già presente ────────────────────────
static void SAOInstallGlowView(void) {
    UIWindow *keyWindow = nil;

    // iOS 15+: uso UIWindowScene per trovare il keyWindow correttamente
    if (@available(iOS 15.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                keyWindow = scene.keyWindow;
                break;
            }
        }
    } else {
        keyWindow = [UIApplication sharedApplication].keyWindow;
    }

    if (!keyWindow || s_glowView) return;

    CGRect screen           = [UIScreen mainScreen].bounds;
    SAOGlowBorderView *glow = [[SAOGlowBorderView alloc] initWithFrame:screen];
    glow.autoresizingMask   = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // Portalo al top della gerarchia senza interferire con il touch routing
    [keyWindow addSubview:glow];
    [keyWindow bringSubviewToFront:glow];

    s_glowView = glow; // weak reference
    NSLog(@"[SAO] GlowBorderView installata.");
}

// ── Hook su UIWindow per intercettare la visualizzazione di SiriUI ─────────────
%group SpringBoard

// Classe: SBUIAnimationController o qualunque classe SpringBoard che viene
// istanziata quando Siri si attiva. Intercettiamo makeKeyAndVisible di UIWindow
// per bloccare qualsiasi finestra Siri prima che appaia.

// ── Hook su -[UIApplication _setUpWithScene:...]: punto di aggancio robusto ──
%hook SpringBoard

// Metodo chiamato a SpringBoard pronto: qui installiamo la glow view
- (void)applicationDidFinishLaunching:(UIApplication *)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SAOInstallGlowView();
        [SAOAIEngine shared]; // pre-alloca il singleton: evita lag al primo uso

        // ── Registra observer notifiche Darwin ────────────────────────────────
        // Darwin notify è il meccanismo più leggero per IPC in jailbreak context.
        // Nessun NSNotificationCenter tra processi diversi.
        CFNotificationCenterRef darwinCenter =
            CFNotificationCenterGetDarwinNotifyCenter();

        // Hey Siri iniziato → accendi glow + avvia SAOAIEngine
        CFNotificationCenterAddObserver(darwinCenter, NULL,
            ^(CFNotificationCenterRef center, void *observer,
              CFStringRef name, const void *object, CFDictionaryRef info) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [s_glowView startGlow];
                    [[SAOAIEngine shared] beginListeningWithCompletion:^{
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [s_glowView stopGlow];
                        });
                    }];
                });
            },
            (__bridge CFStringRef)kHerySiriDidStart,
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // Hey Siri annullato → spegni glow
        CFNotificationCenterAddObserver(darwinCenter, NULL,
            ^(CFNotificationCenterRef center, void *observer,
              CFStringRef name, const void *object, CFDictionaryRef info) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[SAOAIEngine shared] cancelAll];
                    [s_glowView stopGlow];
                });
            },
            (__bridge CFStringRef)kHerySiriDidStop,
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

%end // %hook SpringBoard


// ── Hook SiriUI: previene la visualizzazione dell'interfaccia nativa Siri ─────
//
//  La classe 'SiriUIUnderstandingOnDeviceHandler' viene allocata quando
//  "Hey Siri" viene rilevato. Intercettiamo la chiamata che mostrerebbe la UI.
//  Targets primari (variano tra versioni iOS — proviamo entrambi con %ctor guard):
//    • SiriUIUnderstandingOnDeviceHandler  (iOS 15-16)
//    • SiriUIAssistantWindowController     (alternativo)
// ─────────────────────────────────────────────────────────────────────────────

%hook SiriUIUnderstandingOnDeviceHandler

// Questo metodo avvia il processo di risposta Siri nativa
// Lo sostituiamo con l'invio di una Darwin notification al nostro motore
- (void)handleOnDeviceSpeechRecognitionResult:(id)result {
    // NON chiamiamo %orig → blocchiamo Siri nativamente
    NSLog(@"[SAO] Intercettato handleOnDeviceSpeechRecognitionResult. Reindirizzo ad AI.");

    // Notifica il processo SpringBoard (dove gira il motore AI)
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kHerySiriDidStart,
        NULL, NULL, YES
    );
}

// Blocca la comparsa dell'UI Siri
- (void)presentUI {
    NSLog(@"[SAO] Bloccata presentUI di SiriUIUnderstandingOnDeviceHandler.");
    // %orig NON chiamato
}

%end // %hook SiriUIUnderstandingOnDeviceHandler


// ── Fallback Hook: SiriUIAssistantWindowController ────────────────────────────
%hook SiriUIAssistantWindowController

- (void)presentWithAnimation:(BOOL)animated {
    NSLog(@"[SAO] Bloccata presentWithAnimation di SiriUIAssistantWindowController.");
    // %orig NON chiamato: Siri non compare visivamente
}

%end // %hook SiriUIAssistantWindowController

%end // %group SpringBoard


// ==============================================================================
#pragma mark - %group AssistantD
//
//  Iniettato in assistantd (demone Siri in background).
//  Intercetta l'attivazione di Hey Siri a basso livello.
// ==============================================================================

%group AssistantD

// AssistantServices framework: gestisce il riconoscimento "Hey Siri"
// SiriTriggerWordDetector è la classe che gestisce la rilevazione vocale
%hook SiriTriggerWordDetector

// Chiamato quando "Hey Siri" viene riconosciuto con successo
- (void)detector:(id)detector didDetectTriggerWordWithConfidence:(double)confidence {
    NSLog(@"[SAO] Hey Siri rilevato (confidence: %.2f). Reindirizzo a SAOAIEngine.", confidence);

    // Invia notifica Darwin a SpringBoard per avviare il glow e il motore AI
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kHerySiriDidStart,
        NULL, NULL, YES
    );

    // NON chiamiamo %orig → il flusso Siri nativo non parte
}

%end // %hook SiriTriggerWordDetector

%end // %group AssistantD


// ==============================================================================
#pragma mark - %ctor / %dtor
//
//  Selezione del gruppo di hook in base al processo che carica il tweak.
// ==============================================================================

%ctor {
    @autoreleasepool {
        NSString *processName = [NSProcessInfo processInfo].processName;
        NSLog(@"[SAO] Caricato in processo: %@", processName);

        if ([processName isEqualToString:@"SpringBoard"]) {
            // Verifica che SiriUIUnderstandingOnDeviceHandler esista (iOS 15+)
            if (NSClassFromString(@"SiriUIUnderstandingOnDeviceHandler")) {
                NSLog(@"[SAO] Inizializzando gruppo SpringBoard (con SiriUIUnderstandingOnDeviceHandler).");
            } else {
                NSLog(@"[SAO] SiriUIUnderstandingOnDeviceHandler non trovata, solo intercettazione SpringBoard.");
            }
            %init(SpringBoard);
        } else if ([processName isEqualToString:@"assistantd"]) {
            // Verifica che SiriTriggerWordDetector esista nel processo
            if (NSClassFromString(@"SiriTriggerWordDetector")) {
                NSLog(@"[SAO] Inizializzando gruppo AssistantD.");
                %init(AssistantD);
            } else {
                NSLog(@"[SAO] SiriTriggerWordDetector non trovata in assistantd.");
            }
        }
    }
}
