// JumpBass Revived – Fenster
//
// Angelehnt an die Original-Oberfläche: dunkles HUD-Fenster, analoges VU-Meter,
// Ein/Aus-Schalter und die Bereiche "Klang" und "Einstellungen".

#import "JumpBassRevived.h"
#include <math.h>

static const CGFloat kWidth = 460, kHeight = 626;

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
@property (nonatomic) BOOL limiting;   // Begrenzer greift (Maximalpegel erreicht)
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

    // Begrenzer-Lampe: leuchtet, wenn der Bass am Maximalpegel abgeregelt wird
    NSDictionary *limAttrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightBold],
                                NSForegroundColorAttributeName: self.limiting ? red : [ink colorWithAlphaComponent:0.22] };
    NSSize ls = [@"LIMIT" sizeWithAttributes:limAttrs];
    [@"LIMIT" drawAtPoint:NSMakePoint(NSMaxX(b) - 22 - ls.width, NSMinY(b) + 36) withAttributes:limAttrs];

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
    NSView *_soundPane, *_settingsPane, *_calPane;
    NSWindow *_calSheet;
    Calibrator *_calibrator;
    NSButton *_calTiming, *_calMax, *_calVolume, *_calStart, *_calReset;
    NSProgressIndicator *_calProgress;
    NSTextField *_calIntro, *_calStatus, *_calResult;
    NSPopUpButton *_presets, *_device, *_levelStyle, *_subsonic, *_maxLevel;
    NSButton *_savePreset, *_deletePreset;
    NSArray *_presetList;
    NSSlider *_level, *_crossover, *_offset;
    NSTextField *_levelValue, *_crossoverValue, *_offsetValue;
    NSView *_gateBox;
    NSButton *_idle, *_login, *_guard, *_updates, *_update;
    NSPopover *_infoPopover;
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

// Kleines (i) direkt hinter dem Text einer Einstellung: Mauszeiger darauf zeigt die Erklärung als Tooltip,
// ein Klick als Popover.
- (void)addInfo:(NSString *)text after:(NSControl *)control {
    NSRect f = control.frame;
    CGFloat textWidth = MIN(control.intrinsicContentSize.width, f.size.width);
    [self addInfoAt:NSMakePoint(NSMinX(f) + textWidth + 3, NSMinY(f) + (f.size.height - 16) / 2) in:control.superview text:text];
}

- (void)addInfoAt:(NSPoint)p in:(NSView *)view text:(NSString *)text {
    NSButton *b = [NSButton buttonWithTitle:@"ⓘ" target:self action:@selector(showInfo:)];
    if (@available(macOS 11.0, *)) {
        NSImage *img = [NSImage imageWithSystemSymbolName:@"info.circle" accessibilityDescription:L(@"Erklärung")];
        if (img) { b.image = img; b.imagePosition = NSImageOnly; }
    }
    b.bordered = NO;
    if (@available(macOS 10.14, *)) b.contentTintColor = NSColor.secondaryLabelColor;
    b.toolTip = text;
    b.frame = NSMakeRect(p.x, p.y, 16, 16);
    [view addSubview:b];
}

// Überschrift einer Einstellung mit (i) dahinter
- (void)heading:(NSString *)title frame:(NSRect)frame in:(NSView *)view info:(NSString *)info {
    NSTextField *l = [self label:title size:13 weight:NSFontWeightMedium frame:frame];
    [view addSubview:l];
    [self addInfo:info after:l];
}

