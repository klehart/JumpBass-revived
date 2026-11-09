// Lautstärke externer Monitore direkt beim Monitor abfragen (DDC/CI: VCP 0x62 Lautstärke, 0x8D Stummschaltung).
// So folgt der Bass dem Monitor, egal welche App ihn regelt (MonitorControl, BetterDisplay, Lunar …) oder ob
// an seinen Tasten gedreht wird.
//
// Auf Apple Silicon gibt es dafür keine offizielle Schnittstelle; wie die genannten Apps nutzen wir die
// IOAVService-Funktionen aus IOKit, zur Laufzeit geladen. Auf Intel-Macs fehlen sie – dort bleibt MonitorControl
// als Quelle. Das Protokoll folgt dem DDC/CI-Standard (VESA MCCS), umgesetzt wie in MonitorControl (Arm64DDC.swift).

#import "JumpBassRevived.h"
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <os/lock.h>

typedef CFTypeRef IOAVServiceRef;
static IOAVServiceRef (*AVServiceCreate)(CFAllocatorRef, io_service_t);
static IOReturn (*AVServiceReadI2C)(IOAVServiceRef, uint32_t chip, uint32_t offset, void *buf, uint32_t size);
static IOReturn (*AVServiceWriteI2C)(IOAVServiceRef, uint32_t chip, uint32_t dataAddress, void *buf, uint32_t size);

static const uint8_t kDDCChip = 0x37, kDDCData = 0x51;
static const uint8_t kVCPVolume = 0x62, kVCPMute = 0x8D;

static BOOL LoadAVService(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AVServiceCreate = dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
        AVServiceReadI2C = dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
        AVServiceWriteI2C = dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    });
    return AVServiceCreate && AVServiceReadI2C && AVServiceWriteI2C;
}

static id RegistryProperty(io_registry_entry_t entry, NSString *key) {
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, (__bridge CFStringRef)key, kCFAllocatorDefault, kIORegistryIterateRecursively));
}

