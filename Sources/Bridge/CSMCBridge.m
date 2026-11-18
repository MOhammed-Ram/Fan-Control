#import "CSMCBridge.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <string.h>
#import <pthread.h>

#define STRUCT_SIZE 80
#define OFF_KEY 0
#define OFF_DATASIZE 28
#define OFF_DATATYPE 32
#define OFF_RESULT 40
#define OFF_DATA8 42
#define OFF_BYTES 48

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

// Forward declarations for IOHIDEventSystemClient
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern CFTypeRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(CFTypeRef event, uint32_t field);

static io_connect_t gSMCConn = 0;
static pthread_mutex_t gSMCLock = PTHREAD_MUTEX_INITIALIZER;
static IOHIDEventSystemClientRef gHIDClient = NULL;
static CFArrayRef gHIDServices = NULL;

// Fast Cached HID Service References
static IOHIDServiceClientRef sCpuServices[64];
static int sCpuServiceCount = 0;
static IOHIDServiceClientRef sGpuServices[32];
static int sGpuServiceCount = 0;
static IOHIDServiceClientRef sBatteryService = NULL;
static IOHIDServiceClientRef sStorageService = NULL;
static bool sSensorsCategorized = false;

// Fallback Holding State
static float s_last_battery_temp = 32.0f;
static float s_last_storage_temp = 38.0f;
static float s_last_cpu_core_peak = 0.0f;
static float s_last_cpu_core_avg = 0.0f;
static float s_last_gpu_temp = 0.0f;
static uint64_t s_last_core_reading_time = 0;
static uint64_t s_last_gpu_reading_time = 0;

// Fan RPM Holding State to prevent single-sample dropout to 0 RPM
#define MAX_SMC_FANS 4
static float s_last_valid_fan_rpm[MAX_SMC_FANS] = {0};
static int s_fan_zero_streak[MAX_SMC_FANS] = {0};

typedef struct {
    uint32_t keyInt;
    char keyStr[5];
    uint32_t dataSize;
    uint32_t dataType;
} SMCKeyMeta;

static SMCKeyMeta sValidCoreKeys[32];
static int sValidCoreCount = 0;
static bool sCoreKeysDiscovered = false;

static SMCKeyMeta sValidGpuKeys[32];
static int sValidGpuCount = 0;
static bool sGpuKeysDiscovered = false;

static uint32_t fourCharCode(const char *s) {
    uint32_t r = 0;
    for (int i = 0; i < 4; i++) {
        r = (r << 8) | (uint8_t)s[i];
    }
    return r;
}

static void codeToString(uint32_t v, char *out) {
    out[0] = (char)((v >> 24) & 0xff);
    out[1] = (char)((v >> 16) & 0xff);
    out[2] = (char)((v >> 8) & 0xff);
    out[3] = (char)(v & 0xff);
    out[4] = '\0';
}

static void setU32(uint8_t *buf, int off, uint32_t val) {
    buf[off]     = (uint8_t)(val & 0xff);
    buf[off + 1] = (uint8_t)((val >> 8) & 0xff);
    buf[off + 2] = (uint8_t)((val >> 16) & 0xff);
    buf[off + 3] = (uint8_t)((val >> 24) & 0xff);
}

static uint32_t getU32(const uint8_t *buf, int off) {
    return (uint32_t)buf[off] |
           ((uint32_t)buf[off + 1] << 8) |
           ((uint32_t)buf[off + 2] << 16) |
           ((uint32_t)buf[off + 3] << 24);
}

static kern_return_t smcCall_unlocked(const uint8_t *input, uint8_t *output) {
    if (!gSMCConn) return KERN_FAILURE;
    size_t inSize = STRUCT_SIZE;
    size_t outSize = STRUCT_SIZE;
    kern_return_t kr = KERN_FAILURE;
    for (int retry = 0; retry < 3; retry++) {
        kr = IOConnectCallStructMethod(gSMCConn, KERNEL_INDEX_SMC, input, inSize, output, &outSize);
        if (kr == KERN_SUCCESS) break;
        usleep(1000); // 1ms backoff on contention
    }
    return kr;
}

