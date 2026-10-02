//
//  vulnlab.c — VulnLab 漏洞研究台（dylib 载荷 v0.1）
//
//  ============================================================================
//  目标：给 iOS 漏洞挖掘提供**攻击面起点**——在宿主 App 的沙盒内，如实读取
//  「能读到什么、读不到什么」。**只做只读探测与信息采集**，不含任何漏洞利用、
//  不含任何内存破坏、不修改系统状态。
//
//  设计原则（对应研究纪律）：
//   · 只用公共 SDK 接口：libc / libSystem / IOKit / CoreFoundation。
//     唯一例外是 csops(2)（BSD syscall，非公开头）——自行 extern 声明，用于读
//     自身 code signing 状态；它是**只读**的，不改变进程状态。
//   · 每个探测项都带 reachable 标志：读得到写真实值，读不到写 errno + 原因。
//     **不把「拿不到」粉饰成「拿到了」**（见各 JSON 里的 reachable/errno）。
//   · bridge 不回传字符串（宿主只取 Int32 rc，见 ModuleService.swift:774-777），
//     所以结果一律写文件到模块数据目录；stderr 同步落 data/go_stderr.log。
//
//  宿主调用约定（实读 EscapeOS/Services/BinaryModuleRunner.swift）：
//   ① 入口 VulnLabMain(char *dataDir)：宿主在独立 pthread(8MB 栈) 调用，参数是
//      模块数据目录；句柄在入口调用**之前**已 dlsym 成功并缓存（:284-289），
//      所以入口立即返回也不影响后续 bridge 动作解析符号。
//   ② bridge 动作：0 参 → int fn(void)；rc==0 视为成功，非 0 抛「执行失败 rc=N」。
//      **不回传字符串**——要展示的内容写文件 / 写 stderr。
//  ============================================================================

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/machine.h>
#include <pthread.h>
#include <servers/bootstrap.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

// 导出宏：编译带 -fvisibility=hidden，只显式导出下列符号。
#if defined(__cplusplus)
#define VULNLAB_EXPORT extern "C" __attribute__((visibility("default")))
#else
#define VULNLAB_EXPORT __attribute__((visibility("default")))
#endif

// ---------------------------------------------------------------------------
// csops(2)：BSD syscall，读自身 code signing 状态。非公开头 → 自行声明。
// 仅用 CS_OPS_STATUS（只读），不改变任何状态。
// ---------------------------------------------------------------------------
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#define VL_CS_OPS_STATUS 0
// 标志位来自 XNU bsd/sys/codesign.h（值稳定）
#define VL_CS_VALID                 0x0000001
#define VL_CS_HARD                  0x0000100
#define VL_CS_KILL                  0x0000200
#define VL_CS_CHECK_LV              0x0000400
#define VL_CS_RESTRICT              0x0000800
#define VL_CS_REQUIRE_LV            0x0002000
#define VL_CS_ENTITLEMENTS_VALIDATED 0x0004000
#define VL_CS_PLATFORM_BINARY       0x4000000
#define VL_CS_DEBUGGED              0x10000000

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------
static char *g_data_dir = NULL;          // 模块数据目录（由 VulnLabMain 记录，常驻不释放）
static const char *k_probe_ver = "vulnlab.v0.1";

// ---------------------------------------------------------------------------
// 小工具：JSON 字符串转义 + 输出文件
// ---------------------------------------------------------------------------
static void jstr(FILE *f, const char *s) {
    fputc('"', f);
    if (s) {
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            switch (*p) {
                case '"':  fputs("\\\"", f); break;
                case '\\': fputs("\\\\", f); break;
                case '\n': fputs("\\n", f);  break;
                case '\r': fputs("\\r", f);  break;
                case '\t': fputs("\\t", f);  break;
                default:
                    if (*p < 0x20) fprintf(f, "\\u%04x", *p);
                    else fputc(*p, f);
            }
        }
    }
    fputc('"', f);
}

// 打开数据目录下的输出文件；失败返回 NULL。
static FILE *open_out(const char *name) {
    if (!g_data_dir) return NULL;
    char path[1200];
    snprintf(path, sizeof(path), "%s/%s", g_data_dir, name);
    return fopen(path, "w");
}

// 写一个 ISO-8601 UTC 时间戳字符串（不换行）。
static void write_ts(FILE *f) {
    time_t t = time(NULL);
    struct tm tmv;
    gmtime_r(&t, &tmv);
    char buf[64];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tmv);
    jstr(f, buf);
}

// ---------------------------------------------------------------------------
// sysctl 读取小工具
// ---------------------------------------------------------------------------
static const char *sc_str(const char *name, char *buf, size_t buflen) {
    size_t len = buflen;
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0 || len == 0) {
        snprintf(buf, buflen, "?");
        return buf;
    }
    if (buf[len - 1] != '\0') buf[(len < buflen) ? len : (buflen - 1)] = '\0';
    return buf;
}

static long long sc_i64(const char *name) {
    long long v = 0;
    size_t len = sizeof(v);
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return -1;
    return v;
}