- (void)showInfo:(NSButton *)sender {
    [_infoPopover close];
    NSTextField *text = [NSTextField wrappingLabelWithString:sender.toolTip];
    text.font = [NSFont systemFontOfSize:12];
    text.preferredMaxLayoutWidth = 280;
    NSSize size = text.fittingSize;
    text.frame = NSMakeRect(14, 12, 280, size.height);
    NSViewController *vc = [[NSViewController alloc] init];
    vc.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 308, size.height + 24)];
    [vc.view addSubview:text];
    _infoPopover = [[NSPopover alloc] init];
    _infoPopover.contentViewController = vc;
    _infoPopover.behavior = NSPopoverBehaviorTransient;
    [_infoPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];
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
    _status = [self label:@"" size:12 weight:NSFontWeightRegular frame:NSMakeRect(24, 62, 250, 18)];
    _status.textColor = [NSColor secondaryLabelColor];
    [root addSubview:_status];
    if (@available(macOS 10.15, *)) {
        NSSwitch *sw = [[NSSwitch alloc] initWithFrame:NSMakeRect(kWidth - 24 - 40, 40, 40, 24)];
        sw.target = self;
        sw.action = @selector(togglePower:);
        [root addSubview:sw];
        _power = sw;
    } else {
        _power = [self checkbox:L(@"An") frame:NSMakeRect(kWidth - 24 - 50, 40, 50, 24) action:@selector(togglePower:)];
        [root addSubview:_power];
    }
    // Hinweis auf eine neue Version, rechts neben der Statuszeile
    _update = [NSButton buttonWithTitle:@"" target:_app action:@selector(openUpdate:)];
    _update.bordered = NO;
    _update.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    if (@available(macOS 10.14, *)) _update.contentTintColor = Accent();
    _update.alignment = NSTextAlignmentRight;
    _update.frame = NSMakeRect(kWidth - 24 - 160, 62, 160, 18);
    _update.hidden = YES;
    [root addSubview:_update];

    _meter = [[VUMeterView alloc] initWithFrame:NSMakeRect(24, 92, kWidth - 48, 170)];
    [root addSubview:_meter];

    _tabs = [NSSegmentedControl segmentedControlWithLabels:@[L(@"Klang"), L(@"Einstellungen")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(switchTab:)];
    // BassJump-Lautstärke, wie im Original direkt unter der Anzeige
    NSImageView *quiet = [self symbol:@"speaker.fill" fallback:@"–" frame:NSMakeRect(24, 276, 22, 22)];
    NSImageView *loud = [self symbol:@"speaker.wave.3.fill" fallback:@"+" frame:NSMakeRect(kWidth - 24 - 86 - 30, 276, 26, 22)];
    [root addSubview:quiet];
    [root addSubview:loud];
    _level = [self sliderMin:0 max:100 frame:NSMakeRect(52, 275, kWidth - 52 - 24 - 86 - 34, 24) action:@selector(changeLevel:)];
    [root addSubview:_level];
    _levelValue = [self label:@"" size:13 weight:NSFontWeightMedium frame:NSMakeRect(kWidth - 24 - 78, 278, 62, 18)];
    [root addSubview:_levelValue];
    [self addInfoAt:NSMakePoint(kWidth - 24 - 16, 279) in:root text:L(@"BassJump-Lautstärke im Verhältnis zu den Lautsprechern: 100 % = ausgewogen, 200 % = +24 dB.\n\n"
                   "Sie folgt automatisch der Lautstärke des Macs – bei externen Monitoren auch deren eigener Lautstärke, egal ob "
                   "über eine App wie MonitorControl, BetterDisplay oder Lunar oder an den Tasten des Monitors verstellt. "
                   "Jede Ausgabe merkt sich ihren eigenen Wert. Hohe Werte bringen den Bass schnell an den Maximalpegel; "
                   "dann leuchtet LIMIT im Messgerät und laute Stellen werden abgeregelt.")];

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
    [self buildCalibrationSheet];

    [_window center];
}