int smc_open(void) {
    pthread_mutex_lock(&gSMCLock);
    if (gSMCConn) {
        pthread_mutex_unlock(&gSMCLock);
        return 0;
    }
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) {
        pthread_mutex_unlock(&gSMCLock);
        return -1;
    }
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &gSMCConn);
    IOObjectRelease(service);
    pthread_mutex_unlock(&gSMCLock);
    return (kr == KERN_SUCCESS) ? 0 : -1;
}

void smc_close(void) {
    pthread_mutex_lock(&gSMCLock);
    if (gSMCConn) {
        IOServiceClose(gSMCConn);
        gSMCConn = 0;
    }
    sCoreKeysDiscovered = false;
    sValidCoreCount = 0;
    sGpuKeysDiscovered = false;
    sValidGpuCount = 0;
    pthread_mutex_unlock(&gSMCLock);
}

static kern_return_t smcReadKey_unlocked(const char *keyStr, uint8_t *outBytes, uint32_t *outSize, char *outType) {
    if (!gSMCConn) return KERN_FAILURE;

    uint8_t input[STRUCT_SIZE] = {0};
    uint8_t output[STRUCT_SIZE] = {0};

    setU32(input, OFF_KEY, fourCharCode(keyStr));
    input[OFF_DATA8] = SMC_CMD_READ_KEYINFO;

    kern_return_t kr = smcCall_unlocked(input, output);
    if (kr != KERN_SUCCESS) return kr;

    uint32_t size = getU32(output, OFF_DATASIZE);
    uint32_t type = getU32(output, OFF_DATATYPE);

    if (outSize) *outSize = size;
    if (outType) codeToString(type, outType);
    if (size == 0) return KERN_FAILURE;

    memset(input, 0, sizeof(input));
    setU32(input, OFF_KEY, fourCharCode(keyStr));
    setU32(input, OFF_DATASIZE, size);
    setU32(input, OFF_DATATYPE, type);
    input[OFF_DATA8] = SMC_CMD_READ_BYTES;

    kr = smcCall_unlocked(input, output);
    if (kr != KERN_SUCCESS) return kr;
    if (output[OFF_RESULT] != 0) return KERN_FAILURE;

    if (outBytes) {
        memcpy(outBytes, output + OFF_BYTES, size > 32 ? 32 : size);
    }
    return KERN_SUCCESS;
}

static kern_return_t smcWriteKey(const char *keyStr, const uint8_t *inBytes, uint32_t size, uint32_t type) {
    if (!gSMCConn && smc_open() != 0) return KERN_FAILURE;

    pthread_mutex_lock(&gSMCLock);
    uint8_t input[STRUCT_SIZE] = {0};
    uint8_t output[STRUCT_SIZE] = {0};

    setU32(input, OFF_KEY, fourCharCode(keyStr));
    setU32(input, OFF_DATASIZE, size);
    setU32(input, OFF_DATATYPE, type);
    input[OFF_DATA8] = SMC_CMD_WRITE_BYTES;
    memcpy(input + OFF_BYTES, inBytes, size > 32 ? 32 : size);

    kern_return_t kr = smcCall_unlocked(input, output);
    pthread_mutex_unlock(&gSMCLock);
    if (kr != KERN_SUCCESS) return kr;
    return (output[OFF_RESULT] == 0) ? KERN_SUCCESS : KERN_FAILURE;
}

int smc_get_fan_count(void) {
    if (!gSMCConn && smc_open() != 0) return 0;
    pthread_mutex_lock(&gSMCLock);
    uint8_t bytes[32];
    uint32_t size = 0;
    int count = 0;
    if (smcReadKey_unlocked("FNum", bytes, &size, NULL) == KERN_SUCCESS && size >= 1) {
        count = (int)bytes[0];
    }
    pthread_mutex_unlock(&gSMCLock);
    return count;
}