static int sc_i32(const char *name) {
    int v = 0;
    size_t len = sizeof(v);
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return -1;
    return v;
}

// 尝试读一个字符串型 sysctl 并写成 JSON 项；first 控制逗号。
static void emit_sc_str(FILE *f, const char *name, int *first) {
    char buf[512];
    size_t len = sizeof(buf);
    errno = 0;
    int rc = sysctlbyname(name, buf, &len, NULL, 0);
    int e = errno;
    if (!*first) fputs(",\n", f);
    *first = 0;
    fprintf(f, "    { \"name\": ");
    jstr(f, name);
    if (rc == 0 && len > 0) {
        if (buf[len - 1] != '\0') buf[(len < sizeof(buf)) ? len : (sizeof(buf) - 1)] = '\0';
        fputs(", \"reachable\": true, \"value\": ", f);
        jstr(f, buf);
        fputs(" }", f);
    } else {
        fprintf(f, ", \"reachable\": false, \"errno\": %d, \"error\": ", e);
        jstr(f, strerror(e));
        fputs(" }", f);
    }
}

// 尝试读一个整数型 sysctl（64 位缓冲，兼容 int/long/long long）并写 JSON 项。
static void emit_sc_num(FILE *f, const char *name, int *first) {
    long long v = 0;
    size_t len = sizeof(v);
    errno = 0;
    int rc = sysctlbyname(name, &v, &len, NULL, 0);
    int e = errno;
    if (!*first) fputs(",\n", f);
    *first = 0;
    fprintf(f, "    { \"name\": ");
    jstr(f, name);
    if (rc == 0) {
        fprintf(f, ", \"reachable\": true, \"value\": %lld }", v);
    } else {
        fprintf(f, ", \"reachable\": false, \"errno\": %d, \"error\": ", e);
        jstr(f, strerror(e));
        fputs(" }", f);
    }
}

// 读自身 code signing 状态；成功返回 0 并写 *out。
static int cs_status(uint32_t *out) {
    uint32_t flags = 0;
    int rc = csops(getpid(), VL_CS_OPS_STATUS, &flags, sizeof(flags));
    if (rc == 0 && out) *out = flags;
    return rc;
}

// ---------------------------------------------------------------------------
// 各探测段的实现
// ---------------------------------------------------------------------------

