/* ios_app.m -- the iPad/iPhone and Apple TV host for the recompiled title.
 *
 * UIKit owns the main thread, so the game (port_main in main.cpp) runs on a
 * thread of its own with the guest's 256 MB stack. Its frames go into the
 * CAMetalLayer of the full-screen view (rsx_metal_backend_set_ios_layer);
 * the view keeps the layer's drawable at its pixel size and the backend's
 * present pass fits the frame into it.
 *
 * Input reaches cellPad three ways. Game controllers come through SDL as on
 * the Mac. A hardware keyboard and the on-screen controls both write
 * g_host_key_down, the table the Mac's window fills, indexed by macOS virtual
 * key code, so the PC layout is the same everywhere: arrows/WASD move, Space
 * fires, Return is START, Escape is back. The on-screen controls show while
 * neither a controller nor a keyboard is connected.
 *
 * The title's files are in the bundle (game/NPEB00121, dev_flash). What the
 * title writes -- saves, the hdd1 cache -- goes into Documents, and so does
 * the log (Documents/log.txt).
 *
 * Apple TV differs in three ways. There are no on-screen controls: the Siri
 * Remote is a controller to SDL, and the root view controller is a
 * GCEventViewController so its buttons reach the game instead of UIKit (Menu
 * would leave the app). There is no Documents directory, only Caches, which
 * the system may empty, so the saves are also kept in the user defaults
 * (saves_backup / saves_restore). */
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern int  port_main(int argc, char** argv);
extern void rsx_metal_backend_set_ios_layer(void* layer);
extern void SDL_SetMainReady(void);
extern _Atomic unsigned char g_host_key_down[128];

#define TITLE_ID "NPEB00121"

/* Where the title's writable files live: Documents, or Caches on Apple TV. */
static NSString* data_dir(void)
{
#if TARGET_OS_TV
    return NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0];
#else
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
#endif
}

#if TARGET_OS_TV
/* ---- saves on Apple TV ----------------------------------------------------
 * The saves (gamedata/) are copied into the user defaults: "saves.files" maps
 * a relative path to its zlib data, "saves.pics" a relative path to the name
 * of the title's own image it is identical to (USRDIR/Pics: the save's
 * ICON0/PIC1). A few kilobytes in all. */
static NSString* const kSavesFiles = @"saves.files";
static NSString* const kSavesPics  = @"saves.pics";
static NSDate* s_saves_stamp;

static NSString* pics_dir(void)
{
    return [[NSBundle mainBundle].bundlePath
        stringByAppendingPathComponent:@"game/" TITLE_ID "/USRDIR/Pics"];
}

static NSDate* tree_stamp(NSString* root)
{
    NSDate* latest = [NSDate distantPast];
    NSDirectoryEnumerator* en = [NSFileManager.defaultManager enumeratorAtPath:root];
    for (NSString* rel in en) {
        NSDate* m = en.fileAttributes[NSFileModificationDate];
        if (m && [m compare:latest] == NSOrderedDescending) latest = m;
    }
    return latest;
}

static void saves_backup(void)
{
    NSString* root = [data_dir() stringByAppendingPathComponent:@"gamedata"];
    NSDate* stamp = tree_stamp(root);
    if (s_saves_stamp && [stamp isEqualToDate:s_saves_stamp]) return;
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    NSMutableDictionary* pics = [NSMutableDictionary dictionary];
    NSFileManager* fm = NSFileManager.defaultManager;
    NSDirectoryEnumerator* en = [fm enumeratorAtPath:root];
    for (NSString* rel in en) {
        if (![en.fileAttributes[NSFileType] isEqual:NSFileTypeRegular]) continue;
        NSData* d = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:rel]];
        if (!d) continue;
        NSData* pic = [NSData dataWithContentsOfFile:
            [pics_dir() stringByAppendingPathComponent:rel.lastPathComponent]];
        if (pic && [pic isEqualToData:d]) { pics[rel] = rel.lastPathComponent; continue; }
        NSData* z = [d compressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
        if (z) out[rel] = z;
    }
    [NSUserDefaults.standardUserDefaults setObject:out forKey:kSavesFiles];
    [NSUserDefaults.standardUserDefaults setObject:pics forKey:kSavesPics];
    s_saves_stamp = stamp;
    printf("[ios] saves backed up: %lu files, %lu images\n",
           (unsigned long)out.count, (unsigned long)pics.count);
}