float smc_get_fan_rpm(int fan) {
    if (fan < 0 || fan >= MAX_SMC_FANS) return 0.0f;
    if (!gSMCConn && smc_open() != 0) return s_last_valid_fan_rpm[fan];

    char key[5];
    snprintf(key, sizeof(key), "F%dAc", fan);
    uint8_t bytes[32];
    uint32_t size = 0;
    char type[5] = {0};

    float rpm = 0.0f;
    bool success = false;

    pthread_mutex_lock(&gSMCLock);
    if (smcReadKey_unlocked(key, bytes, &size, type) == KERN_SUCCESS) {
        if (strcmp(type, "flt ") == 0 && size >= 4) {
            rpm = *(float *)bytes;
            success = true;
        } else if (strcmp(type, "fpe2") == 0 && size >= 2) {
            rpm = (float)((bytes[0] << 6) | (bytes[1] >> 2));
            success = true;
        }
    }
    pthread_mutex_unlock(&gSMCLock);

    // Guard against single-cycle tachometer dropouts (SMC busy / lock collision)
    if (success && rpm > 0.0f) {
        s_last_valid_fan_rpm[fan] = rpm;
        s_fan_zero_streak[fan] = 0;
        return rpm;
    } else {
        s_fan_zero_streak[fan]++;
        // If tachometer reported 0 but previously was spinning, hold previous RPM for up to 3 polls (~1.5s)
        if (s_last_valid_fan_rpm[fan] > 100.0f && s_fan_zero_streak[fan] < 3) {
            return s_last_valid_fan_rpm[fan];
        }
        return 0.0f;
    }
}

float smc_get_fan_min_rpm(int fan) {
    if (!gSMCConn && smc_open() != 0) return 1200.0f;
    char key[5];
    snprintf(key, sizeof(key), "F%dMn", fan);
    uint8_t bytes[32];
    uint32_t size = 0;
    char type[5] = {0};
    float rpm = 1200.0f;

    pthread_mutex_lock(&gSMCLock);
    if (smcReadKey_unlocked(key, bytes, &size, type) == KERN_SUCCESS) {
        if (strcmp(type, "flt ") == 0 && size >= 4) {
            rpm = *(float *)bytes;
        } else if (strcmp(type, "fpe2") == 0 && size >= 2) {
            rpm = (float)((bytes[0] << 6) | (bytes[1] >> 2));
        }
    }
    pthread_mutex_unlock(&gSMCLock);
    return rpm > 0.0f ? rpm : 1200.0f;
}

float smc_get_fan_max_rpm(int fan) {
    if (!gSMCConn && smc_open() != 0) return 6500.0f;
    char key[5];
    snprintf(key, sizeof(key), "F%dMx", fan);
    uint8_t bytes[32];
    uint32_t size = 0;
    char type[5] = {0};
    float rpm = 6500.0f;

    pthread_mutex_lock(&gSMCLock);
    if (smcReadKey_unlocked(key, bytes, &size, type) == KERN_SUCCESS) {
        if (strcmp(type, "flt ") == 0 && size >= 4) {
            rpm = *(float *)bytes;
        } else if (strcmp(type, "fpe2") == 0 && size >= 2) {
            rpm = (float)((bytes[0] << 6) | (bytes[1] >> 2));
        }
    }
    pthread_mutex_unlock(&gSMCLock);
    return rpm > 0.0f ? rpm : 6500.0f;
}

float smc_get_fan_target_rpm(int fan) {
    if (!gSMCConn && smc_open() != 0) return 0.0f;
    char key[5];
    snprintf(key, sizeof(key), "F%dTg", fan);
    uint8_t bytes[32];
    uint32_t size = 0;
    char type[5] = {0};
    float rpm = 0.0f;

    pthread_mutex_lock(&gSMCLock);
    if (smcReadKey_unlocked(key, bytes, &size, type) == KERN_SUCCESS) {
        if (strcmp(type, "flt ") == 0 && size >= 4) {
            rpm = *(float *)bytes;
        } else if (strcmp(type, "fpe2") == 0 && size >= 2) {
            rpm = (float)((bytes[0] << 6) | (bytes[1] >> 2));
        }
    }
    pthread_mutex_unlock(&gSMCLock);
    return rpm;
}

int smc_get_fan_mode(int fan) {
    if (!gSMCConn && smc_open() != 0) return 0;
    char key[5];
    snprintf(key, sizeof(key), "F%dmd", fan);
    uint8_t bytes[32];
    uint32_t size = 0;
    int mode = 0;

    pthread_mutex_lock(&gSMCLock);
    if (smcReadKey_unlocked(key, bytes, &size, NULL) == KERN_SUCCESS && size >= 1) {
        mode = (int)bytes[0];
    }
    pthread_mutex_unlock(&gSMCLock);
    return mode;
}

