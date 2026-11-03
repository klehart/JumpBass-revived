// JumpBass Revived – Fenster
//
// Angelehnt an die Original-Oberfläche: dunkles HUD-Fenster, analoges VU-Meter,
// Ein/Aus-Schalter und die Bereiche "Klang" und "Einstellungen".

#import "JumpBassRevived.h"
#include <math.h>

static const CGFloat kWidth = 460, kHeight = 596;

static NSColor *Accent(void) { return [NSColor colorWithCalibratedRed:1.0 green:0.55 blue:0.12 alpha:1.0]; }

@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

#pragma mark - VU-Meter

@interface VUMeterView : NSView
@property (nonatomic) double needle;   // 0…1 auf der Skala
@property (nonatomic) int lamp;        // 0 aus, 1 Ruhemodus, 2 an
@end

@implementation VUMeterView

// VU-Skala von -20 bis +3: Position proportional zur Amplitude, wie bei echten Zeigerinstrumenten
static double ScalePos(double vu) {
    return (pow(10.0, vu / 20.0) - 0.1) / (pow(10.0, 3.0 / 20.0) - 0.1);
}

- (NSPoint)pivot { return NSMakePoint(NSMidX(self.bounds), NSMinY(self.bounds) - self.bounds.size.height * 0.42); }
- (CGFloat)radius { return self.bounds.size.height * 1.12; }
- (CGFloat)angleFor:(double)pos { return (130.0 - 80.0 * pos) * M_PI / 180.0; }