- (void)buildSoundPane {
    CGFloat lx = 24, cx = 168, cw = 200, vx = 376, y = 10, row = 46;

    [self heading:L(@"Klangeinstellung") frame:NSMakeRect(lx, y + 3, 140, 18) in:_soundPane info:
        L(@"Fertige Kombinationen aus Übergangsfrequenz und Lautstärke.\n\n"
         "Mit + speicherst du die aktuellen Werte – inklusive Bass-Timing, Tiefbass-Schutz und Maximalpegel – als eigenes Preset; "
         "mit − löschst du das ausgewählte eigene Preset. „Eigene Einstellung“ heißt: Die Werte passen zu keinem Preset.")];
    _presets = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cx - 3, y - 1, cw + 6, 26) pullsDown:NO];
    _presets.target = self;
    _presets.action = @selector(choosePreset:);
    _presets.autoenablesItems = NO;
    [_soundPane addSubview:_presets];
    _savePreset = [self iconButton:@"plus" fallback:@"+" frame:NSMakeRect(vx, y, 30, 24) action:@selector(savePreset:)];
    _savePreset.toolTip = L(@"Aktuelle Einstellung als eigenes Preset speichern");
    _deletePreset = [self iconButton:@"minus" fallback:@"−" frame:NSMakeRect(vx + 34, y, 30, 24) action:@selector(deletePreset:)];
    _deletePreset.toolTip = L(@"Ausgewähltes eigenes Preset löschen");
    [_soundPane addSubview:_savePreset];
    [_soundPane addSubview:_deletePreset];
    y += row;


    [self heading:L(@"Übergangsfrequenz") frame:NSMakeRect(lx, y + 3, 140, 18) in:_soundPane info:
        L(@"Bis zu dieser Frequenz spielt der BassJump, darüber nur die Lautsprecher.\n\n"
         "80–120 Hz: nur tiefer Bass, der BassJump fällt nicht als eigene Quelle auf. "
         "150 Hz: gute Wahl für MacBook-Lautsprecher (Standard). "
         "Ab etwa 250 Hz klingt es voller, aber man hört, dass der Ton auch aus dem BassJump kommt.")];
    _crossover = [self sliderMin:40 max:500 frame:NSMakeRect(cx, y, cw, 24) action:@selector(changeCrossover:)];
    [_soundPane addSubview:_crossover];
    _crossoverValue = [self label:@"" size:12 weight:NSFontWeightRegular frame:NSMakeRect(vx, y + 4, 70, 18)];
    [_soundPane addSubview:_crossoverValue];
    y += row;

    [self heading:L(@"Bass-Timing") frame:NSMakeRect(lx, y + 3, 140, 18) in:_soundPane info:
        L(@"Gleicht aus, dass Lautsprecher und BassJump den Ton unterschiedlich schnell ausgeben.\n\n"
         "0 = automatisch aus den gemeldeten Gerätelatenzen – das passt meistens. Klingt der Bass verwaschen "
         "oder „hinterher“, in kleinen Schritten verschieben: plus = Bass später, minus = Bass früher.")];
    _offset = [self sliderMin:-100 max:200 frame:NSMakeRect(cx, y, cw, 24) action:@selector(changeOffset:)];
    [_soundPane addSubview:_offset];
    _offsetValue = [self label:@"" size:12 weight:NSFontWeightRegular frame:NSMakeRect(vx, y + 4, 70, 18)];
    [_soundPane addSubview:_offsetValue];
    NSTextField *hint = [self label:L(@"0 = automatisch abgeglichen · plus = Bass später") size:11 weight:NSFontWeightRegular frame:NSMakeRect(cx, y + 26, 280, 16)];
    hint.textColor = [NSColor tertiaryLabelColor];
    [_soundPane addSubview:hint];
    y += row + 8;

    // Schutz vor Krachen: Frequenzen, die der kleine Treiber nicht schafft, und zu hohe Spitzen
    [self heading:L(@"Tiefbass-Schutz") frame:NSMakeRect(lx, y + 3, 140, 18) in:_soundPane info:
        L(@"Filtert Frequenzen unterhalb des gewählten Werts heraus.\n\n"
         "So tiefe Töne kann der kleine Lautsprecher kaum hörbar wiedergeben, sie brauchen aber viel Membranhub "
         "und Verstärkerleistung – bei lauter Musik führt das zum Krachen. Gemessen ist 40 Hz am BassJump über 10 dB leiser "
         "als 60 Hz, übersteuert aber genauso früh. 50 Hz ist daher die Voreinstellung.")];
    _subsonic = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cx - 3, y - 1, cw + 6, 26) pullsDown:NO];
    for (NSNumber *hz in @[@0, @30, @40, @50, @60, @70]) {
        [_subsonic addItemWithTitle:hz.intValue ? [NSString stringWithFormat:L(@"unter %@ Hz ausblenden"), hz] : L(@"Aus")];
        _subsonic.lastItem.representedObject = hz;
    }
    _subsonic.target = self;
    _subsonic.action = @selector(chooseSubsonic:);
    [_soundPane addSubview:_subsonic];
    y += row;

    [self heading:L(@"Maximalpegel") frame:NSMakeRect(lx, y + 3, 140, 18) in:_soundPane info:
        L(@"Obergrenze für das Bass-Signal. Lautere Stellen regelt ein Begrenzer weich ab, statt sie verzerren zu lassen – "
         "dann leuchtet LIMIT im Messgerät.\n\n"
         "Gemessen übersteuert der BassJump ab etwa -10 dB: Darüber wird er nicht mehr lauter, sondern kracht nur. "
         "-12 dB lässt etwas Reserve. Kracht es trotzdem, weiter senken. Leuchtet LIMIT ständig, "
         "ist die BassJump-Lautstärke zu hoch eingestellt.")];
    _maxLevel = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cx - 3, y - 1, cw + 6, 26) pullsDown:NO];
    _maxLevel.target = self;
    _maxLevel.action = @selector(chooseMaxLevel:);
    [_soundPane addSubview:_maxLevel];
}

