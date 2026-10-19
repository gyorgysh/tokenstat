// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Link the production object to test its internal ARC boundary.
#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <mach/mach.h>
#import <dlfcn.h>
#include <assert.h>
extern xpc_endpoint_t TSCreateSimulatorEndpoint(mach_port_t port);

int main(void) {
    if (!dlsym(RTLD_DEFAULT,"xpc_endpoint_create_mach_port_4sim")) {
        puts("SKIP: optional simulator endpoint API is unavailable");
        return 0;
    }
    mach_port_t port = MACH_PORT_NULL;
    assert(mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&port) == KERN_SUCCESS);
    assert(mach_port_insert_right(mach_task_self(),port,port,MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS);
    @autoreleasepool {
        xpc_endpoint_t endpoint = TSCreateSimulatorEndpoint(port);
        assert(endpoint != nil);
    }
    mach_port_urefs_t references = 1;
    assert(mach_port_get_refs(mach_task_self(),port,MACH_PORT_RIGHT_SEND,&references) == KERN_SUCCESS);
    assert(references == 0 && "Attaching leaked an XPC endpoint and its Mach send right");
    assert(mach_port_mod_refs(mach_task_self(),port,MACH_PORT_RIGHT_RECEIVE,-1) == KERN_SUCCESS);
    puts("PASS: native simulator endpoint releases its Mach send right");
    return 0;
}
