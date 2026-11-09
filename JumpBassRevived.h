// Gemeinsame Schnittstelle zwischen Audio-Logik (main.m) und Fenster (MainWindow.m).

#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>

// Oberflächentexte: Deutsch steht im Code und dient als Schlüssel, en.lproj/Localizable.strings übersetzt.
#define L(s) NSLocalizedString(s, nil)

extern NSString *const kGateAlways;

// BassJump-Lautstärkeregler, wahlweise in Prozent oder Dezibel (Einstellung "levelStyle").
//   Prozent: 0 % = aus, 100 % = normal (0 dB), 200 % = +24 dB, linear in dB
//   Dezibel: -30 dB (= aus) bis +24 dB
static const double kMutedDB = -120;
static inline BOOL LevelStyleIsDB(void) { return [[NSUserDefaults standardUserDefaults] boolForKey:@"levelStyleDB"]; }
static inline double LevelSliderMin(BOOL db) { return db ? -30 : 0; }
static inline double LevelSliderMax(BOOL db) { return db ? 24 : 200; }
static inline double LevelSliderFromDB(double level, BOOL db) {
    if (db) return MAX(-30, MIN(24, level));
    return level <= -24 ? 0 : MIN(200, 100 + level / 0.24);
}
static inline double LevelDBFromSlider(double v, BOOL db) {
    if (db) return v <= -29.75 ? kMutedDB : round(v * 2) / 2;
    v = round(v);
    return v < 0.5 ? kMutedDB : (v - 100) * 0.24;
}
static inline NSString *LevelText(double level, BOOL db) {
    if (level <= -30) return @"aus";
    if (db) return [NSString stringWithFormat:@"%+.1f dB", level];
    double pct = LevelSliderFromDB(level, NO);
    return pct < 0.5 ? @"< 1 %" : [NSString stringWithFormat:@"%.0f %%", pct]; // leise, aber nicht aus
}

// Maximalpegel-Stufen. Gemessen: Der Verstärker im BassJump übersteuert ab etwa -10 dBFS am Eingang
// (darüber wird er nicht lauter, nur verzerrter), daher liegt die höchste Stufe dort.
static const double kHardwareCeilingDB = -10;
static inline NSArray<NSNumber *> *MaxLevelChoices(void) { return @[@-10, @-12, @-15, @-18]; }
static inline NSString *MaxLevelTitle(NSNumber *db) {
    if (db.intValue == -10) return L(@"-10 dB (am Limit)");
    if (db.intValue == -12) return L(@"-12 dB (empfohlen)");
    return [NSString stringWithFormat:@"%@ dB", db];
}

NSArray<NSNumber *> *OutputDevices(void);
NSString *DeviceUID(AudioObjectID dev);
NSString *DeviceName(AudioObjectID dev);
BOOL LooksLikeBassJump(AudioObjectID dev);

@class MainWindowController;

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong, readonly) NSString *statusText;

- (NSUserDefaults *)defaults;
- (BOOL)engineActive;
- (BOOL)engineStandby;
- (BOOL)usesSystemTap;
- (float)takeMeterPeak;     // Spitzenpegel des Bass-Signals seit dem letzten Aufruf (0…1)
- (BOOL)limiterActive;      // Begrenzer hat gerade hörbar abgesenkt (Maximalpegel erreicht)

- (NSArray<NSDictionary *> *)presets; // name, values (Einstellungsschlüssel -> Wert), user
- (NSInteger)currentPresetIndex;      // -1 = keine Übereinstimmung
- (void)applyPresetAtIndex:(NSInteger)i;
- (void)saveUserPresetNamed:(NSString *)name;
- (void)deleteUserPresetNamed:(NSString *)name;

- (void)setBassEnabled:(BOOL)on;
- (void)setLevelDB:(double)db;
- (void)setCrossoverHz:(double)hz;
- (void)setOffsetMs:(double)ms;
- (void)setLevelStyleDB:(BOOL)on;
- (void)setSubsonicHz:(double)hz;
- (void)setMaxLevelDB:(double)db;
- (void)uninstall:(id)sender;
- (void)setIdleStandby:(BOOL)on;
- (BOOL)guardDefaultsEnabled;
- (void)setGuardDefaults:(BOOL)on;  // BassJump nicht als Mikrofon/Standardausgabe zulassen
- (BOOL)checkUpdatesEnabled;
- (void)setCheckUpdates:(BOOL)on;
- (NSString *)availableUpdate;      // neuere Version auf GitHub oder nil
- (void)openUpdate:(id)sender;
- (void)setBassJumpUID:(NSString *)uid; // nil = automatisch
- (NSArray<NSString *> *)gateUIDs;
- (void)toggleGateUID:(NSString *)uid;
- (BOOL)launchAtLogin;
- (void)setLaunchAtLogin:(BOOL)on;
- (void)showWindow:(id)sender;

// Kalibrierung
- (NSString *)currentOutputName;
- (float)monitorControlVolume;          // 0…1 bei Monitoren, die MonitorControl regelt, sonst -1
- (NSDictionary *)calibrationForCurrentOutput;  // date, offsetMs, timingSpreadMs, clipDB, maxLevelDB, volumeSlope
- (void)applyCalibration:(NSDictionary *)result;
- (void)resetCalibration;
- (void)setCalibrating:(BOOL)on;
- (BOOL)playTestSpeaker:(const float *)speaker bass:(const float *)bass frames:(UInt32)frames raw:(BOOL)raw;
- (BOOL)testPlaying;
- (double)outputSampleRate;
- (AudioObjectID)measurementMicrophone;
@end

@interface Calibrator : NSObject
@property (readonly) BOOL running;
- (instancetype)initWithApp:(AppDelegate *)app;
- (void)runTiming:(BOOL)timing maxLevel:(BOOL)maxLevel volume:(BOOL)volume
         progress:(void (^)(NSString *text, double fraction))progress
       completion:(void (^)(NSDictionary *result, NSString *error))completion;  // error nil und result nil = abgebrochen
- (void)cancel;
@end

@interface MainWindowController : NSObject <NSWindowDelegate>
- (instancetype)initWithApp:(AppDelegate *)app;
- (void)show;
- (void)snapshot:(NSString *)path tab:(NSInteger)tab;
@end
