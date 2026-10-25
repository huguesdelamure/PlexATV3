// Runtime helpers to subclass BackRow classes that are not exported by the
// AppleTV binary (no _OBJC_CLASS_$_BRxxx symbols to link against).
//
// Pattern: write a normal "template" class deriving from NSObject, then call
// PXCreateSubclass() at load time. It creates a real runtime class whose
// superclass is the BackRow class and copies every method of the template
// into it. Inside template methods, never use [super ...]: use PX_SUPER().

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

Class PXCreateSubclass(const char *name, const char *superName, Class templateClass);

// Superclass of the runtime class `name` (looked up once per call site).
Class PXSuperOf(const char *name);

// Call the superclass implementation of the current method.
// Usage: PX_SUPER("PXMenuController", id, self)            -> [super same-selector]
//        PX_SUPER_ARGS("PXMenuController", BOOL, (id), self, event)
#define PX_SUPER(clsName, RetType, obj)                                         \
    ({ struct objc_super _s = { (obj), PXSuperOf(clsName) };                    \
       ((RetType (*)(struct objc_super *, SEL))objc_msgSendSuper)(&_s, _cmd); })

#define PX_SUPER_ARGS(clsName, RetType, ArgTypes, obj, ...)                     \
    ({ struct objc_super _s = { (obj), PXSuperOf(clsName) };                    \
       ((RetType (*)(struct objc_super *, SEL, PX_UNPAREN ArgTypes))objc_msgSendSuper)(&_s, _cmd, __VA_ARGS__); })

#define PX_SUPER_SEL(clsName, RetType, ArgTypes, obj, sel, ...)                 \
    ({ struct objc_super _s = { (obj), PXSuperOf(clsName) };                    \
       ((RetType (*)(struct objc_super *, SEL, PX_UNPAREN ArgTypes))objc_msgSendSuper)(&_s, sel, __VA_ARGS__); })

#define PX_UNPAREN(...) __VA_ARGS__

// Associated-object storage (runtime subclasses cannot have compiled ivars).
id PXGet(id obj, const char *key);
void PXSet(id obj, const char *key, id value);

// Send a message to a class/object known only by name, without compiler noise.
#define PXCls(name) ((id)objc_getClass(name))