static void saves_restore(void)
{
    NSUserDefaults* ud = NSUserDefaults.standardUserDefaults;
    NSDictionary* files = [ud dictionaryForKey:kSavesFiles];
    NSDictionary* pics  = [ud dictionaryForKey:kSavesPics];
    NSString* root = [data_dir() stringByAppendingPathComponent:@"gamedata"];
    NSFileManager* fm = NSFileManager.defaultManager;
    unsigned n = 0;
    NSMutableSet* all = [NSMutableSet setWithArray:files.allKeys ?: @[]];
    [all addObjectsFromArray:pics.allKeys ?: @[]];
    for (NSString* rel in all) {
        NSString* path = [root stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:path]) continue;          /* Caches survived */
        NSData* d = pics[rel]
            ? [NSData dataWithContentsOfFile:[pics_dir() stringByAppendingPathComponent:pics[rel]]]
            : [files[rel] decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:nil];
        if (!d) continue;
        [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES attributes:nil error:nil];
        [d writeToFile:path atomically:YES];
        n++;
    }
    s_saves_stamp = tree_stamp(root);
    printf("[ios] saves restored: %u files\n", n);
}
#endif

/* ---- keys ----------------------------------------------------------------
 * Two sources, OR-ed into the table cellPad reads. */
static unsigned char s_kb_keys[128];
static unsigned char s_touch_keys[128];

static void keys_publish(void)
{
    for (unsigned k = 0; k < 128; k++)
        atomic_store(&g_host_key_down[k], (unsigned char)(s_kb_keys[k] | s_touch_keys[k]));
}

/* macOS virtual key codes cellPad's keyboard map uses. */
enum { VK_A = 0x00, VK_S = 0x01, VK_D = 0x02, VK_Q = 0x0C, VK_W = 0x0D, VK_E = 0x0E,
       VK_1 = 0x12, VK_2 = 0x13, VK_3 = 0x14, VK_4 = 0x15, VK_P = 0x23,
       VK_RETURN = 0x24, VK_TAB = 0x30, VK_SPACE = 0x31, VK_DELETE = 0x33,
       VK_ESCAPE = 0x35, VK_KP_ENTER = 0x4C,
       VK_LEFT = 0x7B, VK_RIGHT = 0x7C, VK_DOWN = 0x7D, VK_UP = 0x7E };

/* GCKeyCode is the HID keyboard usage. */
static int vk_from_hid(long hid)
{
    switch (hid) {
    case 0x52: return VK_UP;     case 0x51: return VK_DOWN;
    case 0x50: return VK_LEFT;   case 0x4F: return VK_RIGHT;
    case 0x1A: return VK_W;      case 0x16: return VK_S;
    case 0x04: return VK_A;      case 0x07: return VK_D;
    case 0x2C: return VK_SPACE;  case 0x29: return VK_ESCAPE;
    case 0x2A: return VK_DELETE; case 0x14: return VK_Q;
    case 0x08: return VK_E;      case 0x28: return VK_RETURN;
    case 0x58: return VK_KP_ENTER; case 0x13: return VK_P;
    case 0x2B: return VK_TAB;
    case 0x1E: return VK_1;      case 0x1F: return VK_2;
    case 0x20: return VK_3;      case 0x21: return VK_4;
    default:   return -1;
    }
}

/* ---- PS3_PERF_UDP=<ip>:<port> ---------------------------------------------
 * The measurement lines also go to a computer on the network as UDP
 * datagrams: reading a file back off an Apple TV is slow and can stall. */
#include <arpa/inet.h>
#include <sys/socket.h>
void ps3_perf_udp(const char* line)
{
    static int fd = -2; static struct sockaddr_in to;
    if (fd == -2) {
        fd = -1;
        const char* e = getenv("PS3_PERF_UDP");
        char host[64]; int port = 0;
        if (e && sscanf(e, "%63[^:]:%d", host, &port) == 2 && port > 0) {
            memset(&to, 0, sizeof to);
            to.sin_family = AF_INET; to.sin_port = htons((uint16_t)port);
            if (inet_pton(AF_INET, host, &to.sin_addr) == 1) fd = socket(AF_INET, SOCK_DGRAM, 0);
        }
    }
    if (fd >= 0) sendto(fd, line, strlen(line), 0, (struct sockaddr*)&to, sizeof to);
}

/* ---- per-thread CPU (PS3RECOMP_METAL_FPS=1) --------------------------------
 * Every two seconds, the CPU share of each thread above 3%, by name. */
