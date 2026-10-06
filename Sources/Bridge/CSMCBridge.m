#import "CSMCBridge.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <unistd.h>
#import <string.h>

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
static IOHIDEventSystemClientRef gHIDClient = NULL;
static CFArrayRef gHIDServices = NULL;

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

static kern_return_t smcCall(const uint8_t *input, uint8_t *output) {
    if (!gSMCConn) return KERN_FAILURE;
    size_t inSize = STRUCT_SIZE;
    size_t outSize = STRUCT_SIZE;
    return IOConnectCallStructMethod(gSMCConn, KERNEL_INDEX_SMC, input, inSize, output, &outSize);
}

int smc_open(void) {
    if (gSMCConn) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &gSMCConn);
    IOObjectRelease(service);
    return (kr == KERN_SUCCESS) ? 0 : -1;
}

void smc_close(void) {
    if (gSMCConn) {
        IOServiceClose(gSMCConn);
        gSMCConn = 0;
    }
}

static kern_return_t smcReadKey(const char *keyStr, uint8_t *outBytes, uint32_t *outSize, char *outType) {
    if (!gSMCConn && smc_open() != 0) return KERN_FAILURE;

    uint8_t input[STRUCT_SIZE] = {0};
    uint8_t output[STRUCT_SIZE] = {0};

    setU32(input, OFF_KEY, fourCharCode(keyStr));
    input[OFF_DATA8] = SMC_CMD_READ_KEYINFO;

    kern_return_t kr = smcCall(input, output);
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

    kr = smcCall(input, output);
    if (kr != KERN_SUCCESS) return kr;
    if (output[OFF_RESULT] != 0) return KERN_FAILURE;

    if (outBytes) {
        memcpy(outBytes, output + OFF_BYTES, size > 32 ? 32 : size);
    }
    return KERN_SUCCESS;
}

static kern_return_t smcWriteKey(const char *keyStr, const uint8_t *inBytes, uint32_t size, uint32_t type) {
    if (!gSMCConn && smc_open() != 0) return KERN_FAILURE;

    uint8_t input[STRUCT_SIZE] = {0};
    uint8_t output[STRUCT_SIZE] = {0};

    setU32(input, OFF_KEY, fourCharCode(keyStr));
    setU32(input, OFF_DATASIZE, size);
    setU32(input, OFF_DATATYPE, type);
    input[OFF_DATA8] = SMC_CMD_WRITE_BYTES;
    memcpy(input + OFF_BYTES, inBytes, size > 32 ? 32 : size);

    kern_return_t kr = smcCall(input, output);
    if (kr != KERN_SUCCESS) return kr;
    return (output[OFF_RESULT] == 0) ? KERN_SUCCESS : KERN_FAILURE;
}

int smc_get_fan_count(void) {
    uint8_t bytes[32];
    uint32_t size = 0;
    if (smcReadKey("FNum", bytes, &size, NULL) == KERN_SUCCESS && size >= 1) {
        return (int)bytes[0];
    }
    return 0;
}

float smc_get_fan_rpm(int fan) {
    char key[5];
    snprintf(key, sizeof(key), "F%dAc", fan);
    uint8_t bytes[32];
    uint32_t size = 0;
    char type[5] = {0};
    if (smcReadKey(key, bytes, &size, type) == KERN_SUCCESS) {
        if (strcmp(type, "flt ") == 0 && size >= 4) {
            return *(float *)bytes;
        } else if (strcmp(type, "fpe2") == 0 && size >= 2) {
            return (float)((bytes[0] << 6) | (bytes[1] >> 2));
        }
    }
    return 0.0f;
}

float smc_get_fan_min_rpm(int fan) {
    char key[5];
    snprintf(key, sizeof(key), "F%dMn", fan);
    uint8_t bytes[32];
    uint32_t size = 0;
    char type[5] = {0};
    if (smcReadKey(key, bytes, &size, type) == KERN_SUCCESS) {
        if (strcmp(type, "flt ") == 0 && size >= 4) {
            return *(float *)bytes;
        } else if (strcmp(type, "fpe2") == 0 && size >= 2) {
            return (float)((bytes[0] << 6) | (bytes[1] >> 2));
        }
    }
    return 1200.0f;
}

