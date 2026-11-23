#import "RBQuickControlsCard.h"
#import "RBPrivacyCard.h"   // RBLog + shared interaction suppression
#import <dlfcn.h>            // dlopen for private frameworks
#import <objc/runtime.h>     // objc_getClass / class_copyMethodList
#import <objc/message.h>     // objc_msgSend (explicit casts below need the decl)
#import <string.h>           // strstr in rbq_probe / rbq_pick
#import <stdlib.h>           // free in rbq_responders

// ─────────────────────────────────────────────────────────────────────────────
// Private-API helpers. Ported from the vcamx drawer's vcam_sys_* set, which was
// verified on device over several rounds (716/718/720/721/723). The whole point
// is FAIL-SAFE: a renamed class or selector must never take down SpringBoard.
// ─────────────────────────────────────────────────────────────────────────────

static BOOL rbq_streq(const char *a, const char *b) {
    if (!a || !b) return NO;
    while (*a && *b) { if (*a != *b) return NO; a++; b++; }
    return *a == *b;
}

// dlopen with a small cache. Called on SB main thread only => no locking needed.
// Deliberately no RTLD_GLOBAL: symbols come from this handle only.
static void *rbq_dl(const char *path) {
    static const char *s_p[12];
    static void *s_h[12];
    static int s_n = 0;
    if (!path) return NULL;
    for (int i = 0; i < s_n; i++) if (rbq_streq(s_p[i], path)) return s_h[i];
    void *h = dlopen(path, RTLD_NOW);
    if (s_n < 12) { s_p[s_n] = path; s_h[s_n] = h; s_n++; }
    return h;
}

// Resolve a class: try straight away, then dlopen its host framework.
static Class rbq_cls(const char *name, const char *fw) {
    Class c = objc_getClass(name);
    if (c) return c;
    if (fw) { rbq_dl(fw); c = objc_getClass(name); }
    return c;
}

static Class rbq_cls2(const char *name, const char *fwA, const char *fwB) {
    Class c = objc_getClass(name);
    if (c) return c;
    if (fwA) { rbq_dl(fwA); c = objc_getClass(name); if (c) return c; }
    if (fwB) { rbq_dl(fwB); c = objc_getClass(name); }
    return c;
}

static BOOL rbq_can(id o, SEL s) { return o != nil && [o respondsToSelector:s]; }

// Class-method respondsToSelector goes through the metaclass.
static BOOL rbq_cancls(Class c, SEL s) {
    if (!c) return NO;
    Class meta = object_getClass(c);
    return meta && class_respondsToSelector(meta, s);
}

// Call a no-arg class method to obtain a singleton, nil/selector safe.
static id rbq_get(Class c, SEL mk) {
    if (!c || ![(id)c respondsToSelector:mk]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)c, mk);
}

// 0.6.3: cross-class responder scan (ported from vcamx vcam_sys_responders).
// 🔴 classSide=NO scans INSTANCE methods. The 0.6.1 lock path scanned class
//    methods (class_respondsToSelector on each class itself via objc_copyClassList)
//    then sent the selector to the Class object -- the real screen-off selector
//    is an instance method / C function, so that path could never fire.
// 🔴 Return the USABLE count (min(cnt,maxn)), never the raw hit count: vcamx 717
//    returned 115 for a 12-slot array -> out-of-bounds read -> SpringBoard Safe Mode.
static int rbq_responders(SEL sel, const char *tag, BOOL classSide, Class *out, int maxn) {
    int cnt = 0;
    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    if (!all) { RBLog(@"qc responders %s: copyClassList failed", tag); return 0; }
    for (unsigned int i = 0; i < total; i++) {
        Class c = all[i];
        Class host = classSide ? object_getClass(c) : c;
        if (host && class_respondsToSelector(host, sel)) {
            if (out && cnt < maxn) out[cnt] = c;
            cnt++;
            if (cnt <= 8) RBLog(@"qc responders %s <- %s", tag, class_getName(c));
        }
    }
    free(all);
    if (cnt == 0) RBLog(@"qc responders %s: none", tag);
    else if (cnt > 8) RBLog(@"qc responders %s: total=%d (listed first 8)", tag, cnt);
    return (out && cnt > maxn) ? maxn : cnt;
}

// 0.6.3: pick a responder class by whitelist substring (vcam_sys_pick).
// 🔴 Strict mode: no whitelist hit => nil. Returning arr[0] once picked a wholly
//    unrelated class (vcamx 718 Safe Mode); better to skip a tier than misfire.
static Class rbq_pick(Class *arr, int n, const char **prefer, int np) {
    if (n <= 0 || !arr) return nil;
    for (int j = 0; j < np; j++) {
        for (int i = 0; i < n; i++) {
            const char *nm = arr[i] ? class_getName(arr[i]) : NULL;
            if (nm && strstr(nm, prefer[j])) return arr[i];
        }
    }
    return nil;
}

