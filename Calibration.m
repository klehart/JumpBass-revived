// Kalibrierung mit dem Mikrofon des Macs: misst das Bass-Timing, die Übersteuerungsgrenze des BassJump und bei
// externen Monitoren mit eigener Lautstärke deren Lautstärkekurve. Die laufende Audio-Engine spielt die Testsignale
// statt des Systemtons ab; Aufnahme und Auswertung laufen auf einem eigenen Thread.

#import "JumpBassRevived.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <os/lock.h>
#import <stdatomic.h>

static double DB(double v) { return 20.0 * log10(v + 1e-12); }

#pragma mark - Mikrofon-Aufnahme

@interface MicRecorder : NSObject
@property (readonly) double rate;
- (OSStatus)startWithDevice:(AudioObjectID)dev;
- (UInt64)position;
- (NSData *)framesFrom:(UInt64)start count:(UInt64)count;
- (void)stop;
@end

@implementation MicRecorder {
    AudioQueueRef _queue;
    float *_data;
    UInt64 _capacity, _count;
    os_unfair_lock _lock;
}

static void RecorderCallback(void *user, AudioQueueRef q, AudioQueueBufferRef buf, const AudioTimeStamp *t,
                             UInt32 packets, const AudioStreamPacketDescription *desc) {
    MicRecorder *r = (__bridge MicRecorder *)user;
    [r append:buf->mAudioData frames:buf->mAudioDataByteSize / sizeof(float)];
    AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

- (OSStatus)startWithDevice:(AudioObjectID)dev {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &rate);
    _rate = rate > 0 ? rate : 48000;
    _lock = OS_UNFAIR_LOCK_INIT;
    _capacity = (UInt64)(_rate * 180);   // reicht für die ganze Kalibrierung
    _data = calloc(_capacity, sizeof(float));

    AudioStreamBasicDescription fmt = { 0 };
    fmt.mSampleRate = _rate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mChannelsPerFrame = 1;
    fmt.mBitsPerChannel = 32;
    fmt.mBytesPerFrame = fmt.mBytesPerPacket = 4;
    fmt.mFramesPerPacket = 1;
    OSStatus err = AudioQueueNewInput(&fmt, RecorderCallback, (__bridge void *)self, NULL, NULL, 0, &_queue);
    if (err) return err;
    CFStringRef uid = (__bridge CFStringRef)DeviceUID(dev);
    if (uid) AudioQueueSetProperty(_queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef buf;
        if ((err = AudioQueueAllocateBuffer(_queue, 4096 * sizeof(float), &buf))) return err;
        AudioQueueEnqueueBuffer(_queue, buf, 0, NULL);
    }
    return AudioQueueStart(_queue, NULL);
}

- (void)append:(const float *)src frames:(UInt32)n {
    os_unfair_lock_lock(&_lock);
    UInt64 room = _capacity - _count;
    memcpy(_data + _count, src, MIN(n, room) * sizeof(float));
    _count += MIN(n, room);
    os_unfair_lock_unlock(&_lock);
}

- (UInt64)position {
    os_unfair_lock_lock(&_lock);
    UInt64 n = _count;
    os_unfair_lock_unlock(&_lock);
    return n;
}

- (NSData *)framesFrom:(UInt64)start count:(UInt64)count {
    os_unfair_lock_lock(&_lock);
    NSData *d = start + count <= _count ? [NSData dataWithBytes:_data + start length:count * sizeof(float)] : nil;
    os_unfair_lock_unlock(&_lock);
    return d;
}

- (void)stop {
    if (_queue) {
        AudioQueueStop(_queue, true);
        AudioQueueDispose(_queue, true);
        _queue = NULL;
    }
}

- (void)dealloc {
    [self stop];
    free(_data);
}
@end

#pragma mark - Audio-Verarbeitung anstoßen

