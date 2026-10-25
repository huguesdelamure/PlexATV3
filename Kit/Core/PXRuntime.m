#import "PXRuntime.h"
#import "PXLog.h"

static void copyMethods(Class from, Class to) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(from, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(list[i]);
        // +load / +initialize of the template must not be inherited.
        if (sel == @selector(load) || sel == @selector(initialize)) continue;
        class_replaceMethod(to, sel, method_getImplementation(list[i]), method_getTypeEncoding(list[i]));
    }
    free(list);
}

Class PXCreateSubclass(const char *name, const char *superName, Class templateClass) {
    Class existing = objc_getClass(name);
    if (existing) return existing;
    Class superClass = objc_getClass(superName);
    if (!superClass) {
        PXLog(@"PXCreateSubclass: superclass %s not found", superName);
        return Nil;
    }
    Class cls = objc_allocateClassPair(superClass, name, 0);
    if (!cls) return Nil;
    copyMethods(templateClass, cls);
    copyMethods(object_getClass(templateClass), object_getClass(cls));
    // Copy declared protocols so conformsToProtocol: works (e.g. BRTopShelfController).
    unsigned int pc = 0;
    Protocol * __unsafe_unretained *protos = class_copyProtocolList(templateClass, &pc);
    for (unsigned int i = 0; i < pc; i++) class_addProtocol(cls, protos[i]);
    free(protos);
    objc_registerClassPair(cls);
    return cls;
}

Class PXSuperOf(const char *name) {
    return class_getSuperclass(objc_getClass(name));
}

id PXGet(id obj, const char *key) {
    return objc_getAssociatedObject(obj, (const void *)sel_registerName(key));
}

void PXSet(id obj, const char *key, id value) {
    objc_setAssociatedObject(obj, (const void *)sel_registerName(key), value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