- (NSPoint)pointAtPos:(double)pos radius:(CGFloat)r {
    NSPoint c = self.pivot;
    CGFloat a = [self angleFor:pos];
    return NSMakePoint(c.x + cos(a) * r, c.y + sin(a) * r);
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = NSInsetRect(self.bounds, 1, 1);
    NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:b xRadius:14 yRadius:14];

    // Skalenhintergrund: warm beleuchtet (an), gedimmt (Ruhemodus) oder kalt (aus)
    NSArray *colors;
    if (self.lamp == 2) colors = @[[NSColor colorWithCalibratedRed:0.98 green:0.86 blue:0.55 alpha:1], [NSColor colorWithCalibratedRed:0.93 green:0.66 blue:0.28 alpha:1]];
    else if (self.lamp == 1) colors = @[[NSColor colorWithCalibratedRed:0.72 green:0.63 blue:0.45 alpha:1], [NSColor colorWithCalibratedRed:0.55 green:0.44 blue:0.27 alpha:1]];
    else colors = @[[NSColor colorWithCalibratedWhite:0.62 alpha:1], [NSColor colorWithCalibratedWhite:0.45 alpha:1]];
    [[[NSGradient alloc] initWithColors:colors] drawInBezierPath:frame angle:-90];

    [NSGraphicsContext saveGraphicsState];
    [frame addClip];

    CGFloat r = self.radius;
    NSColor *ink = [NSColor colorWithCalibratedWhite:0.12 alpha:1];
    NSColor *red = [NSColor colorWithCalibratedRed:0.85 green:0.08 blue:0.05 alpha:1];

    // Skalenbogen: schwarz bis 0 VU, rot darüber
    NSBezierPath *arc = [NSBezierPath bezierPath];
    arc.lineWidth = 2.5;
    [arc appendBezierPathWithArcWithCenter:self.pivot radius:r startAngle:[self angleFor:0] * 180 / M_PI endAngle:[self angleFor:ScalePos(0)] * 180 / M_PI clockwise:YES];
    [ink setStroke];
    [arc stroke];
    NSBezierPath *redArc = [NSBezierPath bezierPath];
    redArc.lineWidth = 7;
    [redArc appendBezierPathWithArcWithCenter:self.pivot radius:r + 2.5 startAngle:[self angleFor:ScalePos(0)] * 180 / M_PI endAngle:[self angleFor:1] * 180 / M_PI clockwise:YES];
    [red setStroke];
    [redArc stroke];

    // Teilstriche und Beschriftung
    NSArray *ticks = @[@-20, @-10, @-7, @-5, @-3, @-2, @-1, @0, @1, @2, @3];
    NSSet *labeled = [NSSet setWithArray:@[@-20, @-10, @-7, @-5, @-3, @0, @3]];
    for (NSNumber *t in ticks) {
        double pos = ScalePos(t.doubleValue);
        BOOL hot = t.intValue >= 0;
        NSBezierPath *tick = [NSBezierPath bezierPath];
        tick.lineWidth = [labeled containsObject:t] ? 2.5 : 1.5;
        [tick moveToPoint:[self pointAtPos:pos radius:r]];
        [tick lineToPoint:[self pointAtPos:pos radius:r + ([labeled containsObject:t] ? 16 : 10)]];
        [(hot ? red : ink) setStroke];
        [tick stroke];
        if (![labeled containsObject:t]) continue;
        NSString *text = [NSString stringWithFormat:@"%d", abs(t.intValue)];
        NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightMedium],
                                 NSForegroundColorAttributeName: hot ? red : ink };
        NSSize sz = [text sizeWithAttributes:attrs];
        NSPoint p = [self pointAtPos:pos radius:r + 28];
        [text drawAtPoint:NSMakePoint(p.x - sz.width / 2, p.y - sz.height / 2) withAttributes:attrs];
    }

    NSDictionary *small = @{ NSFontAttributeName: [NSFont systemFontOfSize:18 weight:NSFontWeightLight], NSForegroundColorAttributeName: ink };
    NSString *vu = @"BASS";
    NSSize vs = [vu sizeWithAttributes:small];
    [vu drawAtPoint:NSMakePoint(NSMidX(b) - vs.width / 2, NSMinY(b) + 30) withAttributes:small];
    NSDictionary *pm = @{ NSFontAttributeName: [NSFont systemFontOfSize:20 weight:NSFontWeightBold] };
    [@"–" drawAtPoint:NSMakePoint(NSMinX(b) + 14, NSMinY(b) + 8) withAttributes:pm];
    NSMutableDictionary *plus = [pm mutableCopy];
    plus[NSForegroundColorAttributeName] = red;
    [@"+" drawAtPoint:NSMakePoint(NSMaxX(b) - 26, NSMinY(b) + 8) withAttributes:plus];

    // Zeiger
    NSBezierPath *needle = [NSBezierPath bezierPath];
    needle.lineWidth = 2.2;
    needle.lineCapStyle = NSLineCapStyleRound;
    [needle moveToPoint:[self pointAtPos:self.needle radius:r * 0.55]];
    [needle lineToPoint:[self pointAtPos:self.needle radius:r + 22]];
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowOffset = NSMakeSize(2, -2);
    shadow.shadowBlurRadius = 3;
    shadow.shadowColor = [NSColor colorWithCalibratedWhite:0 alpha:0.35];
    [NSGraphicsContext saveGraphicsState];
    [shadow set];
    [ink setStroke];
    [needle stroke];
    [NSGraphicsContext restoreGraphicsState];

    // Glasreflex
    NSRect glass = NSMakeRect(NSMinX(b), NSMidY(b), b.size.width, b.size.height / 2);
    [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:1 alpha:0.28]
                                   endingColor:[NSColor colorWithCalibratedWhite:1 alpha:0.0]] drawInRect:glass angle:-90];
    [NSGraphicsContext restoreGraphicsState];

    [[NSColor colorWithCalibratedWhite:0 alpha:0.6] setStroke];
    frame.lineWidth = 1.5;
    [frame stroke];
}

@end

#pragma mark - Fenster

