// JumpBass Revived
//
// Ersatz für die eingestellte Twelve South BassJump 2 Software.
// Der BassJump ist ein USB-Audio-Class-Gerät (C-Media, VID 0x0D8C / PID 0x013A),
// das macOS ohne Treiber erkennt. Die Frequenzweiche, die früher im HAL-Plugin
// lief, rechnet jetzt diese Menüleisten-App:
//
//   macOS 14.2+   Core-Audio-Process-Tap (Systemton) -> Tiefpass -> BassJump
//   macOS 10.13+  Loopback-Gerät (z.B. BlackHole) -> Lautsprecher + Tiefpass -> BassJump
//
// Beide Wege laufen über ein privates Aggregate-Device mit Drift-Kompensation,
// damit die getrennten Uhren von Mac-Lautsprechern und BassJump synchron bleiben.

#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <ServiceManagement/ServiceManagement.h>
#include <stdatomic.h>
#include <math.h>
#import "JumpBassRevived.h"

static NSString *const kAggregateUIDPrefix = @"io.github.jumpbassrevived.aggregate";
static NSString *const kSourceSystemTap = @"__systemtap__";
NSString *const kGateAlways = @"__always__";
static NSString *const kPassNone = @"__none__";
static NSString *const kLaunchAgentLabel = @"io.github.jumpbassrevived";
static UInt32 kBufferFrames = 128;
static const CFTimeInterval kIdleSeconds = 10;   // Stille, nach der der BassJump in den Ruhemodus geht
static const float kSilenceThreshold = 0.0001f;  // -80 dBFS
static const CFTimeInterval kRetrySeconds = 10;  // erneuter Startversuch nach einem Fehler
static const NSTimeInterval kUpdateCheckInterval = 24 * 3600;
static NSString *const kReleasesURL = @"https://github.com/klehart/JumpBass-revived/releases/latest";
static NSString *const kLatestReleaseAPI = @"https://api.github.com/repos/klehart/JumpBass-revived/releases/latest";

#pragma mark - Echtzeit-DSP

#define kRingSize 65536 // Zweierpotenz, reicht auch bei 192 kHz für >300 ms Verzögerung

typedef struct {
    double b0, b1, b2, a1, a2;
} BiquadCoefs;

typedef struct {
    double x1, x2, y1, y2;
} BiquadState;

#define kLookaheadRing 2048 // Zweierpotenz, reicht für die Vorausschau des Begrenzers bis 192 kHz

typedef struct {
    UInt32 lookahead;   // Vorausschau in Frames
    UInt32 hold;        // Haltezeit der Hüllkurve in Frames
    float attack;       // Annäherung der Verstärkung pro Frame beim Absenken
    float release;      // Abklingfaktor der Hüllkurve pro Frame nach der Haltezeit
} LimiterParams;

typedef struct {
    BiquadCoefs coefs, hpCoefs;               // nur im IOProc gelesen
    BiquadCoefs pendingCoefs, pendingHpCoefs; // vom Main-Thread geschrieben
    int hpOn, pendingHpOn;
    LimiterParams lim, pendingLim;
    atomic_uint coefsSeq;       // Seqlock: ungerade = Main-Thread schreibt gerade die pending-Werte
    unsigned appliedSeq;        // zuletzt übernommene Version, nur im IOProc
    BiquadState stage1, stage2; // Linkwitz-Riley 4. Ordnung = 2x Butterworth 2. Ordnung
    BiquadState hpStage;        // Tiefbass-Schutz: Hochpass gegen Frequenzen, die der kleine Treiber nicht schafft
    _Atomic float limitLevel;   // Obergrenze des Begrenzers (linear)
    _Atomic float targetGain;
    float currentGain;

    // Begrenzer mit Vorausschau: Der Bass läuft ein paar Millisekunden verzögert, damit die Verstärkung schon
    // abgesenkt ist, wenn eine Spitze ankommt. Sofortiges Absenken knickt die Wellenform (hörbar als Knacken),
    // schnelles Lösen moduliert jede Bass-Schwingung (hörbar als Verzerrung) – beides vermeidet er.
    float limEnv, limGain;
    UInt32 limHoldLeft, laPos;
    float laRing[kLookaheadRing];
    _Atomic float limMinGain;   // stärkste Absenkung seit der letzten Abfrage (Diagnose, Anzeige)

    _Atomic float peak;         // für die Pegelanzeige im Menü
    _Atomic float uiPeak;       // für das VU-Meter im Fenster
    _Atomic float inputPeak;    // Eingangspegel, erkennt Stille für den Ruhemodus
    _Atomic double ioDelayMs;   // Abstand Eingangs- zu Ausgangszeitstempel (Diagnose)

    // Laufzeitausgleich zwischen Lautsprechern und BassJump (in Frames, je einer davon ist 0)
    atomic_int bassDelay, passDelay;
    UInt32 writePos;
    float bassRing[kRingSize];
    float passRing[kRingSize * 2];

    // Kalibrierung: Testsignale statt Systemton. Der Main-Thread setzt Zeiger und testPos, zuletzt testFrames;
    // der IOProc spielt sie einmal ab und setzt testFrames danach auf 0.
    const float *testSpeaker, *testBass;
    UInt32 testPos;
    int testRaw;                // 1 = Bass ohne Filter, Pegel und Begrenzer (Messung der Übersteuerung)
    _Atomic UInt32 testFrames;
    atomic_uint ioCycles;       // Aufrufe des IOProc (Diagnose)

    // Puffer-Layout des Aggregate-Devices
    UInt32 inputBuffer;
    UInt32 passFirst, passCount; // Durchleitung des vollen Signals an die Lautsprecher
    UInt32 bassFirst, bassCount; // BassJump-Ausgänge
} BassEngine;

static BiquadCoefs LowpassCoefs(double freq, double sampleRate) {
    double w0 = 2.0 * M_PI * freq / sampleRate;
    double cosw = cos(w0);
    double alpha = sin(w0) / (2.0 * M_SQRT1_2);
    double a0 = 1.0 + alpha;
    BiquadCoefs c;
    c.b0 = ((1.0 - cosw) / 2.0) / a0;
    c.b1 = (1.0 - cosw) / a0;
    c.b2 = c.b0;
    c.a1 = (-2.0 * cosw) / a0;
    c.a2 = (1.0 - alpha) / a0;
    return c;
}

static BiquadCoefs HighpassCoefs(double freq, double sampleRate) {
    double w0 = 2.0 * M_PI * freq / sampleRate;
    double cosw = cos(w0);
    double alpha = sin(w0) / (2.0 * M_SQRT1_2);
    double a0 = 1.0 + alpha;
    BiquadCoefs c;
    c.b0 = ((1.0 + cosw) / 2.0) / a0;
    c.b1 = -(1.0 + cosw) / a0;
    c.b2 = c.b0;
    c.a1 = (-2.0 * cosw) / a0;
    c.a2 = (1.0 - alpha) / a0;
    return c;
}

static inline double BiquadProcess(const BiquadCoefs *c, BiquadState *s, double x) {
    double y = c->b0 * x + c->b1 * s->x1 + c->b2 * s->x2 - c->a1 * s->y1 - c->a2 * s->y2;
    s->x2 = s->x1; s->x1 = x;
    s->y2 = s->y1; s->y1 = y;
    return y;
}

// Ausklingende Filterzustände rechtzeitig auf 0 setzen, bevor sie in den langsamen Denormal-Bereich fallen.
static inline void BiquadFlush(BiquadState *s) {
    if (fabs(s->x1) < 1e-30) s->x1 = 0;
    if (fabs(s->x2) < 1e-30) s->x2 = 0;
    if (fabs(s->y1) < 1e-30) s->y1 = 0;
    if (fabs(s->y2) < 1e-30) s->y2 = 0;
}