#include <mach/mach.h>
extern unsigned ppu_boot_frames_presented(void);
static void* cpu_sampler(void* arg)
{
    (void)arg;
    for (;;) {
        sleep(2);
        thread_act_array_t th; mach_msg_type_number_t n;
        if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) continue;
        char line[2048]; int len = snprintf(line, sizeof line, "[CPU]");
        for (mach_msg_type_number_t i = 0; i < n; i++) {
            thread_basic_info_data_t bi; mach_msg_type_number_t c = THREAD_BASIC_INFO_COUNT;
            if (thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &c) == KERN_SUCCESS &&
                !(bi.flags & TH_FLAGS_IDLE) && bi.cpu_usage * 100 / TH_USAGE_SCALE >= 3) {
                char name[64] = "?";
                thread_extended_info_data_t ei; mach_msg_type_number_t ec = THREAD_EXTENDED_INFO_COUNT;
                if (thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&ei, &ec) == KERN_SUCCESS && ei.pth_name[0])
                    snprintf(name, sizeof name, "%s", ei.pth_name);
                thread_identifier_info_data_t ii; mach_msg_type_number_t ic = THREAD_IDENTIFIER_INFO_COUNT;
                if (!strcmp(name, "?") && thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &ic) == KERN_SUCCESS)
                    snprintf(name, sizeof name, "tid%llu", (unsigned long long)ii.thread_id);
                if (len < (int)sizeof line - 80)
                    len += snprintf(line + len, sizeof line - len, " %s=%d%%", name,
                                    bi.cpu_usage * 100 / TH_USAGE_SCALE);
            }
            mach_port_deallocate(mach_task_self(), th[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_act_t));
        printf("%s\n", line);
        { static unsigned last_frames, stuck; static int dumped;
          extern void watchdog_dump_hook(void);
          const unsigned f = ppu_boot_frames_presented();
          if (f && f == last_frames) { if (++stuck == 2 && !dumped) { dumped = 1; watchdog_dump_hook(); } }
          else stuck = 0;
          last_frames = f; }
        /* PS3_STACKS_AT=<s>: every thread's stack once, that many seconds in
         * -- for a hang that keeps presenting the same frame. */
        { static int at = -1, ticks; if (at < 0) { const char* e = getenv("PS3_STACKS_AT"); at = e ? atoi(e) : 0; }
          ticks += 2;
          if (at > 0 && ticks >= at && ticks < at + 2) watchdog_dump_hook(); }
        { static FILE* pf; static int tried;
          if (!tried) { tried = 1; const char* pp = getenv("PS3_PERF_LOG"); if (pp && *pp) pf = fopen(pp, "a"); }
          if (pf) { fprintf(pf, "%s\n", line); fflush(pf); } }
        { size_t l = strlen(line); if (l + 1 < sizeof line) { line[l] = '\n'; line[l + 1] = 0; } ps3_perf_udp(line); }
    }
    return NULL;
}

/* ---- PS3_PROFILE=<thread name>|* -----------------------------------------
 * A sampling profiler for a device Instruments cannot reach: the named
 * thread's program counter (or every thread's, with "*") about 1000 times a
 * second, symbolised with dladdr. A sample in a system call is charged to the
 * first caller in our own image ("wait@..."). The top entries go out every
 * 5 s with the perf lines, prefixed by the thread's id with "*". */
#include <dlfcn.h>
#include <mach/thread_act.h>
static uintptr_t prof_symbol(thread_act_t th)
{
    arm_thread_state64_t st; mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
    if (thread_suspend(th) != KERN_SUCCESS) return 0;
    const kern_return_t kr = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, &sc);
    thread_resume(th);
    if (kr != KERN_SUCCESS) return 0;
    Dl_info di; memset(&di, 0, sizeof di);
    const uintptr_t pc = (uintptr_t)arm_thread_state64_get_pc(st);
    uintptr_t f = dladdr((void*)pc, &di) ? (uintptr_t)di.dli_saddr : pc;
    if (!di.dli_fname || !strstr(di.dli_fname, "DiggerHD")) {
        uintptr_t lr = (uintptr_t)arm_thread_state64_get_lr(st);
        uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st);
        for (int depth = 0; depth < 12; depth++) {
            Dl_info d2;
            if (lr && dladdr((void*)lr, &d2) && d2.dli_fname && strstr(d2.dli_fname, "DiggerHD"))
                return (uintptr_t)d2.dli_saddr | 1u;
            if (!fp || (fp & 7)) break;
            uintptr_t frame[2]; vm_size_t got = 0;
            if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof frame,
                                  (vm_address_t)frame, &got) != KERN_SUCCESS || got != sizeof frame) break;
            fp = frame[0]; lr = frame[1];
        }
    }
    return f;
}