// ① 系统基线：uname / kern+hw sysctl / 进程身份 / csops 状态
static int write_baseline(void) {
    FILE *f = open_out("vulnlab-baseline.json");
    if (!f) { fprintf(stderr, "[vulnlab] baseline: 打不开输出文件 (%s)\n", strerror(errno)); return 3; }

    struct utsname u;
    memset(&u, 0, sizeof(u));
    int uname_ok = (uname(&u) == 0);

    char model[256], osver[256], osrel[256], osrev[256], kver[1024], hostname[256];
    sc_str("hw.model", model, sizeof(model));
    sc_str("kern.osversion", osver, sizeof(osver));
    sc_str("kern.osrelease", osrel, sizeof(osrel));
    sc_str("kern.osrevision", osrev, sizeof(osrev));
    sc_str("kern.version", kver, sizeof(kver));
    sc_str("kern.hostname", hostname, sizeof(hostname));

    fprintf(f, "{\n  \"probe\": ");
    jstr(f, k_probe_ver);
    fprintf(f, ",\n  \"generatedAt\": ");
    write_ts(f);

    fprintf(f, ",\n  \"uname\": {\n    \"sysname\": ");
    jstr(f, uname_ok ? u.sysname : "?");
    fprintf(f, ",\n    \"nodename\": ");
    jstr(f, uname_ok ? u.nodename : "?");
    fprintf(f, ",\n    \"release\": ");
    jstr(f, uname_ok ? u.release : "?");
    fprintf(f, ",\n    \"version\": ");
    jstr(f, uname_ok ? u.version : "?");
    fprintf(f, ",\n    \"machine\": ");
    jstr(f, uname_ok ? u.machine : "?");
    fprintf(f, "\n  },\n");

    fprintf(f, "  \"sysctl_kern\": [\n");
    int first = 1;
    emit_sc_str(f, "kern.osversion", &first);
    emit_sc_str(f, "kern.osrelease", &first);
    emit_sc_str(f, "kern.osrevision", &first);
    emit_sc_str(f, "kern.version", &first);
    emit_sc_str(f, "kern.hostname", &first);
    emit_sc_str(f, "kern.boottime", &first);
    emit_sc_str(f, "kern.uuid", &first);
    emit_sc_num(f, "kern.secure_kernel", &first);
    emit_sc_num(f, "kern.argmax", &first);
    fprintf(f, "\n  ],\n");

    fprintf(f, "  \"sysctl_hw\": [\n");
    first = 1;
    emit_sc_str(f, "hw.machine", &first);
    emit_sc_str(f, "hw.model", &first);
    emit_sc_num(f, "hw.ncpu", &first);
    emit_sc_num(f, "hw.physicalcpu", &first);
    emit_sc_num(f, "hw.logicalcpu", &first);
    emit_sc_num(f, "hw.memsize", &first);
    emit_sc_num(f, "hw.cputype", &first);
    emit_sc_num(f, "hw.cpusubtype", &first);
    emit_sc_num(f, "hw.pagesize", &first);
    emit_sc_num(f, "hw.optional.arm64", &first);
    fprintf(f, "\n  ],\n");

    char cwd[1024];
    if (!getcwd(cwd, sizeof(cwd))) snprintf(cwd, sizeof(cwd), "?");
    fprintf(f, "  \"process\": {\n    \"pid\": %d,\n    \"ppid\": %d,\n    \"uid\": %d,\n    \"euid\": %d,\n    \"gid\": %d,\n    \"egid\": %d,\n",
            (int)getpid(), (int)getppid(), (int)getuid(), (int)geteuid(), (int)getgid(), (int)getegid());
    fprintf(f, "    \"cwd\": ");
    jstr(f, cwd);
    fprintf(f, ",\n    \"HOME\": ");
    jstr(f, getenv("HOME") ? getenv("HOME") : "?");
    fprintf(f, ",\n    \"TMPDIR\": ");
    jstr(f, getenv("TMPDIR") ? getenv("TMPDIR") : "?");
    fprintf(f, ",\n    \"dataDir\": ");
    jstr(f, g_data_dir ? g_data_dir : "?");
    fprintf(f, "\n  },\n");

    uint32_t cs = 0;
    int cs_rc = cs_status(&cs);
    fprintf(f, "  \"codesign\": {\n    \"csops_rc\": %d,\n", cs_rc);
    if (cs_rc == 0) {
        fprintf(f, "    \"status\": %u,\n", cs);
        fprintf(f, "    \"CS_VALID\": %s,\n", (cs & VL_CS_VALID) ? "true" : "false");
        fprintf(f, "    \"CS_HARD\": %s,\n", (cs & VL_CS_HARD) ? "true" : "false");
        fprintf(f, "    \"CS_KILL\": %s,\n", (cs & VL_CS_KILL) ? "true" : "false");
        fprintf(f, "    \"CS_RESTRICT\": %s,\n", (cs & VL_CS_RESTRICT) ? "true" : "false");
        fprintf(f, "    \"CS_REQUIRE_LV\": %s,\n", (cs & VL_CS_REQUIRE_LV) ? "true" : "false");
        fprintf(f, "    \"CS_PLATFORM_BINARY\": %s,\n", (cs & VL_CS_PLATFORM_BINARY) ? "true" : "false");
        fprintf(f, "    \"CS_ENTITLEMENTS_VALIDATED\": %s,\n", (cs & VL_CS_ENTITLEMENTS_VALIDATED) ? "true" : "false");
        fprintf(f, "    \"CS_DEBUGGED\": %s\n", (cs & VL_CS_DEBUGGED) ? "true" : "false");
    } else {
        fprintf(f, "    \"note\": \"csops 调用失败（可能被沙盒/平台策略拒绝）\"\n");
    }
    fprintf(f, "  }\n}\n");

    fclose(f);
    fprintf(stderr, "[vulnlab] baseline → %s/vulnlab-baseline.json (uname=%s, csops_rc=%d)\n",
            g_data_dir, uname_ok ? u.machine : "?", cs_rc);
    return 0;
}