@implementation MainWindowController {
    __weak AppDelegate *_app;
    NSWindow *_window;
    NSTimer *_meterTimer, *_refreshTimer;
    NSTextField *_status;
    id _power;                  // NSSwitch ab 10.15, sonst Checkbox
    VUMeterView *_meter;
    NSSegmentedControl *_tabs;
    NSView *_soundPane, *_settingsPane;
    NSPopUpButton *_presets, *_device, *_levelStyle, *_subsonic, *_maxLevel;
    NSButton *_savePreset, *_deletePreset;
    NSArray *_presetList;
    NSSlider *_level, *_crossover, *_offset;
    NSTextField *_levelValue, *_crossoverValue, *_offsetValue;
    NSView *_gateBox;
    NSButton *_idle, *_login;
    NSString *_deviceSignature;
}

- (instancetype)initWithApp:(AppDelegate *)app {
    if ((self = [super init])) {
        _app = app;
        [self build];
    }
    return self;
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight frame:(NSRect)frame {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.frame = frame;
    return l;
}

- (NSImageView *)symbol:(NSString *)name fallback:(NSString *)text frame:(NSRect)frame {
    NSImage *img = nil;
    if (@available(macOS 11.0, *)) img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!img) {
        img = [NSImage imageWithSize:frame.size flipped:NO drawingHandler:^BOOL(NSRect r) {
            [text drawInRect:r withAttributes:@{ NSFontAttributeName: [NSFont boldSystemFontOfSize:16], NSForegroundColorAttributeName: NSColor.secondaryLabelColor }];
            return YES;
        }];
    }
    NSImageView *v = [NSImageView imageViewWithImage:img];
    v.frame = frame;
    if (@available(macOS 10.14, *)) v.contentTintColor = NSColor.secondaryLabelColor;
    return v;
}

- (NSButton *)iconButton:(NSString *)symbol fallback:(NSString *)title frame:(NSRect)frame action:(SEL)action {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    if (@available(macOS 11.0, *)) {
        NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
        if (img) { b.image = img; b.imagePosition = NSImageOnly; }
    }
    b.bezelStyle = NSBezelStyleSmallSquare;
    b.frame = frame;
    return b;
}

- (NSSlider *)sliderMin:(double)min max:(double)max frame:(NSRect)frame action:(SEL)action {
    NSSlider *s = [NSSlider sliderWithValue:min minValue:min maxValue:max target:self action:action];
    s.frame = frame;
    s.continuous = YES;
    if (@available(macOS 11.0, *)) s.trackFillColor = Accent();
    return s;
}

- (NSButton *)checkbox:(NSString *)title frame:(NSRect)frame action:(SEL)action {
    NSButton *b = [NSButton checkboxWithTitle:title target:self action:action];
    b.frame = frame;
    return b;
}