static void* profiler(void* arg)
{
    const char* want = (const char*)arg;
    const int all = !strcmp(want, "*");
    enum { SLOTS = 8192 };
    static uintptr_t fn[SLOTS]; static uint64_t tidk[SLOTS]; static unsigned cnt[SLOTS];
    unsigned total = 0;
    uint64_t t_report = 0;
    const thread_act_t self = mach_thread_self();
    for (;;) {
        thread_act_array_t th; mach_msg_type_number_t n;
        if (task_threads(mach_task_self(), &th, &n) == KERN_SUCCESS) {
            for (mach_msg_type_number_t i = 0; i < n; i++) {
                int take = 0; uint64_t tid = 0;
                if (th[i] != self) {
                    thread_extended_info_data_t ei; mach_msg_type_number_t ec = THREAD_EXTENDED_INFO_COUNT;
                    thread_basic_info_data_t bi; mach_msg_type_number_t bc = THREAD_BASIC_INFO_COUNT;
                    thread_identifier_info_data_t ii; mach_msg_type_number_t ic = THREAD_IDENTIFIER_INFO_COUNT;
                    if (all) take = thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &bc) == KERN_SUCCESS &&
                                    bi.run_state == TH_STATE_RUNNING;
                    else take = thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&ei, &ec) == KERN_SUCCESS &&
                                !strcmp(ei.pth_name, want);
                    if (take && all && thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &ic) == KERN_SUCCESS)
                        tid = ii.thread_id;
                }
                if (take) {
                    const uintptr_t f = prof_symbol(th[i]);
                    if (f) {
                        unsigned h = (unsigned)(((f >> 2) ^ (tid * 40503u)) * 2654435761u) % SLOTS;
                        while (cnt[h] && (fn[h] != f || tidk[h] != tid)) h = (h + 1) % SLOTS;
                        fn[h] = f; tidk[h] = tid; cnt[h]++; total++;
                    }
                }
                mach_port_deallocate(mach_task_self(), th[i]);
            }
            vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_act_t));
        }
        usleep(1000);
        const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        if (!t_report) t_report = now;
        if (now - t_report > 5000000000ull && total) {
            t_report = now;
            char line[1600]; int len = snprintf(line, sizeof line, "[PROF %s %u]", want, total);
            for (int k = 0; k < 18; k++) {
                unsigned best = 0, bi = 0;
                for (unsigned i = 0; i < SLOTS; i++) if (cnt[i] > best) { best = cnt[i]; bi = i; }
                if (!best) break;
                Dl_info di; const char* name = "?";
                if (dladdr((void*)(fn[bi] & ~(uintptr_t)1), &di) && di.dli_sname) name = di.dli_sname;
                if (all) len += snprintf(line + len, sizeof line - len, " %llu:", (unsigned long long)tidk[bi]);
                else     len += snprintf(line + len, sizeof line - len, " ");
                len += snprintf(line + len, sizeof line - len, "%s%s=%u%%", (fn[bi] & 1) ? "wait@" : "",
                                name, best * 100 / total);
                cnt[bi] = 0;
                if (len > (int)sizeof line - 120) break;
            }
            memset(cnt, 0, sizeof cnt); total = 0;
            strcat(line, "\n");
            fputs(line, stdout);
            ps3_perf_udp(line);
        }
    }
    return NULL;
}

/* ---- hang watchdog (PS3RECOMP_METAL_FPS=1) ---------------------------------
 * When presents stop for 4 s, every thread's stack (frame-pointer walk,
 * symbolised) goes out once with the perf lines: on an Apple TV the crash
 * logs are often out of reach. */