// ② 缓解措施探测：逐项标注 reachable（读得到给值，读不到给原因）
static int write_mitigations(void) {
    FILE *f = open_out("vulnlab-mitigations.json");
    if (!f) { fprintf(stderr, "[vulnlab] mitigations: 打不开输出文件 (%s)\n", strerror(errno)); return 3; }

    int cpusub = sc_i32("hw.cpusubtype");   // arm64e 的 CPU_SUBTYPE_ARM64E = 2
    char machine[128];
    sc_str("hw.machine", machine, sizeof(machine));

    fprintf(f, "{\n  \"probe\": ");
    jstr(f, k_probe_ver);
    fprintf(f, ",\n  \"generatedAt\": ");
    write_ts(f);
    fprintf(f, ",\n  \"arch\": {\n    \"hw.machine\": ");
    jstr(f, machine);
    fprintf(f, ",\n    \"hw.cpusubtype\": %d,\n", cpusub);
    fprintf(f, "    \"is_arm64e\": %s,\n", (cpusub == 2) ? "true" : "false");
    fprintf(f, "    \"ptrauth_compile_flag\": %s\n",
#if defined(__arm64e__) || defined(__PTRAUTH_INTRINSICS__)
            "true"
#else
            "false"
#endif
    );
    fprintf(f, "  },\n");

    // 可读的 sysctl 指标（能读到的真实值）
    fprintf(f, "  \"readable_indicators\": [\n");
    int first = 1;
    emit_sc_num(f, "hw.optional.arm64", &first);
    emit_sc_num(f, "hw.optional.arm.FEAT_PAuth", &first);
    emit_sc_num(f, "hw.optional.arm.FEAT_PAuth2", &first);
    emit_sc_num(f, "hw.optional.arm.FEAT_BTI", &first);
    emit_sc_num(f, "hw.optional.arm.FEAT_MTE", &first);
    emit_sc_num(f, "hw.optional.arm.FEAT_LSE", &first);
    emit_sc_num(f, "kern.secure_kernel", &first);
    emit_sc_num(f, "kern.hv_support", &first);
    fprintf(f, "\n  ],\n");

    uint32_t cs = 0;
    int cs_rc = cs_status(&cs);
    fprintf(f, "  \"codesign_flags\": { \"csops_rc\": %d, \"hardened\": %s, \"platform_binary\": %s, \"restricted\": %s },\n",
            cs_rc,
            (cs_rc == 0 && (cs & VL_CS_HARD)) ? "true" : "false",
            (cs_rc == 0 && (cs & VL_CS_PLATFORM_BINARY)) ? "true" : "false",
            (cs_rc == 0 && (cs & VL_CS_RESTRICT)) ? "true" : "false");

    // 逐项可达性清单：**诚实标注**哪些拿得到、哪些拿不到、为什么
    fprintf(f, "  \"mitigations\": [\n");
    fprintf(f, "    { \"name\": \"PAC\", \"reachable\": %s, \"evidence\": \"hw.cpusubtype==2(arm64e) 为间接证据\", \"note\": \"无公开 sysctl 直接读 PAC 状态；arm64e 只表明二进制用 PAC 指令集\" },\n",
            (cpusub == 2) ? "true" : "false");
    fprintf(f, "    { \"name\": \"PPL\", \"reachable\": false, \"note\": \"无公开接口；需内核读原语或私有 KPI\" },\n");
    fprintf(f, "    { \"name\": \"SPTM\", \"reachable\": false, \"note\": \"无公开接口；SPTM 状态属内核内部\" },\n");
    fprintf(f, "    { \"name\": \"MIE\", \"reachable\": false, \"note\": \"无公开接口\" },\n");
    fprintf(f, "    { \"name\": \"zone_sequestration\", \"reachable\": false, \"note\": \"kern.zone_separation 非公开/不可读；已尝试并记录 errno\" },\n");
    fprintf(f, "    { \"name\": \"KASLR_slide\", \"reachable\": false, \"note\": \"无公开接口读内核 slide；需 kernel base 泄露\" }\n");
    fprintf(f, "  ],\n");

    fprintf(f, "  \"notes\": \"reachable=false 的项**不是探测失败，而是当前进程权限下无公开读取路径**；不要据此判断系统未启用该缓解。\"\n}\n");

    fclose(f);
    fprintf(stderr, "[vulnlab] mitigations → %s/vulnlab-mitigations.json (cpusubtype=%d)\n", g_data_dir, cpusub);
    return 0;
}

// 读一个 IORegistry 字符串属性到 out；成功返回 0。
static int ioreg_copy_str(io_registry_entry_t entry, CFStringRef key, char *out, size_t n) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!v) return -1;
    int ok = -3;
    if (CFGetTypeID(v) == CFStringGetTypeID()) {
        ok = CFStringGetCString((CFStringRef)v, out, (CFIndex)n, kCFStringEncodingUTF8) ? 0 : -2;
    }
    CFRelease(v);
    return ok;
}