- (void)build {
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kWidth, kHeight)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
                                            backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"JumpBass";
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility = NSWindowTitleHidden;
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    _window.movableByWindowBackground = YES;
    if (@available(macOS 10.14, *)) _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    else _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, kHeight)];
    if (@available(macOS 10.14, *)) bg.material = NSVisualEffectMaterialHUDWindow;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bg.state = NSVisualEffectStateActive;
    _window.contentView = bg;

    FlippedView *root = [[FlippedView alloc] initWithFrame:bg.bounds];
    [bg addSubview:root];

    // Kopfzeile
    [root addSubview:[self label:@"JumpBass" size:22 weight:NSFontWeightBold frame:NSMakeRect(24, 34, 250, 28)]];
    _status = [self label:@"" size:12 weight:NSFontWeightRegular frame:NSMakeRect(24, 62, 300, 18)];
    _status.textColor = [NSColor secondaryLabelColor];
    [root addSubview:_status];
    if (@available(macOS 10.15, *)) {
        NSSwitch *sw = [[NSSwitch alloc] initWithFrame:NSMakeRect(kWidth - 24 - 40, 40, 40, 24)];
        sw.target = self;
        sw.action = @selector(togglePower:);
        [root addSubview:sw];
        _power = sw;
    } else {
        _power = [self checkbox:@"An" frame:NSMakeRect(kWidth - 24 - 50, 40, 50, 24) action:@selector(togglePower:)];
        [root addSubview:_power];
    }

    _meter = [[VUMeterView alloc] initWithFrame:NSMakeRect(24, 92, kWidth - 48, 170)];
    [root addSubview:_meter];

    _tabs = [NSSegmentedControl segmentedControlWithLabels:@[@"Klang", @"Einstellungen"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(switchTab:)];
    // BassJump-Lautstärke, wie im Original direkt unter der Anzeige
    NSImageView *quiet = [self symbol:@"speaker.fill" fallback:@"–" frame:NSMakeRect(24, 276, 22, 22)];
    NSImageView *loud = [self symbol:@"speaker.wave.3.fill" fallback:@"+" frame:NSMakeRect(kWidth - 24 - 70 - 30, 276, 26, 22)];
    [root addSubview:quiet];
    [root addSubview:loud];
    _level = [self sliderMin:0 max:100 frame:NSMakeRect(52, 275, kWidth - 52 - 24 - 70 - 34, 24) action:@selector(changeLevel:)];
    [root addSubview:_level];
    _levelValue = [self label:@"" size:13 weight:NSFontWeightMedium frame:NSMakeRect(kWidth - 24 - 62, 278, 62, 18)];
    [root addSubview:_levelValue];

    _tabs.frame = NSMakeRect((kWidth - 260) / 2, 316, 260, 24);
    _tabs.selectedSegment = 0;
    [root addSubview:_tabs];

    NSRect paneFrame = NSMakeRect(0, 354, kWidth, kHeight - 354);
    _soundPane = [[FlippedView alloc] initWithFrame:paneFrame];
    _settingsPane = [[FlippedView alloc] initWithFrame:paneFrame];
    _settingsPane.hidden = YES;
    [root addSubview:_soundPane];
    [root addSubview:_settingsPane];
    [self buildSoundPane];
    [self buildSettingsPane];

    [_window center];
}

