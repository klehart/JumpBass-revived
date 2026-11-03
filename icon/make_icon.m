// Zeichnet das App-Icon und erzeugt AppIcon.icns.
// Aufruf: clang -fobjc-arc -framework Cocoa icon/make_icon.m -o /tmp/make_icon && /tmp/make_icon icon
//
// Motiv: kleiner Aluminium-Subwoofer mit Lautsprechergitter oben, davor orange Schallwellen –
// angelehnt an das Original-Icon (Produktfoto), aber gezeichnet und ohne Herstellerlogo.

#import <Cocoa/Cocoa.h>

static NSColor *RGB(int r, int g, int b, CGFloat a) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

static void Draw(CGFloat s) {
    NSAffineTransform *t = [NSAffineTransform transform];
    [t scaleBy:s / 1024.0];
    [t concat];

    // Hintergrund: dunkles Squircle im macOS-Raster (824 pt Fläche, 100 pt Rand)
    NSRect tile = NSMakeRect(100, 100, 824, 824);
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:185 yRadius:185];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *drop = [[NSShadow alloc] init];
    drop.shadowOffset = NSMakeSize(0, -12);
    drop.shadowBlurRadius = 28;
    drop.shadowColor = [NSColor colorWithWhite:0 alpha:0.45];
    [drop set];
    [RGB(30, 30, 34, 1) setFill];
    [bg fill];
    [NSGraphicsContext restoreGraphicsState];
    [[[NSGradient alloc] initWithStartingColor:RGB(52, 52, 58, 1) endingColor:RGB(16, 16, 19, 1)] drawInBezierPath:bg angle:-90];

    [NSGraphicsContext saveGraphicsState];
    [bg addClip];
    // warmes Leuchten unter dem Lautsprecher
    NSGradient *glow = [[NSGradient alloc] initWithColorsAndLocations:RGB(255, 140, 30, 0.55), 0.0, RGB(255, 120, 20, 0.0), 1.0, nil];
    [glow drawFromCenter:NSMakePoint(512, 300) radius:0 toCenter:NSMakePoint(512, 300) radius:420 options:0];

    // Schallwellen über dem Gerät
    for (int i = 0; i < 3; i++) {
        NSBezierPath *wave = [NSBezierPath bezierPath];
        CGFloat r = 285 + i * 62;   // flache, breite Wellen: Bass, der nach oben "springt"
        [wave appendBezierPathWithArcWithCenter:NSMakePoint(512, 380) radius:r startAngle:66 - i * 3 endAngle:114 + i * 3];
        wave.lineWidth = 26 - i * 4;
        wave.lineCapStyle = NSLineCapStyleRound;
        [RGB(255, 145, 40, 0.95 - i * 0.25) setStroke];
        [wave stroke];
    }

    // Schatten unter dem Gehäuse
    NSGradient *shadow = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0 alpha:0.55] endingColor:[NSColor colorWithWhite:0 alpha:0]];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *squash = [NSAffineTransform transform];
    [squash translateXBy:512 yBy:262];
    [squash scaleXBy:1 yBy:0.16];
    [squash concat];
    [shadow drawFromCenter:NSZeroPoint radius:0 toCenter:NSZeroPoint radius:330 options:0];
    [NSGraphicsContext restoreGraphicsState];

    // Oberseite: schwarzes Gitter in Perspektive
    CGFloat fl = 222, fr = 802, ft = 520, fb = 285;   // Front
    CGFloat bl = 268, br = 756, bt = 618;               // hintere Kante
    NSBezierPath *top = [NSBezierPath bezierPath];
    [top moveToPoint:NSMakePoint(fl, ft)];
    [top lineToPoint:NSMakePoint(fr, ft)];
    [top lineToPoint:NSMakePoint(br, bt)];
    [top lineToPoint:NSMakePoint(bl, bt)];
    [top closePath];
    [[[NSGradient alloc] initWithStartingColor:RGB(46, 46, 50, 1) endingColor:RGB(12, 12, 14, 1)] drawInBezierPath:top angle:90];
    [NSGraphicsContext saveGraphicsState];
    [top addClip];
    int lines = 64;
    for (int i = 0; i <= lines; i++) {
        CGFloat f = (CGFloat)i / lines;
        NSBezierPath *l = [NSBezierPath bezierPath];
        [l moveToPoint:NSMakePoint(fl + (fr - fl) * f, ft)];
        [l lineToPoint:NSMakePoint(bl + (br - bl) * f, bt)];
        l.lineWidth = 3.2;
        [RGB(0, 0, 0, 0.75) setStroke];
        [l stroke];
    }
    [NSGraphicsContext restoreGraphicsState];

    // Front: gebürstetes Aluminium
    NSBezierPath *front = [NSBezierPath bezierPath];
    [front moveToPoint:NSMakePoint(fl, ft)];
    [front lineToPoint:NSMakePoint(fr, ft)];
    [front lineToPoint:NSMakePoint(fr, fb + 34)];
    [front curveToPoint:NSMakePoint(fr - 34, fb) controlPoint1:NSMakePoint(fr, fb + 12) controlPoint2:NSMakePoint(fr - 12, fb)];
    [front lineToPoint:NSMakePoint(fl + 34, fb)];
    [front curveToPoint:NSMakePoint(fl, fb + 34) controlPoint1:NSMakePoint(fl + 12, fb) controlPoint2:NSMakePoint(fl, fb + 12)];
    [front closePath];
    [[[NSGradient alloc] initWithColorsAndLocations:RGB(248, 248, 250, 1), 0.0, RGB(214, 216, 221, 1), 0.55, RGB(176, 178, 184, 1), 1.0, nil] drawInBezierPath:front angle:-90];
    [NSGraphicsContext saveGraphicsState];
    [front addClip];
    for (int y = (int)fb; y < ft; y += 5) {               // feine Schleifspuren
        NSBezierPath *brush = [NSBezierPath bezierPathWithRect:NSMakeRect(fl, y, fr - fl, 1.2)];
        [RGB(255, 255, 255, (y % 3) ? 0.10 : 0.05) setFill];
        [brush fill];
    }
    [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0 alpha:0.18] endingColor:[NSColor colorWithWhite:0 alpha:0]]
        drawInRect:NSMakeRect(fl, fb, 60, ft - fb) angle:0];
    [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0 alpha:0.18] endingColor:[NSColor colorWithWhite:0 alpha:0]]
        drawInRect:NSMakeRect(fr - 60, fb, 60, ft - fb) angle:180];
    [NSGraphicsContext restoreGraphicsState];
    NSBezierPath *edge = [NSBezierPath bezierPath];
    [edge moveToPoint:NSMakePoint(fl + 2, ft - 2)];
    [edge lineToPoint:NSMakePoint(fr - 2, ft - 2)];
    edge.lineWidth = 4;
    [[NSColor colorWithWhite:1 alpha:0.9] setStroke];
    [edge stroke];

    // Emblem auf der Front: Membran mit Schall nach beiden Seiten, eingeprägt
    NSPoint c = NSMakePoint(512, 402);
    NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 18, c.y - 18, 36, 36)];
    [RGB(255, 140, 30, 1) setFill];
    [dot fill];
    for (int side = 0; side < 2; side++) {
        for (int i = 0; i < 2; i++) {
            NSBezierPath *a = [NSBezierPath bezierPath];
            CGFloat r = 38 + i * 22, mid = side ? 0 : 180;
            [a appendBezierPathWithArcWithCenter:c radius:r startAngle:mid - 38 endAngle:mid + 38];
            a.lineWidth = 9;
            a.lineCapStyle = NSLineCapStyleRound;
            [RGB(255, 140, 30, 1.0 - i * 0.35) setStroke];
            [a stroke];
        }
    }
    [NSGraphicsContext restoreGraphicsState];

    // feiner Rand um die Kachel
    [[NSColor colorWithWhite:1 alpha:0.08] setStroke];
    bg.lineWidth = 2;
    [bg stroke];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *out = argc > 1 ? @(argv[1]) : @".";
        NSString *set = [out stringByAppendingPathComponent:@"AppIcon.iconset"];
        [[NSFileManager defaultManager] createDirectoryAtPath:set withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSNumber *n in @[@16, @32, @128, @256, @512]) {
            for (int scale = 1; scale <= 2; scale++) {
                NSInteger px = n.integerValue * scale;
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                [NSGraphicsContext saveGraphicsState];
                NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
                Draw(px);
                [NSGraphicsContext restoreGraphicsState];
                NSString *name = scale == 1 ? [NSString stringWithFormat:@"icon_%@x%@.png", n, n] : [NSString stringWithFormat:@"icon_%@x%@@2x.png", n, n];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[set stringByAppendingPathComponent:name] atomically:YES];
            }
        }
        NSTask *task = [NSTask launchedTaskWithLaunchPath:@"/usr/bin/iconutil" arguments:@[@"-c", @"icns", set, @"-o", [out stringByAppendingPathComponent:@"AppIcon.icns"]]];
        [task waitUntilExit];
        [[NSFileManager defaultManager] removeItemAtPath:set error:nil];
        return task.terminationStatus;
    }
}