static OSStatus BassIOProc(AudioObjectID device, const AudioTimeStamp *now,
                           const AudioBufferList *inData, const AudioTimeStamp *inTime,
                           AudioBufferList *outData, const AudioTimeStamp *outTime,
                           void *clientData) {
    BassEngine *e = (BassEngine *)clientData;
    if (inTime && outTime && (inTime->mFlags & kAudioTimeStampHostTimeValid) && (outTime->mFlags & kAudioTimeStampHostTimeValid)) {
        atomic_store(&e->ioDelayMs, (AudioConvertHostTimeToNanos(outTime->mHostTime) - (double)AudioConvertHostTimeToNanos(inTime->mHostTime)) / 1e6);
    }

    // Neue Filterwerte nur übernehmen, wenn sie vollständig geschrieben sind; sonst im nächsten Puffer.
    unsigned seq = atomic_load_explicit(&e->coefsSeq, memory_order_acquire);
    if (seq != e->appliedSeq && !(seq & 1)) {
        BiquadCoefs lp = e->pendingCoefs, hp = e->pendingHpCoefs;
        int hpOn = e->pendingHpOn;
        LimiterParams lim = e->pendingLim;
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&e->coefsSeq, memory_order_relaxed) == seq) {
            e->coefs = lp;
            e->hpCoefs = hp;
            e->hpOn = hpOn;
            e->lim = lim;
            e->appliedSeq = seq;
        }
    }
    const LimiterParams lim = e->lim;
    UInt32 lookahead = MIN(lim.lookahead, kLookaheadRing - 1);
    float limit = atomic_load(&e->limitLevel);
    UInt32 testFrames = atomic_load_explicit(&e->testFrames, memory_order_acquire);
    atomic_fetch_add_explicit(&e->ioCycles, 1, memory_order_relaxed);

    // Liefert der Systemton gerade keinen Puffer (nichts spielt), laufen nur Testsignale – mit der Länge der Ausgabe
    const float *src = NULL;
    UInt32 inCh = 1, frames = 0;
    if (inData && e->inputBuffer < inData->mNumberBuffers) {
        const AudioBuffer *in = &inData->mBuffers[e->inputBuffer];
        if (in->mData && in->mNumberChannels) {
            src = (const float *)in->mData;
            inCh = in->mNumberChannels;
            frames = in->mDataByteSize / (sizeof(float) * inCh);
        }
    }
    if (!src) {
        if (!testFrames || e->bassFirst >= outData->mNumberBuffers) return noErr;
        const AudioBuffer *out = &outData->mBuffers[e->bassFirst];
        frames = out->mNumberChannels ? out->mDataByteSize / (sizeof(float) * out->mNumberChannels) : 0;
    }

    // Mono-Summe -> LR4-Tiefpass -> Pegel -> BassJump; volles Signal -> Lautsprecher.
    // Beide Wege laufen durch Verzögerungsringe, damit sie gleichzeitig am Ohr ankommen.
    float target = atomic_load(&e->targetGain);
    float gain = e->currentGain;
    float peak = 0.0f, inPeak = 0.0f, minGain = 1.0f;
    UInt32 bassDelay = (UInt32)MIN(MAX(atomic_load(&e->bassDelay), 0), kRingSize - 1);
    UInt32 passDelay = (UInt32)MIN(MAX(atomic_load(&e->passDelay), 0), kRingSize - 1);
    UInt32 bassEnd = MIN(e->bassFirst + e->bassCount, outData->mNumberBuffers);
    UInt32 passEnd = MIN(e->passFirst + e->passCount, outData->mNumberBuffers);

    for (UInt32 i = 0; i < frames; i++) {
        float l = src ? src[i * inCh] : 0.0f;
        float r = src && inCh > 1 ? src[i * inCh + 1] : l;
        inPeak = fmaxf(inPeak, fmaxf(fabsf(l), fabsf(r)));
        double mono = 0.5 * ((double)l + r);
        float testBass = 0.0f;
        if (testFrames) {
            BOOL playing = e->testPos < testFrames;
            l = r = playing && e->testSpeaker ? e->testSpeaker[e->testPos] : 0.0f;
            mono = testBass = playing && e->testBass ? e->testBass[e->testPos] : 0.0f;
            e->testPos++;
        }
        double y = BiquadProcess(&e->coefs, &e->stage1, mono);
        y = BiquadProcess(&e->coefs, &e->stage2, y);
        if (e->hpOn) y = BiquadProcess(&e->hpCoefs, &e->hpStage, y);
        gain += (target - gain) * 0.0005f;
        float v = (float)(y * (testFrames ? 1.0f : gain));   // Testsignale mit festem Pegel

        // Hüllkurve hält den Spitzenwert länger als eine Bass-Schwingung und klingt erst danach ab.
        float a = fabsf(v);
        if (a >= e->limEnv) { e->limEnv = a; e->limHoldLeft = lim.hold; }
        else if (e->limHoldLeft) e->limHoldLeft--;
        else e->limEnv *= lim.release;
        float want = e->limEnv > limit ? limit / e->limEnv : 1.0f;
        e->limGain = want < e->limGain ? e->limGain + (want - e->limGain) * lim.attack : want;
        minGain = fminf(minGain, e->limGain);
        UInt32 la = e->laPos++ & (kLookaheadRing - 1);
        e->laRing[la] = v;
        v = e->laRing[(la - lookahead) & (kLookaheadRing - 1)] * e->limGain;
        if (v > limit) v = limit;                 // Reste der Annäherung (<1 %) sicher abfangen
        else if (v < -limit) v = -limit;
        if (testFrames && e->testRaw) v = fmaxf(-1.0f, fminf(1.0f, testBass));
        if (fabsf(v) > peak) peak = fabsf(v);

        UInt32 w = e->writePos++ & (kRingSize - 1);
        e->bassRing[w] = v;
        e->passRing[w * 2] = l;
        e->passRing[w * 2 + 1] = r;
        float bass = e->bassRing[(w - bassDelay) & (kRingSize - 1)];
        UInt32 p = (w - passDelay) & (kRingSize - 1);

        for (UInt32 b = e->bassFirst; b < bassEnd; b++) {
            AudioBuffer *out = &outData->mBuffers[b];
            UInt32 ch = out->mNumberChannels;
            if (!out->mData || ch == 0 || i >= out->mDataByteSize / (sizeof(float) * ch)) continue;
            float *dst = (float *)out->mData;
            for (UInt32 c = 0; c < ch; c++) dst[i * ch + c] = bass;
        }
        for (UInt32 b = e->passFirst; b < passEnd; b++) {
            AudioBuffer *out = &outData->mBuffers[b];
            UInt32 ch = out->mNumberChannels;
            if (!out->mData || ch == 0 || i >= out->mDataByteSize / (sizeof(float) * ch)) continue;
            float *dst = (float *)out->mData;
            for (UInt32 c = 0; c < ch; c++) dst[i * ch + c] = e->passRing[p * 2 + MIN(c, 1)];
        }
    }
    e->currentGain = gain;
    if (testFrames && e->testPos >= testFrames) atomic_store_explicit(&e->testFrames, 0, memory_order_release);
    BiquadFlush(&e->stage1);
    BiquadFlush(&e->stage2);
    BiquadFlush(&e->hpStage);
    if (minGain < atomic_load(&e->limMinGain)) atomic_store(&e->limMinGain, minGain);
    if (peak > atomic_load(&e->peak)) atomic_store(&e->peak, peak);
    if (peak > atomic_load(&e->uiPeak)) atomic_store(&e->uiPeak, peak);
    if (inPeak > atomic_load(&e->inputPeak)) atomic_store(&e->inputPeak, inPeak);
    return noErr;
}

#pragma mark - Core-Audio-Hilfsfunktionen

static AudioObjectPropertyAddress Addr(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope, AudioObjectPropertyElement el) {
    AudioObjectPropertyAddress a = { sel, scope, el };
    return a;
}

static NSArray<NSNumber *> *AllDevices(void) {
    AudioObjectPropertyAddress a = Addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != noErr) return @[];
    UInt32 count = size / sizeof(AudioObjectID);
    AudioObjectID *ids = calloc(count, sizeof(AudioObjectID));
    NSMutableArray *result = [NSMutableArray array];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids) == noErr) {
        for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) [result addObject:@(ids[i])];
    }
    free(ids);
    return result;
}

static NSString *DeviceString(AudioObjectID dev, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = Addr(sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    CFStringRef s = NULL;
    UInt32 size = sizeof(s);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &s) != noErr || !s) return nil;
    return CFBridgingRelease(s);
}

NSString *DeviceUID(AudioObjectID dev) { return DeviceString(dev, kAudioDevicePropertyDeviceUID); }
NSString *DeviceName(AudioObjectID dev) { return DeviceString(dev, kAudioObjectPropertyName) ?: @"?"; }

static UInt32 DeviceUInt32(AudioObjectID dev, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = Addr(sel, scope, kAudioObjectPropertyElementMain);
    UInt32 v = 0, size = sizeof(v);
    AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &v);
    return v;
}

static UInt32 StreamCount(AudioObjectID dev, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr) return 0;
    return size / sizeof(AudioStreamID);
}

static UInt32 ChannelCount(AudioObjectID dev, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr || size == 0) return 0;
    AudioBufferList *list = malloc(size);
    UInt32 channels = 0;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, list) == noErr) {
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) channels += list->mBuffers[i].mNumberChannels;
    }
    free(list);
    return channels;
}

static AudioObjectID DeviceForUID(NSString *uid) {
    if (!uid) return kAudioObjectUnknown;
    for (NSNumber *n in AllDevices()) {
        if ([DeviceUID(n.unsignedIntValue) isEqualToString:uid]) return n.unsignedIntValue;
    }
    return kAudioObjectUnknown;
}

static AudioObjectID DefaultDevice(AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = Addr(sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev);
    return dev;
}

static void SetDefaultDevice(AudioObjectPropertySelector sel, AudioObjectID dev) {
    AudioObjectPropertyAddress a = Addr(sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof(dev), &dev);
}

static AudioObjectID DefaultOutputDevice(void) { return DefaultDevice(kAudioHardwarePropertyDefaultOutputDevice); }

static Float64 SampleRate(AudioObjectID dev) {
    AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &rate);
    return rate;
}

// Gleiche Abtastrate wie die Quelle erspart der Drift-Kompensation die Umrechnung und damit Latenz.
static void MatchSampleRate(AudioObjectID dev, Float64 rate) {
    if (!dev || rate <= 0 || SampleRate(dev) == rate) return;
    AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) != noErr || size == 0) return;
    AudioValueRange *ranges = malloc(size);
    BOOL supported = NO;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, ranges) == noErr) {
        for (UInt32 i = 0; i < size / sizeof(AudioValueRange); i++) {
            if (rate >= ranges[i].mMinimum && rate <= ranges[i].mMaximum) supported = YES;
        }
    }
    free(ranges);
    if (!supported) return;
    a.mSelector = kAudioDevicePropertyNominalSampleRate;
    AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(rate), &rate);
    for (int i = 0; i < 50 && SampleRate(dev) != rate; i++) usleep(10000);
}

static void SetBufferFrames(AudioObjectID dev, UInt32 frames) {
    AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    AudioValueRange range = { frames, frames };
    UInt32 size = sizeof(range);
    AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &range);
    frames = (UInt32)MAX(range.mMinimum, MIN(range.mMaximum, frames));
    a.mSelector = kAudioDevicePropertyBufferFrameSize;
    AudioObjectSetPropertyData(dev, &a, 0, NULL, sizeof(frames), &frames);
}

static BOOL IsOwnAggregate(AudioObjectID dev) {
    return [DeviceUID(dev) hasPrefix:kAggregateUIDPrefix];
}

NSArray<NSNumber *> *OutputDevices(void) {
    NSMutableArray *r = [NSMutableArray array];
    for (NSNumber *n in AllDevices()) {
        if (!IsOwnAggregate(n.unsignedIntValue) && ChannelCount(n.unsignedIntValue, kAudioObjectPropertyScopeOutput) > 0) [r addObject:n];
    }
    return r;
}

static NSArray<NSNumber *> *InputDevices(void) {
    NSMutableArray *r = [NSMutableArray array];
    for (NSNumber *n in AllDevices()) {
        if (!IsOwnAggregate(n.unsignedIntValue) && ChannelCount(n.unsignedIntValue, kAudioObjectPropertyScopeInput) > 0) [r addObject:n];
    }
    return r;
}

