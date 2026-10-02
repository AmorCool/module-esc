//
//  labkit.c — LabKit 私人研究模块（dylib 骨架 v0.1）
//
//  ============================================================================
//  第一版目标：**能编译、能被 dlopen、能被 bridge 调**，仅此而已。
//  · 纯 C，导出符号不经 C++ 名字修饰（dlsym 可直接按名字找）。
//  · 只调用公共 libc / POSIX API（uname / sysctlbyname / open / getuid …），
//    **不触碰任何私有 API**；不实现任何漏洞利用。
//  ============================================================================
//
//  宿主调用约定（结论来自实读 EscapeOS/Services/BinaryModuleRunner.swift）：
//
//  ① 入口符号（binary.entrySymbol，或自动发现 *Main 结尾的第一个导出）：
//       int LabKitMain(char *dataDir)
//     · 宿主在**独立 pthread**（8MB 栈）上调用，参数是模块数据目录
//       （宿主 strdup 出来的 C 字符串，见 startBinaryModule）。
//     · 宿主在调用入口**之前**就 dlsym 成功并缓存了 dlopen 句柄
//       （BinaryModuleRunner.swift:284-289）——所以入口即使立即返回，
//       后续 bridge 动作照样能解析到符号。
//     · 常驻服务应在此阻塞；本骨架不做服务，记录 dataDir 后即返回。
//
//  ② bridge 动作（module.json actions[].type == "bridge"）：
//     · 宿主按 args 数量分派 C 签名（BinaryModuleRunner.bridgeCall:192-208）：
//         0 参 → int fn(void)
//         1 参 → int fn(char *)
//         2 参 → int fn(char *, char *)
//     · **返回 int；rc == 0 视为成功**，非 0 时宿主抛
//       「「<label>」执行失败 rc=N」（ModuleService.run:776）。
//     · bridge **不回传字符串**——宿主只拿 rc，再用 module.json 的 success
//       模板回显「实参」（{0}/{1}）。所以要让用户看到的内容要么写文件、
//       要么写日志（stderr 会被宿主重定向到 data/go_stderr.log）。
//

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>

// 导出宏：默认隐藏（编译带 -fvisibility=hidden），只显式导出下面这几个符号。
// 用 C 链接（C++ 下 extern "C"）保证符号名不被修饰，dlsym 按原名可找。
#if defined(__cplusplus)
#define LABKIT_EXPORT extern "C" __attribute__((visibility("default")))
#else
#define LABKIT_EXPORT __attribute__((visibility("default")))
#endif

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------

// 模块数据目录（由 LabKitMain 记录）。进程常驻，故意不释放。
static char *g_data_dir = NULL;

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

// 读一个字符串型 sysctl；失败写 "?"。返回传入的 buf。
static const char *sysctl_str(const char *name, char *buf, size_t buflen) {
    size_t len = buflen;
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0 || len == 0) {
        snprintf(buf, buflen, "?");
        return buf;
    }
    if (buf[len - 1] != '\0') {
        buf[(len < buflen) ? len : (buflen - 1)] = '\0';
    }
    return buf;
}

// 读一个 64 位整数型 sysctl（如 hw.memsize）；失败返回 -1。
static long long sysctl_i64(const char *name) {
    long long v = 0;
    size_t len = sizeof(v);
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return -1;
    return v;
}

// 读一个 32 位整数型 sysctl（如 hw.ncpu / hw.cputype）；失败返回 -1。
// 内核里这些是 CTLTYPE_INT，缓冲区给 4 字节才不会 EINVAL。
static int sysctl_i32(const char *name) {
    int v = 0;
    size_t len = sizeof(v);
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return -1;
    return v;
}

// 探一条路径「能不能读」——这是本骨架最想验证的事：
// dylib 运行在宿主 App 的沙盒里，沙盒外路径应当被拒（EACCES/EPERM）。
// 用公共 POSIX open(2)，不是私有 API。*first 用于控制 JSON 逗号。
static void probe_path(FILE *f, const char *path, int *first) {
    errno = 0;
    int fd = open(path, O_RDONLY);
    int e = errno;
    if (fd >= 0) close(fd);
    if (!*first) fprintf(f, ",\n");
    *first = 0;
    if (fd >= 0) {
        fprintf(f, "    { \"path\": \"%s\", \"readable\": true, \"errno\": 0 }", path);
    } else {
        fprintf(f, "    { \"path\": \"%s\", \"readable\": false, \"errno\": %d, \"error\": \"%s\" }",
                path, e, strerror(e));
    }
}

// ---------------------------------------------------------------------------
// 导出符号
// ---------------------------------------------------------------------------

// 入口。宿主在独立线程调用；dataDir = 模块数据目录（可能为 NULL）。
// 骨架版：只记录 dataDir，立即返回（不做常驻服务）。
LABKIT_EXPORT int LabKitMain(char *dataDir) {
    if (dataDir) {
        free(g_data_dir);
        g_data_dir = strdup(dataDir);
    }
    fprintf(stderr, "[labkit] LabKitMain(dataDir=%s)\n",
            g_data_dir ? g_data_dir : "(null)");
    return 0;
}