- (void)buildSoundPane {
    CGFloat lx = 24, cx = 168, cw = 200, vx = 376, y = 10, row = 46;

    [_soundPane addSubview:[self label:@"Klangeinstellung" size:13 weight:NSFontWeightMedium frame:NSMakeRect(lx, y + 3, 140, 18)]];
    _presets = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cx - 3, y - 1, cw + 6, 26) pullsDown:NO];
    _presets.target = self;
    _presets.action = @selector(choosePreset:);
    _presets.autoenablesItems = NO;
    [_soundPane addSubview:_presets];
    _savePreset = [self iconButton:@"plus" fallback:@"+" frame:NSMakeRect(vx, y, 30, 24) action:@selector(savePreset:)];
    _savePreset.toolTip = @"Aktuelle Einstellung als eigenes Preset speichern";
    _deletePreset = [self iconButton:@"minus" fallback:@"−" frame:NSMakeRect(vx + 34, y, 30, 24) action:@selector(deletePreset:)];
    _deletePreset.toolTip = @"Ausgewähltes eigenes Preset löschen";
    [_soundPane addSubview:_savePreset];
    [_soundPane addSubview:_deletePreset];
    y += row;


    [_soundPane addSubview:[self label:@"Übergangsfrequenz" size:13 weight:NSFontWeightMedium frame:NSMakeRect(lx, y + 3, 140, 18)]];
    _crossover = [self sliderMin:40 max:500 frame:NSMakeRect(cx, y, cw, 24) action:@selector(changeCrossover:)];
    [_soundPane addSubview:_crossover];
    _crossoverValue = [self label:@"" size:12 weight:NSFontWeightRegular frame:NSMakeRect(vx, y + 4, 70, 18)];
    [_soundPane addSubview:_crossoverValue];
    y += row;

    [_soundPane addSubview:[self label:@"Bass-Timing" size:13 weight:NSFontWeightMedium frame:NSMakeRect(lx, y + 3, 140, 18)]];
    _offset = [self sliderMin:-100 max:200 frame:NSMakeRect(cx, y, cw, 24) action:@selector(changeOffset:)];
    [_soundPane addSubview:_offset];
    _offsetValue = [self label:@"" size:12 weight:NSFontWeightRegular frame:NSMakeRect(vx, y + 4, 70, 18)];
    [_soundPane addSubview:_offsetValue];
    NSTextField *hint = [self label:@"0 = automatisch abgeglichen · plus = Bass später" size:11 weight:NSFontWeightRegular frame:NSMakeRect(cx, y + 26, 280, 16)];
    hint.textColor = [NSColor tertiaryLabelColor];
    [_soundPane addSubview:hint];
    y += row + 8;

    // Schutz vor Krachen: Frequenzen, die der kleine Treiber nicht schafft, und zu hohe Spitzen
    [_soundPane addSubview:[self label:@"Tiefbass-Schutz" size:13 weight:NSFontWeightMedium frame:NSMakeRect(lx, y + 3, 140, 18)]];
    _subsonic = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cx - 3, y - 1, cw + 6, 26) pullsDown:NO];
    for (NSNumber *hz in @[@0, @30, @40, @50, @60, @70]) {
        [_subsonic addItemWithTitle:hz.intValue ? [NSString stringWithFormat:@"unter %@ Hz ausblenden", hz] : @"Aus"];
        _subsonic.lastItem.representedObject = hz;
    }
    _subsonic.target = self;
    _subsonic.action = @selector(chooseSubsonic:);
    [_soundPane addSubview:_subsonic];
    y += row;

    [_soundPane addSubview:[self label:@"Maximalpegel" size:13 weight:NSFontWeightMedium frame:NSMakeRect(lx, y + 3, 140, 18)]];
    _maxLevel = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cx - 3, y - 1, cw + 6, 26) pullsDown:NO];
    for (NSNumber *db in @[@-1, @-3, @-6, @-9, @-12]) {
        [_maxLevel addItemWithTitle:db.intValue == -1 ? @"-1 dB (ungebremst)" : [NSString stringWithFormat:@"%@ dB", db]];
        _maxLevel.lastItem.representedObject = db;
    }
    _maxLevel.target = self;
    _maxLevel.action = @selector(chooseMaxLevel:);
    [_soundPane addSubview:_maxLevel];
}

- (void)buildSettingsPane {
    [_settingsPane addSubview:[self label:@"BassJump spielt mit bei:" size:13 weight:NSFontWeightMedium frame:NSMakeRect(24, 4, 200, 18)]];
    _gateBox = [[FlippedView alloc] initWithFrame:NSMakeRect(24, 28, 200, 180)];
    [_settingsPane addSubview:_gateBox];

    CGFloat x = 240, w = kWidth - x - 20;
    _idle = [self checkbox:@"Ruhemodus bei Stille" frame:NSMakeRect(x, 2, w, 22) action:@selector(toggleIdle:)];
    _login = [self checkbox:@"Beim Anmelden starten" frame:NSMakeRect(x, 28, w, 22) action:@selector(toggleLogin:)];
    [_settingsPane addSubview:_idle];
    [_settingsPane addSubview:_login];

    [_settingsPane addSubview:[self label:@"BassJump-Gerät" size:13 weight:NSFontWeightMedium frame:NSMakeRect(x, 66, w, 18)]];
    _device = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x - 3, 88, w + 6, 26) pullsDown:NO];
    _device.target = self;
    _device.action = @selector(chooseDevice:);
    [_settingsPane addSubview:_device];

    [_settingsPane addSubview:[self label:@"Lautstärkeregler in" size:13 weight:NSFontWeightMedium frame:NSMakeRect(x, 128, w, 18)]];
    _levelStyle = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x - 3, 150, w + 6, 26) pullsDown:NO];
    [_levelStyle addItemsWithTitles:@[@"Prozent (100 % = normal)", @"Dezibel (Bass-Pegel)"]];
    _levelStyle.target = self;
    _levelStyle.action = @selector(chooseLevelStyle:);
    [_settingsPane addSubview:_levelStyle];

    NSButton *uninstall = [NSButton buttonWithTitle:@"Deinstallieren …" target:_app action:@selector(uninstall:)];
    uninstall.frame = NSMakeRect(20, 202, 150, 28);
    [_settingsPane addSubview:uninstall];
}