// Get an instance via common singleton entry points (nil safe).
static id rbq_instance(Class c) {
    if (!c) return nil;
    static const char *mk[] = {"sharedInstance", "sharedApplication", "sharedController",
                               "sharedManager", "defaultInstance", NULL};
    for (int i = 0; mk[i]; i++) {
        SEL s = NSSelectorFromString([NSString stringWithUTF8String:mk[i]]);
        if (rbq_cancls(c, s)) return ((id (*)(id, SEL))objc_msgSend)((id)c, s);
    }
    return nil;
}

// 0.6.3: read the real lock state for before/after self-evidence.
// Defined AFTER rbq_instance on purpose (plain C: no forward declaration).
static BOOL rbq_lockActive(void) {
    id mgr = rbq_instance(objc_getClass("SBLockScreenManager"));
    SEL s = NSSelectorFromString(@"isLockScreenActive");
    if (!rbq_can(mgr, s)) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(mgr, s);
}

// Method-name probe: dump a class's methods matching a keyword to the log.
// One dump gives the real name instead of four more rounds of guessing.
static void rbq_probe(Class c, const char *tag, const char *kw) {
    if (!c) { RBLog(@"qc probe %s: class missing", tag); return; }
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    if (!ms) { RBLog(@"qc probe %s: no methods", tag); return; }
    RBLog(@"qc probe %s: %u methods, filter=%s", tag, n, kw ? kw : "*");
    int hit = 0;
    for (unsigned int i = 0; i < n && hit < 24; i++) {
        const char *nm = sel_getName(method_getName(ms[i]));
        if (!kw || strstr(nm, kw)) { RBLog(@"qc   %s", nm); hit++; }
    }
    free(ms);
}

// ─────────────────────────────────────────────────────────────────────────────
// Toggle definitions. index order matches the tile grid.
// ─────────────────────────────────────────────────────────────────────────────
typedef NS_ENUM(NSUInteger, RBQuickToggle) {
    RBQFlashlight = 0,
    RBQRingerMute,
    RBQLowPower,
    RBQDarkMode,
    RBQOrientLock,
    RBQLockScreen,
    RBQCount
};

static NSString *const kRBQNames[] = {
    @"手电筒", @"静音", @"低电量", @"深浅模式", @"方向锁", @"锁屏"
};
static NSString *const kRBQIcons[] = {
    @"flashlight.on.fill", @"bell.slash.fill", @"battery.100.bolt",
    @"moon.fill", @"lock.rotation", @"power"
};
// iOS 16 is picky about some SF Symbol names (battery.bolt was not one of them).
// Every tile gets a plain glyph fallback so no slot is ever blank.
static NSString *const kRBQIconFallbacks[] = {
    @"flashlight.on.fill", @"bell.slash", @"bolt.fill",
    @"moon", @"lock", @"power"
};

#pragma mark - Flashlight

// The Control Center flashlight is owned by SpringBoard's SBUIFlashlightController.
// Its -level is the ONLY read that reflects a light turned on from Control Center;
// AVCaptureDevice.torchActive always read back 0 inside SpringBoard (0.6.0 bug:
// the card could only ever turn the light ON, never OFF). This is the same class
// the open-source FlashlightSettings tweak (wrp1002, iOS 12-16) drives.
static id rbq_flashlightController(void) {
    Class c = objc_getClass("SBUIFlashlightController");
    if (!c) c = rbq_cls("SBUIFlashlightController",
                        "/System/Library/PrivateFrameworks/SpringBoardUI.framework/SpringBoardUI");
    id ctl = rbq_get(c, NSSelectorFromString(@"sharedInstance"));
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        RBLog(@"qc flashlight controller cls=%d inst=%d level=%d on=%d off=%d",
              (int)(c != Nil), (int)(ctl != nil),
              (int)rbq_can(ctl, NSSelectorFromString(@"level")),
              (int)rbq_can(ctl, NSSelectorFromString(@"turnFlashlightOnForReason:")),
              (int)rbq_can(ctl, NSSelectorFromString(@"turnFlashlightOffForReason:")));
    }
    return ctl;
}