BOOL LooksLikeBassJump(AudioObjectID dev) {
    NSString *name = [[DeviceName(dev) lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
    if ([name containsString:@"bassjump"]) return YES;
    NSString *ids = [[NSString stringWithFormat:@"%@ %@", DeviceUID(dev) ?: @"", DeviceString(dev, kAudioDevicePropertyModelUID) ?: @""] lowercaseString];
    return [ids containsString:@"d8c"] && [ids containsString:@"13a"];
}

static AudioObjectID BuiltInSpeakers(void) {
    for (NSNumber *n in OutputDevices()) {
        if (DeviceUInt32(n.unsignedIntValue, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeBuiltIn) return n.unsignedIntValue;
    }
    return kAudioObjectUnknown;
}

// Eingebautes Mikrofon, sonst das erste Mikrofon, das nicht der BassJump ist
static AudioObjectID FallbackMicrophone(AudioObjectID bassJump) {
    AudioObjectID first = kAudioObjectUnknown;
    for (NSNumber *n in InputDevices()) {
        AudioObjectID dev = n.unsignedIntValue;
        if (dev == bassJump || LooksLikeBassJump(dev)) continue;
        if (DeviceUInt32(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeBuiltIn) return dev;
        if (!first) first = dev;
    }
    return first;
}

// Monitore ohne macOS-Lautstärke (DisplayPort/HDMI) regeln Apps wie MonitorControl, BetterDisplay oder Lunar per DDC
// direkt im Gerät; macOS erfährt davon nichts. Wir fragen den Wert selbst per DDC ab (DDC.m). Klappt das nicht
// (Intel-Mac, Dock ohne DDC), lesen wir ihn aus MonitorControl: "value98(<Name><Hersteller><Modell>@<Display-ID>)"
// (98 = DDC-Lautstärke 0…1, 141 = DDC-Stummschaltung, 2 = stumm, 1 = an).
// Gemessen am LG UltraFine (5 … 42 %, 8 Punkte): Der Schalldruck ist proportional zur eingestellten Lautstärke,
// doppelte Prozentzahl = +6 dB, auf 0,3 dB genau. Eine Kalibrierung misst den Exponenten des jeweiligen Monitors.
static const float kMonitorExponent = 1.0f;
static float MonitorVolumeDB(float v, float exponent) {
    return v < 0.005f ? -INFINITY : exponent * 20.0f * log10f(v);
}

static float CalibratedMonitorExponent(AudioObjectID dev) {
    NSString *uid = DeviceUID(dev);
    NSDictionary *cal = uid ? [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"calibrations"][uid] : nil;
    NSNumber *e = [cal isKindOfClass:[NSDictionary class]] ? cal[@"volumeExponent"] : nil;
    return [e isKindOfClass:[NSNumber class]] && e.floatValue > 0.2f && e.floatValue < 4 ? e.floatValue : kMonitorExponent;
}

static NSString *ScreenName(NSScreen *screen) {
    if (@available(macOS 10.15, *)) return screen.localizedName;
    return nil;
}

static BOOL MonitorControlValue(AudioObjectID dev, float *volume, BOOL *muted);
static DDCVolume *gDDC;   // fragt die Lautstärke des aktuellen Monitors per DDC ab

// Lautstärke eines Monitors ohne macOS-Lautstärke: direkt per DDC, sonst aus MonitorControl
static BOOL ExternalMonitorValue(AudioObjectID dev, float *volume, BOOL *muted) {
    return [gDDC volume:volume muted:muted forDisplayNamed:DeviceName(dev)] || MonitorControlValue(dev, volume, muted);
}

static BOOL ExternalMonitorDB(AudioObjectID dev, float *db) {
    float v; BOOL muted;
    if (!ExternalMonitorValue(dev, &v, &muted)) return NO;
    *db = muted ? -INFINITY : MonitorVolumeDB(v, CalibratedMonitorExponent(dev));
    return YES;
}

static BOOL MonitorControlValue(AudioObjectID dev, float *volume, BOOL *mutedOut) {
    NSString *name = DeviceName(dev);
    for (NSScreen *screen in NSScreen.screens) {
        if (![ScreenName(screen) isEqualToString:name]) continue;
        CGDirectDisplayID d = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        NSString *compact = [[name componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsJoinedByString:@""];
        NSString *prefsID = [NSString stringWithFormat:@"(%@%u%u@%u)", compact, CGDisplayVendorNumber(d), CGDisplayModelNumber(d), d];
        CFStringRef app = CFSTR("app.monitorcontrol.MonitorControl");
        CFPreferencesAppSynchronize(app);
        id stored = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)[@"value98" stringByAppendingString:prefsID], app));
        id mute = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)[@"value141" stringByAppendingString:prefsID], app));
        if (![stored respondsToSelector:@selector(floatValue)]) return NO;
        *volume = MAX(0.0f, MIN(1.0f, [stored floatValue]));
        *mutedOut = [mute respondsToSelector:@selector(intValue)] && [mute intValue] == 2;
        return YES;
    }
    return NO;
}

// Wie stark der Bass der Gerätelautstärke folgt: 0.6 dB je dB. Das Gehör verliert bei leiser Wiedergabe
// überproportional Bass (Kurven gleicher Lautheit), und die MacBook-Lautsprecher heben leise Pegel per DSP an.
// Bei voller dB-Kopplung war der Bass schon bei mittlerer Lautstärke kaum noch zu spüren.
static const float kBassTracking = 0.6f;

// Lautstärke des Ausgabegeräts in dB, -INFINITY = stumm (der Tap greift das Signal vor der Gerätelautstärke ab).
static float DeviceVolumeDB(AudioObjectID dev) {
    for (AudioObjectPropertyElement el = 0; el <= 2; el++) {
        AudioObjectPropertyAddress mute = Addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, el);
        UInt32 m = 0, size = sizeof(m);
        if (AudioObjectHasProperty(dev, &mute) && AudioObjectGetPropertyData(dev, &mute, 0, NULL, &size, &m) == noErr) {
            if (m) return -INFINITY;
            break;
        }
    }
    for (AudioObjectPropertyElement el = 0; el <= 2; el++) {
        AudioObjectPropertyAddress vol = Addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el);
        Float32 scalar = 1.0f;
        UInt32 size = sizeof(scalar);
        if (!AudioObjectHasProperty(dev, &vol) || AudioObjectGetPropertyData(dev, &vol, 0, NULL, &size, &scalar) != noErr) continue;
        if (scalar <= 0.0001f) return -INFINITY;
        AudioObjectPropertyAddress conv = Addr(kAudioDevicePropertyVolumeScalarToDecibels, kAudioDevicePropertyScopeOutput, el);
        Float32 db = scalar;
        size = sizeof(db);
        if (AudioObjectGetPropertyData(dev, &conv, 0, NULL, &size, &db) == noErr && isfinite(db)) return db;
        return 40.0f * log10f(scalar);
    }
    float monitor;
    if (ExternalMonitorDB(dev, &monitor)) return monitor;
    return 0.0f;
}

static BOOL DeviceHasVolume(AudioObjectID dev) {
    for (AudioObjectPropertyElement el = 0; el <= 2; el++) {
        AudioObjectPropertyAddress vol = Addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el);
        if (AudioObjectHasProperty(dev, &vol)) return YES;
    }
    return NO;
}

static float DeviceVolumeGain(AudioObjectID dev) {
    float db = DeviceVolumeDB(dev);
    return isfinite(db) ? powf(10.0f, kBassTracking * db / 20.0f) : 0.0f;
}

#pragma mark - Menüleisten-Symbol

// Vereinfachtes App-Icon als Vorlagenbild: Gehäuse mit Gitter oben, darüber die drei Schallwellen.
// Gezeichnet in den Koordinaten von icon/make_icon.m (1024er Raster), nur der Ausschnitt mit dem Motiv.
static NSImage *StatusIcon(void) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(21, 18) flipped:NO drawingHandler:^BOOL(NSRect r) {
        CGFloat s = 17.0 / 520;                       // Motiv 222…802 x 285…805 -> 17 pt hoch
        NSAffineTransform *t = [NSAffineTransform transform];
        [t translateXBy:0.5 yBy:0.5];
        [t scaleBy:s];
        [t translateXBy:-222 yBy:-285];
        [t concat];
        [[NSColor blackColor] set];

        for (int i = 0; i < 3; i++) {                 // Schallwellen, kräftiger als im großen Icon
            NSBezierPath *wave = [NSBezierPath bezierPath];
            [wave appendBezierPathWithArcWithCenter:NSMakePoint(512, 380) radius:275 + i * 62 startAngle:64 - i * 3 endAngle:116 + i * 3];
            wave.lineWidth = 40;
            wave.lineCapStyle = NSLineCapStyleRound;
            [[NSColor colorWithWhite:0 alpha:1.0 - i * 0.25] setStroke];
            [wave stroke];
        }
        CGFloat fl = 222, fr = 802, ft = 520, fb = 285, bl = 268, br = 756, bt = 610;
        NSBezierPath *top = [NSBezierPath bezierPath];  // Gitter: halbtransparent
        [top moveToPoint:NSMakePoint(fl, ft)];
        [top lineToPoint:NSMakePoint(fr, ft)];
        [top lineToPoint:NSMakePoint(br, bt)];
        [top lineToPoint:NSMakePoint(bl, bt)];
        [top closePath];
        [[NSColor colorWithWhite:0 alpha:0.45] setFill];
        [top fill];
        NSBezierPath *front = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(fl, fb, fr - fl, ft - fb - 28) xRadius:60 yRadius:60];
        [[NSColor blackColor] setFill];
        [front fill];
        // Emblem als Aussparung in der Front
        [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationClear];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(512 - 42, 390 - 42, 84, 84)] fill];
        return YES;
    }];
    img.template = YES;
    img.accessibilityDescription = @"JumpBass";
    return img;
}

#pragma mark - App

static void SetHardwareSilent(AudioObjectID dev, BOOL silent);

@interface AppDelegate () <NSMenuDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSString *runningSignature;
@property (strong) NSString *failedSignature; // verhindert Endlosschleife: eigenes Aggregate löst Geräteliste-Änderung aus
@property (strong) NSString *statusText;
@property (strong) NSString *lastOutputUID;   // letzte Ausgabe außer dem BassJump, Ziel für guardDefaults
@property (strong) NSString *profileUID;      // Ausgabe, zu der die aktuellen Klangwerte gehören
@property (strong) NSTimer *timer;
@property (strong) NSTimer *updateTimer;
@property (strong) MainWindowController *window;
@end

@implementation AppDelegate {
    BassEngine _engine;
    AudioObjectID _aggregate;
    AudioObjectID _tap;
    AudioDeviceIOProcID _ioProc;
    AudioObjectID _bassJump;
    AudioObjectID _speakers;
    BOOL _standby;              // Ruhemodus: BassJump freigegeben, ein ungemuteter Tap lauscht auf Ton
    CFAbsoluteTime _lastSound;
    CFAbsoluteTime _failedAt;
    CFAbsoluteTime _limitingUntil;  // bis dahin leuchtet die Begrenzer-Anzeige
    double _sampleRate;
    float _meter;
    BOOL _calibrating;          // während der Kalibrierung kein Ruhemodus
}

- (NSUserDefaults *)defaults { return [NSUserDefaults standardUserDefaults]; }