// Im IORegistry folgt auf den Framebuffer eines Monitors (mit Produktname) dessen DCPAVServiceProxy.
// Bei zwei gleichnamigen Monitoren gewinnt der erste.
static IOAVServiceRef ServiceForDisplay(NSString *name) {
    if (!name || !LoadAVService()) return NULL;
    io_iterator_t it;
    if (IORegistryEntryCreateIterator(IORegistryGetRootEntry(MACH_PORT_NULL), kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return NULL;
    NSString *product = nil;
    IOAVServiceRef service = NULL;
    io_registry_entry_t entry;
    while (!service && (entry = IOIteratorNext(it))) {
        io_name_t n;
        if (IORegistryEntryGetName(entry, n) == KERN_SUCCESS) {
            if (!strcmp(n, "AppleCLCD2") || !strcmp(n, "IOMobileFramebufferShim")) {
                NSDictionary *attrs = RegistryProperty(entry, @"DisplayAttributes");
                id p = [attrs isKindOfClass:[NSDictionary class]] ? attrs[@"ProductAttributes"][@"ProductName"] : nil;
                product = [p isKindOfClass:[NSString class]] ? p : nil;
            } else if (!strcmp(n, "DCPAVServiceProxy") && [RegistryProperty(entry, @"Location") isEqual:@"External"]
                       && product && [product caseInsensitiveCompare:name] == NSOrderedSame) {
                service = AVServiceCreate(kCFAllocatorDefault, entry);
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(it);
    return service;
}

// VCP-Wert lesen: Anfrage schreiben, kurz warten, Antwort lesen und Prüfsumme kontrollieren
static BOOL DDCRead(IOAVServiceRef service, uint8_t vcp, uint16_t *current, uint16_t *maximum) {
    uint8_t request[4] = { 0x82, 0x01, vcp, 0 };
    request[3] = (kDDCChip << 1) ^ request[0] ^ request[1] ^ request[2];
    for (int attempt = 0; attempt < 3; attempt++) {
        for (int i = 0; i < 2; i++) {
            usleep(10000);
            AVServiceWriteI2C(service, kDDCChip, kDDCData, request, sizeof(request));
        }
        usleep(50000);
        uint8_t reply[11] = { 0 };
        if (AVServiceReadI2C(service, kDDCChip, 0, reply, sizeof(reply)) == kIOReturnSuccess) {
            uint8_t sum = 0x50;
            for (int i = 0; i < 10; i++) sum ^= reply[i];
            // Antwort: Länge, 0x02 (VCP-Antwort), Ergebnis 0 = unterstützt, VCP-Code, Typ, Max (2 Byte), Aktuell (2 Byte)
            if (sum == reply[10] && reply[2] == 0x02 && reply[3] == 0x00 && reply[4] == vcp) {
                *maximum = (uint16_t)(reply[6] << 8 | reply[7]);
                *current = (uint16_t)(reply[8] << 8 | reply[9]);
                return YES;
            }
        }
        usleep(20000);
    }
    return NO;
}

@implementation DDCVolume {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    os_unfair_lock _lock;
    NSString *_name;            // gewünschter Monitor (Main-Thread schreibt, Queue liest unter _lock)
    NSString *_serviceName;     // Monitor, zu dem _service gehört (nur auf der Queue)
    IOAVServiceRef _service;
    CFAbsoluteTime _lookupAt;   // nächster Suchversuch, wenn der Monitor nicht gefunden wurde
    BOOL _muteSupported;
    unsigned _polls;
    // Letzter gelesener Stand
    NSString *_readName;
    float _volume;
    BOOL _muted;
    CFAbsoluteTime _readAt;
}

+ (BOOL)supported { return LoadAVService(); }

- (instancetype)init {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _queue = dispatch_queue_create("JumpBass.DDC", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)watchDisplayNamed:(NSString *)name {
    if (![DDCVolume supported]) return;
    os_unfair_lock_lock(&_lock);
    BOOL changed = !(name == _name || [name isEqualToString:_name]);
    _name = [name copy];
    os_unfair_lock_unlock(&_lock);
    if (!changed) return;
    if (name && !_timer) {
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
        __weak DDCVolume *weakSelf = self;
        dispatch_source_set_event_handler(_timer, ^{ [weakSelf poll]; });
        dispatch_resume(_timer);
    } else if (!name && _timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
        dispatch_async(_queue, ^{ [self dropService]; });
    }
}

- (void)dropService {
    if (_service) CFRelease(_service);
    _service = NULL;
    _serviceName = nil;
}

// Auf der Queue: zweimal pro Sekunde die Lautstärke, alle 2 s die Stummschaltung
- (void)poll {
    os_unfair_lock_lock(&_lock);
    NSString *name = _name;
    os_unfair_lock_unlock(&_lock);
    if (!name) return;
    if (![name isEqualToString:_serviceName]) {
        if (CFAbsoluteTimeGetCurrent() < _lookupAt && _serviceName == nil) return;
        [self dropService];
        _service = ServiceForDisplay(name);
        _muteSupported = YES;
        if (!_service) { _lookupAt = CFAbsoluteTimeGetCurrent() + 30; return; }
        _serviceName = name;
    }
    uint16_t cur, max;
    if (!DDCRead(_service, kVCPVolume, &cur, &max) || max == 0) return;
    float volume = MIN(1.0f, (float)cur / max);
    BOOL muted = NO, haveMute = NO;
    if (_muteSupported && _polls++ % 4 == 0) {
        _muteSupported = DDCRead(_service, kVCPMute, &cur, &max);
        haveMute = _muteSupported;
        muted = cur == 1;   // MCCS: 1 = stumm, 2 = an
    }
    os_unfair_lock_lock(&_lock);
    if (![_readName isEqualToString:name]) _muted = NO;
    _readName = name;
    _volume = volume;
    if (haveMute) _muted = muted;
    _readAt = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)volume:(float *)volume muted:(BOOL *)muted forDisplayNamed:(NSString *)name {
    os_unfair_lock_lock(&_lock);
    BOOL fresh = name && [_readName isEqualToString:name] && CFAbsoluteTimeGetCurrent() - _readAt < 5;
    if (fresh) { *volume = _volume; *muted = _muted; }
    os_unfair_lock_unlock(&_lock);
    return fresh;
}

@end