extern unsigned ppu_boot_frames_presented(void);
static void watchdog_dump(void)
{
    thread_act_array_t th; mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS) return;
    const thread_act_t self = mach_thread_self();
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        if (th[i] != self) {
            char line[1400]; int len;
            thread_extended_info_data_t ei; mach_msg_type_number_t ec = THREAD_EXTENDED_INFO_COUNT;
            thread_identifier_info_data_t ii; mach_msg_type_number_t ic = THREAD_IDENTIFIER_INFO_COUNT;
            const char* nm = (thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&ei, &ec) == KERN_SUCCESS)
                             ? ei.pth_name : "";
            unsigned long long tid = 0;
            if (thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &ic) == KERN_SUCCESS) tid = ii.thread_id;
            len = snprintf(line, sizeof line, "[HANG] %llu %s:", tid, nm[0] ? nm : "-");
            arm_thread_state64_t st; mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
            if (thread_suspend(th[i]) == KERN_SUCCESS) {
                const kern_return_t kr = thread_get_state(th[i], ARM_THREAD_STATE64, (thread_state_t)&st, &sc);
                thread_resume(th[i]);
                if (kr == KERN_SUCCESS) {
                    uintptr_t pcs[16]; int np = 0;
                    pcs[np++] = (uintptr_t)arm_thread_state64_get_pc(st);
                    pcs[np++] = (uintptr_t)arm_thread_state64_get_lr(st);
                    uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st);
                    while (np < 16 && fp && !(fp & 7)) {
                        uintptr_t frame[2]; vm_size_t got = 0;
                        if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof frame,
                                              (vm_address_t)frame, &got) != KERN_SUCCESS || got != sizeof frame) break;
                        if (!frame[1]) break;
                        pcs[np++] = frame[1]; fp = frame[0];
                    }
                    for (int k = 0; k < np && len < (int)sizeof line - 90; k++) {
                        Dl_info di;
                        const char* sym = (dladdr((void*)pcs[k], &di) && di.dli_sname) ? di.dli_sname : "?";
                        len += snprintf(line + len, sizeof line - len, " %.70s", sym);
                    }
                }
            }
            snprintf(line + len, sizeof line - len, "\n");
            fputs(line, stdout);
            ps3_perf_udp(line);
        }
        mach_port_deallocate(mach_task_self(), th[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_act_t));
}

void watchdog_dump_hook(void) { watchdog_dump(); }

/* ---- the game thread ----------------------------------------------------- */
static void* game_thread(void* arg)
{
    (void)arg;
    pthread_setname_np("ppu-main");
    /* The guest's main thread and the RSX thread (main.cpp) are the two the
     * frame waits on: keep them on the fast cores. */
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    NSString* bundle = [[NSBundle mainBundle] bundlePath];
    NSString* docs = data_dir();
    NSFileManager* fm = [NSFileManager defaultManager];

    freopen([[docs stringByAppendingPathComponent:@"log.txt"] fileSystemRepresentation], "w", stdout);
    dup2(fileno(stdout), fileno(stderr));
    setvbuf(stdout, NULL, _IOLBF, 0);

    /* /dev_hdd0 is writable (Documents/hdd0) but holds the title's directory
     * too: link it to the bundle's copy, again on every launch, since an
     * update moves the bundle. */
    NSString* game = [bundle stringByAppendingPathComponent:@"game/" TITLE_ID];
    NSString* hdd0 = [docs stringByAppendingPathComponent:@"hdd0"];
    NSString* link = [hdd0 stringByAppendingPathComponent:@"game/" TITLE_ID];
    [fm createDirectoryAtPath:[hdd0 stringByAppendingPathComponent:@"game"]
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:link error:nil];
    [fm createSymbolicLinkAtPath:link withDestinationPath:game error:nil];
    NSString* hdd1 = [docs stringByAppendingPathComponent:@"hdd1"];
    NSString* gamedata = [docs stringByAppendingPathComponent:@"gamedata"];
    [fm createDirectoryAtPath:hdd1 withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:gamedata withIntermediateDirectories:YES attributes:nil error:nil];
    chdir([docs fileSystemRepresentation]);

    setenv("PS3_TITLE", "Digger HD", 0);
    setenv("PS3_HDD0_ROOT", [hdd0 fileSystemRepresentation], 1);
    setenv("PS3_HDD1_ROOT", [hdd1 fileSystemRepresentation], 1);
    setenv("PS3_GAMEDATA_ROOT", [gamedata fileSystemRepresentation], 1);
    /* PAD_AUTOPLAY runs, like the Mac playtest, start from no save at all,
     * in a directory of their own, and never touch the player's saves. */
    const int autoplay = getenv("PAD_AUTOPLAY") != NULL;
    if (autoplay) {
        NSString* ap = [docs stringByAppendingPathComponent:
            [NSString stringWithFormat:@"autoplay/%.0f", NSDate.date.timeIntervalSince1970]];
        [fm createDirectoryAtPath:ap withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("PS3_GAMEDATA_ROOT", [ap fileSystemRepresentation], 1);
        setenv("PAD_AUTOPLAY_REFS", [[bundle stringByAppendingPathComponent:@"autoplay-refs.bin"] fileSystemRepresentation], 1);
    }
    setenv("PS3_VFS_ROOT", [game fileSystemRepresentation], 1);
    setenv("PS3_DEV_FLASH", [[bundle stringByAppendingPathComponent:@"dev_flash"] fileSystemRepresentation], 1);
    /* Translated shaders: the bundled ones (made on a Mac), and the ones this
     * device translates itself (Metal backend, PS3_SHADER_CACHE). */
    NSString* shaders = [docs stringByAppendingPathComponent:@"shaders"];
    [fm createDirectoryAtPath:shaders withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("PS3_SHADER_CACHE", [shaders fileSystemRepresentation], 1);
    setenv("PS3_SHADER_CACHE_RO", [[bundle stringByAppendingPathComponent:@"shaders"] fileSystemRepresentation], 1);
#if TARGET_OS_TV
    if (!autoplay) saves_restore();
    if (!autoplay)
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer* t) { saves_backup(); }];
    });