bool smc_is_root(void) {
    return (geteuid() == 0);
}

int smc_set_fan_target(int fan, float rpm) {
    if (!smc_is_root()) return -2;

    // 1. Set mode to 1 (manual mode)
    char keyMode[5];
    snprintf(keyMode, sizeof(keyMode), "F%dmd", fan);
    uint8_t modeVal = 1;
    smcWriteKey(keyMode, &modeVal, 1, fourCharCode("ui8 "));

    // 2. Write Target RPM
    char keyTarget[5];
    snprintf(keyTarget, sizeof(keyTarget), "F%dTg", fan);

    uint8_t dummy[32];
    uint32_t size = 4;
    char type[5] = "flt ";

    pthread_mutex_lock(&gSMCLock);
    smcReadKey_unlocked(keyTarget, dummy, &size, type);
    pthread_mutex_unlock(&gSMCLock);

    if (strcmp(type, "flt ") == 0) {
        float fRpm = rpm;
        return smcWriteKey(keyTarget, (uint8_t *)&fRpm, 4, fourCharCode("flt ")) == KERN_SUCCESS ? 0 : -1;
    } else {
        uint16_t fpe2Rpm = (uint16_t)(((int)rpm) << 2);
        uint8_t fpe2Buf[2] = { (uint8_t)(fpe2Rpm >> 8), (uint8_t)(fpe2Rpm & 0xff) };
        return smcWriteKey(keyTarget, fpe2Buf, 2, fourCharCode("fpe2")) == KERN_SUCCESS ? 0 : -1;
    }
}

int smc_set_fan_auto(int fan) {
    if (!smc_is_root()) return -2;

    char keyMode[5];
    snprintf(keyMode, sizeof(keyMode), "F%dmd", fan);
    uint8_t modeVal = 0;
    smcWriteKey(keyMode, &modeVal, 1, fourCharCode("ui8 "));
    if (smc_get_fan_mode(fan) != 0) {
        usleep(5000);
        smcWriteKey(keyMode, &modeVal, 1, fourCharCode("ui8 "));
    }
    return 0;
}

int smc_set_all_auto(void) {
    if (!smc_is_root()) return -2;

    int count = smc_get_fan_count();
    for (int i = 0; i < count; i++) {
        smc_set_fan_auto(i);
    }
    return 0;
}

// MARK: - IOHID Sensors Implementation

int sensors_init(void) {
    if (gHIDClient && sSensorsCategorized) return 0;

    if (!gHIDClient) {
        gHIDClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!gHIDClient) return -1;

        int32_t page = 0xFF00; // Apple Vendor Page
        int32_t usage = 0x05;  // Temperature Usage

        CFNumberRef pageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &page);
        CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage);

        const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
        const void *values[] = { pageNum, usageNum };
        CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

        IOHIDEventSystemClientSetMatching(gHIDClient, matching);
        gHIDServices = IOHIDEventSystemClientCopyServices(gHIDClient);

        CFRelease(matching);
        CFRelease(pageNum);
        CFRelease(usageNum);
    }

    if (!gHIDServices) return -1;

    // Categorize services once at initialization for ultra-fast (0.03ms) zero-allocation polling
    CFIndex count = CFArrayGetCount(gHIDServices);
    sCpuServiceCount = 0;
    sGpuServiceCount = 0;
    sBatteryService = NULL;
    sStorageService = NULL;

    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gHIDServices, i);
        CFTypeRef prop = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (prop && CFGetTypeID(prop) == CFStringGetTypeID()) {
            char name[64] = {0};
            CFStringGetCString((CFStringRef)prop, name, sizeof(name), kCFStringEncodingUTF8);
            CFRelease(prop);

            if ((strstr(name, "GPU") != NULL || strstr(name, "gpu") != NULL) && sGpuServiceCount < 32) {
                sGpuServices[sGpuServiceCount++] = service;
            } else if (strstr(name, "tdie") != NULL && sCpuServiceCount < 64) {
                sCpuServices[sCpuServiceCount++] = service;
            } else if (!sBatteryService && (strstr(name, "battery") != NULL || strstr(name, "gas gauge") != NULL)) {
                sBatteryService = service;
            } else if (!sStorageService && (strstr(name, "NAND") != NULL || strstr(name, "SSD") != NULL)) {
                sStorageService = service;
            }
        }
    }
    sSensorsCategorized = true;

    return 0;
}