- (void)buildSettingsPane {
    [self heading:L(@"BassJump spielt mit bei:") frame:NSMakeRect(24, 4, 200, 18) in:_settingsPane info:
        L(@"Der Bass wird nur zugeschaltet, wenn der Ton über eines dieser Geräte läuft – zum Beispiel MacBook-Lautsprecher "
         "und Monitor, aber nicht Kopfhörer oder AirPods. „Immer“ schaltet ihn bei jeder Ausgabe zu.")];
    _gateBox = [[FlippedView alloc] initWithFrame:NSMakeRect(24, 28, 200, 180)];
    [_settingsPane addSubview:_gateBox];

    CGFloat x = 240, w = kWidth - x - 20;
    _idle = [self checkbox:L(@"Ruhemodus bei Stille") frame:NSMakeRect(x, 2, w - 20, 22) action:@selector(toggleIdle:)];
    _login = [self checkbox:L(@"Beim Anmelden starten") frame:NSMakeRect(x, 28, w - 20, 22) action:@selector(toggleLogin:)];
    _guard = [self checkbox:L(@"Nur als Subwoofer nutzen") frame:NSMakeRect(x, 54, w - 20, 22) action:@selector(toggleGuard:)];
    _updates = [self checkbox:L(@"Nach Updates suchen") frame:NSMakeRect(x, 80, w - 20, 22) action:@selector(toggleUpdates:)];
    [_settingsPane addSubview:_idle];
    [_settingsPane addSubview:_login];
    [_settingsPane addSubview:_guard];
    [_settingsPane addSubview:_updates];
    [self addInfo:L(@"Nach 10 Sekunden Stille gibt JumpBass den BassJump frei und schaltet ihn stumm. Die Lautsprecher spielen dann "
                   "direkt, ohne Umweg über JumpBass, und der Mac rechnet nichts. Der BassJump kann so selbst in seinen Standby gehen.\n\n"
                   "Am Klang ändert das nichts: Ein Rauschen des BassJump war in der Messung auch ohne Ruhemodus nicht hörbar. "
                   "Sobald wieder Ton kommt, schaltet sich der Bass automatisch zu – die ersten Sekundenbruchteile noch ohne Bass. "
                   "Stört das, den Ruhemodus ausschalten.") after:_idle];
    [self addInfo:L(@"Startet JumpBass automatisch, sobald du dich am Mac anmeldest.") after:_login];
    [self addInfo:L(@"Der BassJump meldet sich bei macOS zusätzlich als Mikrofon und Lautsprecher („BassJump Core“). "
                   "Entfernen lässt sich das ohne Treiber nicht.\n\n"
                   "Ist diese Option an, wählt JumpBass sofort das vorherige Mikrofon bzw. die vorherige Ausgabe zurück, "
                   "wenn macOS den BassJump dafür auswählt – Diktat, Siri, Anrufe und Hinweistöne laufen dann nicht über ihn.") after:_guard];
    [self addInfo:L(@"Fragt einmal am Tag bei GitHub nach, ob es eine neue Version gibt, und zeigt sie dann im Fenster und im Menü an. "
                   "Dabei werden keine Daten über dich oder deinen Mac übertragen. Installiert wird nichts automatisch.") after:_updates];

    [self heading:L(@"BassJump-Gerät") frame:NSMakeRect(x, 116, w, 18) in:_settingsPane info:
        L(@"Welches Gerät als Subwoofer dient. „Automatisch erkennen“ findet den BassJump an seinem Namen bzw. seiner USB-Kennung.")];
    _device = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x - 3, 138, w + 6, 26) pullsDown:NO];
    _device.target = self;
    _device.action = @selector(chooseDevice:);
    [_settingsPane addSubview:_device];

    [self heading:L(@"Lautstärkeregler in") frame:NSMakeRect(x, 172, w, 18) in:_settingsPane info:
        L(@"Ob der BassJump-Regler in Prozent (100 % = normal) oder in Dezibel angezeigt wird. Am Klang ändert das nichts.")];
    _levelStyle = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x - 3, 194, w + 6, 26) pullsDown:NO];
    [_levelStyle addItemsWithTitles:@[L(@"Prozent (100 % = normal)"), L(@"Dezibel (Bass-Pegel)")]];
    _levelStyle.target = self;
    _levelStyle.action = @selector(chooseLevelStyle:);
    [_settingsPane addSubview:_levelStyle];

    NSButton *calibrate = [NSButton buttonWithTitle:L(@"Kalibrieren …") target:self action:@selector(showCalibration:)];
    calibrate.frame = NSMakeRect(20, 230, 150, 28);
    [_settingsPane addSubview:calibrate];
    [self addInfoAt:NSMakePoint(176, 236) in:_settingsPane text:L(@"Misst mit dem Mikrofon des Macs Bass-Timing, Maximalpegel und bei Monitoren die Lautstärkekurve und stellt die Werte passend ein.")];
    NSButton *uninstall = [NSButton buttonWithTitle:L(@"Deinstallieren …") target:_app action:@selector(uninstall:)];
    uninstall.frame = NSMakeRect(kWidth - 20 - 150, 230, 150, 28);
    [_settingsPane addSubview:uninstall];
}