// ③ IOKit 枚举：沙盒内可达的 IOService（含 user client 类）
static int write_iokit(void) {
    FILE *f = open_out("vulnlab-iokit.json");
    if (!f) { fprintf(stderr, "[vulnlab] iokit: 打不开输出文件 (%s)\n", strerror(errno)); return 3; }

    fprintf(f, "{\n  \"probe\": ");
    jstr(f, k_probe_ver);
    fprintf(f, ",\n  \"generatedAt\": ");
    write_ts(f);
    fprintf(f, ",\n  \"services\": [\n");

    io_iterator_t iter = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                    IOServiceMatching("IOService"),
                                                    &iter);
    int count = 0;
    int first = 1;
    if (kr == KERN_SUCCESS && iter != IO_OBJECT_NULL) {
        io_registry_entry_t svc;
        while ((svc = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
            io_name_t name;   // char[128]
            io_name_t cls;
            memset(name, 0, sizeof(name));
            memset(cls, 0, sizeof(cls));
            IORegistryEntryGetName(svc, name);
            IOObjectGetClass(svc, cls);

            // 只登记“user client”候选（类名含 UserClient）与普通服务名，供找攻击面
            if (!first) fputs(",\n", f);
            first = 0;
            fprintf(f, "    { \"name\": ");
            jstr(f, name);
            fprintf(f, ", \"class\": ");
            jstr(f, cls);
            fprintf(f, ", \"is_user_client\": %s }",
                    (strstr(cls, "UserClient") != NULL) ? "true" : "false");

            IOObjectRelease(svc);
            if (++count >= 1024) break;   // 上限，避免超大迭代
        }
        IOObjectRelease(iter);
    }

    fprintf(f, "\n  ],\n");
    fprintf(f, "  \"count\": %d,\n", count);
    fprintf(f, "  \"IOServiceGetMatchingServices_kr\": %d,\n", (int)kr);

    // 定向探测：平台专家设备（型号/序列号通常被沙盒拒）
    io_registry_entry_t pe = IOServiceGetMatchingService(kIOMainPortDefault,
                                                         IOServiceMatching("IOPlatformExpertDevice"));
    fprintf(f, "  \"platform_expert\": { \"found\": %s", (pe != IO_OBJECT_NULL) ? "true" : "false");
    if (pe != IO_OBJECT_NULL) {
        char serial[256];
        int s_ok = ioreg_copy_str(pe, CFSTR("IOPlatformSerialNumber"), serial, sizeof(serial));
        fprintf(f, ",\n    \"IOPlatformSerialNumber_reachable\": %s", (s_ok == 0) ? "true" : "false");
        if (s_ok == 0) { fprintf(f, ",\n    \"IOPlatformSerialNumber\": "); jstr(f, serial); }
        else fprintf(f, ",\n    \"IOPlatformSerialNumber_err\": %d", s_ok);
        IOObjectRelease(pe);
    }
    fprintf(f, " },\n");
    fprintf(f, "  \"notes\": \"枚举结果为沙盒内**可见**的 IOService；被 sandbox 过滤的服务不会出现，不代表不存在。\"\n}\n");

    fclose(f);
    fprintf(stderr, "[vulnlab] iokit → %s/vulnlab-iokit.json (services=%d, kr=%d)\n", g_data_dir, count, (int)kr);
    return 0;
}

// ④ sysctl 扫描：命名节点取值 + 顶层命名空间 OID 计数
static int write_sysctl(void) {
    FILE *f = open_out("vulnlab-sysctl.json");
    if (!f) { fprintf(stderr, "[vulnlab] sysctl: 打不开输出文件 (%s)\n", strerror(errno)); return 3; }

    static const char *names[] = {
        // kern
        "kern.osversion", "kern.osrelease", "kern.osrevision", "kern.version",
        "kern.hostname", "kern.boottime", "kern.uuid", "kern.secure_kernel",
        "kern.argmax", "kern.maxproc", "kern.maxfiles", "kern.maxvnodes",
        "kern.ostype", "kern.securelevel", "kern.tty.ptmx_max",
        // hw
        "hw.machine", "hw.model", "hw.ncpu", "hw.physicalcpu", "hw.logicalcpu",
        "hw.memsize", "hw.cputype", "hw.cpusubtype", "hw.pagesize",
        "hw.optional.arm64", "hw.optional.arm.FEAT_PAuth", "hw.optional.arm.FEAT_BTI",
        "hw.optional.arm.FEAT_LSE", "hw.optional.arm.FEAT_MTE",
        // security / mac
        "security.mac.sandbox.sentinel", "security.mac.sandbox.profile",
        "security.mac.sandbox.extensions",
        // vm
        "vm.pagesize", "vm.page_free_count", "vm.swapusage",
        // net
        "net.inet.ip.forwarding", "net.inet.tcp.blackhole", "net.inet.udp.blackhole",
        "net.local.stream.sendspace", "net.local.stream.recvspace",
        // machdep / other
        "machdep.cpu.brand_string",
        // debug
        "debug.emergency_logging",
    };
    const size_t n_names = sizeof(names) / sizeof(names[0]);

    fprintf(f, "{\n  \"probe\": ");
    jstr(f, k_probe_ver);
    fprintf(f, ",\n  \"generatedAt\": ");
    write_ts(f);
    fprintf(f, ",\n  \"named_nodes\": [\n");

    int first = 1;
    for (size_t i = 0; i < n_names; i++) {
        // 先试字符串，失败再试数字——两类都记，reachable 以任一成功为准
        char buf[512];
        size_t len = sizeof(buf);
        errno = 0;
        int rc = sysctlbyname(names[i], buf, &len, NULL, 0);
        int e = errno;
        if (!first) fputs(",\n", f);
        first = 0;
        fprintf(f, "    { \"name\": ");
        jstr(f, names[i]);
        if (rc == 0 && len > 0) {
            if (buf[len - 1] != '\0') buf[(len < sizeof(buf)) ? len : (sizeof(buf) - 1)] = '\0';
            // 判断是否像可打印字符串
            int printable = 1;
            for (size_t k = 0; k < len && buf[k]; k++)
                if ((unsigned char)buf[k] < 0x20 && buf[k] != '\n') { printable = 0; break; }
            if (printable) { fputs(", \"reachable\": true, \"value\": ", f); jstr(f, buf); fputs(" }", f); }
            else { fprintf(f, ", \"reachable\": true, \"raw_len\": %zu, \"note\": \"非字符串值\" }", len); }
        } else {
            fprintf(f, ", \"reachable\": false, \"errno\": %d, \"error\": ", e);
            jstr(f, strerror(e));
            fputs(" }", f);
        }
    }
    fprintf(f, "\n  ],\n");

    // 顶层命名空间 OID 计数（索引式遍历，只计数不解引用）
    static const struct { int ctl; const char *name; } NS[] = {
        { CTL_KERN, "kern" }, { CTL_HW, "hw" }, { CTL_VM, "vm" },
        { CTL_NET, "net" }, { CTL_VFS, "vfs" }, { CTL_MACHDEP, "machdep" },
        { CTL_DEBUG, "debug" },
    };
    const size_t n_ns = sizeof(NS) / sizeof(NS[0]);
    fprintf(f, "  \"namespaces\": [\n");
    for (size_t i = 0; i < n_ns; i++) {
        int reachable = 0, gaps = 0;
        for (int idx = 0; idx < 2048 && gaps < 64; idx++) {
            int mib[2] = { NS[i].ctl, idx };
            size_t len = 0;
            if (sysctl(mib, 2, NULL, &len, NULL, 0) == 0) { reachable++; gaps = 0; }
            else gaps++;
        }
        fprintf(f, "    { \"namespace\": ");
        jstr(f, NS[i].name);
        fprintf(f, ", \"ctl\": %d, \"reachable_oids\": %d }%s\n",
                NS[i].ctl, reachable, (i + 1 < n_ns) ? "," : "");
    }
    fprintf(f, "\n  ],\n");
    fprintf(f, "  \"notes\": \"named_nodes 为人工挑选的高价值节点；namespaces 为索引式遍历的**可达 OID 计数**（无公开 oid→name 反查，故只给计数）。\"\n}\n");

    fclose(f);
    fprintf(stderr, "[vulnlab] sysctl → %s/vulnlab-sysctl.json (%zu named nodes)\n", g_data_dir, n_names);
    return 0;
}