void sensors_close(void) {
    sCpuServiceCount = 0;
    sGpuServiceCount = 0;
    sBatteryService = NULL;
    sStorageService = NULL;
    sSensorsCategorized = false;

    if (gHIDServices) {
        CFRelease(gHIDServices);
        gHIDServices = NULL;
    }
    if (gHIDClient) {
        CFRelease(gHIDClient);
        gHIDClient = NULL;
    }
}

int sensors_get_count(void) {
    if (!gHIDServices && sensors_init() != 0) return 0;
    if (!gHIDServices) return 0;
    return (int)CFArrayGetCount(gHIDServices);
}

bool sensors_get_info(int index, char *nameBuf, int maxLen, float *tempOut) {
    if (!gHIDServices && sensors_init() != 0) return false;
    if (!gHIDServices) return false;

    CFIndex count = CFArrayGetCount(gHIDServices);
    if (index < 0 || index >= count) return false;

    IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gHIDServices, index);
    if (!service) return false;

    if (nameBuf && maxLen > 0) {
        nameBuf[0] = '\0';
        CFTypeRef prop = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (prop && CFGetTypeID(prop) == CFStringGetTypeID()) {
            CFStringGetCString((CFStringRef)prop, nameBuf, maxLen, kCFStringEncodingUTF8);
            CFRelease(prop);
        }
    }

    CFTypeRef event = IOHIDServiceClientCopyEvent(service, 15, 0, 0); // Event 15 = Temperature
    if (event) {
        double val = IOHIDEventGetFloatValue(event, (uint32_t)(15 << 16));
        CFRelease(event);
        if (tempOut) *tempOut = (float)val;
        return true;
    }

    return false;
}

float sensors_get_cpu_avg(void) {
    if (!sSensorsCategorized && sensors_init() != 0) return 50.0f;
    if (sCpuServiceCount == 0) return 50.0f;

    double sum = 0.0;
    int validCount = 0;

    for (int i = 0; i < sCpuServiceCount; i++) {
        CFTypeRef event = IOHIDServiceClientCopyEvent(sCpuServices[i], 15, 0, 0);
        if (event) {
            double val = IOHIDEventGetFloatValue(event, (uint32_t)(15 << 16));
            CFRelease(event);
            if (val > 10.0 && val < 115.0) {
                sum += val;
                validCount++;
            }
        }
    }

    return (validCount > 0) ? (float)(sum / validCount) : 48.0f;
}

float sensors_get_cpu_max(void) {
    if (!sSensorsCategorized && sensors_init() != 0) return 50.0f;
    if (sCpuServiceCount == 0) return 50.0f;

    double maxVal = 0.0;

    for (int i = 0; i < sCpuServiceCount; i++) {
        CFTypeRef event = IOHIDServiceClientCopyEvent(sCpuServices[i], 15, 0, 0);
        if (event) {
            double val = IOHIDEventGetFloatValue(event, (uint32_t)(15 << 16));
            CFRelease(event);
            if (val > 10.0 && val < 115.0 && val > maxVal) {
                maxVal = val;
            }
        }
    }

    return (maxVal > 0.0) ? (float)maxVal : 50.0f;
}

static float sensors_get_gpu_avg_hid(void) {
    if (!sSensorsCategorized && sensors_init() != 0) return 0.0f;
    if (sGpuServiceCount == 0) return 0.0f;

    double sum = 0.0;
    int validCount = 0;

    for (int i = 0; i < sGpuServiceCount; i++) {
        CFTypeRef event = IOHIDServiceClientCopyEvent(sGpuServices[i], 15, 0, 0);
        if (event) {
            double val = IOHIDEventGetFloatValue(event, (uint32_t)(15 << 16));
            CFRelease(event);
            if (val > 10.0 && val < 115.0) {
                sum += val;
                validCount++;
            }
        }
    }

    return (validCount > 0) ? (float)(sum / validCount) : 0.0f;
}