// Kleines Fenster (Sheet) über dem Hauptfenster
- (void)buildCalibrationSheet {
    _calSheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kWidth, 286) styleMask:NSWindowStyleMaskTitled
                                              backing:NSBackingStoreBuffered defer:YES];
    _calSheet.title = L(@"Kalibrieren");
    _calSheet.appearance = _window.appearance;
    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 286)];
    if (@available(macOS 10.14, *)) bg.material = NSVisualEffectMaterialHUDWindow;
    bg.state = NSVisualEffectStateActive;
    _calSheet.contentView = bg;
    FlippedView *content = [[FlippedView alloc] initWithFrame:bg.bounds];
    [bg addSubview:content];
    _calPane = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 20, kWidth, 230)];
    [content addSubview:_calPane];
    NSButton *close = [NSButton buttonWithTitle:L(@"Schließen") target:self action:@selector(closeCalibration:)];
    close.keyEquivalent = @"\e";
    close.frame = NSMakeRect(kWidth - 24 - 110, 244, 116, 30);
    [content addSubview:close];

    CGFloat x = 24, w = kWidth - 48;
    _calIntro = [NSTextField wrappingLabelWithString:@""];
    _calIntro.font = [NSFont systemFontOfSize:12];
    _calIntro.textColor = NSColor.secondaryLabelColor;
    _calIntro.frame = NSMakeRect(x, 0, w, 64);
    [_calPane addSubview:_calIntro];

    // Nebeneinander, jeweils mit Platz für das (i)
    CGFloat cx = x;
    _calTiming = [self checkbox:L(@"Bass-Timing") frame:NSMakeRect(cx, 74, 0, 22) action:nil];
    cx += _calTiming.intrinsicContentSize.width + 28;
    _calMax = [self checkbox:L(@"Maximalpegel") frame:NSMakeRect(cx, 74, 0, 22) action:nil];
    cx += _calMax.intrinsicContentSize.width + 28;
    _calVolume = [self checkbox:L(@"Lautstärkekurve") frame:NSMakeRect(cx, 74, 0, 22) action:nil];
    for (NSButton *b in @[_calTiming, _calMax, _calVolume]) [b setFrameSize:NSMakeSize(b.intrinsicContentSize.width, 22)];
    _calTiming.state = _calMax.state = NSControlStateValueOn;
    [_calPane addSubview:_calTiming];
    [_calPane addSubview:_calMax];
    [_calPane addSubview:_calVolume];
    [self addInfo:L(@"Misst die Verzögerung zwischen Lautsprechern und BassJump und stellt das Bass-Timing so ein, dass beide gleichzeitig ankommen. Gilt für die aktuelle Ausgabe.") after:_calTiming];
    [self addInfo:L(@"Spielt Tieftöne in steigender Lautstärke auf dem BassJump, bis er hörbar übersteuert, und setzt den Maximalpegel knapp darunter. Dabei wird es kurz laut. Gilt für alle Ausgaben.") after:_calMax];
    [self addInfo:L(@"Nur bei externen Monitoren mit eigener Lautstärke: Verstellt sie kurz über die Lautstärketasten und misst, wie stark der Monitor lauter wird, damit der Bass genau mitgeht. Dafür muss eine App wie MonitorControl, BetterDisplay oder Lunar die Tasten an den Monitor weitergeben. Braucht die Freigabe „Bedienungshilfen“.") after:_calVolume];

    _calStart = [NSButton buttonWithTitle:L(@"Kalibrierung starten") target:self action:@selector(startCalibration:)];
    _calStart.frame = NSMakeRect(x - 6, 104, 190, 30);
    [_calPane addSubview:_calStart];
    _calProgress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(x + 196, 110, w - 196, 20)];
    _calProgress.indeterminate = NO;
    _calProgress.minValue = 0;
    _calProgress.maxValue = 1;
    _calProgress.hidden = YES;
    [_calPane addSubview:_calProgress];
    _calStatus = [self label:@"" size:12 weight:NSFontWeightRegular frame:NSMakeRect(x, 140, w, 34)];
    _calStatus.lineBreakMode = NSLineBreakByWordWrapping;
    _calStatus.maximumNumberOfLines = 2;
    [_calPane addSubview:_calStatus];

    _calResult = [NSTextField wrappingLabelWithString:@""];
    _calResult.font = [NSFont systemFontOfSize:12];
    _calResult.frame = NSMakeRect(x, 178, w - 130, 50);
    [_calPane addSubview:_calResult];
    _calReset = [NSButton buttonWithTitle:L(@"Zurücksetzen") target:self action:@selector(resetCalibration:)];
    _calReset.frame = NSMakeRect(kWidth - 24 - 120, 182, 126, 30);
    [_calPane addSubview:_calReset];
}