- (BOOL)tapSupported {
    if (@available(macOS 14.2, *)) return YES;
    return NO;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self migrateFromOldName];
    [self.defaults registerDefaults:@{
        @"enabled": @YES,
        @"crossover": @150.0,
        @"levelDB": @0.0,
        @"bassOffsetMs": @0.0,
        @"idleStandby": @YES,
        @"subsonicHz": @50.0,
        @"maxLevelDB": @-12.0,
        @"guardDefaults": @YES,
        @"checkUpdates": @YES,
    }];
    // Frühere Stufen (-1 … -9 dB) lagen über der Übersteuerungsgrenze des BassJump
    if ([self.defaults objectForKey:@"maxLevelDB"] && [self.defaults doubleForKey:@"maxLevelDB"] > kHardwareCeilingDB)
        [self.defaults removeObjectForKey:@"maxLevelDB"];

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = StatusIcon();
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    self.statusItem.menu = menu;

    __weak AppDelegate *weakSelf = self;
    AudioObjectPropertyAddress devs = Addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &devs, dispatch_get_main_queue(), ^(UInt32 n, const AudioObjectPropertyAddress *a) {
        [weakSelf guardDefaults];
        [weakSelf reconcile];
    });
    AudioObjectPropertyAddress def = Addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &def, dispatch_get_main_queue(), ^(UInt32 n, const AudioObjectPropertyAddress *a) {
        [weakSelf guardDefaults];
        [weakSelf loadProfile];
        [weakSelf updateMonitorWatch];
        [weakSelf reconcile];
        [weakSelf updateGain];
    });
    for (NSNumber *sel in @[@(kAudioHardwarePropertyDefaultInputDevice), @(kAudioHardwarePropertyDefaultSystemOutputDevice)]) {
        AudioObjectPropertyAddress other = Addr(sel.unsignedIntValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &other, dispatch_get_main_queue(), ^(UInt32 n, const AudioObjectPropertyAddress *a) {
            [weakSelf guardDefaults];
        });
    }
    [self guardDefaults];
    [self loadProfile];
    gDDC = [[DDCVolume alloc] init];
    [self updateMonitorWatch];

    // Auch bei geöffnetem Menü weiterlaufen (Lautstärke-Nachführung, Ruhemodus)
    self.timer = [NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self reconcile];
    // Stündlich prüfen, ob die tägliche Update-Abfrage fällig ist (schlägt sie fehl, eine Stunde später erneut)
    self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:3600 target:self selector:@selector(checkForUpdate) userInfo:nil repeats:YES];
    [self performSelector:@selector(checkForUpdate) withObject:nil afterDelay:10];

    // Diagnose: JUMPBASS_CALIBRATE=1 öffnet die Kalibrierung und startet sie sofort
    if (NSProcessInfo.processInfo.environment[@"JUMPBASS_CALIBRATE"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self showWindow:nil];
            [self.window startCalibrationNow];
        });
    }
    NSString *snap = NSProcessInfo.processInfo.environment[@"JUMPBASS_SNAPSHOT"];
    if (snap) {
        [self showWindow:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self.window snapshot:snap tab:0];
            [self.window snapshot:[snap stringByReplacingOccurrencesOfString:@".png" withString:@"-2.png"] tab:1];
            [self.window snapshot:[snap stringByReplacingOccurrencesOfString:@".png" withString:@"-3.png"] tab:2];
        });
    }
}

// Bis zur Umbenennung hieß die App "BassJump Revived" (local.bassjump.revived): Einstellungen übernehmen.
- (void)migrateFromOldName {
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    NSDictionary *old = [self.defaults persistentDomainForName:@"local.bassjump.revived"];
    if (!old.count || [self.defaults persistentDomainForName:bundleID].count) return;
    [self.defaults setPersistentDomain:old forName:bundleID];
    [self.defaults removePersistentDomainForName:@"local.bassjump.revived"];
    [self setLaunchAtLogin:YES];
}

// Erneutes Öffnen der App (Doppelklick im Finder, Spotlight) zeigt das Fenster.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    [self showWindow:nil];
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [self stopEngine];
    SetHardwareSilent([self findBassJump], NO);
}

- (void)tick {
    // Nach einem Startfehler (z.B. Gerät kurz belegt) regelmäßig neu versuchen
    if (self.failedSignature && CFAbsoluteTimeGetCurrent() - _failedAt > kRetrySeconds) {
        self.failedSignature = nil;
        [self reconcile];
    }
    [self updateGain];
    [self checkIdle];
    BOOL dim = ![self engineActive];                  // Symbol gedimmt, solange kein Bass läuft
    if (self.statusItem.button.appearsDisabled != dim) self.statusItem.button.appearsDisabled = dim;
    float p = atomic_exchange(&_engine.peak, 0.0f);
    _meter = MAX(p, _meter * 0.7f);
    float limGain = atomic_exchange(&_engine.limMinGain, 1.0f);
    if (limGain < 0.89f) _limitingUntil = CFAbsoluteTimeGetCurrent() + 0.6; // mehr als 1 dB abgesenkt
    if (getenv("JUMPBASS_DEBUG")) {
        if (atomic_load(&_engine.testFrames)) NSLog(@"Test: Position %u von %u, IOProc-Aufrufe %u", _engine.testPos, atomic_load(&_engine.testFrames), atomic_load(&_engine.ioCycles));
        NSLog(@"Pegel %.4f, Begrenzer %.1f dB, Gain %.3f, IO-Abstand %.1f ms, Aggregate: Puffer %u, Latenz ein %u/%u aus %u/%u Frames @ %.0f Hz",
              p, 20 * log10f(fmaxf(limGain, 1e-6f)), atomic_load(&_engine.targetGain), atomic_load(&_engine.ioDelayMs),
              DeviceUInt32(_aggregate, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
              DeviceUInt32(_aggregate, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput),
              DeviceUInt32(_aggregate, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput),
              DeviceUInt32(_aggregate, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
              DeviceUInt32(_aggregate, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput), _sampleRate);
    }
}

// Ruhemodus: Nach längerer Stille den BassJump freigeben. Hörbares Rauschen hat er im Betrieb nicht (gemessen),
// es geht um Rechenzeit und darum, dass der BassJump selbst in seinen Standby gehen kann.
- (void)checkIdle {
    if (!_tap) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL sound = atomic_exchange(&_engine.inputPeak, 0.0f) > kSilenceThreshold;
    if (sound) _lastSound = now;
    BOOL wantStandby = _standby ? !sound : (now - _lastSound > kIdleSeconds);
    wantStandby = wantStandby && [self.defaults boolForKey:@"idleStandby"] && !_calibrating;
    if (wantStandby == _standby) return;
    _standby = wantStandby;
    [self reconcile];
}

#pragma mark Konfiguration

// Der BassJump meldet sich bei macOS auch als Mikrofon und Lautsprecher ("BassJump Core"). Neu angesteckte
// USB-Geräte macht macOS gern zum Standard – dann liefen Diktat, Siri, Anrufe oder Hinweistöne darüber.
// Ohne Treiber lässt sich der Eingang nicht entfernen, also wählen wir sofort das vorherige Gerät zurück.
- (void)guardDefaults {
    AudioObjectID bj = [self findBassJump];
    AudioObjectID out = DefaultOutputDevice();
    if (out && out != bj && !IsOwnAggregate(out)) self.lastOutputUID = DeviceUID(out);
    if (!bj || ![self.defaults boolForKey:@"guardDefaults"]) return;

    AudioObjectID fallback = DeviceForUID(self.lastOutputUID);
    if (!fallback || fallback == bj) fallback = BuiltInSpeakers();
    if (fallback && out == bj) SetDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, fallback);
    if (fallback && DefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice) == bj)
        SetDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice, fallback);
    if (DefaultDevice(kAudioHardwarePropertyDefaultInputDevice) == bj) {
        AudioObjectID mic = FallbackMicrophone(bj);
        if (mic) SetDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, mic);
    }
}

- (BOOL)guardDefaultsEnabled { return [self.defaults boolForKey:@"guardDefaults"]; }
- (void)setGuardDefaults:(BOOL)on { [self.defaults setBool:on forKey:@"guardDefaults"]; [self guardDefaults]; }

#pragma mark Update-Hinweis

// Einmal am Tag bei GitHub die Nummer der neuesten Version abfragen. Es wird nichts übertragen außer der Anfrage selbst.
- (void)checkForUpdate {
    if (![self checkUpdatesEnabled]) return;
    NSDate *last = [self.defaults objectForKey:@"lastUpdateCheck"];
    if ([last isKindOfClass:[NSDate class]] && -last.timeIntervalSinceNow < kUpdateCheckInterval) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kLatestReleaseAPI]];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *tag = [json isKindOfClass:[NSDictionary class]] ? json[@"tag_name"] : nil;
        if (![tag isKindOfClass:[NSString class]]) return;
        NSString *latest = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.defaults setObject:[NSDate date] forKey:@"lastUpdateCheck"];
            [self.defaults setObject:latest forKey:@"latestVersion"];
        });
    }] resume];
}

- (NSString *)availableUpdate {
    if (![self checkUpdatesEnabled]) return nil;
    NSString *latest = [self.defaults stringForKey:@"latestVersion"];
    NSString *mine = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"];
    return latest && mine && [latest compare:mine options:NSNumericSearch] == NSOrderedDescending ? latest : nil;
}

- (void)openUpdate:(id)sender { [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kReleasesURL]]; }
- (BOOL)checkUpdatesEnabled { return [self.defaults boolForKey:@"checkUpdates"]; }
- (void)setCheckUpdates:(BOOL)on {
    [self.defaults setBool:on forKey:@"checkUpdates"];
    [self.defaults removeObjectForKey:@"lastUpdateCheck"];
    [self checkForUpdate];
}

- (AudioObjectID)findBassJump {
    NSString *uid = [self.defaults stringForKey:@"bassJumpUID"];
    if (uid) return DeviceForUID(uid);
    for (NSNumber *n in OutputDevices()) {
        if (LooksLikeBassJump(n.unsignedIntValue)) return n.unsignedIntValue;
    }
    return kAudioObjectUnknown;
}

- (NSString *)sourceUID {
    NSString *s = [self.defaults stringForKey:@"sourceUID"];
    if (!s) return [self tapSupported] ? kSourceSystemTap : nil;
    if ([s isEqualToString:kSourceSystemTap] && ![self tapSupported]) return nil;
    return s;
}

- (NSString *)passthroughUID {
    NSString *s = [self.defaults stringForKey:@"passthroughUID"];
    if (s) return s;
    AudioObjectID b = BuiltInSpeakers();
    return b ? DeviceUID(b) : kPassNone;
}

// Ausgabegeräte, bei denen der BassJump mitspielt (z.B. Mac-Lautsprecher und Monitor, aber keine Kopfhörer)
- (NSArray<NSString *> *)gateUIDs {
    NSArray *s = [self.defaults arrayForKey:@"gateUIDs"];
    if (s) return s;
    AudioObjectID b = BuiltInSpeakers();
    return @[ b ? DeviceUID(b) : kGateAlways ];
}

// Läuft der Systemton gerade über ein Gerät, bei dem der BassJump mitspielen soll?
- (BOOL)outputGated {
    AudioObjectID out = DefaultOutputDevice();
    if (!out || out == [self findBassJump]) return NO;
    NSArray *gates = [self gateUIDs];
    return [gates containsObject:kGateAlways] || [gates containsObject:DeviceUID(out) ?: @""];
}

- (NSString *)desiredSignature {
    AudioObjectID bj = [self findBassJump];
    NSString *src = [self sourceUID];
    if (!bj || !src || ![self.defaults boolForKey:@"enabled"]) return nil;
    if ([src isEqualToString:kSourceSystemTap]) {
        if (![self outputGated]) return nil;
        AudioObjectID out = DefaultOutputDevice();
        return [NSString stringWithFormat:@"tap|%@|%@|%.0f%@", DeviceUID(bj), DeviceUID(out), SampleRate(out), _standby ? @"|standby" : @""];
    }
    if (!DeviceForUID(src)) return nil;
    NSString *pass = [self passthroughUID];
    if (!DeviceForUID(pass)) pass = kPassNone;
    return [NSString stringWithFormat:@"loop|%@|%@|%@", DeviceUID(bj), src, pass];
}