#pragma mark Anzeigen und Aktualisieren

- (void)show {
    [self refresh];
    if (!_window.visible) [_window center];
    [NSApp activateIgnoringOtherApps:YES];
    [_window makeKeyAndOrderFront:nil];
    if (!_meterTimer) {
        _meterTimer = [NSTimer timerWithTimeInterval:1.0 / 30 target:self selector:@selector(animateMeter) userInfo:nil repeats:YES];
        _refreshTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_meterTimer forMode:NSRunLoopCommonModes];
        [[NSRunLoop mainRunLoop] addTimer:_refreshTimer forMode:NSRunLoopCommonModes];
    }
}

// Diagnose: JUMPBASS_SNAPSHOT=/pfad.png speichert ein Bild des Fensters
- (void)snapshot:(NSString *)path tab:(NSInteger)tab {
    _tabs.selectedSegment = tab;
    [self switchTab:_tabs];
    NSView *v = _window.contentView;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

- (void)windowWillClose:(NSNotification *)note {
    [_meterTimer invalidate];
    [_refreshTimer invalidate];
    _meterTimer = _refreshTimer = nil;
}

- (void)animateMeter {
    float peak = [_app takeMeterPeak];
    // -12 dBFS Spitzenpegel des Bass-Signals = 0 VU
    double vu = peak > 0 ? 20.0 * log10(peak) + 12.0 : -40;
    double target = MAX(0.0, MIN(1.04, ScalePos(vu)));
    if (![_app engineActive]) target = 0;
    double n = _meter.needle;
    n += (target - n) * (target > n ? 0.35 : 0.10);
    if (fabs(n - _meter.needle) > 0.0005) {
        _meter.needle = n;
        _meter.needsDisplay = YES;
    }
}

- (void)refresh {
    NSUserDefaults *d = _app.defaults;
    _status.stringValue = _app.statusText ?: @"";
    BOOL enabled = [d boolForKey:@"enabled"];
    [_power setState:enabled ? NSControlStateValueOn : NSControlStateValueOff];
    int lamp = [_app engineActive] ? 2 : [_app engineStandby] ? 1 : 0;
    if (lamp != _meter.lamp) {
        _meter.lamp = lamp;
        _meter.needsDisplay = YES;
    }

    [self syncPreset];

    BOOL dbStyle = LevelStyleIsDB();
    _level.minValue = LevelSliderMin(dbStyle);
    _level.maxValue = LevelSliderMax(dbStyle);
    _level.doubleValue = LevelSliderFromDB([d doubleForKey:@"levelDB"], dbStyle);
    [_levelStyle selectItemAtIndex:dbStyle ? 1 : 0];
    _crossover.doubleValue = [d doubleForKey:@"crossover"];
    _offset.doubleValue = [d doubleForKey:@"bassOffsetMs"];
    [self updateValueLabels];

    [self selectItemIn:_subsonic value:[d doubleForKey:@"subsonicHz"]];
    [self selectItemIn:_maxLevel value:[d doubleForKey:@"maxLevelDB"]];
    _idle.state = [d boolForKey:@"idleStandby"];
    _login.state = [_app launchAtLogin];
    _idle.enabled = [_app usesSystemTap];

    [self refreshDevices];
}

- (void)updateValueLabels {
    _levelValue.stringValue = LevelText([_app.defaults doubleForKey:@"levelDB"], LevelStyleIsDB());
    _crossoverValue.stringValue = [NSString stringWithFormat:@"%.0f Hz", _crossover.doubleValue];
    _offsetValue.stringValue = round(_offset.doubleValue) == 0 ? @"0 ms" : [NSString stringWithFormat:@"%+.0f ms", _offset.doubleValue];
}

// Geräteliste nur neu aufbauen, wenn sich Geräte oder Auswahl geändert haben
- (void)refreshDevices {
    NSArray *outputs = OutputDevices();
    NSArray *gates = [_app gateUIDs];
    NSString *bjSetting = [_app.defaults stringForKey:@"bassJumpUID"];
    NSMutableString *sig = [NSMutableString stringWithFormat:@"%@|%@|", [gates componentsJoinedByString:@","], bjSetting];
    for (NSNumber *n in outputs) [sig appendFormat:@"%@;", DeviceUID(n.unsignedIntValue)];
    if ([sig isEqualToString:_deviceSignature]) return;
    _deviceSignature = sig;

    for (NSView *v in [_gateBox.subviews copy]) [v removeFromSuperview];
    CGFloat y = 0;
    NSButton *always = [self checkbox:@"Immer (jede Ausgabe)" frame:NSMakeRect(0, y, 200, 22) action:@selector(toggleGate:)];
    always.identifier = kGateAlways;
    always.state = [gates containsObject:kGateAlways];
    [_gateBox addSubview:always];
    y += 24;
    for (NSNumber *n in outputs) {
        if (LooksLikeBassJump(n.unsignedIntValue)) continue;
        NSButton *b = [self checkbox:DeviceName(n.unsignedIntValue) frame:NSMakeRect(0, y, 200, 22) action:@selector(toggleGate:)];
        b.identifier = DeviceUID(n.unsignedIntValue);
        b.state = [gates containsObject:b.identifier] || [gates containsObject:kGateAlways];
        b.enabled = ![gates containsObject:kGateAlways];
        [_gateBox addSubview:b];
        y += 24;
    }

    [_device removeAllItems];
    [_device addItemWithTitle:@"Automatisch erkennen"];
    [_device itemAtIndex:0].representedObject = nil;
    [_device selectItemAtIndex:0];
    for (NSNumber *n in outputs) {
        NSString *uid = DeviceUID(n.unsignedIntValue);
        [_device addItemWithTitle:DeviceName(n.unsignedIntValue)];
        _device.lastItem.representedObject = uid;
        if ([uid isEqualToString:bjSetting]) [_device selectItem:_device.lastItem];
    }
}

#pragma mark Aktionen

- (void)togglePower:(id)sender {
    NSInteger state = [sender state];
    [_app setBassEnabled:state == NSControlStateValueOn];
    [self refresh];
}

- (void)switchTab:(NSSegmentedControl *)sender {
    _soundPane.hidden = sender.selectedSegment != 0;
    _settingsPane.hidden = sender.selectedSegment != 1;
}

- (void)choosePreset:(NSPopUpButton *)sender {
    NSNumber *index = sender.selectedItem.representedObject;
    if (index) [_app applyPresetAtIndex:index.integerValue];
    [self refresh];
}

// Liste neu aufbauen, wenn sich die Presets geändert haben: eingebaute, Trennlinie, eigene, "Eigene Einstellung"
- (void)rebuildPresets {
    NSArray *presets = _app.presets;
    if ([presets isEqualToArray:_presetList]) return;
    _presetList = presets;
    [_presets removeAllItems];
    [presets enumerateObjectsUsingBlock:^(NSDictionary *p, NSUInteger i, BOOL *stop) {
        if ([p[@"user"] boolValue] && (i == 0 || ![presets[i - 1][@"user"] boolValue])) [self->_presets.menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:p[@"name"] action:nil keyEquivalent:@""];
        item.representedObject = @(i);
        [self->_presets.menu addItem:item];
    }];
    [_presets.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *custom = [[NSMenuItem alloc] initWithTitle:@"Eigene Einstellung" action:nil keyEquivalent:@""];
    custom.enabled = NO;
    [_presets.menu addItem:custom];
}

- (void)savePreset:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Preset speichern";
    alert.informativeText = @"Speichert Lautstärke, Übergangsfrequenz, Bass-Timing, Tiefbass-Schutz und Maximalpegel. Ein vorhandenes Preset mit gleichem Namen wird ersetzt.";
    [alert addButtonWithTitle:@"Speichern"];
    [alert addButtonWithTitle:@"Abbrechen"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    field.placeholderString = @"Name, z. B. Abends Film";
    NSInteger current = [_app currentPresetIndex];
    if (current >= 0 && [_app.presets[current][@"user"] boolValue]) field.stringValue = _app.presets[current][@"name"];
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
        NSString *name = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (r != NSAlertFirstButtonReturn || name.length == 0) return;
        [self->_app saveUserPresetNamed:name];
        [self refresh];
    }];
}