// Nach dem Start (oder dem Ruhemodus) läuft die Engine erst los, wenn ein anderes Programm etwas abspielt –
// den eigenen Ton nimmt der Systemton-Tap absichtlich nicht auf. Ohne Musik spielt afplay deshalb eine halbe
// Sekunde Stille ab; danach läuft die Engine weiter, auch wenn wieder nichts spielt.
static void KickEngine(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"jumpbass-stille.wav"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        UInt32 frames = 24000, dataSize = frames * 2;
        NSMutableData *wav = [NSMutableData dataWithLength:44 + dataSize];
        uint8_t *h = wav.mutableBytes;
        UInt32 riff = 36 + dataSize, fmtSize = 16, rate = 48000, byteRate = 96000;
        UInt16 pcm = 1, channels = 1, align = 2, bits = 16;
        memcpy(h, "RIFF", 4); memcpy(h + 4, &riff, 4); memcpy(h + 8, "WAVEfmt ", 8);
        memcpy(h + 16, &fmtSize, 4); memcpy(h + 20, &pcm, 2); memcpy(h + 22, &channels, 2); memcpy(h + 24, &rate, 4);
        memcpy(h + 28, &byteRate, 4); memcpy(h + 32, &align, 2); memcpy(h + 34, &bits, 2);
        memcpy(h + 36, "data", 4); memcpy(h + 40, &dataSize, 4);
        [wav writeToFile:path atomically:YES];
    }
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/afplay";
    task.arguments = @[path];
    @try { [task launch]; [task waitUntilExit]; } @catch (NSException *e) {}
}

#pragma mark - Testsignale und Auswertung

// Linearer Sweep von f0 nach f1 mit weichen Rändern (je 10 % Hann), eingebettet ab Sekunde at
static void AddChirp(float *dst, double rate, double at, double f0, double f1, double dur, float amp) {
    size_t start = (size_t)(at * rate), n = (size_t)(dur * rate), edge = n / 10;
    for (size_t i = 0; i < n; i++) {
        double t = i / rate;
        double w = i < edge ? 0.5 - 0.5 * cos(M_PI * i / edge) : i >= n - edge ? 0.5 - 0.5 * cos(M_PI * (n - 1 - i) / edge) : 1;
        dst[start + i] += (float)(amp * w * sin(2 * M_PI * (f0 * t + (f1 - f0) * t * t / (2 * dur))));
    }
}

// Sinuston mit 20 ms Ein- und Ausblendung
static void AddTone(float *dst, double rate, double at, double f, double dur, float amp) {
    size_t start = (size_t)(at * rate), n = (size_t)(dur * rate), edge = (size_t)(0.02 * rate);
    for (size_t i = 0; i < n; i++) {
        double w = i < edge ? (double)i / edge : i >= n - edge ? (double)(n - 1 - i) / edge : 1;
        dst[start + i] += (float)(amp * w * sin(2 * M_PI * f * i / rate));
    }
}

// Hüllkurve der Kreuzkorrelation (Betrag des analytischen Signals): env[k] ~ Übereinstimmung von ref mit x ab Stelle k.
// Die Hüllkurve statt der Korrelation selbst, damit bei tiefen Frequenzen nicht eine Nachbarschwingung gewinnt.
static NSData *CorrelationEnvelope(const float *x, size_t n, const float *ref, size_t m) {
    vDSP_Length log2n = (vDSP_Length)ceil(log2((double)(n + m)));
    size_t N = (size_t)1 << log2n;
    FFTSetup setup = vDSP_create_fftsetup(log2n, kFFTRadix2);
    float *buf = calloc(N * 4, sizeof(float));
    DSPSplitComplex X = { buf, buf + N }, R = { buf + 2 * N, buf + 3 * N };
    memcpy(X.realp, x, n * sizeof(float));
    memcpy(R.realp, ref, m * sizeof(float));
    vDSP_fft_zip(setup, &X, 1, log2n, kFFTDirection_Forward);
    vDSP_fft_zip(setup, &R, 1, log2n, kFFTDirection_Forward);
    vDSP_zvmul(&R, 1, &X, 1, &X, 1, N, -1);           // X · konj(R)
    for (size_t k = 1; k < N / 2; k++) { X.realp[k] *= 2; X.imagp[k] *= 2; }
    for (size_t k = N / 2 + 1; k < N; k++) X.realp[k] = X.imagp[k] = 0;
    vDSP_fft_zip(setup, &X, 1, log2n, kFFTDirection_Inverse);
    NSMutableData *env = [NSMutableData dataWithLength:n * sizeof(float)];
    vDSP_zvabs(&X, 1, env.mutableBytes, 1, n);
    vDSP_destroy_fftsetup(setup);
    free(buf);
    return env;
}