- (void)reconcile {
    NSString *want = [self desiredSignature];
    if (want && [want isEqualToString:self.runningSignature]) return;
    if (want && [want isEqualToString:self.failedSignature]) return;
    self.failedSignature = nil;
    if (_aggregate) [self stopEngine];

    if (!want) {
        SetHardwareSilent([self findBassJump], YES);
        if (![self.defaults boolForKey:@"enabled"]) self.statusText = L(@"Ausgeschaltet");
        else if (![self findBassJump]) self.statusText = L(@"BassJump nicht gefunden");
        else if ([[self sourceUID] isEqualToString:kSourceSystemTap]) self.statusText = [NSString stringWithFormat:L(@"Pausiert (Ausgabe über %@)"), DeviceName(DefaultOutputDevice())];
        else self.statusText = L(@"Keine Tonquelle gewählt (siehe Tonquelle)");
        return;
    }
    NSString *error = [self startEngine];
    if (error) {
        self.statusText = error;
        [self stopEngine];
        self.failedSignature = want;
        _failedAt = CFAbsoluteTimeGetCurrent();
    } else {
        self.runningSignature = want;
        _lastSound = CFAbsoluteTimeGetCurrent();
        self.statusText = _standby ? L(@"Ruhemodus – wartet auf Ton") : [NSString stringWithFormat:L(@"Aktiv mit %@"), DeviceName(DefaultOutputDevice())];
    }
    SetHardwareSilent([self findBassJump], !_aggregate || _standby);
    NSLog(@"%@", self.statusText);
    [self updateGain];
}

#pragma mark Engine

- (NSString *)startEngine {
    _bassJump = [self findBassJump];
    NSString *bjUID = DeviceUID(_bassJump);
    NSString *src = [self sourceUID];
    BOOL tapMode = [src isEqualToString:kSourceSystemTap];

    memset(&_engine, 0, sizeof(_engine));
    NSString *aggUID = [NSString stringWithFormat:@"%@.%@", kAggregateUIDPrefix, [NSUUID UUID].UUIDString];
    NSMutableDictionary *desc = [@{
        @kAudioAggregateDeviceNameKey: @"JumpBass Revived",
        @kAudioAggregateDeviceUIDKey: aggUID,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceIsStackedKey: @NO,
    } mutableCopy];

    if (tapMode) {
        if (@available(macOS 14.2, *)) {
            // Eigenen Prozess ausschließen, sonst hört der Tap unsere Bass-Ausgabe mit.
            NSMutableArray *exclude = [NSMutableArray array];
            AudioObjectPropertyAddress a = Addr(kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
            pid_t pid = getpid();
            AudioObjectID proc = kAudioObjectUnknown;
            UInt32 size = sizeof(proc);
            if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(pid), &pid, &size, &proc) == noErr && proc) {
                [exclude addObject:@(proc)];
            }
            CATapDescription *tapDesc = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:exclude];
            tapDesc.name = @"JumpBass Revived";
            tapDesc.privateTap = YES;
            // Der Original-Ton wird stummgeschaltet und von uns zeitgleich mit dem Bass ausgegeben.
            // So laufen Lautsprecher und BassJump synchron, statt dass der Bass ~50 ms hinterherhinkt.
            // "WhenTapped": beendet sich die App, ist der Ton sofort wieder da.
            tapDesc.muteBehavior = _standby ? CATapUnmuted : CATapMutedWhenTapped;
            OSStatus err = AudioHardwareCreateProcessTap(tapDesc, &_tap);
            if (err != noErr) return [NSString stringWithFormat:L(@"Fehler: Systemton-Tap (%d)"), (int)err];

            // Das aktuelle Ausgabegerät ist Taktgeber: Der Tap läuft in dessen Takt und braucht
            // keine Drift-Kompensation. Nur der BassJump wird angeglichen.
            _speakers = DefaultOutputDevice();
            NSString *speakersUID = DeviceUID(_speakers);
            desc[@kAudioAggregateDeviceMainSubDeviceKey] = speakersUID;
            desc[@kAudioAggregateDeviceSubDeviceListKey] = _standby
                ? @[ @{ @kAudioSubDeviceUIDKey: speakersUID } ]
                : @[ @{ @kAudioSubDeviceUIDKey: speakersUID },
                     @{ @kAudioSubDeviceUIDKey: bjUID, @kAudioSubDeviceDriftCompensationKey: @YES,
                        @kAudioSubDeviceInputChannelsKey: @0 } ];   // Mikrofon des BassJump nicht einbinden
            desc[@kAudioAggregateDeviceTapListKey] = @[ @{ @kAudioSubTapUIDKey: tapDesc.UUID.UUIDString,
                                                           @kAudioSubTapDriftCompensationKey: @NO } ];
            desc[@kAudioAggregateDeviceTapAutoStartKey] = @YES;

            // Puffer-Reihenfolge: Subdevices in Listenreihenfolge, danach der Tap.
            UInt32 speakersOut = StreamCount(_speakers, kAudioObjectPropertyScopeOutput);
            _engine.inputBuffer = StreamCount(_speakers, kAudioObjectPropertyScopeInput) + (_standby ? 0 : StreamCount(_bassJump, kAudioObjectPropertyScopeInput));
            _engine.passFirst = 0;
            _engine.passCount = _standby ? 0 : speakersOut;
            _engine.bassFirst = speakersOut;
            _engine.bassCount = _standby ? 0 : StreamCount(_bassJump, kAudioObjectPropertyScopeOutput);
        }
    } else {
        AudioObjectID srcDev = DeviceForUID(src);
        NSString *pass = [self passthroughUID];
        AudioObjectID passDev = [pass isEqualToString:kPassNone] ? kAudioObjectUnknown : DeviceForUID(pass);
        _speakers = passDev;

        NSMutableArray *subs = [NSMutableArray arrayWithObject:@{ @kAudioSubDeviceUIDKey: src }];
        if (passDev) [subs addObject:@{ @kAudioSubDeviceUIDKey: pass, @kAudioSubDeviceDriftCompensationKey: @YES }];
        [subs addObject:@{ @kAudioSubDeviceUIDKey: bjUID, @kAudioSubDeviceDriftCompensationKey: @YES }];
        desc[@kAudioAggregateDeviceMainSubDeviceKey] = src;
        desc[@kAudioAggregateDeviceSubDeviceListKey] = subs;

        UInt32 srcOut = StreamCount(srcDev, kAudioObjectPropertyScopeOutput);
        UInt32 passOut = passDev ? StreamCount(passDev, kAudioObjectPropertyScopeOutput) : 0;
        _engine.inputBuffer = 0;
        _engine.passFirst = srcOut;
        _engine.passCount = passOut;
        _engine.bassFirst = srcOut + passOut;
        _engine.bassCount = StreamCount(_bassJump, kAudioObjectPropertyScopeOutput);
    }

    if (tapMode) {
        if (!_standby) MatchSampleRate(_bassJump, SampleRate(DefaultOutputDevice()));
    } else {
        Float64 rate = SampleRate(DeviceForUID(src));
        MatchSampleRate(_bassJump, rate);
        MatchSampleRate(DeviceForUID([self passthroughUID]), rate);
    }

    OSStatus err = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)desc, &_aggregate);
    if (err != noErr) return [NSString stringWithFormat:L(@"Fehler: Aggregate-Device (%d)"), (int)err];
    SetBufferFrames(_aggregate, kBufferFrames);
    // Der Tap-Stream liegt hinter allen Subdevice-Eingängen, also immer als letzter Eingang.
    if (tapMode) _engine.inputBuffer = StreamCount(_aggregate, kAudioObjectPropertyScopeInput) - 1;
    if (getenv("JUMPBASS_DEBUG")) NSLog(@"Aggregate: %u Eingangs-Streams, Tap an Position %u", StreamCount(_aggregate, kAudioObjectPropertyScopeInput), _engine.inputBuffer);

    AudioObjectPropertyAddress sr = Addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    Float64 rate = 48000;
    UInt32 size = sizeof(rate);
    AudioObjectGetPropertyData(_aggregate, &sr, 0, NULL, &size, &rate);
    _sampleRate = rate > 0 ? rate : 48000;
    [self updateFilter];
    _engine.coefs = _engine.pendingCoefs;
    _engine.hpCoefs = _engine.pendingHpCoefs;
    _engine.hpOn = _engine.pendingHpOn;
    _engine.lim = _engine.pendingLim;
    _engine.appliedSeq = atomic_load(&_engine.coefsSeq);
    atomic_store(&_engine.limMinGain, 1.0f);
    [self updateLimit];
    atomic_store(&_engine.targetGain, 0.0f);
    [self updateDelay];

    __weak AppDelegate *weakSelf = self;
    AudioObjectAddPropertyListenerBlock(_aggregate, &sr, dispatch_get_main_queue(), ^(UInt32 n, const AudioObjectPropertyAddress *a) {
        [weakSelf sampleRateChanged];
    });

    err = AudioDeviceCreateIOProcID(_aggregate, BassIOProc, &_engine, &_ioProc);
    if (err != noErr) return [NSString stringWithFormat:L(@"Fehler: IOProc (%d)"), (int)err];
    SetStreamUsage(_aggregate, _ioProc, kAudioObjectPropertyScopeInput, _engine.inputBuffer, 1);
    if (_standby) SetStreamUsage(_aggregate, _ioProc, kAudioObjectPropertyScopeOutput, 0, 0);
    err = AudioDeviceStart(_aggregate, _ioProc);
    if (err != noErr) return [NSString stringWithFormat:L(@"Fehler: Start (%d) – Berechtigung für Audioaufnahme erteilt?"), (int)err];
    return nil;
}

- (void)stopEngine {
    if (_aggregate) {
        if (_ioProc) {
            AudioDeviceStop(_aggregate, _ioProc);
            AudioDeviceDestroyIOProcID(_aggregate, _ioProc);
        }
        AudioHardwareDestroyAggregateDevice(_aggregate);
    }
    if (_tap) {
        if (@available(macOS 14.2, *)) AudioHardwareDestroyProcessTap(_tap);
    }
    _ioProc = NULL;
    _speakers = kAudioObjectUnknown;
    _aggregate = kAudioObjectUnknown;
    _tap = kAudioObjectUnknown;
    self.runningSignature = nil;
}

- (void)sampleRateChanged {
    if (!_aggregate) return;
    AudioObjectPropertyAddress sr = Addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain);
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    if (AudioObjectGetPropertyData(_aggregate, &sr, 0, NULL, &size, &rate) == noErr && rate > 0) {
        _sampleRate = rate;
        [self updateFilter];
        [self updateDelay];
    }
}