- (void)refreshCalibration {
    NSString *output = [_app currentOutputName] ?: @"–";
    _calIntro.stringValue = [NSString stringWithFormat:L(@"Misst mit dem Mikrofon des Macs, wie der BassJump mit „%@“ zusammenspielt, und stellt die Werte passend ein. Dauert etwa eine halbe Minute, kurz wird es laut. Vorher: Raum still, Mac und BassJump wie beim Hören aufstellen, normale Lautstärke."), output];
    BOOL monitor = [_app monitorVolume] >= 0;
    BOOL running = _calibrator.running;
    if (monitor != (_calVolume.tag == 1)) {   // nur beim Wechsel der Ausgabe vorbelegen, nicht die Wahl überschreiben
        _calVolume.tag = monitor;
        _calVolume.state = monitor ? NSControlStateValueOn : NSControlStateValueOff;
    }
    _calVolume.enabled = monitor && !running;
    _calTiming.enabled = _calMax.enabled = !running;
    _calStart.title = running ? L(@"Abbrechen") : L(@"Kalibrierung starten");
    _calProgress.hidden = !running;

    NSDictionary *cal = [_app calibrationForCurrentOutput];
    _calReset.hidden = cal == nil || running;
    if (!cal) {
        _calResult.stringValue = [NSString stringWithFormat:L(@"„%@“ ist noch nicht kalibriert."), output];
        return;
    }
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateStyle = NSDateFormatterMediumStyle;
    f.timeStyle = NSDateFormatterShortStyle;
    NSMutableArray *parts = [NSMutableArray array];
    if (cal[@"offsetMs"]) [parts addObject:[NSString stringWithFormat:L(@"Bass-Timing %+.0f ms (Streuung %.1f ms)"), [cal[@"offsetMs"] doubleValue], [cal[@"timingSpreadMs"] doubleValue]]];
    if (cal[@"maxLevelDB"]) {
        [parts addObject:cal[@"clipDB"] ? [NSString stringWithFormat:L(@"Maximalpegel %.0f dB (übersteuert ab %.0f dB)"), [cal[@"maxLevelDB"] doubleValue], [cal[@"clipDB"] doubleValue]]
                                        : [NSString stringWithFormat:L(@"Maximalpegel %.0f dB (keine Übersteuerung gefunden)"), [cal[@"maxLevelDB"] doubleValue]]];
    }
    if (cal[@"volumeExponent"]) [parts addObject:[NSString stringWithFormat:L(@"Lautstärkekurve: doppelte Lautstärke = %+.1f dB"), [cal[@"volumeExponent"] doubleValue] * 20 * log10(2)]];
    _calResult.stringValue = [NSString stringWithFormat:L(@"Zuletzt kalibriert am %@:\n%@"), [f stringFromDate:cal[@"date"]], [parts componentsJoinedByString:@" · "]];
}