#endif

    { const char* f = getenv("PS3RECOMP_METAL_FPS");
      if (f && !strcmp(f, "1")) { pthread_t t; pthread_create(&t, NULL, cpu_sampler, NULL); } }
    { const char* prof = getenv("PS3_PROFILE");
      if (prof && *prof) { pthread_t t; pthread_create(&t, NULL, profiler, (void*)prof); } }
    SDL_SetMainReady();
    char* argv[] = { (char*)"DiggerHD",
                     (char*)[[game stringByAppendingPathComponent:@"USRDIR/EBOOT.elf"] fileSystemRepresentation],
                     NULL };
    const int rc = port_main(2, argv);
    printf("[ios] port_main returned %d\n", rc);
    fflush(stdout);
    exit(rc);
    return NULL;
}

/* ---- vertical blank --------------------------------------------------------
 * The screen's refresh, counted by a CADisplayLink on the main run loop; the
 * frame clock (main.cpp) delivers the guest's vblank from it. */
static _Atomic unsigned long s_vsync_count;
static dispatch_semaphore_t s_vsync_sem;
unsigned long ios_vsync_count(void) { return atomic_load(&s_vsync_count); }
dispatch_semaphore_t ios_vsync_semaphore(void) { return s_vsync_sem; }

@interface VsyncTarget : NSObject
@end
@implementation VsyncTarget
- (void)tick:(CADisplayLink*)link
{
    atomic_fetch_add(&s_vsync_count, 1);
    dispatch_semaphore_signal(s_vsync_sem);
}
@end

/* ---- the view ------------------------------------------------------------ */
@interface GameView : UIView
@end

@implementation GameView
+ (Class)layerClass { return [CAMetalLayer class]; }

- (void)layoutSubviews
{
    [super layoutSubviews];
    CAMetalLayer* layer = (CAMetalLayer*)self.layer;
    const CGFloat sc = self.window ? self.window.windowScene.screen.nativeScale : self.contentScaleFactor;
    layer.contentsScale = sc;
    CGSize px = CGSizeMake(floor(self.bounds.size.width * sc), floor(self.bounds.size.height * sc));
    /* PS3_DRAWABLE_MAX_H caps the drawable's height (0: the screen's own).
     * On Apple TV the default is the title's 720 lines, as a PS3 sends them:
     * the box scales them to the TV in its display hardware for nothing,
     * while drawing the TV's 3840x2160 ourselves -- MetalFX into it and a
     * present pass over it -- took the A15's GPU from ~90 ms to ~1300 ms of
     * work a second and the game from 55 fps to 23. */
    const char* cap = getenv("PS3_DRAWABLE_MAX_H");
#if TARGET_OS_TV
    const int max_h = cap ? atoi(cap) : 720;
#else
    const int max_h = cap ? atoi(cap) : 0;
#endif
    if (max_h > 0 && px.height > max_h) {
        px.width = floor(px.width * max_h / px.height); px.height = max_h;
    }
    layer.drawableSize = px;
}
@end

#if !TARGET_OS_TV
/* ---- on-screen controls ---------------------------------------------------
 * A d-pad on the left (four-way: the dominant axis wins, as the game's
 * tunnels only go one way at a time) and four buttons on the right. */
