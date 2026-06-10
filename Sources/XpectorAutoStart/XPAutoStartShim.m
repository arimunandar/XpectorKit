#import <Foundation/Foundation.h>
#import "XPAutoStartShim.h"

#if DEBUG

// Implemented in Swift (XpectorServer target) via @_cdecl. The symbol resolves
// when the host app links the XpectorServer product, which always includes
// both targets.
extern void XpectorServerAutoStart(void);

// Zero-code integration: adding the package to a DEBUG build is enough to
// start the inspection server — no init() edit in the host app. Deferred to
// the main queue so it runs once the run loop starts, after the host app's
// own init; a manual start(config:) therefore always wins (see
// XpectorServer.startAutomatically for the ordering rules, and
// XPECTOR_DISABLED for the opt-out).
__attribute__((constructor))
static void XPAutoStartConstructor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        XpectorServerAutoStart();
    });
}

#endif