float smc_get_fan_max_rpm(int fan) {
    char key[5];
    snprintf(key, sizeof(key), "F%dMx", fan);
    uint8_t bytes[32];
    uint32_t size = 0;
    char type[5] = {0};
    if (smcReadKey(key, bytes, &size, type) == KERN_SUCCESS) {
        if (strcmp(type, "flt ") == 0 && size >= 4) {
            return *(float *)bytes;
        } else if (strcmp(type, "fpe2") == 0 && size >= 2) {
            return (float)((bytes[0] << 6) | (bytes[1] >> 2));
        }
    }
    return 6500.0f;
}

float smc_get_fan_target_rpm(int fan) {
    char key[5];
    snprintf(key, sizeof(key), "F%dTg", fan);
    uint8_t bytes[32];
    uint32_t size = 0;
    char type[5] = {0};
    if (smcReadKey(key, bytes, &size, type) == KERN_SUCCESS) {
        if (strcmp(type, "flt ") == 0 && size >= 4) {
            return *(float *)bytes;
        } else if (strcmp(type, "fpe2") == 0 && size >= 2) {
            return (float)((bytes[0] << 6) | (bytes[1] >> 2));
        }
    }
    return 0.0f;
}

int smc_get_fan_mode(int fan) {
    char key[5];
    snprintf(key, sizeof(key), "F%dmd", fan);
    uint8_t bytes[32];
    uint32_t size = 0;
    if (smcReadKey(key, bytes, &size, NULL) == KERN_SUCCESS && size >= 1) {
        return (int)bytes[0];
    }
    return 0;
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
    smcReadKey(keyTarget, dummy, &size, type);

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
    if (gHIDClient) return 0;

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

    return (gHIDServices != NULL) ? 0 : -1;
}

void sensors_close(void) {
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
    if (!gHIDServices && sensors_init() != 0) return 50.0f;
    if (!gHIDServices) return 50.0f;

    CFIndex count = CFArrayGetCount(gHIDServices);
    double sum = 0.0;
    int validCount = 0;

    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gHIDServices, i);
        CFTypeRef prop = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (prop && CFGetTypeID(prop) == CFStringGetTypeID()) {
            char name[64] = {0};
            CFStringGetCString((CFStringRef)prop, name, sizeof(name), kCFStringEncodingUTF8);
            CFRelease(prop);

            // Match SoC CPU / PMU die sensors (tdie)
            if (strstr(name, "tdie") != NULL) {
                CFTypeRef event = IOHIDServiceClientCopyEvent(service, 15, 0, 0);
                if (event) {
                    double val = IOHIDEventGetFloatValue(event, (uint32_t)(15 << 16));
                    CFRelease(event);
                    if (val > 10.0 && val < 115.0) {
                        sum += val;
                        validCount++;
                    }
                }
            }
        }
    }

    return (validCount > 0) ? (float)(sum / validCount) : 48.0f;
}

float sensors_get_cpu_max(void) {
    if (!gHIDServices && sensors_init() != 0) return 50.0f;
    if (!gHIDServices) return 50.0f;

    CFIndex count = CFArrayGetCount(gHIDServices);
    double maxVal = 0.0;

    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gHIDServices, i);
        CFTypeRef prop = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (prop && CFGetTypeID(prop) == CFStringGetTypeID()) {
            char name[64] = {0};
            CFStringGetCString((CFStringRef)prop, name, sizeof(name), kCFStringEncodingUTF8);
            CFRelease(prop);

            if (strstr(name, "tdie") != NULL) {
                CFTypeRef event = IOHIDServiceClientCopyEvent(service, 15, 0, 0);
                if (event) {
                    double val = IOHIDEventGetFloatValue(event, (uint32_t)(15 << 16));
                    CFRelease(event);
                    if (val > 10.0 && val < 115.0 && val > maxVal) {
                        maxVal = val;
                    }
                }
            }
        }
    }

    return (maxVal > 0.0) ? (float)maxVal : 50.0f;
}