// 探测单个 syscall（用零参调用，只观察 rc/errno）。仅用于**安全子集**。
static void probe_syscall(FILE *f, const char *name, long num, int *first) {
    errno = 0;
    long rc = (long)syscall((int)num, (long)0, (long)0, (long)0, (long)0, (long)0, (long)0);
    int e = errno;
    if (!*first) fputs(",\n", f);
    *first = 0;
    fprintf(f, "    { \"name\": ");
    jstr(f, name);
    fprintf(f, ", \"number\": %ld, \"rc\": %ld, \"errno\": %d, \"error\": ", num, rc, e);
    jstr(f, strerror(e));
    fputs(" }", f);
}

// ⑤ syscall 可用性探测
// ⚠️ 只探测**安全子集**：这些 syscall 用零参调用只会返回 EFAULT/EINVAL/EPERM/ENOSYS，
//    不会改变进程状态。**刻意不做全表盲扫**——exit/fork/execve/reboot 等若被误调会
//    直接杀死宿主 App（见 BinaryModuleRunner 的崩溃循环守卫，宿主最怕这个）。
static int write_syscall(void) {
    FILE *f = open_out("vulnlab-syscall.json");
    if (!f) { fprintf(stderr, "[vulnlab] syscall: 打不开输出文件 (%s)\n", strerror(errno)); return 3; }

    fprintf(f, "{\n  \"probe\": ");
    jstr(f, k_probe_ver);
    fprintf(f, ",\n  \"generatedAt\": ");
    write_ts(f);
    fprintf(f, ",\n  \"safe_subset\": [\n");

    int first = 1;
#ifdef SYS_getpid
    probe_syscall(f, "getpid", SYS_getpid, &first);
#endif
#ifdef SYS_getppid
    probe_syscall(f, "getppid", SYS_getppid, &first);
#endif
#ifdef SYS_getuid
    probe_syscall(f, "getuid", SYS_getuid, &first);
#endif
#ifdef SYS_geteuid
    probe_syscall(f, "geteuid", SYS_geteuid, &first);
#endif
#ifdef SYS_getgid
    probe_syscall(f, "getgid", SYS_getgid, &first);
#endif
#ifdef SYS_getegid
    probe_syscall(f, "getegid", SYS_getegid, &first);
#endif
#ifdef SYS_getentropy
    probe_syscall(f, "getentropy", SYS_getentropy, &first);
#endif
#ifdef SYS_proc_info
    probe_syscall(f, "proc_info", SYS_proc_info, &first);
#endif
#ifdef SYS_csops
    probe_syscall(f, "csops", SYS_csops, &first);
#endif
#ifdef SYS_gettimeofday
    probe_syscall(f, "gettimeofday", SYS_gettimeofday, &first);
#endif
#ifdef SYS_getrusage
    probe_syscall(f, "getrusage", SYS_getrusage, &first);
#endif
#ifdef SYS_issetugid
    probe_syscall(f, "issetugid", SYS_issetugid, &first);
#endif
#ifdef SYS_sysctl
    probe_syscall(f, "sysctl", SYS_sysctl, &first);
#endif
#ifdef SYS_getdirentries
    probe_syscall(f, "getdirentries", SYS_getdirentries, &first);
#endif
#ifdef SYS_mach_port_self
    probe_syscall(f, "mach_port_self", SYS_mach_port_self, &first);
#endif
    fprintf(f, "\n  ],\n");

    // ENOSYS 边界：探测明显超出表的编号，确认内核对未知 syscall 的行为
    fprintf(f, "  \"enosys_boundary\": [\n");
    first = 1;
    long probes[] = { 600, 700, 800, 1000, 2000 };
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        char nm[32];
        snprintf(nm, sizeof(nm), "syscall_%ld", probes[i]);
        probe_syscall(f, nm, probes[i], &first);
    }
    fprintf(f, "\n  ],\n");
    fprintf(f, "  \"notes\": \"safe_subset 用零参调用：EFAULT/EINVAL/EPERM 表明该 syscall 存在但参数非法；ENOSYS 表明内核未实现。**未做全表盲扫**（exit/fork/execve/reboot 会杀宿主），如需完整表请在独立进程内做。\"\n}\n");

    fclose(f);
    fprintf(stderr, "[vulnlab] syscall → %s/vulnlab-syscall.json\n", g_data_dir);
    return 0;
}