- (void)deletePreset:(id)sender {
    NSInteger current = [_app currentPresetIndex];
    if (current < 0 || ![_app.presets[current][@"user"] boolValue]) return;
    [_app deleteUserPresetNamed:_app.presets[current][@"name"]];
    [self refresh];
}

- (void)changeLevel:(NSSlider *)sender {
    [_app setLevelDB:LevelDBFromSlider(sender.doubleValue, LevelStyleIsDB())];
    [self updateValueLabels];
    [self syncPreset];
}

- (void)changeCrossover:(NSSlider *)sender {
    double hz = round(sender.doubleValue / 5) * 5;
    [_app setCrossoverHz:hz];
    [self updateValueLabels];
    [self syncPreset];
}

- (void)changeOffset:(NSSlider *)sender {
    [_app setOffsetMs:round(sender.doubleValue)];
    [self updateValueLabels];
    [self syncPreset];
}

- (void)syncPreset {
    [self rebuildPresets];
    NSInteger preset = [_app currentPresetIndex];
    NSInteger item = preset >= 0 ? [_presets indexOfItemWithRepresentedObject:@(preset)] : -1;
    [_presets selectItemAtIndex:item >= 0 ? item : _presets.numberOfItems - 1];
    _deletePreset.enabled = preset >= 0 && [_presetList[preset][@"user"] boolValue];
}