// 最小连通性测试：能返回 0 就说明 dylib 已加载、符号已被 dlsym 解析。
LABKIT_EXPORT int LabKitPing(void) {
    fprintf(stderr, "[labkit] LabKitPing ok (pid=%d uid=%d)\n",
            (int)getpid(), (int)getuid());
    return 0;
}

// 采集设备 / 沙盒基本信息，写 <dataDir>/labkit-info.json。
// 返回：0 成功；2 = 入口还没跑（模块未启动）；3 = 文件打不开。
// 用途：验证「dylib 在宿主进程里能读到什么」——为后续研究确定起点。
LABKIT_EXPORT int LabKitInfo(void) {
    if (!g_data_dir) {
        fprintf(stderr, "[labkit] LabKitInfo: 数据目录未知（模块未启动？）\n");
        return 2;
    }

    char path[1024];
    snprintf(path, sizeof(path), "%s/labkit-info.json", g_data_dir);
    FILE *f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "[labkit] LabKitInfo: 打不开 %s (%s)\n", path, strerror(errno));
        return 3;
    }

    struct utsname u;
    memset(&u, 0, sizeof(u));
    int uname_ok = (uname(&u) == 0);

    char model[256], osver[256];
    sysctl_str("hw.model", model, sizeof(model));
    sysctl_str("kern.osversion", osver, sizeof(osver));

    fprintf(f, "{\n");
    fprintf(f, "  \"probe\": \"labkit.v0.1\",\n");
    fprintf(f, "  \"uname\": {\n");
    fprintf(f, "    \"sysname\": \"%s\",\n", uname_ok ? u.sysname : "?");
    fprintf(f, "    \"release\": \"%s\",\n", uname_ok ? u.release : "?");
    fprintf(f, "    \"machine\": \"%s\"\n",  uname_ok ? u.machine : "?");
    fprintf(f, "  },\n");
    fprintf(f, "  \"sysctl\": {\n");
    fprintf(f, "    \"hw.model\": \"%s\",\n", model);
    fprintf(f, "    \"kern.osversion\": \"%s\",\n", osver);
    fprintf(f, "    \"hw.ncpu\": %d,\n", sysctl_i32("hw.ncpu"));
    fprintf(f, "    \"hw.memsize\": %lld,\n", sysctl_i64("hw.memsize"));
    fprintf(f, "    \"hw.cputype\": %d,\n", sysctl_i32("hw.cputype"));
    fprintf(f, "    \"hw.cpusubtype\": %d\n", sysctl_i32("hw.cpusubtype"));
    fprintf(f, "  },\n");
    fprintf(f, "  \"process\": {\n");
    fprintf(f, "    \"pid\": %d,\n", (int)getpid());
    fprintf(f, "    \"ppid\": %d,\n", (int)getppid());
    fprintf(f, "    \"uid\": %d,\n", (int)getuid());
    fprintf(f, "    \"euid\": %d,\n", (int)geteuid());
    fprintf(f, "    \"gid\": %d,\n", (int)getgid());
    fprintf(f, "    \"home\": \"%s\"\n", getenv("HOME") ? getenv("HOME") : "?");
    fprintf(f, "  },\n");
    fprintf(f, "  \"path_probe\": [\n");
    int first = 1;
    probe_path(f, "/", &first);
    probe_path(f, "/etc/hosts", &first);
    probe_path(f, "/var/mobile", &first);
    probe_path(f, "/private/var/mobile/Library/Preferences", &first);
    probe_path(f, "/System/Library/CoreServices/SystemVersion.plist", &first);
    probe_path(f, "/Applications", &first);
    fprintf(f, "\n  ]\n");
    fprintf(f, "}\n");

    fclose(f);

    fprintf(stderr, "[labkit] LabKitInfo: 已写入 %s\n", path);
    return 0;
}

// 预留：宿主能力表交接钩子（**可选**，本骨架不依赖、也不使用）。
// 宿主在 BinaryModuleRunner.handoffHostCapabilities 里找这个符号，
// 找到就把 EscapeHostAPI 函数表指针传进来（见 HostCapabilityService.swift）。
// 导出它是为了给后续研究留一个扩展点；不导出也完全正常（宿主只记一行日志）。
// 这里只记录 ABI 版本，不解引用——避免骨架阶段因结构体布局不一致而出问题。
static unsigned g_host_abi = 0;

LABKIT_EXPORT int escape_module_init(const void *api) {
    // api 指向的 struct 前 8 字节是 { uint32 abiVersion; uint32 structSize; }
    if (api) {
        const unsigned *p = (const unsigned *)api;
        g_host_abi = p[0];
    }
    fprintf(stderr, "[labkit] escape_module_init: abi=%u（骨架未使用宿主能力）\n", g_host_abi);
    return 0;
}