static BOOL rbq_flashlightRead(void) {
    id ctl = rbq_flashlightController();
    SEL sLevel = NSSelectorFromString(@"level");
    if (rbq_can(ctl, sLevel)) {
        unsigned long long lv = ((unsigned long long (*)(id, SEL))objc_msgSend)(ctl, sLevel);
        return lv != 0;
    }
    // Last resort only: this reads 0 in SpringBoard, but keep it for completeness.
    Class c = rbq_cls("AVCaptureDevice", "/System/Library/Frameworks/AVFoundation.framework/AVFoundation");
    SEL sDev = NSSelectorFromString(@"defaultDeviceWithDeviceType:mediaType:position:");
    if (!rbq_cancls(c, sDev)) return NO;
    id dev = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
        (id)c, sDev, @"AVCaptureDeviceTypeBuiltInWideAngleCamera", @"vide", 1);
    if (!dev || !rbq_can(dev, NSSelectorFromString(@"torchActive"))) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(dev, NSSelectorFromString(@"torchActive"));
}

static BOOL rbq_flashlightSet(BOOL on) {
    id ctl = rbq_flashlightController();
    SEL sAvail = NSSelectorFromString(@"isAvailable");
    SEL sOn = NSSelectorFromString(@"turnFlashlightOnForReason:");
    SEL sOff = NSSelectorFromString(@"turnFlashlightOffForReason:");
    if (rbq_can(ctl, sOn) && rbq_can(ctl, sOff)) {
        if (rbq_can(ctl, sAvail) && !((BOOL (*)(id, SEL))objc_msgSend)(ctl, sAvail)) {
            RBLog(@"qc flashlight: SBUIFlashlightController unavailable");
            return NO;
        }
        if (on) {
            // Match the system: set a level first, then turn on for a reason.
            SEL sLoad = NSSelectorFromString(@"_loadFlashlightLevel");
            SEL sSet = NSSelectorFromString(@"setLevel:");
            unsigned long long lv = 4;
            if (rbq_can(ctl, sLoad)) lv = ((unsigned long long (*)(id, SEL))objc_msgSend)(ctl, sLoad);
            if (lv == 0) lv = 4;
            if (rbq_can(ctl, sSet)) ((void (*)(id, SEL, unsigned long long))objc_msgSend)(ctl, sSet, lv);
            ((void (*)(id, SEL, id))objc_msgSend)(ctl, sOn, @"ReachDeck");
            RBLog(@"qc flashlight: SBUIFlashlightController on level=%llu", lv);
        } else {
            ((void (*)(id, SEL, id))objc_msgSend)(ctl, sOff, @"ReachDeck");
            RBLog(@"qc flashlight: SBUIFlashlightController off");
        }
        return YES;
    }
    // Fallback: public AVCaptureDevice torch (works on iOS, but its state cannot
    // be read back from SpringBoard -- only used when the private controller is gone).
    Class c = rbq_cls("AVCaptureDevice", "/System/Library/Frameworks/AVFoundation.framework/AVFoundation");
    SEL sDev = NSSelectorFromString(@"defaultDeviceWithDeviceType:mediaType:position:");
    if (!rbq_cancls(c, sDev)) { RBLog(@"qc flashlight: no controller and no AVCaptureDevice"); return NO; }
    id dev = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
        (id)c, sDev, @"AVCaptureDeviceTypeBuiltInWideAngleCamera", @"vide", 1);
    if (!dev) { RBLog(@"qc flashlight: no back camera device"); return NO; }
    NSError *err = nil;
    SEL sLock = NSSelectorFromString(@"lockForConfiguration:");
    if (!rbq_can(dev, sLock)) { RBLog(@"qc flashlight: lockForConfiguration missing"); return NO; }
    BOOL locked = ((BOOL (*)(id, SEL, id *))objc_msgSend)(dev, sLock, &err);
    if (!locked) { RBLog(@"qc flashlight: lock failed err=%@", err); return NO; }
    SEL sMode = NSSelectorFromString(@"setTorchMode:");
    if (rbq_can(dev, sMode)) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(dev, sMode, on ? 1 : 0);
    } else if (on && rbq_can(dev, NSSelectorFromString(@"setTorchModeOnWithLevel:error:"))) {
        ((BOOL (*)(id, SEL, float, id *))objc_msgSend)(
            dev, NSSelectorFromString(@"setTorchModeOnWithLevel:error:"), 1.0f, &err);
    }
    ((void (*)(id, SEL))objc_msgSend)(dev, NSSelectorFromString(@"unlockForConfiguration"));
    RBLog(@"qc flashlight: AVCaptureDevice fallback set=%d err=%@", (int)on, err);
    return YES;
}

#pragma mark - Ringer mute (SBRingerControl — verified 716)