// Stelle des Maximums in env[lo, hi) mit parabolischer Verfeinerung; snr = Maximum / Median des Bereichs
static double PeakIn(NSData *envData, size_t lo, size_t hi, double *snr) {
    const float *env = envData.bytes;
    hi = MIN(hi, envData.length / sizeof(float));
    if (lo + 3 >= hi) { *snr = 0; return 0; }
    size_t best = lo;
    for (size_t i = lo; i < hi; i++) if (env[i] > env[best]) best = i;
    NSMutableData *sorted = [NSMutableData dataWithBytes:env + lo length:(hi - lo) * sizeof(float)];
    vDSP_vsort(sorted.mutableBytes, hi - lo, 1);
    float median = ((float *)sorted.mutableBytes)[(hi - lo) / 2];
    *snr = env[best] / fmaxf(median, 1e-12f);
    if (best == lo || best + 1 >= hi) return best;
    double a = env[best - 1], b = env[best], c = env[best + 1], d = a - 2 * b + c;
    return best + (d != 0 ? 0.5 * (a - c) / d : 0);
}

// Amplitude eines Sinustons der Frequenz f (Hann-gefensterte DFT an genau dieser Frequenz)
static double ToneAmplitude(NSData *data, double rate, double f) {
    const float *x = data.bytes;
    size_t n = data.length / sizeof(float);
    double re = 0, im = 0, wsum = 0;
    for (size_t i = 0; i < n; i++) {
        double w = 0.5 - 0.5 * cos(2 * M_PI * i / (n - 1)), ph = 2 * M_PI * f * i / rate;
        re += w * x[i] * cos(ph);
        im += w * x[i] * sin(ph);
        wsum += w;
    }
    return 2 * sqrt(re * re + im * im) / wsum;
}

// Effektivwert oberhalb von 1 kHz (Hochpass 4. Ordnung): Knacken und Verzerrung eines Basstons landen dort,
// der Ton selbst nicht.
static double HighBandRMS(NSData *data, double rate) {
    const float *x = data.bytes;
    size_t n = data.length / sizeof(float), skip = (size_t)(0.02 * rate);
    double w0 = 2 * M_PI * 1000 / rate, cw = cos(w0), alpha = sin(w0) / (2 * M_SQRT1_2), a0 = 1 + alpha;
    double b0 = (1 + cw) / 2 / a0, b1 = -(1 + cw) / a0, a1 = -2 * cw / a0, a2 = (1 - alpha) / a0;
    double s[2][4] = { { 0 } }, sum = 0;
    for (size_t i = 0; i < n; i++) {
        double y = x[i];
        for (int k = 0; k < 2; k++) {
            double out = b0 * y + b1 * s[k][0] + b0 * s[k][1] - a1 * s[k][2] - a2 * s[k][3];
            s[k][1] = s[k][0]; s[k][0] = y; s[k][3] = s[k][2]; s[k][2] = out;
            y = out;
        }
        if (i >= skip) sum += y * y;
    }
    return sqrt(sum / MAX(n - skip, 1));
}

#pragma mark - Ablauf

@implementation Calibrator {
    AppDelegate *_app;
    MicRecorder *_mic;
    double _outRate;
    atomic_bool _cancel;
    void (^_progress)(NSString *, double);
    NSString *_failure;         // Grund, warum das letzte Testsignal nicht aufgenommen werden konnte
}

