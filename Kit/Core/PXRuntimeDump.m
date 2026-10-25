// Debug helper: dumps the Objective-C classes and protocols of the AppleTV
// executable as raw text (methods with type encodings, ivars, properties).
// Output: <PXDataDir>/dump/<Name>.txt. Run once, decoded on the Mac.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "PXLog.h"

static void dumpMethods(NSMutableString *out, Class cls, char prefix) {
    unsigned int n = 0;
    Method *m = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++)
        [out appendFormat:@"%c %s\t%s\n", prefix, sel_getName(method_getName(m[i])), method_getTypeEncoding(m[i]) ?: ""];
    free(m);
}

static NSString *dumpClass(Class cls) {
    NSMutableString *out = [NSMutableString string];
    Class sup = class_getSuperclass(cls);
    [out appendFormat:@"@interface %s : %s", class_getName(cls), sup ? class_getName(sup) : "-"];
    unsigned int pc = 0;
    Protocol * __unsafe_unretained *protos = class_copyProtocolList(cls, &pc);
    if (pc) {
        [out appendString:@" <"];
        for (unsigned int i = 0; i < pc; i++) [out appendFormat:@"%s%s", i ? ", " : "", protocol_getName(protos[i])];
        [out appendString:@">"];
    }
    free(protos);
    [out appendFormat:@"  // size=%zu\n", class_getInstanceSize(cls)];
    unsigned int n = 0;
    Ivar *iv = class_copyIvarList(cls, &n);
    for (unsigned int i = 0; i < n; i++)
        [out appendFormat:@"ivar %s\t%s\t@%td\n", ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]) ?: "", ivar_getOffset(iv[i])];
    free(iv);
    objc_property_t *props = class_copyPropertyList(cls, &n);
    for (unsigned int i = 0; i < n; i++)
        [out appendFormat:@"prop %s\t%s\n", property_getName(props[i]), property_getAttributes(props[i])];
    free(props);
    dumpMethods(out, object_getClass(cls), '+');
    dumpMethods(out, cls, '-');
    return out;
}

static void dumpProtoMethods(NSMutableString *out, Protocol *p, BOOL req, BOOL inst) {
    unsigned int n = 0;
    struct objc_method_description *d = protocol_copyMethodDescriptionList(p, req, inst, &n);
    for (unsigned int i = 0; i < n; i++)
        [out appendFormat:@"%c%@ %s\t%s\n", inst ? '-' : '+', req ? @"" : @"(opt)", sel_getName(d[i].name), d[i].types ?: ""];
    free(d);
}

void PXRuntimeDump(BOOL force) {
    NSString *dir = [PXDataDir() stringByAppendingPathComponent:@"dump"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!force && [fm fileExistsAtPath:dir]) return;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];

    const char *mainImage = _dyld_get_image_name(0);
    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(mainImage, &count);
    PXLog(@"dump: %u classes in %s", count, mainImage);
    for (unsigned int i = 0; i < count; i++) {
        Class cls = objc_getClass(names[i]);
        if (!cls) continue;
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.txt", names[i]]];
        [dumpClass(cls) writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }
    free(names);

    unsigned int pcount = 0;
    Protocol * __unsafe_unretained *protos = objc_copyProtocolList(&pcount);
    for (unsigned int i = 0; i < pcount; i++) {
        const char *pn = protocol_getName(protos[i]);
        if (strncmp(pn, "BR", 2) && strncmp(pn, "ATV", 3)) continue;
        NSMutableString *out = [NSMutableString stringWithFormat:@"@protocol %s\n", pn];
        dumpProtoMethods(out, protos[i], YES, YES);
        dumpProtoMethods(out, protos[i], NO, YES);
        dumpProtoMethods(out, protos[i], YES, NO);
        dumpProtoMethods(out, protos[i], NO, NO);
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"@%s.txt", pn]];
        [out writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }
    free(protos);
    PXLog(@"dump: done");
}