// ⑥ 沙盒能力探测：路径读/写 + mach service 可达性
static int write_sandbox(void) {
    FILE *f = open_out("vulnlab-sandbox.json");
    if (!f) { fprintf(stderr, "[vulnlab] sandbox: 打不开输出文件 (%s)\n", strerror(errno)); return 3; }

    static const char *paths[] = {
        "/", "/etc/hosts", "/etc/passwd", "/var/mobile", "/private/var/mobile",
        "/private/var/mobile/Library/Preferences",
        "/private/var/mobile/Containers/Data/Application",
        "/System/Library/CoreServices/SystemVersion.plist",
        "/System/Library/Frameworks/UIKit.framework",
        "/Applications", "/usr/bin", "/usr/lib", "/dev", "/tmp",
        "/private/var/db/dyld", "/var/db/timezone",
        "/private/var/preferences",
    };
    const size_t n_paths = sizeof(paths) / sizeof(paths[0]);

    fprintf(f, "{\n  \"probe\": ");
    jstr(f, k_probe_ver);
    fprintf(f, ",\n  \"generatedAt\": ");
    write_ts(f);
    fprintf(f, ",\n  \"path_probe\": [\n");

    int first = 1;
    for (size_t i = 0; i < n_paths; i++) {
        errno = 0;
        int rfd = open(paths[i], O_RDONLY);
        int r_err = errno;
        if (rfd >= 0) close(rfd);

        errno = 0;
        int wfd = open(paths[i], O_WRONLY);
        int w_err = errno;
        if (wfd >= 0) close(wfd);

        struct stat st;
        int exists = (stat(paths[i], &st) == 0);

        if (!first) fputs(",\n", f);
        first = 0;
        fprintf(f, "    { \"path\": ");
        jstr(f, paths[i]);
        fprintf(f, ", \"exists\": %s, \"readable\": %s, \"writable\": %s",
                exists ? "true" : "false",
                (rfd >= 0) ? "true" : "false",
                (wfd >= 0) ? "true" : "false");
        if (rfd < 0) { fprintf(f, ", \"read_errno\": %d, \"read_error\": ", r_err); jstr(f, strerror(r_err)); }
        if (wfd < 0) { fprintf(f, ", \"write_errno\": %d, \"write_error\": ", w_err); jstr(f, strerror(w_err)); }
        fputs(" }", f);
    }
    fprintf(f, "\n  ],\n");

    // mach service 可达性（bootstrap_look_up）：经典沙盒能力探针
    static const char *svcs[] = {
        "com.apple.system.logger",
        "com.apple.system.notification_center",
        "com.apple.system.opendirectoryd.libinfo",
        "com.apple.SpringBoard.services",
        "com.apple.frontboard.systemappservices",
        "com.apple.backboardd",
        "com.apple.cfprefsd.daemon",
        "com.apple.securityd",
        "com.apple.distributed_notifications",
        "com.apple.mDNSResponder",
    };
    const size_t n_svcs = sizeof(svcs) / sizeof(svcs[0]);

    fprintf(f, "  \"mach_services\": [\n");
    first = 1;
    for (size_t i = 0; i < n_svcs; i++) {
        mach_port_t sp = MACH_PORT_NULL;
        kern_return_t kr = bootstrap_look_up(bootstrap_port, svcs[i], &sp);
        if (!first) fputs(",\n", f);
        first = 0;
        fprintf(f, "    { \"name\": ");
        jstr(f, svcs[i]);
        fprintf(f, ", \"reachable\": %s, \"kr\": %d }",
                (kr == KERN_SUCCESS) ? "true" : "false", (int)kr);
        if (kr == KERN_SUCCESS && sp != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), sp);
    }
    fprintf(f, "\n  ],\n");
    fprintf(f, "  \"notes\": \"路径可写探测用 O_WRONLY **不会创建/截断**（无 O_CREAT/O_TRUNC），失败即被沙盒拒；mach_services kr==0(KERN_SUCCESS) 表示可 lookup。\"\n}\n");

    fclose(f);
    fprintf(stderr, "[vulnlab] sandbox → %s/vulnlab-sandbox.json (%zu paths, %zu services)\n",
            g_data_dir, n_paths, n_svcs);
    return 0;
}