// Nur die Streams öffnen, die wir wirklich brauchen. Vor allem bleibt so der Mikrofoneingang
// des BassJump zu – sonst verlangt macOS Mikrofon-Zugriff und zeigt den orangen Punkt.
static void SetStreamUsage(AudioObjectID dev, AudioDeviceIOProcID proc, AudioObjectPropertyScope scope, UInt32 first, UInt32 count) {
    UInt32 n = StreamCount(dev, scope);
    if (n == 0) return;
    UInt32 size = (UInt32)(offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + n * sizeof(UInt32));
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = n;
    for (UInt32 i = 0; i < n; i++) usage->mStreamIsOn[i] = (i >= first && i < first + count);
    AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyIOProcStreamUsage, scope, kAudioObjectPropertyElementMain);
    OSStatus err = AudioObjectSetPropertyData(dev, &a, 0, NULL, size, usage);
    if (err != noErr) NSLog(@"Stream-Nutzung (%u): Fehler %d", (unsigned)scope, (int)err);
    free(usage);
}

// Hardware-Stummschaltung und -Lautstärke des BassJump (C-Media-Chip). Im Ruhemodus ganz zu,
// damit die Ausgangsstufe möglichst wenig rauscht; beim Abspielen voll auf, Pegel regelt die App.
static void SetHardwareSilent(AudioObjectID dev, BOOL silent) {
    if (!dev) return;
    for (AudioObjectPropertyElement el = 0; el <= 2; el++) {
        AudioObjectPropertyAddress mute = Addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, el);
        Boolean settable = false;
        if (AudioObjectHasProperty(dev, &mute) && AudioObjectIsPropertySettable(dev, &mute, &settable) == noErr && settable) {
            UInt32 m = silent;
            AudioObjectSetPropertyData(dev, &mute, 0, NULL, sizeof(m), &m);
        }
        AudioObjectPropertyAddress vol = Addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el);
        if (AudioObjectHasProperty(dev, &vol) && AudioObjectIsPropertySettable(dev, &vol, &settable) == noErr && settable) {
            Float32 v = silent ? 0.0f : 1.0f;
            AudioObjectSetPropertyData(dev, &vol, 0, NULL, sizeof(v), &v);
        }
    }
}

// Gesamte Ausgabelatenz eines Geräts in Frames (Treiber + Sicherheitsreserve + Stream)
static SInt32 OutputLatency(AudioObjectID dev) {
    if (!dev) return 0;
    SInt32 frames = DeviceUInt32(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
                  + DeviceUInt32(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput);
    AudioObjectPropertyAddress a = Addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain);
    AudioStreamID stream = 0;
    UInt32 size = sizeof(stream);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &stream) == noErr && stream) {
        frames += DeviceUInt32(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal);
    }
    return frames;
}

// Bass gegenüber den Lautsprechern verzögern (oder umgekehrt), damit beide gleichzeitig ankommen:
// automatisch aus den gemeldeten Gerätelatenzen plus der Feineinstellung aus dem Menü.
- (void)updateDelay {
    SInt32 frames = 0;
    if (_speakers) frames = OutputLatency(_speakers) - OutputLatency(_bassJump);
    frames -= (SInt32)[self limiterLookahead];   // um die Vorausschau des Begrenzers ist der Bass ohnehin später
    frames += (SInt32)lround([self.defaults doubleForKey:@"bassOffsetMs"] * _sampleRate / 1000.0);
    atomic_store(&_engine.bassDelay, MAX(frames, 0));
    atomic_store(&_engine.passDelay, MAX(-frames, 0));
    if (getenv("JUMPBASS_DEBUG")) NSLog(@"Verzögerung: Bass %d, Lautsprecher %d Frames", MAX(frames, 0), MAX(-frames, 0));
}

- (void)updateFilter {
    double subsonic = [self.defaults doubleForKey:@"subsonicHz"];
    BiquadCoefs lp = LowpassCoefs([self.defaults doubleForKey:@"crossover"], _sampleRate);
    BiquadCoefs hp = subsonic > 0 ? HighpassCoefs(subsonic, _sampleRate) : _engine.pendingHpCoefs;
    LimiterParams lim;
    lim.lookahead = [self limiterLookahead];
    lim.hold = (UInt32)lround(0.030 * _sampleRate) + lim.lookahead; // länger als eine halbe 20-Hz-Schwingung
    lim.attack = 1.0f - expf(-5.0f / MAX(lim.lookahead, 1));          // nach der Vorausschau zu >99 % abgesenkt
    lim.release = expf(-1.0f / (0.150f * _sampleRate));                 // löst sich in ~150 ms
    // Seqlock: ungerade Version während des Schreibens, der IOProc übernimmt nur vollständige Sätze.
    atomic_fetch_add_explicit(&_engine.coefsSeq, 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    _engine.pendingCoefs = lp;
    _engine.pendingHpCoefs = hp;
    _engine.pendingHpOn = subsonic > 0;
    _engine.pendingLim = lim;
    atomic_fetch_add_explicit(&_engine.coefsSeq, 1, memory_order_release);
}

// Vorausschau des Begrenzers: 4 ms
- (UInt32)limiterLookahead {
    return (UInt32)MIN(lround(0.004 * _sampleRate), kLookaheadRing - 1);
}

- (void)updateLimit {
    atomic_store(&_engine.limitLevel, powf(10.0f, fmin([self.defaults doubleForKey:@"maxLevelDB"], kHardwareCeilingDB) / 20.0f));
}

- (void)updateGain {
    if (!_aggregate) return;
    float gain = powf(10.0f, [self.defaults floatForKey:@"levelDB"] / 20.0f);
    if (_tap) {
        AudioObjectID out = DefaultOutputDevice();
        NSArray *gates = [self gateUIDs];
        if (![gates containsObject:kGateAlways] && ![gates containsObject:DeviceUID(out) ?: @""]) gain = 0;
        if (out == _bassJump) gain = 0;
        // Der Tap liefert den Ton vor der Gerätelautstärke; die Lautsprecher-Durchleitung wird vom Gerät
        // geregelt, den Bass regeln wir selbst mit – sonst bliebe er laut, wenn der Mac leise ist.
        if (gain > 0) gain *= DeviceVolumeGain(out);
    }
    atomic_store(&_engine.targetGain, gain);
}

#pragma mark Anmeldung

- (NSString *)launchAgentPath {
    return [NSHomeDirectory() stringByAppendingFormat:@"/Library/LaunchAgents/%@.plist", kLaunchAgentLabel];
}

- (BOOL)launchAtLogin {
    if (@available(macOS 13.0, *)) return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    return [[NSFileManager defaultManager] fileExistsAtPath:[self launchAgentPath]];
}

- (void)setLaunchAtLogin:(BOOL)on {
    if (@available(macOS 13.0, *)) {
        NSError *err = nil;
        if (on) [SMAppService.mainAppService registerAndReturnError:&err];
        else [SMAppService.mainAppService unregisterAndReturnError:&err];
        if (err) NSLog(@"Anmeldeobjekt: %@", err);
        return;
    }
    if (on) {
        NSDictionary *plist = @{ @"Label": kLaunchAgentLabel,
                                 @"ProgramArguments": @[ [NSBundle mainBundle].executablePath ],
                                 @"RunAtLoad": @YES };
        [[NSFileManager defaultManager] createDirectoryAtPath:[[self launchAgentPath] stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [plist writeToFile:[self launchAgentPath] atomically:YES];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:[self launchAgentPath] error:nil];
    }
}

#pragma mark Menü

- (NSMenuItem *)item:(NSString *)title action:(SEL)action rep:(id)rep checked:(BOOL)checked {
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    i.target = self;
    i.representedObject = rep;
    i.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    return i;
}

// Lautstärkeregler direkt im Menü, wie der Lautstärkeregler von macOS
- (NSMenuItem *)volumeMenuItem {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 46)];
    NSTextField *title = [NSTextField labelWithString:L(@"BassJump-Lautstärke")];
    title.font = [NSFont menuFontOfSize:0];
    title.textColor = NSColor.secondaryLabelColor;
    title.frame = NSMakeRect(20, 25, 160, 17);
    [v addSubview:title];
    BOOL dbStyle = LevelStyleIsDB();
    double level = [self.defaults doubleForKey:@"levelDB"];
    NSTextField *value = [NSTextField labelWithString:@""];
    value.font = [NSFont menuFontOfSize:0];
    value.textColor = NSColor.secondaryLabelColor;
    value.alignment = NSTextAlignmentRight;
    value.frame = NSMakeRect(180, 25, 64, 17);
    value.tag = 1;
    [v addSubview:value];
    NSSlider *slider = [NSSlider sliderWithValue:LevelSliderFromDB(level, dbStyle) minValue:LevelSliderMin(dbStyle) maxValue:LevelSliderMax(dbStyle) target:self action:@selector(menuVolumeChanged:)];
    slider.frame = NSMakeRect(18, 4, 228, 20);
    slider.continuous = YES;
    [v addSubview:slider];
    value.stringValue = LevelText(level, dbStyle);
    NSMenuItem *item = [[NSMenuItem alloc] init];
    item.view = v;
    return item;
}

- (void)menuVolumeChanged:(NSSlider *)slider {
    BOOL dbStyle = LevelStyleIsDB();
    double level = LevelDBFromSlider(slider.doubleValue, dbStyle);
    [self setLevelDB:level];
    ((NSTextField *)[slider.superview viewWithTag:1]).stringValue = LevelText(level, dbStyle);
}

- (void)setSubsonicHz:(double)hz { [self.defaults setDouble:hz forKey:@"subsonicHz"]; [self updateFilter]; }
- (void)setMaxLevelDB:(double)db { [self.defaults setDouble:db forKey:@"maxLevelDB"]; [self updateLimit]; }
- (void)chooseMaxLevel:(NSMenuItem *)s { [self setMaxLevelDB:[s.representedObject doubleValue]]; }

#pragma mark Deinstallieren

// Entfernt Anmeldeobjekt, Einstellungen und Berechtigungen und legt die App in den Papierkorb.
- (void)uninstall:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = L(@"JumpBass Revived deinstallieren?");
    alert.informativeText = L(@"Die App wird beendet und in den Papierkorb gelegt. Einstellungen, Anmeldeobjekt und Berechtigungen werden entfernt. Der BassJump funktioniert danach wieder als normales USB-Audiogerät.");
    [alert addButtonWithTitle:L(@"Deinstallieren")];
    [alert addButtonWithTitle:L(@"Abbrechen")];
    if (@available(macOS 11.0, *)) alert.buttons[0].hasDestructiveAction = YES;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    [self.timer invalidate];
    [self stopEngine];
    SetHardwareSilent([self findBassJump], NO);
    [self setLaunchAtLogin:NO];
    [[NSFileManager defaultManager] removeItemAtPath:[self launchAgentPath] error:nil];

    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    [self.defaults removePersistentDomainForName:bundleID];
    [self.defaults synchronize];
    NSTask *tcc = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/tccutil" arguments:@[@"reset", @"All", bundleID]];
    [tcc waitUntilExit];

    [[NSWorkspace sharedWorkspace] recycleURLs:@[[NSBundle mainBundle].bundleURL] completionHandler:^(NSDictionary *moved, NSError *err) {
        if (err) NSLog(@"Papierkorb: %@", err);
        exit(0); // nicht terminate:, damit keine Einstellungen mehr geschrieben werden
    }];
}