// Candidate SMC Core Keys for Apple Silicon M-series SoCs
static const char *kCandidateCoreKeys[] = {
    "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R",
    "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p",
    "Tp0u", "Tp0y", "Tp1E", "Tp1I", "Tp1Q", "Tp1U", "Tp1g"
};

// Candidate SMC GPU Die Keys for Apple Silicon M-series SoCs
static const char *kCandidateGpuKeys[] = {
    "Tg04", "Tg05", "Tg08", "Tg0C", "Tg0D", "Tg0G", "Tg0K", "Tg0L",
    "Tg0P", "Tg0T", "Tg0U", "Tg0X", "Tg0b", "Tg0d", "Tg0f", "Tg0j",
    "Tg0n", "Tg0r", "Tg0v", "Tg0y", "Tg1c", "Tg1g", "Tg1k"
};

static void smc_discover_core_keys_if_needed(void) {
    if (sCoreKeysDiscovered) return;
    if (!gSMCConn && smc_open() != 0) return;

    int totalCandidates = sizeof(kCandidateCoreKeys) / sizeof(kCandidateCoreKeys[0]);
    sValidCoreCount = 0;

    for (int i = 0; i < totalCandidates; i++) {
        uint8_t input[STRUCT_SIZE] = {0};
        uint8_t output[STRUCT_SIZE] = {0};
        setU32(input, OFF_KEY, fourCharCode(kCandidateCoreKeys[i]));
        input[OFF_DATA8] = SMC_CMD_READ_KEYINFO;
        if (smcCall_unlocked(input, output) != KERN_SUCCESS) continue;

        uint32_t size = getU32(output, OFF_DATASIZE);
        uint32_t type = getU32(output, OFF_DATATYPE);
        if (size == 4 && type == fourCharCode("flt ")) {
            sValidCoreKeys[sValidCoreCount].keyInt = fourCharCode(kCandidateCoreKeys[i]);
            strncpy(sValidCoreKeys[sValidCoreCount].keyStr, kCandidateCoreKeys[i], 4);
            sValidCoreKeys[sValidCoreCount].keyStr[4] = '\0';
            sValidCoreKeys[sValidCoreCount].dataSize = size;
            sValidCoreKeys[sValidCoreCount].dataType = type;
            sValidCoreCount++;
            if (sValidCoreCount >= 32) break;
        }
    }
    sCoreKeysDiscovered = (sValidCoreCount > 0);
}

static void smc_discover_gpu_keys_if_needed(void) {
    if (sGpuKeysDiscovered) return;
    if (!gSMCConn && smc_open() != 0) return;

    int totalCandidates = sizeof(kCandidateGpuKeys) / sizeof(kCandidateGpuKeys[0]);
    sValidGpuCount = 0;

    for (int i = 0; i < totalCandidates; i++) {
        uint8_t input[STRUCT_SIZE] = {0};
        uint8_t output[STRUCT_SIZE] = {0};
        setU32(input, OFF_KEY, fourCharCode(kCandidateGpuKeys[i]));
        input[OFF_DATA8] = SMC_CMD_READ_KEYINFO;
        if (smcCall_unlocked(input, output) != KERN_SUCCESS) continue;

        uint32_t size = getU32(output, OFF_DATASIZE);
        uint32_t type = getU32(output, OFF_DATATYPE);
        if (size == 4 && type == fourCharCode("flt ")) {
            sValidGpuKeys[sValidGpuCount].keyInt = fourCharCode(kCandidateGpuKeys[i]);
            strncpy(sValidGpuKeys[sValidGpuCount].keyStr, kCandidateGpuKeys[i], 4);
            sValidGpuKeys[sValidGpuCount].keyStr[4] = '\0';
            sValidGpuKeys[sValidGpuCount].dataSize = size;
            sValidGpuKeys[sValidGpuCount].dataType = type;
            sValidGpuCount++;
            if (sValidGpuCount >= 32) break;
        }
    }
    sGpuKeysDiscovered = (sValidGpuCount > 0);
}

static double mach_seconds_since(uint64_t start) {
    if (start == 0) return 999999.0;
    uint64_t end = mach_absolute_time();
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)(end - start) * tb.numer / tb.denom / 1e9;
}