- (void)toggleGate:(NSButton *)sender { [_app toggleGateUID:sender.identifier]; [self refresh]; }
- (void)toggleIdle:(NSButton *)sender { [_app setIdleStandby:sender.state == NSControlStateValueOn]; }
- (void)toggleLogin:(NSButton *)sender { [_app setLaunchAtLogin:sender.state == NSControlStateValueOn]; [self refresh]; }
- (void)chooseLevelStyle:(NSPopUpButton *)sender { [_app setLevelStyleDB:sender.indexOfSelectedItem == 1]; [self refresh]; }
- (void)selectItemIn:(NSPopUpButton *)popup value:(double)value {
    for (NSMenuItem *i in popup.itemArray) {
        if (fabs([i.representedObject doubleValue] - value) < 0.5) [popup selectItem:i];
    }
}
- (void)chooseSubsonic:(NSPopUpButton *)sender { [_app setSubsonicHz:[sender.selectedItem.representedObject doubleValue]]; [self syncPreset]; }
- (void)chooseMaxLevel:(NSPopUpButton *)sender { [_app setMaxLevelDB:[sender.selectedItem.representedObject doubleValue]]; [self syncPreset]; }
- (void)chooseDevice:(NSPopUpButton *)sender { [_app setBassJumpUID:sender.selectedItem.representedObject]; [self refresh]; }

@end