static id rbq_ringerControl(void) {
    Class cSB = objc_getClass("SpringBoard");
    id sb = rbq_get(cSB, NSSelectorFromString(@"sharedApplication"));
    SEL gRC = NSSelectorFromString(@"ringerControl");
    id rc = rbq_can(sb, gRC) ? ((id (*)(id, SEL))objc_msgSend)(sb, gRC) : nil;
    if (!rc) {
        id bp = rbq_get(objc_getClass("SBMediaController"), NSSelectorFromString(@"sharedInstance"));
        if (rbq_can(bp, gRC)) rc = ((id (*)(id, SEL))objc_msgSend)(bp, gRC);
    }
    return rc;
}

static BOOL rbq_ringerRead(id rc, id sb) {
    SEL sAcc = NSSelectorFromString(@"_accessibilityIsRingerMuted");
    if (rbq_can(sb, sAcc)) return ((BOOL (*)(id, SEL))objc_msgSend)(sb, sAcc);
    if (rbq_can(rc, NSSelectorFromString(@"isRingerMuted")))
        return ((BOOL (*)(id, SEL))objc_msgSend)(rc, NSSelectorFromString(@"isRingerMuted"));
    return NO;
}

static BOOL rbq_ringerSet(BOOL muted) {
    id rc = rbq_ringerControl();
    Class cSB = objc_getClass("SpringBoard");
    id sb = rbq_get(cSB, NSSelectorFromString(@"sharedApplication"));
    // 716: the working selector on device is the single-argument one.
    SEL sSet = NSSelectorFromString(@"setRingerMuted:");
    if (rbq_can(rc, sSet)) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(rc, sSet, muted);
        RBLog(@"qc ringer setRingerMuted:%d (rc)", (int)muted);
        return YES;
    }
    if (rbq_can(sb, sSet)) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(sb, sSet, muted);
        RBLog(@"qc ringer setRingerMuted:%d (sb)", (int)muted);
        return YES;
    }
    if (rbq_can(rc, NSSelectorFromString(@"toggleRingerMute"))) {
        ((void (*)(id, SEL))objc_msgSend)(rc, NSSelectorFromString(@"toggleRingerMute"));
        RBLog(@"qc ringer toggleRingerMute fallback");
        return YES;
    }
    RBLog(@"qc ringer: no setter (rc=%d)", (int)(rc != nil));
    return NO;
}

#pragma mark - Low power (three-tier fallback — verified)

static BOOL rbq_lowPowerRead(void) {
    return [NSProcessInfo processInfo].isLowPowerModeEnabled;
}

static BOOL rbq_lowPowerSet(BOOL on) {
    NSInteger want = on ? 1 : 0;
    Class c = rbq_cls("_PMLowPowerMode", "/System/Library/PrivateFrameworks/LowPowerMode.framework/LowPowerMode");
    id pm = rbq_get(c, NSSelectorFromString(@"sharedInstance"));
    SEL s = NSSelectorFromString(@"setPowerMode:fromSource:");
    if (rbq_can(pm, s)) {
        ((void (*)(id, SEL, NSInteger, id))objc_msgSend)(pm, s, want, @"ReachDeck");
        RBLog(@"qc lowpower tier1 _PMLowPowerMode setPowerMode:%ld", (long)want);
        return YES;
    }
    Class c2 = rbq_cls2("_CDBatterySaver",
                        "/System/Library/PrivateFrameworks/CoreDuet.framework/CoreDuet",
                        "/System/Library/PrivateFrameworks/PreferencesUI.framework/PreferencesUI");
    id bs = rbq_get(c2, NSSelectorFromString(@"sharedInstance"));
    SEL s2 = NSSelectorFromString(@"setMode:");
    if (rbq_can(bs, s2)) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(bs, s2, want);
        RBLog(@"qc lowpower tier2 _CDBatterySaver setMode:%ld", (long)want);
        return YES;
    }
    Class c3 = rbq_cls2("PSLowPowerModeSettingsDetail",
                        "/System/Library/PrivateFrameworks/PreferencesUI.framework/PreferencesUI",
                        "/System/Library/PrivateFrameworks/Preferences.framework/Preferences");
    id d3 = rbq_get(c3, NSSelectorFromString(@"sharedInstance"));
    SEL s3 = NSSelectorFromString(@"setEnabled:");
    if (rbq_can(d3, s3)) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(d3, s3, on);
        RBLog(@"qc lowpower tier3 PSLowPowerModeSettingsDetail setEnabled:%d", (int)on);
        return YES;
    }
    RBLog(@"qc lowpower: no tier available");
    return NO;
}

#pragma mark - Dark mode (UIUserInterfaceStyleArbiter — verified 718)