- (void)setLevelStyleDB:(BOOL)on { [self.defaults setBool:on forKey:@"levelStyleDB"]; }
- (void)chooseLevelStyle:(NSMenuItem *)s { [self setLevelStyleDB:[s.representedObject boolValue]]; }

- (NSMenuItem *)submenu:(NSString *)title items:(NSArray<NSMenuItem *> *)items {
    NSMenuItem *parent = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *sub = [[NSMenu alloc] initWithTitle:title];
    for (NSMenuItem *i in items) [sub addItem:i];
    parent.submenu = sub;
    return parent;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSUserDefaults *d = self.defaults;

    NSMenuItem *status = [[NSMenuItem alloc] initWithTitle:self.statusText ?: @"" action:nil keyEquivalent:@""];
    status.enabled = NO;
    [menu addItem:status];
    NSString *update = [self availableUpdate];
    if (update) [menu addItem:[self item:[NSString stringWithFormat:L(@"Update verfügbar: Version %@ …"), update] action:@selector(openUpdate:) rep:nil checked:NO]];
    if (_aggregate) {
        int bars = (int)lroundf(MIN(_meter, 1.0f) * 20);
        NSString *meter = [@"" stringByPaddingToLength:bars withString:@"▮" startingAtIndex:0];
        NSMenuItem *m = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:L(@"Pegel: %@"), bars ? meter : @"–"] action:nil keyEquivalent:@""];
        m.enabled = NO;
        [menu addItem:m];
    }
    [menu addItem:[self item:L(@"Bass aktiv") action:@selector(toggleEnabled:) rep:nil checked:[d boolForKey:@"enabled"]]];
    [menu addItem:[self item:L(@"Fenster öffnen …") action:@selector(showWindow:) rep:nil checked:NO]];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMutableArray *presetItems = [NSMutableArray array];
    NSInteger current = [self currentPresetIndex];
    [self.presets enumerateObjectsUsingBlock:^(NSDictionary *p, NSUInteger i, BOOL *stop) {
        if ([p[@"user"] boolValue] && (i == 0 || ![self.presets[i - 1][@"user"] boolValue])) [presetItems addObject:[NSMenuItem separatorItem]];
        [presetItems addObject:[self item:p[@"name"] action:@selector(setPreset:) rep:@(i) checked:(NSInteger)i == current]];
    }];
    [menu addItem:[self submenu:L(@"Voreinstellung") items:presetItems]];

    [menu addItem:[self volumeMenuItem]];
    [menu addItem:[self submenu:L(@"Lautstärkeregler in") items:@[
        [self item:L(@"Prozent (100 % = normal)") action:@selector(chooseLevelStyle:) rep:@NO checked:!LevelStyleIsDB()],
        [self item:L(@"Dezibel (Bass-Pegel)") action:@selector(chooseLevelStyle:) rep:@YES checked:LevelStyleIsDB()] ]]];

    NSMutableArray *xoItems = [NSMutableArray array];
    for (NSNumber *hz in @[@40, @60, @80, @100, @120, @150, @175, @200, @250, @300, @400, @500]) {
        BOOL on = fabs([d doubleForKey:@"crossover"] - hz.doubleValue) < 0.5;
        [xoItems addObject:[self item:[NSString stringWithFormat:@"%@ Hz", hz] action:@selector(setCrossover:) rep:hz checked:on]];
    }
    [menu addItem:[self submenu:[NSString stringWithFormat:L(@"Übergangsfrequenz (%.0f Hz)"), [d doubleForKey:@"crossover"]] items:xoItems]];

    NSMutableArray *offsetItems = [NSMutableArray array];
    for (NSNumber *ms in @[@-100, @-50, @-30, @-20, @-10, @-5, @0, @5, @10, @20, @30, @50, @100, @200]) {
        BOOL on = fabs([d doubleForKey:@"bassOffsetMs"] - ms.doubleValue) < 0.5;
        NSString *title = ms.intValue == 0 ? L(@"0 ms (automatisch)") : [NSString stringWithFormat:@"%+d ms%@", ms.intValue, ms.intValue > 0 ? L(@" (Bass später)") : L(@" (Bass früher)")];
        [offsetItems addObject:[self item:title action:@selector(setBassOffset:) rep:ms checked:on]];
    }
    [menu addItem:[self submenu:[NSString stringWithFormat:L(@"Bass-Timing (%+.0f ms)"), [d doubleForKey:@"bassOffsetMs"]] items:offsetItems]];
    [menu addItem:[NSMenuItem separatorItem]];

    NSArray *outputs = OutputDevices();
    NSString *bjSetting = [d stringForKey:@"bassJumpUID"];
    NSMutableArray *bjItems = [NSMutableArray arrayWithObject:[self item:L(@"Automatisch erkennen") action:@selector(setBassJumpDevice:) rep:nil checked:bjSetting == nil]];
    for (NSNumber *n in outputs) {
        NSString *uid = DeviceUID(n.unsignedIntValue);
        [bjItems addObject:[self item:DeviceName(n.unsignedIntValue) action:@selector(setBassJumpDevice:) rep:uid checked:[uid isEqualToString:bjSetting]]];
    }
    [menu addItem:[self submenu:L(@"BassJump-Gerät") items:bjItems]];

    NSString *src = [self sourceUID];
    NSMutableArray *srcItems = [NSMutableArray array];
    NSMenuItem *tapItem = [self item:L(@"Systemton (ab macOS 14.2)") action:@selector(setSource:) rep:kSourceSystemTap checked:[src isEqualToString:kSourceSystemTap]];
    tapItem.enabled = [self tapSupported];
    [srcItems addObject:tapItem];
    [srcItems addObject:[NSMenuItem separatorItem]];
    for (NSNumber *n in InputDevices()) {
        NSString *uid = DeviceUID(n.unsignedIntValue);
        [srcItems addObject:[self item:[NSString stringWithFormat:@"Loopback: %@", DeviceName(n.unsignedIntValue)] action:@selector(setSource:) rep:uid checked:[uid isEqualToString:src]]];
    }
    [menu addItem:[self submenu:L(@"Tonquelle") items:srcItems]];

    if (src && ![src isEqualToString:kSourceSystemTap]) {
        NSString *pass = [self passthroughUID];
        NSMutableArray *passItems = [NSMutableArray arrayWithObject:[self item:L(@"Keine") action:@selector(setPassthrough:) rep:kPassNone checked:[pass isEqualToString:kPassNone]]];
        for (NSNumber *n in outputs) {
            NSString *uid = DeviceUID(n.unsignedIntValue);
            if ([uid isEqualToString:src] || LooksLikeBassJump(n.unsignedIntValue)) continue;
            [passItems addObject:[self item:DeviceName(n.unsignedIntValue) action:@selector(setPassthrough:) rep:uid checked:[uid isEqualToString:pass]]];
        }
        [menu addItem:[self submenu:L(@"Vollton weiterleiten an") items:passItems]];
    }
    [menu addItem:[NSMenuItem separatorItem]];

    NSMutableArray *maxItems = [NSMutableArray array];
    for (NSNumber *db in MaxLevelChoices([d doubleForKey:@"maxLevelDB"])) {
        [maxItems addObject:[self item:MaxLevelTitle(db) action:@selector(chooseMaxLevel:) rep:db checked:fabs([d doubleForKey:@"maxLevelDB"] - db.doubleValue) < 0.5]];
    }
    [menu addItem:[self submenu:L(@"Maximalpegel (gegen Krachen)") items:maxItems]];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:L(@"Beenden") action:@selector(terminate:) keyEquivalent:@"q"];
    [menu addItem:quit];
}

#pragma mark Einstellungen (Menü und Fenster)

// Werte, die ein eigenes Preset speichert
static NSArray<NSString *> *PresetKeys(void) { return @[@"crossover", @"levelDB", @"bassOffsetMs", @"subsonicHz", @"maxLevelDB"]; }

// Eingebaute Presets (nur Übergangsfrequenz und Pegel), danach die eigenen ("user" = YES).
// Die ersten fünf stammen aus der Original-Software (SettingsDB.plist, Lautstärke relativ zu "Default" 0.6).
- (NSArray<NSDictionary *> *)presets {
    double (^orig)(double) = ^double(double v) { return 20.0 * log10(v / 0.6); };
    NSArray *raw = @[ @[L(@"Standard"), @150, @(orig(0.6))], @[L(@"Klassik"), @175, @(orig(0.5))], @[@"Pop", @200, @(orig(0.75))],
                      @[@"R&B", @150, @(orig(1.0))], @[@"Rock", @175, @(orig(0.8))],
                      @[@"Jazz", @120, @-1.0], @[L(@"Akustik"), @100, @-3.0], @[@"Hip-Hop", @120, @2.0],
                      @[L(@"Elektronisch"), @100, @2.0], @[@"Metal", @175, @0.0], @[L(@"Film & Serien"), @120, @1.0],
                      @[L(@"Spiele"), @150, @1.0], @[L(@"Sprache & Podcast"), @80, @-6.0], @[L(@"Nachtmodus"), @150, @-9.0],
                      @[L(@"Volle Fülle"), @200, @1.0], @[L(@"Maximaler Bass"), @175, @3.0] ];
    NSMutableArray *r = [NSMutableArray array];
    for (NSArray *p in raw) [r addObject:@{ @"name": p[0], @"values": @{ @"crossover": p[1], @"levelDB": p[2] } }];
    for (NSDictionary *p in [self.defaults arrayForKey:@"userPresets"]) {
        if ([p[@"name"] isKindOfClass:[NSString class]] && [p[@"values"] isKindOfClass:[NSDictionary class]])
            [r addObject:@{ @"name": p[@"name"], @"values": p[@"values"], @"user": @YES }];
    }
    return r;
}

// Ein Preset passt, wenn alle seine gespeicherten Werte mit den aktuellen übereinstimmen.
// Eigene Presets haben Vorrang, weil sie mehr Werte festlegen.
- (NSInteger)currentPresetIndex {
    NSArray *presets = self.presets;
    NSInteger match = -1;
    for (NSUInteger i = 0; i < presets.count; i++) {
        NSDictionary *values = presets[i][@"values"];
        BOOL same = YES;
        for (NSString *key in values) {
            if (fabs([self.defaults doubleForKey:key] - [values[key] doubleValue]) > 0.05) same = NO;
        }
        if (same && (match < 0 || [presets[i][@"user"] boolValue])) match = i;
    }
    return match;
}

#pragma mark Werte je Ausgabe