- (NSString *)interrupted {
    return [self cancelled] ? nil : [NSString stringWithFormat:L(@"Die Messung wurde unterbrochen (%@)."), _failure ?: @"?"];
}

- (instancetype)initWithApp:(AppDelegate *)app {
    if ((self = [super init])) _app = app;
    return self;
}

- (void)cancel { atomic_store(&_cancel, true); }
- (BOOL)cancelled { return atomic_load(&_cancel); }

- (void)report:(NSString *)text fraction:(double)f {
    void (^progress)(NSString *, double) = _progress;
    dispatch_async(dispatch_get_main_queue(), ^{ progress(text, f); });
}

- (void)runTiming:(BOOL)timing maxLevel:(BOOL)maxLevel volume:(BOOL)volume
         progress:(void (^)(NSString *, double))progress
       completion:(void (^)(NSDictionary *, NSString *))completion {
    _running = YES;
    atomic_store(&_cancel, false);
    _progress = progress;
    void (^finish)(NSDictionary *, NSString *) = ^(NSDictionary *result, NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_running = NO;
            [self->_app setCalibrating:NO];
            completion(result, error);
        });
    };
    // Mikrofon-Freigabe: macOS fragt beim ersten Mal nach
    void (^start)(void) = ^{
        [self->_app setCalibrating:YES];
        AudioObjectID mic = [self->_app measurementMicrophone];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *error = nil;
            NSDictionary *result = [self measureWithMicrophone:mic timing:timing maxLevel:maxLevel volume:volume error:&error];
            finish(result, error);
        });
    };
    if (@available(macOS 10.14, *)) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
            finish(nil, L(@"Kein Zugriff auf das Mikrofon. Erlaube ihn unter Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon."));
            return;
        }
        if (status == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (granted) start();
                    else finish(nil, L(@"Kein Zugriff auf das Mikrofon. Erlaube ihn unter Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon."));
                });
            }];
            return;
        }
    }
    start();
}