@interface TouchControls : UIView
@end

@implementation TouchControls {
    CGPoint _pad;          /* d-pad centre */
    CGFloat _padR;
    struct { CGPoint c; CGFloat r; int vk; NSString* label; } _btn[4];
}

- (instancetype)initWithFrame:(CGRect)f
{
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    const CGSize s = self.bounds.size;
    const UIEdgeInsets in = self.safeAreaInsets;
    const CGFloat u = MIN(s.width, s.height) / 10.0;      /* one unit */
    _padR = u * 1.6;
    _pad = CGPointMake(in.left + u * 0.6 + _padR, s.height - in.bottom - u * 0.6 - _padR);
    const CGFloat br = u * 0.62;
    const CGFloat cx = s.width - in.right - u * 0.6 - u * 1.6, cy = s.height - in.bottom - u * 0.6 - u * 1.6;
    _btn[0].c = CGPointMake(cx, cy + u * 1.0);  _btn[0].vk = VK_SPACE;  _btn[0].label = @"Fire";
    _btn[1].c = CGPointMake(cx + u * 1.0, cy);  _btn[1].vk = VK_ESCAPE; _btn[1].label = @"Back";
    _btn[2].c = CGPointMake(cx - u * 1.0, cy);  _btn[2].vk = VK_Q;      _btn[2].label = @"□";
    _btn[3].c = CGPointMake(cx, cy - u * 1.0);  _btn[3].vk = VK_RETURN; _btn[3].label = @"Start";
    for (int i = 0; i < 4; i++) _btn[i].r = br;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect
{
    CGContextRef g = UIGraphicsGetCurrentContext();
    [[UIColor colorWithWhite:1 alpha:0.14] setFill];
    [[UIColor colorWithWhite:1 alpha:0.35] setStroke];
    UIBezierPath* p = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(_pad.x - _padR, _pad.y - _padR, _padR * 2, _padR * 2)];
    p.lineWidth = 2; [p fill]; [p stroke];
    /* direction marks */
    const CGFloat a = _padR * 0.62, t = _padR * 0.16;
    for (int d = 0; d < 4; d++) {
        const CGFloat dx[4] = {0, 0, -1, 1}, dy[4] = {-1, 1, 0, 0};
        CGPoint tip = CGPointMake(_pad.x + dx[d] * (a + t), _pad.y + dy[d] * (a + t));
        CGPoint b1 = CGPointMake(_pad.x + dx[d] * a + dy[d] * t, _pad.y + dy[d] * a + dx[d] * t);
        CGPoint b2 = CGPointMake(_pad.x + dx[d] * a - dy[d] * t, _pad.y + dy[d] * a - dx[d] * t);
        UIBezierPath* tri = [UIBezierPath bezierPath];
        [tri moveToPoint:tip]; [tri addLineToPoint:b1]; [tri addLineToPoint:b2]; [tri closePath];
        [[UIColor colorWithWhite:1 alpha:0.5] setFill]; [tri fill];
    }
    for (int i = 0; i < 4; i++) {
        UIBezierPath* c = [UIBezierPath bezierPathWithOvalInRect:
            CGRectMake(_btn[i].c.x - _btn[i].r, _btn[i].c.y - _btn[i].r, _btn[i].r * 2, _btn[i].r * 2)];
        [[UIColor colorWithWhite:1 alpha:0.14] setFill];
        [[UIColor colorWithWhite:1 alpha:0.35] setStroke];
        c.lineWidth = 2; [c fill]; [c stroke];
        NSDictionary* at = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:_btn[i].r * 0.5],
                              NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.7] };
        CGSize ts = [_btn[i].label sizeWithAttributes:at];
        [_btn[i].label drawAtPoint:CGPointMake(_btn[i].c.x - ts.width / 2, _btn[i].c.y - ts.height / 2)
                    withAttributes:at];
    }
    (void)g;
}