float smc_get_cpu_core_peak(void) {
    if (!gSMCConn && smc_open() != 0) {
        return (s_last_cpu_core_peak > 0.0f) ? s_last_cpu_core_peak : sensors_get_cpu_max();
    }

    pthread_mutex_lock(&gSMCLock);
    smc_discover_core_keys_if_needed();

    float maxVal = 0.0f;
    float secondMaxVal = 0.0f;
    double sum = 0.0;
    int validReadings = 0;

    if (sValidCoreCount > 0) {
        for (int i = 0; i < sValidCoreCount; i++) {
            uint8_t input[STRUCT_SIZE] = {0};
            uint8_t output[STRUCT_SIZE] = {0};
            setU32(input, OFF_KEY, sValidCoreKeys[i].keyInt);
            setU32(input, OFF_DATASIZE, sValidCoreKeys[i].dataSize);
            setU32(input, OFF_DATATYPE, sValidCoreKeys[i].dataType);
            input[OFF_DATA8] = SMC_CMD_READ_BYTES;

            if (smcCall_unlocked(input, output) == KERN_SUCCESS && output[OFF_RESULT] == 0) {
                float v = *(float *)(output + OFF_BYTES);
                if (v > 10.0f && v < 115.0f) {
                    if (v >= maxVal) {
                        secondMaxVal = maxVal;
                        maxVal = v;
                    } else if (v > secondMaxVal) {
                        secondMaxVal = v;
                    }
                    sum += v;
                    validReadings++;
                }
            }
        }
    }
    pthread_mutex_unlock(&gSMCLock);

    if (validReadings > 0 && maxVal > 0.0f) {
        float peakResult = maxVal;
        if (validReadings >= 4 && secondMaxVal > 0.0f) {
            float avgVal = (float)(sum / validReadings);
            // Average top 2 core diodes and cap isolated single-junction micro-spikes to avg + 15°C
            float clusterPeak = (maxVal + secondMaxVal) * 0.5f;
            float maxPlausiblePeak = avgVal + 15.0f;
            peakResult = (clusterPeak < maxPlausiblePeak) ? clusterPeak : maxPlausiblePeak;
        }
        s_last_cpu_core_peak = peakResult;
        s_last_core_reading_time = mach_absolute_time();
        return peakResult;
    }

    // Critical Stability Guard:
    // If a transient SMC collision occurs, do NOT plummet ~20°C down to HID ambient!
    // Hold the previous valid core peak reading for up to 3 seconds.
    if (s_last_cpu_core_peak > 0.0f && mach_seconds_since(s_last_core_reading_time) < 3.0) {
        return s_last_cpu_core_peak;
    }

    return sensors_get_cpu_max();
}

float smc_get_cpu_core_avg(void) {
    if (!gSMCConn && smc_open() != 0) {
        return (s_last_cpu_core_avg > 0.0f) ? s_last_cpu_core_avg : sensors_get_cpu_avg();
    }

    pthread_mutex_lock(&gSMCLock);
    smc_discover_core_keys_if_needed();

    double sum = 0.0;
    int count = 0;

    if (sValidCoreCount > 0) {
        for (int i = 0; i < sValidCoreCount; i++) {
            uint8_t input[STRUCT_SIZE] = {0};
            uint8_t output[STRUCT_SIZE] = {0};
            setU32(input, OFF_KEY, sValidCoreKeys[i].keyInt);
            setU32(input, OFF_DATASIZE, sValidCoreKeys[i].dataSize);
            setU32(input, OFF_DATATYPE, sValidCoreKeys[i].dataType);
            input[OFF_DATA8] = SMC_CMD_READ_BYTES;

            if (smcCall_unlocked(input, output) == KERN_SUCCESS && output[OFF_RESULT] == 0) {
                float v = *(float *)(output + OFF_BYTES);
                if (v > 10.0f && v < 115.0f) {
                    sum += v;
                    count++;
                }
            }
        }
    }
    pthread_mutex_unlock(&gSMCLock);

    if (count > 0) {
        float avg = (float)(sum / count);
        s_last_cpu_core_avg = avg;
        return avg;
    }

    // Hold last valid reading if transient collision occurred within 3 seconds
    if (s_last_cpu_core_avg > 0.0f && mach_seconds_since(s_last_core_reading_time) < 3.0) {
        return s_last_cpu_core_avg;
    }

    return sensors_get_cpu_avg();
}