- (void)startCalibration:(id)sender {
    if (_calibrator.running) {
        [_calibrator cancel];
        _calStatus.stringValue = L(@"Wird abgebrochen …");
        return;
    }
    BOOL volume = _calVolume.enabled && _calVolume.state == NSControlStateValueOn;
    if (volume && !AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{ (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES })) {
        _calStatus.stringValue = L(@"Für die Lautstärkekurve braucht JumpBass die Freigabe „Bedienungshilfen“. Erteile sie und starte die Kalibrierung erneut.");
        if (getenv("JUMPBASS_DEBUG")) NSLog(@"Kalibrierung: Bedienungshilfen fehlen");
        return;
    }
    if (!_calibrator) _calibrator = [[Calibrator alloc] initWithApp:_app];
    _calProgress.doubleValue = 0;
    _calStatus.stringValue = L(@"Starte …");
    [_calibrator runTiming:_calTiming.state == NSControlStateValueOn maxLevel:_calMax.state == NSControlStateValueOn volume:volume
                  progress:^(NSString *text, double fraction) {
        self->_calStatus.stringValue = text;
        self->_calProgress.doubleValue = fraction;
    } completion:^(NSDictionary *result, NSString *error) {
        if (getenv("JUMPBASS_DEBUG")) NSLog(@"Kalibrierung beendet: %@ %@", result, error);
        if (result.count) [self->_app applyCalibration:result];
        self->_calStatus.stringValue = error ?: result.count ? L(@"Fertig – die gemessenen Werte sind übernommen.") : result ? @"" : L(@"Abgebrochen.");
        [self refresh];
    }];
    [self refreshCalibration];
}