- (void)updateTouches:(UIEvent*)event
{
    memset(s_touch_keys, 0, sizeof s_touch_keys);
    for (UITouch* t in [event allTouches]) {
        if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) continue;
        const CGPoint p = [t locationInView:self];
        const CGFloat dx = p.x - _pad.x, dy = p.y - _pad.y;
        if (dx * dx + dy * dy <= _padR * _padR * 1.6) {
            if (dx * dx + dy * dy > _padR * _padR * 0.04) {
                if (fabs(dx) > fabs(dy)) s_touch_keys[dx < 0 ? VK_LEFT : VK_RIGHT] = 1;
                else                     s_touch_keys[dy < 0 ? VK_UP : VK_DOWN] = 1;
            }
            continue;
        }
        for (int i = 0; i < 4; i++) {
            const CGFloat bx = p.x - _btn[i].c.x, by = p.y - _btn[i].c.y;
            if (bx * bx + by * by <= _btn[i].r * _btn[i].r * 1.5) s_touch_keys[_btn[i].vk] = 1;
        }
    }
    keys_publish();
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e     { [self updateTouches:e]; }
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e     { [self updateTouches:e]; }
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e     { [self updateTouches:e]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e { [self updateTouches:e]; }
@end
#endif

/* ---- the controller ------------------------------------------------------ */
#if TARGET_OS_TV
@interface GameViewController : GCEventViewController
@end
#else
@interface GameViewController : UIViewController
@end
#endif

@implementation GameViewController {
#if !TARGET_OS_TV
    TouchControls* _touch;
#endif
}

- (void)loadView
{
    GameView* v = [[GameView alloc] initWithFrame:CGRectZero];
    v.opaque = YES;             /* the Metal layer fills it; nothing to blend */
    self.view = v;
#if TARGET_OS_TV
    self.controllerUserInteractionEnabled = NO;   /* the remote's buttons are the game's */
#else
    _touch = [[TouchControls alloc] initWithFrame:v.bounds];
    _touch.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [v addSubview:_touch];
#endif
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName n in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification,
                                   GCKeyboardDidConnectNotification, GCKeyboardDidDisconnectNotification])
        [nc addObserver:self selector:@selector(devicesChanged) name:n object:nil];
    [self devicesChanged];

    rsx_metal_backend_set_ios_layer((__bridge void*)self.view.layer);
    /* 60 Hz, the rate the title is made for, even on a 120 Hz screen. */
    static VsyncTarget* vt; static CADisplayLink* link;
    vt = [VsyncTarget new];
    s_vsync_sem = dispatch_semaphore_create(0);
    link = [CADisplayLink displayLinkWithTarget:vt selector:@selector(tick:)];
    link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 256u * 1024u * 1024u);
    pthread_t th;
    pthread_create(&th, &attr, game_thread, NULL);
    pthread_attr_destroy(&attr);
}

- (void)devicesChanged
{
    GCKeyboard* kb = GCKeyboard.coalescedKeyboard;
    if (kb) {
        kb.keyboardInput.keyChangedHandler = ^(GCKeyboardInput* in, GCControllerButtonInput* key,
                                               GCKeyCode code, BOOL pressed) {
            const int vk = vk_from_hid((long)code);
            if (vk < 0) return;
            s_kb_keys[vk] = pressed ? 1 : 0;
            keys_publish();
        };
    } else {
        memset(s_kb_keys, 0, sizeof s_kb_keys);
        keys_publish();
    }
#if !TARGET_OS_TV
    _touch.hidden = (GCController.controllers.count > 0 || kb != nil);
    if (_touch.hidden) { memset(s_touch_keys, 0, sizeof s_touch_keys); keys_publish(); }
#endif
}

/* Swallow hardware key presses so UIKit does not beep or act on them; the
 * GCKeyboard handler above is what reads them. */
- (void)pressesBegan:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {}
- (void)pressesEnded:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {}

#if !TARGET_OS_TV
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
#endif
@end

/* ---- the app -------------------------------------------------------------
 * One scene (UIApplicationSceneManifest in Info.plist): tvOS 27 stops an app
 * that does not adopt the scene life cycle. */
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow* window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session
      options:(UISceneConnectionOptions*)opts
{
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController = [GameViewController new];
    [self.window makeKeyAndVisible];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
}
#if TARGET_OS_TV
- (void)sceneWillResignActive:(UIScene*)scene { saves_backup(); }
- (void)sceneDidEnterBackground:(UIScene*)scene { saves_backup(); }
#endif
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opts
{
    return YES;
}

- (UISceneConfiguration*)application:(UIApplication*)app
    configurationForConnectingSceneSession:(UISceneSession*)session
                                   options:(UISceneConnectionOptions*)opts
{
    UISceneConfiguration* c = [[UISceneConfiguration alloc] initWithName:@"Default"
                                                             sessionRole:session.role];
    c.delegateClass = [SceneDelegate class];
    return c;
}
@end

int main(int argc, char* argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
