// Gemeinsame Schnittstelle zwischen Audio-Logik (main.m) und Fenster (MainWindow.m).

#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>

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
- (void)setBassJumpUID:(NSString *)uid; // nil = automatisch
- (NSArray<NSString *> *)gateUIDs;
- (void)toggleGateUID:(NSString *)uid;
- (BOOL)launchAtLogin;
- (void)setLaunchAtLogin:(BOOL)on;
- (void)showWindow:(id)sender;
@end

@interface MainWindowController : NSObject <NSWindowDelegate>
- (instancetype)initWithApp:(AppDelegate *)app;
- (void)show;
- (void)snapshot:(NSString *)path tab:(NSInteger)tab;
@end