- (void)showCalibration:(id)sender {
    [self refreshCalibration];
    if (!_calSheet.sheetParent) [_window beginSheet:_calSheet completionHandler:nil];
}

- (void)startCalibrationNow {
    _tabs.selectedSegment = 1;
    [self switchTab:_tabs];
    [self showCalibration:nil];
    if (!_calibrator.running) [self startCalibration:nil];
}

- (void)closeCalibration:(id)sender {
    [_calibrator cancel];
    [_window endSheet:_calSheet];
}

- (void)resetCalibration:(id)sender {
    [_app resetCalibration];
    _calStatus.stringValue = L(@"Auf Standardwerte zurückgesetzt.");
    [self refresh];
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
    _tabs.selectedSegment = MIN(tab, 1);
    [self switchTab:_tabs];
    if (tab == 2) [self refreshCalibration];
    NSView *v = tab == 2 ? _calSheet.contentView : _window.contentView;
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
    BOOL limiting = [_app limiterActive];
    if (limiting != _meter.limiting) {
        _meter.limiting = limiting;
        _meter.needsDisplay = YES;
    }
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
    double maxLevel = [d doubleForKey:@"maxLevelDB"];
    NSArray *choices = MaxLevelChoices(maxLevel);
    if (![[_maxLevel.itemArray valueForKey:@"representedObject"] isEqualToArray:choices]) {
        [_maxLevel removeAllItems];
        for (NSNumber *db in choices) {
            [_maxLevel addItemWithTitle:MaxLevelTitle(db)];
            _maxLevel.lastItem.representedObject = db;
        }
    }
    [self selectItemIn:_maxLevel value:maxLevel];
    _idle.state = [d boolForKey:@"idleStandby"];
    _login.state = [_app launchAtLogin];
    _idle.enabled = [_app usesSystemTap];
    _guard.state = [_app guardDefaultsEnabled];
    _updates.state = [_app checkUpdatesEnabled];
    NSString *update = [_app availableUpdate];
    _update.hidden = update == nil;
    if (update) _update.title = [NSString stringWithFormat:L(@"Version %@ verfügbar"), update];

    [self refreshDevices];
    [self refreshCalibration];
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
    NSButton *always = [self checkbox:L(@"Immer (jede Ausgabe)") frame:NSMakeRect(0, y, 200, 22) action:@selector(toggleGate:)];
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
    [_device addItemWithTitle:L(@"Automatisch erkennen")];
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
    NSMenuItem *custom = [[NSMenuItem alloc] initWithTitle:L(@"Eigene Einstellung") action:nil keyEquivalent:@""];
    custom.enabled = NO;
    [_presets.menu addItem:custom];
}

- (void)savePreset:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = L(@"Preset speichern");
    alert.informativeText = L(@"Speichert Lautstärke, Übergangsfrequenz, Bass-Timing, Tiefbass-Schutz und Maximalpegel. Ein vorhandenes Preset mit gleichem Namen wird ersetzt.");
    [alert addButtonWithTitle:L(@"Speichern")];
    [alert addButtonWithTitle:L(@"Abbrechen")];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    field.placeholderString = L(@"Name, z. B. Abends Film");
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
- (void)toggleGuard:(NSButton *)sender { [_app setGuardDefaults:sender.state == NSControlStateValueOn]; }
- (void)toggleUpdates:(NSButton *)sender { [_app setCheckUpdates:sender.state == NSControlStateValueOn]; [self refresh]; }
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