static const char *kCPUCoreKeys[] = {
    "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R",
    "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p",
    "Tp0u", "Tp0y", "Tp1E", "Tp1I", "Tp1Q", "Tp1U", "Tp1g"
};

float smc_get_cpu_core_peak(void) {
    float maxVal = 0.0f;
    for (size_t i = 0; i < sizeof(kCPUCoreKeys)/sizeof(kCPUCoreKeys[0]); i++) {
        uint8_t bytes[32];
        uint32_t size = 0;
        char type[5] = {0};
        if (smcReadKey(kCPUCoreKeys[i], bytes, &size, type) == KERN_SUCCESS) {
            if (strcmp(type, "flt ") == 0 && size >= 4) {
                float v = *(float *)bytes;
                if (v > 10.0f && v < 115.0f && v > maxVal) {
                    maxVal = v;
                }
            }
        }
    }
    return (maxVal > 0.0f) ? maxVal : sensors_get_cpu_max();
}

float smc_get_cpu_core_avg(void) {
    double sum = 0.0;
    int count = 0;
    for (size_t i = 0; i < sizeof(kCPUCoreKeys)/sizeof(kCPUCoreKeys[0]); i++) {
        uint8_t bytes[32];
        uint32_t size = 0;
        char type[5] = {0};
        if (smcReadKey(kCPUCoreKeys[i], bytes, &size, type) == KERN_SUCCESS) {
            if (strcmp(type, "flt ") == 0 && size >= 4) {
                float v = *(float *)bytes;
                if (v > 10.0f && v < 115.0f) {
                    sum += v;
                    count++;
                }
            }
        }
    }
    return (count > 0) ? (float)(sum / count) : sensors_get_cpu_avg();
}

float sensors_get_battery_temp(void) {
    if (!gHIDServices && sensors_init() != 0) return 30.0f;
    if (!gHIDServices) return 30.0f;

    CFIndex count = CFArrayGetCount(gHIDServices);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gHIDServices, i);
        CFTypeRef prop = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (prop && CFGetTypeID(prop) == CFStringGetTypeID()) {
            char name[64] = {0};
            CFStringGetCString((CFStringRef)prop, name, sizeof(name), kCFStringEncodingUTF8);
            CFRelease(prop);

            if (strstr(name, "battery") != NULL || strstr(name, "gas gauge") != NULL) {
                CFTypeRef event = IOHIDServiceClientCopyEvent(service, 15, 0, 0);
                if (event) {
                    double val = IOHIDEventGetFloatValue(event, (uint32_t)(15 << 16));
                    CFRelease(event);
                    if (val > 0.0 && val < 80.0) return (float)val;
                }
            }
        }
    }

    return 32.0f;
}

float sensors_get_storage_temp(void) {
    if (!gHIDServices && sensors_init() != 0) return 35.0f;
    if (!gHIDServices) return 35.0f;

    CFIndex count = CFArrayGetCount(gHIDServices);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gHIDServices, i);
        CFTypeRef prop = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (prop && CFGetTypeID(prop) == CFStringGetTypeID()) {
            char name[64] = {0};
            CFStringGetCString((CFStringRef)prop, name, sizeof(name), kCFStringEncodingUTF8);
            CFRelease(prop);

            if (strstr(name, "NAND") != NULL || strstr(name, "SSD") != NULL) {
                CFTypeRef event = IOHIDServiceClientCopyEvent(service, 15, 0, 0);
                if (event) {
                    double val = IOHIDEventGetFloatValue(event, (uint32_t)(15 << 16));
                    CFRelease(event);
                    if (val > 0.0 && val < 90.0) return (float)val;
                }
            }
        }
    }

    return 38.0f;
}