// Lautstärke, Übergangsfrequenz und Bass-Timing hängen von den Lautsprechern ab und werden je Ausgabe gemerkt
// (Maximalpegel und Tiefbass-Schutz hängen am BassJump und gelten überall). Die Einstellungsschlüssel enthalten
// immer die Werte der aktuellen Ausgabe; "outputProfiles" hält die aller Ausgaben, nach Geräte-UID.
static NSArray<NSString *> *ProfileKeys(void) { return @[@"levelDB", @"crossover", @"bassOffsetMs"]; }

- (NSString *)currentProfileUID {
    AudioObjectID out = DefaultOutputDevice();
    return out == kAudioObjectUnknown || LooksLikeBassJump(out) ? nil : DeviceUID(out);
}

- (void)saveProfile {
    NSString *uid = self.profileUID;
    if (!uid) return;
    NSMutableDictionary *profiles = [[self.defaults dictionaryForKey:@"outputProfiles"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in ProfileKeys()) values[key] = @([self.defaults doubleForKey:key]);
    profiles[uid] = values;
    [self.defaults setObject:profiles forKey:@"outputProfiles"];
}

// Neue Ausgabe: deren Werte laden. Kennt sie noch keine, übernimmt sie die bisherigen.
- (void)loadProfile {
    NSString *uid = [self currentProfileUID];
    if (!uid || [uid isEqualToString:self.profileUID]) return;
    self.profileUID = uid;
    NSDictionary *values = [self.defaults dictionaryForKey:@"outputProfiles"][uid];
    if (![values isKindOfClass:[NSDictionary class]]) { [self saveProfile]; return; }
    for (NSString *key in ProfileKeys()) {
        if ([values[key] respondsToSelector:@selector(doubleValue)]) [self.defaults setDouble:[values[key] doubleValue] forKey:key];
    }
    [self updateFilter];
    [self updateGain];
    [self updateDelay];
}

#pragma mark Kalibrierung (Schnittstelle für Calibration.m)

- (void)setCalibrating:(BOOL)on {
    _calibrating = on;
    _lastSound = CFAbsoluteTimeGetCurrent();
    [self checkIdle];
}

// Spielt ein Testsignal einmal ab: speaker auf den Lautsprechern, bass über den Bass-Weg (raw = ohne Filter,
// Pegel und Begrenzer). Die Puffer müssen gültig bleiben, bis testPlaying NO liefert.
- (BOOL)playTestSpeaker:(const float *)speaker bass:(const float *)bass frames:(UInt32)frames raw:(BOOL)raw {
    if (!_aggregate || _standby || atomic_load(&_engine.testFrames) || frames == 0) return NO;
    _engine.testSpeaker = speaker;
    _engine.testBass = bass;
    _engine.testRaw = raw;
    _engine.testPos = 0;
    atomic_store_explicit(&_engine.testFrames, frames, memory_order_release);
    return YES;
}

- (BOOL)testPlaying { return atomic_load(&_engine.testFrames) != 0; }
- (unsigned)ioCycles { return atomic_load(&_engine.ioCycles); }
- (double)outputSampleRate { return _sampleRate; }
- (AudioObjectID)measurementMicrophone { return FallbackMicrophone([self findBassJump]); }
- (NSString *)currentOutputName { AudioObjectID out = DefaultOutputDevice(); return out ? DeviceName(out) : nil; }

// Monitor ohne macOS-Lautstärke, dessen eigene Lautstärke lesbar ist: 0…1, sonst -1
- (float)monitorVolume {
    float v; BOOL muted;
    AudioObjectID out = DefaultOutputDevice();
    return !DeviceHasVolume(out) && ExternalMonitorValue(out, &v, &muted) ? v : -1;
}

// DDC-Abfrage nur für eine Ausgabe ohne macOS-Lautstärke (Monitor über DisplayPort/HDMI/USB-C)
- (void)updateMonitorWatch {
    AudioObjectID out = DefaultOutputDevice();
    [gDDC watchDisplayNamed:out && !LooksLikeBassJump(out) && !DeviceHasVolume(out) ? DeviceName(out) : nil];
}

- (NSDictionary *)calibrationForCurrentOutput {
    NSString *uid = [self currentProfileUID];
    NSDictionary *cal = uid ? [self.defaults dictionaryForKey:@"calibrations"][uid] : nil;
    return [cal isKindOfClass:[NSDictionary class]] ? cal : nil;
}

// Ergebnis übernehmen: Bass-Timing gehört zur Ausgabe, der Maximalpegel zum BassJump (gilt überall).
- (void)applyCalibration:(NSDictionary *)result {
    NSString *uid = [self currentProfileUID];
    if (!uid) return;
    NSMutableDictionary *all = [[self.defaults dictionaryForKey:@"calibrations"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *cal = [all[uid] isKindOfClass:[NSDictionary class]] ? [all[uid] mutableCopy] : [NSMutableDictionary dictionary];
    [cal addEntriesFromDictionary:result];
    cal[@"date"] = [NSDate date];
    all[uid] = cal;
    [self.defaults setObject:all forKey:@"calibrations"];
    if (result[@"offsetMs"]) [self setOffsetMs:[result[@"offsetMs"] doubleValue]];
    if (result[@"maxLevelDB"]) [self setMaxLevelDB:[result[@"maxLevelDB"] doubleValue]];
    [self updateGain];
}

- (void)resetCalibration {
    NSString *uid = [self currentProfileUID];
    NSMutableDictionary *all = [[self.defaults dictionaryForKey:@"calibrations"] mutableCopy];
    if (!uid || !all[uid]) return;
    [all removeObjectForKey:uid];
    [self.defaults setObject:all forKey:@"calibrations"];
    [self setOffsetMs:0];
    [self.defaults removeObjectForKey:@"maxLevelDB"];
    [self updateLimit];
    [self updateGain];
}

- (void)applyPresetAtIndex:(NSInteger)i {
    NSDictionary *values = self.presets[i][@"values"];
    for (NSString *key in values) [self.defaults setDouble:[values[key] doubleValue] forKey:key];
    [self updateFilter];
    [self updateGain];
    [self updateDelay];
    [self updateLimit];
    [self saveProfile];
}

- (void)saveUserPresetNamed:(NSString *)name {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in PresetKeys()) values[key] = @([self.defaults doubleForKey:key]);
    NSMutableArray *list = [[self.defaults arrayForKey:@"userPresets"] mutableCopy] ?: [NSMutableArray array];
    NSIndexSet *same = [list indexesOfObjectsPassingTest:^BOOL(NSDictionary *p, NSUInteger i, BOOL *stop) { return [p[@"name"] isEqual:name]; }];
    [list removeObjectsAtIndexes:same];   // gleicher Name überschreibt
    [list addObject:@{ @"name": name, @"values": values }];
    [self.defaults setObject:list forKey:@"userPresets"];
}

- (void)deleteUserPresetNamed:(NSString *)name {
    NSMutableArray *list = [[self.defaults arrayForKey:@"userPresets"] mutableCopy];
    [list filterUsingPredicate:[NSPredicate predicateWithFormat:@"name != %@", name]];
    [self.defaults setObject:list forKey:@"userPresets"];
}

- (BOOL)engineActive { return _aggregate && !_standby; }
- (BOOL)engineStandby { return _aggregate && _standby; }
- (float)takeMeterPeak { return atomic_exchange(&_engine.uiPeak, 0.0f); }
- (BOOL)limiterActive { return [self engineActive] && CFAbsoluteTimeGetCurrent() < _limitingUntil; }
- (BOOL)usesSystemTap { return [[self sourceUID] isEqualToString:kSourceSystemTap]; }

- (void)setBassEnabled:(BOOL)on { self.failedSignature = nil; [self.defaults setBool:on forKey:@"enabled"]; [self reconcile]; }
- (void)setLevelDB:(double)db { [self.defaults setDouble:db forKey:@"levelDB"]; [self updateGain]; [self saveProfile]; }
- (void)setCrossoverHz:(double)hz { [self.defaults setDouble:hz forKey:@"crossover"]; [self updateFilter]; [self saveProfile]; }
- (void)setOffsetMs:(double)ms { [self.defaults setDouble:ms forKey:@"bassOffsetMs"]; [self updateDelay]; [self saveProfile]; }
- (void)setIdleStandby:(BOOL)on {
    [self.defaults setBool:on forKey:@"idleStandby"];
    _lastSound = CFAbsoluteTimeGetCurrent();
    [self checkIdle];
}
- (void)setBassJumpUID:(NSString *)uid { [self setDefault:uid forKey:@"bassJumpUID"]; }

- (void)toggleGateUID:(NSString *)uid {
    NSMutableArray *gates = [[self gateUIDs] mutableCopy];
    if ([uid isEqualToString:kGateAlways]) {
        // "Immer" aus: zurück zur Standardauswahl (eingebaute Lautsprecher)
        if ([gates containsObject:kGateAlways]) [self.defaults removeObjectForKey:@"gateUIDs"];
        else [self.defaults setObject:@[kGateAlways] forKey:@"gateUIDs"];
    } else {
        [gates removeObject:kGateAlways];
        if ([gates containsObject:uid]) [gates removeObject:uid];
        else [gates addObject:uid];
        [self.defaults setObject:gates forKey:@"gateUIDs"];
    }
    [self reconcile];
    [self updateGain];
}

- (void)showWindow:(id)sender {
    if (!self.window) self.window = [[MainWindowController alloc] initWithApp:self];
    [self.window show];
}

- (void)setDefault:(id)value forKey:(NSString *)key {
    if (value) [self.defaults setObject:value forKey:key];
    else [self.defaults removeObjectForKey:key];
    self.failedSignature = nil;
    [self reconcile];
    [self updateGain];
}

#pragma mark Menü-Aktionen

- (void)toggleEnabled:(NSMenuItem *)s { [self setBassEnabled:![self.defaults boolForKey:@"enabled"]]; }
- (void)setPreset:(NSMenuItem *)s { [self applyPresetAtIndex:[s.representedObject integerValue]]; }
- (void)setBassOffset:(NSMenuItem *)s { [self setOffsetMs:[s.representedObject doubleValue]]; }
- (void)setCrossover:(NSMenuItem *)s { [self setCrossoverHz:[s.representedObject doubleValue]]; }
- (void)setBassJumpDevice:(NSMenuItem *)s { [self setBassJumpUID:s.representedObject]; }
- (void)setSource:(NSMenuItem *)s { [self setDefault:s.representedObject forKey:@"sourceUID"]; }
- (void)setPassthrough:(NSMenuItem *)s { [self setDefault:s.representedObject forKey:@"passthroughUID"]; }

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Für deinstallieren.sh: Anmeldeobjekt (SMAppService) abmelden und sofort beenden
        if (argc > 1 && strcmp(argv[1], "--unregister-login") == 0) {
            if (@available(macOS 13.0, *)) [SMAppService.mainAppService unregisterAndReturnError:nil];
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