static Class rbq_arbiterClass(void) {
    Class c = rbq_cls2("UIUserInterfaceStyleArbiter",
                       "/System/Library/PrivateFrameworks/UIKitServices.framework/UIKitServices",
                       "/System/Library/Frameworks/UIKit.framework/UIKit");
    if (!c) c = objc_getClass("UIUserInterfaceStyleArbiter");
    return c;
}

static BOOL rbq_darkRead(void) {
    if (@available(iOS 13.0, *)) {
        return [UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

static BOOL rbq_darkSet(void) {
    // 718: the real method (dump-probed) is toggleCurrentStyle. NEVER call
    // setUserInterfaceStyle: on all responders — that crashed SB into Safe Mode.
    Class c = rbq_arbiterClass();
    id arb = rbq_instance(c);
    SEL sToggle = NSSelectorFromString(@"toggleCurrentStyle");
    if (rbq_can(arb, sToggle)) {
        ((void (*)(id, SEL))objc_msgSend)(arb, sToggle);
        RBLog(@"qc dark: arbiter.toggleCurrentStyle (tier1)");
        return YES;
    }
    // Warn-only probe so a future iOS rename is diagnosable in one build.
    RBLog(@"qc dark: toggleCurrentStyle missing, arbiter=%d — probing", (int)(arb != nil));
    rbq_probe(c, "UIUserInterfaceStyleArbiter", "toggle");
    return NO;
}

#pragma mark - Orientation lock (SBOrientationLockManager — verified 721)

static id rbq_orientMgr(void) {
    Class c = objc_getClass("SBOrientationLockManager");
    if (!c) c = rbq_cls("SBOrientationLockManager",
                        "/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard");
    return rbq_instance(c);
}

static BOOL rbq_orientRead(id mgr) {
    SEL s = NSSelectorFromString(@"isUserLocked");
    BOOL hasUser = rbq_can(mgr, s);
    SEL sEff = NSSelectorFromString(@"isEffectivelyLocked");
    if (hasUser) return ((BOOL (*)(id, SEL))objc_msgSend)(mgr, s);
    if (rbq_can(mgr, sEff)) return ((BOOL (*)(id, SEL))objc_msgSend)(mgr, sEff);
    return NO;
}

static BOOL rbq_orientSet(BOOL lock) {
    id mgr = rbq_orientMgr();
    SEL sLock = NSSelectorFromString(lock ? @"lock" : @"unlock");
    if (rbq_can(mgr, sLock)) {
        ((void (*)(id, SEL))objc_msgSend)(mgr, sLock);
        RBLog(@"qc orient: %s()", lock ? "lock" : "unlock");
        return YES;
    }
    RBLog(@"qc orient: lock/unlock missing (mgr=%d) — probing", (int)(mgr != nil));
    rbq_probe(object_getClass(mgr), "SBOrientationLockManager", "ock");
    return NO;
}

#pragma mark - Lock screen (vcamx 717 verified — screen-off, not light-only lock)

// 0.6.3 FIX: 0.6.1 sent _simulateLockButtonPress to a CLASS object found by
// scanning class methods -- but the real screen-off path is a C function in
// UIKitServices plus an INSTANCE method on SB classes. It therefore never fired
// (field report: "lock has no effect"). Port the full device-verified 6-tier
// ladder from the vcamx drawer (w2symtrace sys:lock, rounds 716/717/718):
//  ① C function dlsym ② instance responders Animated ③ lockAndDimDevice…
//  ⑥ light-only lockUIFromSource as the LAST fallback (that was 716's symptom).
// Every tier is guarded; the log carries the real before-state plus the exact
// tier/class that fired, so a device report can be checked without guessing.
static BOOL rbq_lockScreen(void) {
    BOOL before = rbq_lockActive();
    SEL selSim  = NSSelectorFromString(@"_simulateLockButtonPress");
    SEL selSimA = NSSelectorFromString(@"_simulateLockButtonPressAnimated:");
    SEL selLD   = NSSelectorFromString(@"lockAndDimDevice");
    SEL selLDD  = NSSelectorFromString(@"lockAndDimDeviceDisconnectingCallIfNecessary:");

    Class rSim[12], rSimA[12], rLD[12], rLDD[12];
    int nSim  = rbq_responders(selSim,  "_simulateLockButtonPress", NO, rSim, 12);
    int nSimA = rbq_responders(selSimA, "_simulateLockButtonPressAnimated:", NO, rSimA, 12);
    int nLD   = rbq_responders(selLD,   "lockAndDimDevice", NO, rLD, 12);
    int nLDD  = rbq_responders(selLDD,  "lockAndDimDeviceDisconnecting", NO, rLDD, 12);
    RBLog(@"qc lock start before=%d nSim=%d nSimA=%d nLD=%d nLDD=%d",
          (int)before, nSim, nSimA, nLD, nLDD);

    // ① SHELLX-verified screen-off path: the C function itself, not an ObjC method.
    void *wUI = rbq_dl("/System/Library/PrivateFrameworks/UIKitServices.framework/UIKitServices");
    void *fpSim = wUI ? dlsym(wUI, "_simulateLockButtonPress") : NULL;
    RBLog(@"qc lock tier1 dlsym=%p", fpSim);
    if (fpSim) {
        ((void (*)(void))fpSim)();
        RBLog(@"qc lock: tier1 C _simulateLockButtonPress()");
        return YES;
    }

    // ② responders: instance method on the host class (strict whitelist pick).
    const char *prefer[] = {"SBLockScreenManager", "SBUIController", "SpringBoard", "LockScreen"};
    if (nSim > 0) {
        Class c = rbq_pick(rSim, nSim, prefer, 4);
        id inst = rbq_instance(c);
        if (rbq_can(inst, selSim)) {
            ((void (*)(id, SEL))objc_msgSend)(inst, selSim);
            RBLog(@"qc lock: tier2 %s._simulateLockButtonPress()", class_getName(c));
            return YES;
        }
    }
    // ③ _simulateLockButtonPressAnimated:YES
    if (nSimA > 0) {
        Class c = rbq_pick(rSimA, nSimA, prefer, 3);
        id inst = rbq_instance(c);
        if (rbq_can(inst, selSimA)) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(inst, selSimA, YES);
            RBLog(@"qc lock: tier3 %s._simulateLockButtonPressAnimated:YES", class_getName(c));
            return YES;
        }
    }
    // ④/⑤ lockAndDimDevice family (lock + dim = screen off).
    if (nLD > 0) {
        Class c = rbq_pick(rLD, nLD, prefer, 3);
        id inst = rbq_instance(c);
        if (rbq_can(inst, selLD)) {
            ((void (*)(id, SEL))objc_msgSend)(inst, selLD);
            RBLog(@"qc lock: tier4 %s.lockAndDimDevice()", class_getName(c));
            return YES;
        }
    }
    if (nLDD > 0) {
        Class c = rbq_pick(rLDD, nLDD, prefer, 3);
        id inst = rbq_instance(c);
        if (rbq_can(inst, selLDD)) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(inst, selLDD, YES);
            RBLog(@"qc lock: tier5 %s.lockAndDimDeviceDisconnectingCallIfNecessary:YES", class_getName(c));
            return YES;
        }
    }

    // ⑥ LAST resort: light-only lock (716's symptom — only usable if all off-paths failed).
    id mgr = rbq_instance(objc_getClass("SBLockScreenManager"));
    SEL lm3 = @selector(lockUIFromSource:withOptions:completion:);
    SEL lm2 = @selector(lockUIFromSource:withOptions:);
    if (rbq_can(mgr, lm3)) {
        ((void (*)(id, SEL, NSInteger, id, id))objc_msgSend)(mgr, lm3, 1, nil, nil);
        RBLog(@"qc lock: tier6 light-only lockUIFromSource:1");
        return YES;
    }
    if (rbq_can(mgr, lm2)) {
        ((void (*)(id, SEL, NSInteger, id))objc_msgSend)(mgr, lm2, 1, nil);
        RBLog(@"qc lock: tier6b light-only lockUIFromSource:1");
        return YES;
    }
    RBLog(@"qc lock: no path");
    return NO;
}

#pragma mark - state / action dispatch

static BOOL rbq_readState(NSUInteger idx) {
    switch (idx) {
        case RBQFlashlight: return rbq_flashlightRead();
        case RBQRingerMute: {
            id rc = rbq_ringerControl();
            id sb = rbq_get(objc_getClass("SpringBoard"), NSSelectorFromString(@"sharedApplication"));
            return rbq_ringerRead(rc, sb);
        }
        case RBQLowPower:   return rbq_lowPowerRead();
        case RBQDarkMode:   return rbq_darkRead();
        case RBQOrientLock: return rbq_orientRead(rbq_orientMgr());
        case RBQLockScreen: return NO;   // momentary action, no persistent state
        default: return NO;
    }
}

// Returns NO for momentary actions (lock screen).
static BOOL rbq_hasPersistentState(NSUInteger idx) {
    return idx != RBQLockScreen;
}

static void rbq_perform(NSUInteger idx) {
    switch (idx) {
        case RBQFlashlight: rbq_flashlightSet(!rbq_flashlightRead()); break;
        case RBQRingerMute: rbq_ringerSet(!rbq_readState(idx)); break;
        case RBQLowPower:   rbq_lowPowerSet(!rbq_lowPowerRead()); break;
        case RBQDarkMode:   rbq_darkSet(); break;   // toggle semantics
        case RBQOrientLock: rbq_orientSet(!rbq_readState(idx)); break;
        case RBQLockScreen: rbq_lockScreen(); break;
        default: break;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// View
// ─────────────────────────────────────────────────────────────────────────────
static NSInteger const kRBQRootTag = 0x5244424C;   // 'RDBL'
static NSInteger const kRBQTileTag = 0x5244424D;   // 'RDBM' + index (0..5)
static NSUInteger const kRBQTilesPerRow = 3;

@interface RBQuickControlsCard ()
@property (nonatomic, strong) UIView *view;
@property (nonatomic, assign) CGFloat styleOpacity;
@property (nonatomic, assign) CGFloat styleCorner;
@property (nonatomic, assign) CGFloat styleBorder;
@property (nonatomic, assign) BOOL styleCompact;
@property (nonatomic, strong) NSMutableArray<UIControl *> *tiles;
@property (nonatomic, strong) NSMutableArray<UILabel *> *stateLabels;
@end

@implementation RBQuickControlsCard

- (NSInteger)rbPriority { return 75; }   // right after dock apps (50), before privacy (100)
- (NSString *)rbIdentifier { return @"quickcontrols"; }
- (NSString *)rbRailImageName { return @"slider.horizontal.3"; }
- (NSString *)rbRailTitle { return @"快捷开关"; }

- (UIView *)rbView {
    if (!self.view) {
        [self buildView];
        [self refreshStates];
    }
    return self.view;
}

- (void)rbRefresh { [self refreshStates]; }

- (void)setStyleOpacity:(CGFloat)opacity corner:(CGFloat)corner border:(CGFloat)border compact:(BOOL)compact {
    if (opacity < 0.2) opacity = 0.2;
    if (opacity > 1.0) opacity = 1.0;
    if (corner < 0) corner = 0;
    if (corner > 24) corner = 24;
    if (border < 0) border = 0;
    if (border > 3) border = 3;
    if (_styleOpacity == opacity && _styleCorner == corner &&
        _styleBorder == border && _styleCompact == compact) return;
    _styleOpacity = opacity;
    _styleCorner = corner;
    _styleBorder = border;
    _styleCompact = compact;
    RBLog(@"qc style apply opacity=%.2f corner=%.0f border=%.0f compact=%d",
          opacity, corner, border, (int)compact);
    self.view = nil;
    self.tiles = nil;
    self.stateLabels = nil;
}

- (UIControl *)rbMakeTileAtIndex:(NSUInteger)idx side:(CGFloat)side {
    UIControl *tile = [[UIControl alloc] initWithFrame:CGRectZero];
    tile.tag = kRBQTileTag + (NSInteger)idx;
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    tile.userInteractionEnabled = YES;
    [tile addTarget:self action:@selector(rbTileDown:) forControlEvents:UIControlEventTouchDown];
    [tile addTarget:self action:@selector(rbTileUp:) forControlEvents:UIControlEventTouchUpInside];
    [tile addTarget:self action:@selector(rbTileCancel:) forControlEvents:UIControlEventTouchCancel];
    [tile addTarget:self action:@selector(rbTileDown:) forControlEvents:UIControlEventTouchDragEnter];

    UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    iconView.tag = 1001;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.userInteractionEnabled = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = [UIColor whiteColor];
    UIImage *img = [UIImage systemImageNamed:kRBQIcons[idx]];
    if (!img) img = [UIImage systemImageNamed:kRBQIconFallbacks[idx]];
    iconView.image = img;
    if (!img) RBLog(@"qc icon missing idx=%ld name=%@", (long)idx, kRBQIcons[idx]);
    [tile addSubview:iconView];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
    name.tag = 1002;
    name.text = kRBQNames[idx];
    name.font = [UIFont systemFontOfSize:(self.styleCompact ? 9.0 : 10.0) weight:UIFontWeightRegular];
    name.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
    name.textAlignment = NSTextAlignmentCenter;
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.userInteractionEnabled = NO;
    [tile addSubview:name];

    UILabel *state = [[UILabel alloc] initWithFrame:CGRectZero];
    state.tag = 1003;
    state.text = @"—";
    state.font = [UIFont systemFontOfSize:(self.styleCompact ? 8.0 : 9.0) weight:UIFontWeightSemibold];
    state.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    state.textAlignment = NSTextAlignmentCenter;
    state.translatesAutoresizingMaskIntoConstraints = NO;
    state.userInteractionEnabled = NO;
    [tile addSubview:state];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.topAnchor constraintEqualToAnchor:tile.topAnchor],
        [iconView.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [iconView.widthAnchor constraintEqualToConstant:22.0],
        [iconView.heightAnchor constraintEqualToConstant:22.0],
        [name.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:3.0],
        [name.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor],
        [name.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor],
        [state.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:1.0],
        [state.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor],
        [state.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor],
        [state.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor],
    ]];
    (void)side;
    return tile;
}

- (UIStackView *)rbMakeRow {
    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = self.styleCompact ? 6.0 : 8.0;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    return row;
}

- (void)buildView {
    CGFloat pad = self.styleCompact ? 8.0 : 11.0;
    CGFloat rowGap = self.styleCompact ? 10.0 : 13.0;

    UIControl *root = [[UIControl alloc] initWithFrame:CGRectZero];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:self.styleOpacity];
    root.layer.cornerRadius = self.styleCorner;
    root.layer.cornerCurve = kCACornerCurveContinuous;
    root.layer.borderWidth = self.styleBorder;
    root.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75].CGColor;
    root.clipsToBounds = YES;
    root.tag = kRBQRootTag;
    root.userInteractionEnabled = YES;

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectZero];
    header.text = @"快捷开关";
    header.font = [UIFont systemFontOfSize:(self.styleCompact ? 10.0 : 11.0) weight:UIFontWeightSemibold];
    header.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.58];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    self.tiles = [NSMutableArray arrayWithCapacity:RBQCount];
    self.stateLabels = [NSMutableArray arrayWithCapacity:RBQCount];

    UIStackView *row1 = [self rbMakeRow];
    UIStackView *row2 = [self rbMakeRow];
    for (NSUInteger i = 0; i < RBQCount; i++) {
        UIControl *tile = [self rbMakeTileAtIndex:i side:38.0];
        [(i < kRBQTilesPerRow ? row1 : row2) addArrangedSubview:tile];
        [self.tiles addObject:tile];
        [self.stateLabels addObject:[tile viewWithTag:1003]];
    }

    [root addSubview:header];
    [root addSubview:row1];
    [root addSubview:row2];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:root.topAnchor constant:pad],
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:pad + 1.0],
        [header.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-(pad + 1.0)],
        [row1.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:(self.styleCompact ? 5.0 : 7.0)],
        [row1.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:pad],
        [row1.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-pad],
        [row2.topAnchor constraintEqualToAnchor:row1.bottomAnchor constant:rowGap],
        [row2.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:pad],
        [row2.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-pad],
        [row2.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-pad],
    ]];
    self.view = root;
}