// ---------------------------------------------------------------------------
// 导出符号
// ---------------------------------------------------------------------------

// 入口：宿主在独立 pthread 调用；dataDir = 模块数据目录（可能为 NULL）。
// 立即返回——句柄在宿主侧已缓存，bridge 动作照样能解析到符号。
VULNLAB_EXPORT int VulnLabMain(char *dataDir) {
    if (dataDir) {
        free(g_data_dir);
        g_data_dir = strdup(dataDir);
    }
    fprintf(stderr, "[vulnlab] VulnLabMain(dataDir=%s) pid=%d uid=%d\n",
            g_data_dir ? g_data_dir : "(null)", (int)getpid(), (int)getuid());
    return 0;
}

// 最小连通性自检：能返回 0 说明 dylib 已加载、符号已 dlsym。
VULNLAB_EXPORT int VulnLabPing(void) {
    fprintf(stderr, "[vulnlab] VulnLabPing ok (pid=%d)\n", (int)getpid());
    return 0;
}

VULNLAB_EXPORT int VulnLabBaseline(void)    { return write_baseline(); }
VULNLAB_EXPORT int VulnLabMitigations(void) { return write_mitigations(); }
VULNLAB_EXPORT int VulnLabIOKit(void)       { return write_iokit(); }
VULNLAB_EXPORT int VulnLabSysctl(void)      { return write_sysctl(); }
VULNLAB_EXPORT int VulnLabSyscall(void)     { return write_syscall(); }
VULNLAB_EXPORT int VulnLabSandbox(void)     { return write_sandbox(); }

// 汇总：依次执行全部探测，再写 vulnlab-report.json（含各文件路径与 rc）。
VULNLAB_EXPORT int VulnLabReport(void) {
    int rc_base = write_baseline();
    int rc_mit  = write_mitigations();
    int rc_io   = write_iokit();
    int rc_sc   = write_sysctl();
    int rc_sy   = write_syscall();
    int rc_sb   = write_sandbox();

    FILE *f = open_out("vulnlab-report.json");
    if (!f) { fprintf(stderr, "[vulnlab] report: 打不开输出文件 (%s)\n", strerror(errno)); return 3; }

    fprintf(f, "{\n  \"probe\": ");
    jstr(f, k_probe_ver);
    fprintf(f, ",\n  \"generatedAt\": ");
    write_ts(f);
    fprintf(f, ",\n  \"dataDir\": ");
    jstr(f, g_data_dir ? g_data_dir : "?");
    fprintf(f, ",\n  \"results\": [\n");
    struct { const char *file; const char *action; int rc; } items[] = {
        { "vulnlab-baseline.json",    "baseline",    rc_base },
        { "vulnlab-mitigations.json", "mitigations", rc_mit  },
        { "vulnlab-iokit.json",       "iokit",       rc_io   },
        { "vulnlab-sysctl.json",      "sysctl",      rc_sc   },
        { "vulnlab-syscall.json",     "syscall",     rc_sy   },
        { "vulnlab-sandbox.json",     "sandbox",     rc_sb   },
    };
    for (size_t i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
        fprintf(f, "    { \"action\": ");
        jstr(f, items[i].action);
        fprintf(f, ", \"file\": ");
        jstr(f, items[i].file);
        fprintf(f, ", \"rc\": %d }%s\n", items[i].rc, (i + 1 < sizeof(items) / sizeof(items[0])) ? "," : "");
    }
    fprintf(f, "  ]\n}\n");
    fclose(f);

    fprintf(stderr, "[vulnlab] report → %s/vulnlab-report.json (rc=%d,%d,%d,%d,%d,%d)\n",
            g_data_dir, rc_base, rc_mit, rc_io, rc_sc, rc_sy, rc_sb);
    // 只要报告本身写成功就返回 0；单项失败已记入 report.json 的 rc
    return 0;
}

// 预留：宿主能力表交接钩子（可选）。宿主在 handoffHostCapabilities 里找这个符号，
// 找到就把 EscapeHostAPI 函数表指针传进来（前 8 字节 = { uint32 abiVersion; uint32 structSize; }）。
// 本模块不依赖宿主能力，只记录 ABI 版本。
static unsigned g_host_abi = 0;

VULNLAB_EXPORT int escape_module_init(const void *api) {
    if (api) {
        const unsigned *p = (const unsigned *)api;
        g_host_abi = p[0];
    }
    fprintf(stderr, "[vulnlab] escape_module_init: abi=%u（本模块未使用宿主能力）\n", g_host_abi);
    return 0;
}
