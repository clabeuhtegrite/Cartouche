//
//  GalleryMainThread.c
//  CartoucheGallery
//
//  Where the gallery's main thread is (GalleryMainThread.h): its registers,
//  then the frames on its stack, each of which holds the frame of its
//  caller and where its caller goes on, read while it is stopped.
//

#include "GalleryMainThread.h"

#include <mach/mach.h>
#include <pthread.h>

static thread_act_t galleryMainThread = MACH_PORT_NULL;
/// The main thread's stack, from its lowest address to above its highest.
static uintptr_t galleryStackLow = 0;
static uintptr_t galleryStackHigh = 0;

void GalleryMainThreadNote(void) {
    pthread_t thread = pthread_self();
    galleryStackHigh = (uintptr_t)pthread_get_stackaddr_np(thread);
    galleryStackLow = galleryStackHigh - (uintptr_t)pthread_get_stacksize_np(thread);
    galleryMainThread = pthread_mach_thread_np(thread);
}

int GalleryMainThreadStack(uintptr_t *frames, int capacity) {
    thread_act_t thread = galleryMainThread;
    if (thread == MACH_PORT_NULL || frames == NULL || capacity <= 0) {
        return 0;
    }
    if (thread_suspend(thread) != KERN_SUCCESS) {
        return 0;
    }
    uintptr_t pc = 0;
    uintptr_t lr = 0;
    uintptr_t fp = 0;
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) == KERN_SUCCESS) {
        pc = (uintptr_t)arm_thread_state64_get_pc(state);
        lr = (uintptr_t)arm_thread_state64_get_lr(state);
        fp = (uintptr_t)arm_thread_state64_get_fp(state);
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &count) == KERN_SUCCESS) {
        pc = (uintptr_t)state.__rip;
        fp = (uintptr_t)state.__rbp;
    }
#endif
    int taken = 0;
    if (pc != 0) {
        frames[taken++] = pc;
    }
    // On arm64, a function that has yet to save where its caller goes on,
    // such as the call into the kernel that waits for a message, has it in
    // its link register alone.
    int linkAt = -1;
    if (lr != 0 && taken < capacity) {
        linkAt = taken;
        frames[taken++] = lr;
    }
    // Each frame lies above the one it called, within the stack.
    while (taken < capacity && fp % sizeof(uintptr_t) == 0 && fp >= galleryStackLow
           && fp <= galleryStackHigh - 2 * sizeof(uintptr_t)) {
        const uintptr_t *frame = (const uintptr_t *)fp;
        uintptr_t caller = frame[0];
        uintptr_t back = frame[1];
        if (back == 0) {
            break;
        }
        // The link register, when the innermost function had saved it.
        if (linkAt >= 0 && taken == linkAt + 1 && frames[linkAt] == back) {
            linkAt = -1;
        } else {
            frames[taken++] = back;
        }
        if (caller <= fp) {
            break;
        }
        fp = caller;
    }
    thread_resume(thread);
    return taken;
}