float smc_get_gpu_temp(void) {
    if (!gSMCConn && smc_open() != 0) {
        if (s_last_gpu_temp > 0.0f) return s_last_gpu_temp;
        float hidGpu = sensors_get_gpu_avg_hid();
        return (hidGpu > 10.0f) ? hidGpu : sensors_get_cpu_avg();
    }

    pthread_mutex_lock(&gSMCLock);
    smc_discover_gpu_keys_if_needed();

    double sum = 0.0;
    int count = 0;

    if (sValidGpuCount > 0) {
        for (int i = 0; i < sValidGpuCount; i++) {
            uint8_t input[STRUCT_SIZE] = {0};
            uint8_t output[STRUCT_SIZE] = {0};
            setU32(input, OFF_KEY, sValidGpuKeys[i].keyInt);
            setU32(input, OFF_DATASIZE, sValidGpuKeys[i].dataSize);
            setU32(input, OFF_DATATYPE, sValidGpuKeys[i].dataType);
            input[OFF_DATA8] = SMC_CMD_READ_BYTES;

            if (smcCall_unlocked(input, output) == KERN_SUCCESS && output[OFF_RESULT] == 0) {
                float v = *(float *)(output + OFF_BYTES);
                if (v > 10.0f && v < 115.0f) {
                    sum += v;
                    count++;
                }
            }
        }
    }
    pthread_mutex_unlock(&gSMCLock);

    if (count > 0) {
        float avg = (float)(sum / count);
        s_last_gpu_temp = avg;
        s_last_gpu_reading_time = mach_absolute_time();
        return avg;
    }

    if (s_last_gpu_temp > 0.0f && mach_seconds_since(s_last_gpu_reading_time) < 3.0) {
        return s_last_gpu_temp;
    }

    float hidGpu = sensors_get_gpu_avg_hid();
    if (hidGpu > 10.0f) {
        s_last_gpu_temp = hidGpu;
        return hidGpu;
    }

    return (s_last_cpu_core_avg > 0.0f) ? s_last_cpu_core_avg : sensors_get_cpu_avg();
}

float sensors_get_battery_temp(void) {
    if (!sSensorsCategorized && sensors_init() != 0) return s_last_battery_temp;
    if (sBatteryService) {
        CFTypeRef event = IOHIDServiceClientCopyEvent(sBatteryService, 15, 0, 0);
        if (event) {
            double val = IOHIDEventGetFloatValue(event, (uint32_t)(15 << 16));
            CFRelease(event);
            if (val > 0.0 && val < 80.0) {
                s_last_battery_temp = (float)val;
                return (float)val;
            }
        }
    }
    return s_last_battery_temp;
}

float sensors_get_storage_temp(void) {
    if (!sSensorsCategorized && sensors_init() != 0) return s_last_storage_temp;
    if (sStorageService) {
        CFTypeRef event = IOHIDServiceClientCopyEvent(sStorageService, 15, 0, 0);
        if (event) {
            double val = IOHIDEventGetFloatValue(event, (uint32_t)(15 << 16));
            CFRelease(event);
            if (val > 0.0 && val < 90.0) {
                s_last_storage_temp = (float)val;
                return (float)val;
            }
        }
    }
    return s_last_storage_temp;
}

static bool read_root_domain_bool(CFStringRef key) {
    io_service_t rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!rootDomain) return false;

    bool result = false;
    CFTypeRef prop = IORegistryEntryCreateCFProperty(rootDomain, key, kCFAllocatorDefault, 0);
    if (prop) {
        if (CFGetTypeID(prop) == CFBooleanGetTypeID()) {
            result = CFBooleanGetValue((CFBooleanRef)prop);
        }
        CFRelease(prop);
    }
    IOObjectRelease(rootDomain);
    return result;
}

bool smc_is_lid_closed(void) {
    return read_root_domain_bool(CFSTR("AppleClamshellState"));
}

bool smc_clamshell_causes_sleep(void) {
    return read_root_domain_bool(CFSTR("AppleClamshellCausesSleep"));
}