- (void)refreshStates {
    if (!self.tiles) return;
    for (NSUInteger i = 0; i < self.tiles.count && i < self.stateLabels.count; i++) {
        UILabel *lab = self.stateLabels[i];
        if (!rbq_hasPersistentState(i)) { lab.text = @"点按"; continue; }
        BOOL on = rbq_readState(i);
        lab.text = on ? @"开" : @"关";
        lab.textColor = on ? [[UIColor colorWithRed:0.35 green:0.9 blue:0.55 alpha:1.0] colorWithAlphaComponent:0.95]
                           : [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    }
}

#pragma mark touch — arm interaction so Reachability doesn't collapse mid-tap

- (void)rbTileDown:(UIControl *)sender {
    (void)sender;
    RBPrivacyArmInteraction();
}

- (void)rbTileUp:(UIControl *)sender {
    NSInteger idx = sender.tag - kRBQTileTag;
    if (idx < 0 || idx >= (NSInteger)RBQCount) { [self rbDisarm]; return; }
    RBLog(@"qc tap idx=%ld name=%@", (long)idx, kRBQNames[idx]);
    UIImpactFeedbackGenerator *haptic =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    NSUInteger k = (NSUInteger)idx;
    BOOL before = rbq_hasPersistentState(k) ? rbq_readState(k) : NO;
    rbq_perform(k);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (rbq_hasPersistentState(k)) {
            BOOL after = rbq_readState(k);
            BOOL flipped = (after != before);
            RBLog(@"qc verify %@ before=%d after=%d %@",
                  kRBQNames[k], (int)before, (int)after,
                  flipped ? @"flipped" : @"no-change");
        }
        [strongSelf refreshStates];
    });
    [self rbDisarm];
}

- (void)rbTileCancel:(UIControl *)sender {
    (void)sender;
    [self rbDisarm];
}

- (void)rbDisarm {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf) RBPrivacyCancelInteraction();
    });
}

@end