- (NSDictionary *)measureWithMicrophone:(AudioObjectID)mic timing:(BOOL)timing maxLevel:(BOOL)maxLevel
                                 volume:(BOOL)volume error:(NSString **)error {
    if (!mic) { *error = L(@"Kein Mikrofon gefunden. Schließe eines an und versuche es erneut."); return nil; }
    // Engine muss laufen (nach dem Ruhemodus startet sie gerade neu)
    for (int i = 0; i < 40 && ![self onMain:^BOOL { return [self->_app engineActive]; }]; i++) usleep(100000);
    unsigned cycles = [_app ioCycles];
    usleep(300000);
    if ([_app ioCycles] == cycles) KickEngine();   // steht still, solange nichts spielt
    for (int i = 0; i < 30 && [_app ioCycles] == cycles; i++) usleep(100000);
    if (![self onMain:^BOOL { return [self->_app engineActive]; }] || [_app ioCycles] == cycles) {
        *error = L(@"Der Bass läuft gerade nicht. Schalte JumpBass ein und wähle eine Ausgabe, bei der der BassJump mitspielt.");
        return nil;
    }
    _outRate = [_app outputSampleRate];
    _mic = [[MicRecorder alloc] init];
    OSStatus err = [_mic startWithDevice:mic];
    usleep(400000);
    if (err || [_mic position] < _mic.rate * 0.2) {
        [_mic stop];
        *error = [NSString stringWithFormat:L(@"Das Mikrofon liefert keinen Ton (Fehler %d)."), (int)err];
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [self report:L(@"Messe die Ruhe im Raum …") fraction:0.02];
    NSData *quiet = [self recordSpeaker:NULL bass:NULL raw:NO seconds:1.2 from:0.4 to:1.0];
    if (!quiet) { *error = [self interrupted]; [_mic stop]; return nil; }

    if (timing && ![self measureTimingInto:result error:error]) { [_mic stop]; return nil; }
    if (maxLevel && ![self measureMaxLevelInto:result quiet:quiet error:error]) { [_mic stop]; return nil; }
    if (volume && ![self measureVolumeInto:result error:error]) { [_mic stop]; return nil; }
    [_mic stop];
    return result;
}

- (BOOL)onMain:(BOOL (^)(void))block {
    __block BOOL r;
    dispatch_sync(dispatch_get_main_queue(), ^{ r = block(); });
    return r;
}

// Spielt ein Testsignal (Länge seconds) und liefert die Aufnahme zwischen from und to Sekunden nach dem Start.
// speaker/bass werden mit der Ausgaberate erzeugt (Block bekommt Puffer und Rate), NULL = Stille.
- (NSData *)recordSpeaker:(void (^)(float *, double))speaker bass:(void (^)(float *, double))bass raw:(BOOL)raw
                  seconds:(double)seconds from:(double)from to:(double)to {
    if ([self cancelled]) return nil;
    UInt32 frames = (UInt32)(seconds * _outRate);
    // Bis zum Ende des Abspielens festhalten: der IOProc liest direkt aus diesen Puffern
    __attribute__((objc_precise_lifetime)) NSMutableData *spk = speaker ? [NSMutableData dataWithLength:frames * sizeof(float)] : nil;
    __attribute__((objc_precise_lifetime)) NSMutableData *bs = bass ? [NSMutableData dataWithLength:frames * sizeof(float)] : nil;
    if (speaker) speaker(spk.mutableBytes, _outRate);
    if (bass) bass(bs.mutableBytes, _outRate);
    __block UInt64 micStart = 0;
    BOOL ok = [self onMain:^BOOL {
        micStart = [self->_mic position];
        return [self->_app playTestSpeaker:spk.mutableBytes bass:bs.mutableBytes frames:frames raw:raw];
    }];
    if (getenv("JUMPBASS_DEBUG") && !ok) NSLog(@"Testsignal abgelehnt (Engine aktiv %d)", [self onMain:^BOOL { return [self->_app engineActive]; }]);
    if (!ok) { _failure = L(@"Bass-Ausgabe nicht bereit"); return nil; }
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + seconds + 3;
    // Die Puffer erst freigeben, wenn der IOProc fertig ist – auch bei Abbruch
    while ([_app testPlaying] && CFAbsoluteTimeGetCurrent() < deadline) usleep(10000);
    if ([_app testPlaying]) { _failure = L(@"Testsignal wurde nicht abgespielt"); return nil; }
    UInt64 start = micStart + (UInt64)(from * _mic.rate), count = (UInt64)((to - from) * _mic.rate);
    for (int i = 0; i < 100 && [_mic position] < start + count; i++) usleep(20000);
    NSData *rec = [self cancelled] ? nil : [_mic framesFrom:start count:count];
    if (!rec) _failure = L(@"Mikrofon liefert keine Daten mehr");
    if (getenv("JUMPBASS_DEBUG") && !rec) NSLog(@"Aufnahme fehlgeschlagen: %@", _failure);
    return rec;
}

#pragma mark Bass-Timing

// Lautsprecher spielen einen kurzen hohen Sweep, 0,6 s später der BassJump einen tiefen. Aus dem Abstand der
// beiden im Mikrofon ergibt sich, wie weit der Bass gegenüber dem beabsichtigten Abstand verrutscht ist.
- (BOOL)measureTimingInto:(NSMutableDictionary *)result error:(NSString **)error {
    const double kAt = 0.1, kGap = 0.6, kSpkDur = 0.15, kBassDur = 0.5;
    NSMutableArray<NSNumber *> *residuals = [NSMutableArray array];
    double worstSpk = INFINITY, worstBass = INFINITY;
    const int kRuns = 8;
    for (int run = 0; run < kRuns; run++) {
        [self report:[NSString stringWithFormat:L(@"Bass-Timing: Messung %d von %d …"), run + 1, kRuns] fraction:0.03 + 0.32 * run / kRuns];
        NSData *rec = [self recordSpeaker:^(float *b, double rate) { AddChirp(b, rate, kAt, 1500, 6000, kSpkDur, 0.3f); }
                                     bass:^(float *b, double rate) { AddChirp(b, rate, kAt + kGap, 45, 110, kBassDur, 0.2f); }
                                      raw:NO seconds:1.5 from:0 to:1.8];
        if (!rec) { *error = [self interrupted]; return NO; }
        double rate = _mic.rate;
        NSMutableData *refS = [NSMutableData dataWithLength:(size_t)(kSpkDur * rate) * sizeof(float)];
        NSMutableData *refB = [NSMutableData dataWithLength:(size_t)(kBassDur * rate) * sizeof(float)];
        AddChirp(refS.mutableBytes, rate, 0, 1500, 6000, kSpkDur, 1);
        AddChirp(refB.mutableBytes, rate, 0, 45, 110, kBassDur, 1);
        size_t n = rec.length / sizeof(float);
        double snrS, snrB;
        double ts = PeakIn(CorrelationEnvelope(rec.bytes, n, refS.bytes, refS.length / sizeof(float)), 0, (size_t)(0.9 * rate), &snrS);
        size_t lo = (size_t)MAX(0.0, ts + (kGap - 0.15) * rate), hi = (size_t)(ts + (kGap + 0.15) * rate);
        double tb = PeakIn(CorrelationEnvelope(rec.bytes, n, refB.bytes, refB.length / sizeof(float)), lo, hi, &snrB);
        worstSpk = fmin(worstSpk, snrS);
        worstBass = fmin(worstBass, snrB);
        if (snrS < 6 || snrB < 3) continue;   // diese Wiederholung war gestört
        [residuals addObject:@(((tb - ts) / rate - kGap) * 1000)];
    }
    if (getenv("JUMPBASS_DEBUG")) NSLog(@"Timing: Abweichungen %@ ms, Abstand zum Rauschen Lautsprecher %.1f, Bass %.1f", residuals, worstSpk, worstBass);
    if (residuals.count < kRuns / 2) {
        *error = worstSpk < 6 ? L(@"Die Lautsprecher waren im Mikrofon kaum zu hören. Stell die Lautstärke etwas höher und versuche es erneut.")
                              : L(@"Der BassJump war im Mikrofon kaum zu hören. Stell ihn näher an den Mac und versuche es erneut.");
        return NO;
    }
    // Median, dann alles verwerfen, was mehr als 3 ms davon abweicht, und den Rest mitteln
    NSArray *sorted = [residuals sortedArrayUsingSelector:@selector(compare:)];
    double median = [sorted[sorted.count / 2] doubleValue], sum = 0, lo = INFINITY, hi = -INFINITY;
    int used = 0;
    for (NSNumber *r in sorted) {
        if (fabs(r.doubleValue - median) > 3) continue;
        sum += r.doubleValue; used++;
        lo = fmin(lo, r.doubleValue); hi = fmax(hi, r.doubleValue);
    }
    median = sum / used;
    double spread = hi - lo;
    double current = [_app.defaults doubleForKey:@"bassOffsetMs"];
    // Abweichung > 0: Bass kommt zu spät an -> früher schicken
    double offset = MAX(-100, MIN(200, round(current - median)));
    result[@"offsetMs"] = @(offset);
    result[@"timingSpreadMs"] = @(round(spread * 10) / 10);
    return YES;
}

#pragma mark Maximalpegel

// Tieftöne in steigendem Pegel direkt auf den BassJump (ohne Begrenzer). Übersteuert der Verstärker, springt der
// Anteil oberhalb von 1 kHz sprunghaft nach oben (Knacken, Verzerrung) und der Ton wächst kaum noch mit.
// Am BassJump 2 gemessen: bei 45, 60 und 80 Hz übereinstimmend ab -10 dBFS.
- (BOOL)measureMaxLevelInto:(NSMutableDictionary *)result quiet:(NSData *)quiet error:(NSString **)error {
    NSArray<NSNumber *> *levels = @[@-20, @-17, @-15, @-14, @-13, @-12, @-11, @-10, @-9, @-8, @-7];
    NSArray<NSNumber *> *freqs = @[@45, @60, @80];
    double rate = _mic.rate, quietHF = HighBandRMS(quiet, rate);
    double clip = INFINITY;
    NSUInteger step = 0, steps = levels.count * freqs.count;
    for (NSNumber *f in freqs) {
        double quietTone = ToneAmplitude(quiet, rate, f.doubleValue);
        double prevTone = NAN, prevCrackle = NAN, prevLevel = NAN;
        for (NSNumber *level in levels) {
            if (level.doubleValue >= clip) break;   // über der schon gefundenen Grenze nicht weiter quälen
            [self report:[NSString stringWithFormat:L(@"Maximalpegel: %@ Hz bei %@ dB …"), f, level] fraction:0.4 + 0.4 * step++ / steps];
            float amp = powf(10, level.floatValue / 20);
            // Der Anteil über 1 kHz wächst normalerweise im gleichen Maß wie der Pegel (Eigenklang des BassJump).
            // Übersteuern zeigt sich als Sprung weit darüber. Ein Sprung zählt erst, wenn er sich bei einer
            // Wiederholung bestätigt – ein Geräusch im Raum reicht nicht.
            double stepDB = level.doubleValue - prevLevel;
            double tone = 0, crackle = INFINITY;
            for (int attempt = 0; attempt < 2 && (attempt == 0 || crackle - prevCrackle - stepDB > 5); attempt++) {
                NSData *rec = [self recordSpeaker:NULL bass:^(float *b, double r) { AddTone(b, r, 0, f.doubleValue, 1.0, amp); }
                                              raw:YES seconds:1.1 from:0.3 to:0.95];
                if (!rec) { *error = [self interrupted]; return NO; }
                tone = DB(ToneAmplitude(rec, rate, f.doubleValue)) - DB(quietTone);
                crackle = fmin(crackle, DB(HighBandRMS(rec, rate)) - DB(quietHF));
                usleep(200000);
            }
            if (getenv("JUMPBASS_DEBUG")) NSLog(@"Maximalpegel %@ Hz %@ dB: Ton +%.1f dB, Anteil >1 kHz +%.1f dB", f, level, tone, crackle);
            if ([level isEqual:levels.firstObject] && tone < 10) {
                *error = L(@"Der BassJump war im Mikrofon kaum zu hören. Stell ihn näher an den Mac und versuche es erneut.");
                return NO;
            }
            BOOL jump = crackle - prevCrackle - stepDB > 5 && crackle > 3;   // beim ersten Pegel (NaN) nie
            BOOL saturated = tone - prevTone < 0.4 * stepDB;
            if (jump || saturated) { clip = level.doubleValue; break; }
            prevTone = tone; prevCrackle = crackle; prevLevel = level.doubleValue;
        }
    }
    // 1 dB unter der Grenze; nie über der festen Obergrenze
    double maxLevel = isfinite(clip) ? fmin(clip - 1, kHardwareCeilingDB) : kHardwareCeilingDB;
    if (isfinite(clip)) result[@"clipDB"] = @(clip);
    result[@"maxLevelDB"] = @(maxLevel);
    return YES;
}

#pragma mark Lautstärkekurve (externe Monitore)

static void PostVolumeKey(BOOL up) {
    int key = up ? 0 : 1;   // NX_KEYTYPE_SOUND_UP / NX_KEYTYPE_SOUND_DOWN
    for (int down = 1; down >= 0; down--) {
        NSEvent *e = [NSEvent otherEventWithType:NSEventTypeSystemDefined location:NSZeroPoint modifierFlags:(down ? 0xa00 : 0xb00)
                                       timestamp:0 windowNumber:0 context:nil subtype:8
                                           data1:((key << 16) | ((down ? 0xa : 0xb) << 8)) data2:-1];
        CGEventPost(kCGHIDEventTap, e.CGEvent);
        usleep(40000);
    }
}

- (float)monitorVolume { __block float v; dispatch_sync(dispatch_get_main_queue(), ^{ v = [self->_app monitorVolume]; }); return v; }

- (float)pressVolume:(BOOL)up times:(int)n {
    for (int i = 0; i < n; i++) { dispatch_sync(dispatch_get_main_queue(), ^{ PostVolumeKey(up); }); usleep(80000); }
    usleep(1200000);   // bis der Monitor umgestellt und der neue Wert gelesen ist
    return [self monitorVolume];
}

// Die Lautstärketasten verstellen den Monitor über die Monitor-App (MonitorControl, BetterDisplay …); ein leiser 1-kHz-Ton auf den Lautsprechern
// zeigt, wie stark der Pegel je Schritt steigt. Danach zurück auf die Ausgangslautstärke.
- (BOOL)measureVolumeInto:(NSMutableDictionary *)result error:(NSString **)error {
    double rate = _mic.rate;
    float start = [self monitorVolume];
    if (start < 0) return YES;
    NSMutableArray<NSArray<NSNumber *> *> *points = [NSMutableArray array];
    int pressed = 0;
    float v = start, step = 0;
    const int kPoints = 8;
    for (int i = 0; i < kPoints; i++) {
        [self report:[NSString stringWithFormat:L(@"Lautstärkekurve: %.0f %% …"), v * 100] fraction:0.82 + 0.15 * i / kPoints];
        double level = 0;
        int got = 0;
        for (int k = 0; k < 2; k++) {   // je Stufe zweimal messen und mitteln
            NSData *rec = [self recordSpeaker:^(float *b, double r) { AddTone(b, r, 0, 1000, 0.8, 0.06f); }
                                         bass:NULL raw:NO seconds:0.9 from:0.3 to:0.75];
            if (rec) { level += DB(ToneAmplitude(rec, rate, 1000)); got++; }
        }
        if (!got) break;
        [points addObject:@[@(v), @(level / got)]];
        if (i == kPoints - 1 || v > start + 0.45f || v > 0.8f) break;
        // Schrittweite beim ersten Tastendruck bestimmen, dann je etwa 6 %
        int presses = step > 0 ? MAX(1, (int)lroundf(0.06f / step)) : 1;
        float next = [self pressVolume:YES times:presses];
        pressed += presses;
        if (step == 0) step = next - v;
        if (next <= v + 0.001f) break;
        v = next;
    }
    if (pressed) [self pressVolume:NO times:pressed];
    if ([self cancelled]) return NO;
    if (points.count < 4) {
        *error = L(@"Die Monitor-Lautstärke ließ sich nicht verstellen. Prüfe, ob eine App wie MonitorControl, BetterDisplay oder Lunar die Lautstärketasten an den Monitor weitergibt und JumpBass unter Bedienungshilfen freigegeben ist.");
        return NO;
    }
    // Pegel in dB gegen 20·log10(Lautstärke): Die Steigung ist der Exponent (1 = Schalldruck proportional zur Einstellung)
    double sx = 0, sy = 0, sxx = 0, sxy = 0, n = points.count;
    for (NSArray *p in points) {
        double x = 20 * log10(fmax([p[0] doubleValue], 0.001)), y = [p[1] doubleValue];
        sx += x; sy += y; sxx += x * x; sxy += x * y;
    }
    double exponent = (n * sxy - sx * sy) / (n * sxx - sx * sx);
    if (getenv("JUMPBASS_DEBUG")) NSLog(@"Lautstärkekurve %@ -> Exponent %.2f", points, exponent);
    if (!isfinite(exponent) || exponent < 0.3 || exponent > 3) {
        *error = L(@"Die Lautstärkekurve ließ sich nicht sicher messen. Bitte im Raum still sein und erneut versuchen.");
        return NO;
    }
    result[@"volumeExponent"] = @(round(exponent * 100) / 100);
    return YES;
}

@end
