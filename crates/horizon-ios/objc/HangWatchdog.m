// horizon-ios: when the main thread stops (the screen freezes), write every thread's stack to
// the log (Documents/horizon-log.txt), so a report from a device shows where the game waits.
// Addresses are printed raw with their image's base: `atos -o horizon-ios -l <base> <address>`
// names them.
//
// The stacks are read while each thread is suspended, using only system calls (no locks a
// suspended thread could hold); the names are looked up after every thread runs again.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

#define HORIZON_MAX_THREADS 128
#define HORIZON_MAX_FRAMES 48
// The main thread may be busy for a few seconds while the game loads; a freeze is longer.
#define HORIZON_STALL_SECONDS 8

static _Atomic uint64_t horizon_heartbeat;

typedef struct {
    char name[64];
    int count;
    uintptr_t frames[HORIZON_MAX_FRAMES];
} HorizonThreadStack;

static HorizonThreadStack horizon_stacks[HORIZON_MAX_THREADS];

/// Called on every display refresh while the main thread runs its loop.
void horizon_ios_heartbeat(void) {
    atomic_fetch_add_explicit(&horizon_heartbeat, 1, memory_order_relaxed);
}

static uintptr_t horizon_strip(uintptr_t address) {
    // Pointer authentication bits on arm64e system libraries.
    return address & 0x0000000FFFFFFFFFULL;
}

static void horizon_dump_threads(int round) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
        return;
    }
    thread_t me = mach_thread_self();
    int stored = 0;
    for (mach_msg_type_number_t i = 0; i < count && stored < HORIZON_MAX_THREADS; i++) {
        thread_t thread = threads[i];
        if (thread == me) {
            continue;
        }
        HorizonThreadStack *stack = &horizon_stacks[stored++];
        memset(stack, 0, sizeof *stack);
        pthread_t pthread = pthread_from_mach_thread_np(thread);
        if (pthread != NULL) {
            pthread_getname_np(pthread, stack->name, sizeof stack->name);
        }
        if (thread_suspend(thread) != KERN_SUCCESS) {
            continue;
        }
        arm_thread_state64_t state;
        mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &state_count) == KERN_SUCCESS) {
            stack->frames[stack->count++] = horizon_strip((uintptr_t)arm_thread_state64_get_pc(state));
            stack->frames[stack->count++] = horizon_strip((uintptr_t)arm_thread_state64_get_lr(state));
            uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(state);
            while (fp != 0 && (fp & 7) == 0 && stack->count < HORIZON_MAX_FRAMES) {
                uintptr_t pair[2] = {0, 0};
                vm_size_t got = 0;
                if (vm_read_overwrite(mach_task_self(), fp, sizeof pair, (vm_address_t)pair, &got) != KERN_SUCCESS ||
                    got != sizeof pair || pair[1] == 0) {
                    break;
                }
                stack->frames[stack->count++] = horizon_strip(pair[1]);
                if (pair[0] <= fp) {
                    break;
                }
                fp = pair[0];
            }
        }
        thread_resume(thread);
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    mach_port_deallocate(mach_task_self(), me);

    fprintf(stderr, "horizon-ios: the main thread has stopped for %d s; every thread's stack (round %d):\n",
        HORIZON_STALL_SECONDS * round, round);
    for (int t = 0; t < stored; t++) {
        HorizonThreadStack *stack = &horizon_stacks[t];
        fprintf(stderr, "horizon-ios: thread %d \"%s\"\n", t, stack->name);
        for (int f = 0; f < stack->count; f++) {
            Dl_info info;
            if (dladdr((const void *)stack->frames[f], &info) != 0 && info.dli_fname != NULL) {
                const char *image = strrchr(info.dli_fname, '/');
                fprintf(stderr, "horizon-ios:   %2d 0x%lx %s base 0x%lx %s\n", f, (unsigned long)stack->frames[f],
                    image != NULL ? image + 1 : info.dli_fname, (unsigned long)info.dli_fbase,
                    info.dli_sname != NULL ? info.dli_sname : "?");
            } else {
                fprintf(stderr, "horizon-ios:   %2d 0x%lx\n", f, (unsigned long)stack->frames[f]);
            }
        }
    }
    fflush(stderr);
}

static void *horizon_watchdog(void *unused) {
    (void)unused;
    pthread_setname_np("horizon-ios watchdog");
    uint64_t last = atomic_load_explicit(&horizon_heartbeat, memory_order_relaxed);
    int stalled = 0;
    int round = 0;
    for (;;) {
        sleep(1);
        uint64_t now = atomic_load_explicit(&horizon_heartbeat, memory_order_relaxed);
        if (now != last) {
            last = now;
            stalled = 0;
            round = 0;
            continue;
        }
        // Two rounds a freeze: what it waits on, and whether that moves.
        if (++stalled == HORIZON_STALL_SECONDS && round < 2) {
            stalled = 0;
            horizon_dump_threads(++round);
        }
    }
    return NULL;
}

/// Starts the watchdog once.
void horizon_ios_start_watchdog(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pthread_t thread;
        if (pthread_create(&thread, NULL, horizon_watchdog, NULL) == 0) {
            pthread_detach(thread);
        }
    });
}
