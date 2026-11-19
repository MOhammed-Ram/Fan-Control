#ifndef CSMCBRIDGE_H
#define CSMCBRIDGE_H

#import <Foundation/Foundation.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// SMC Low-level API
int smc_open(void);
void smc_close(void);
int smc_get_fan_count(void);
float smc_get_fan_rpm(int fan);
float smc_get_fan_min_rpm(int fan);
float smc_get_fan_max_rpm(int fan);
float smc_get_fan_target_rpm(int fan);
int smc_get_fan_mode(int fan);
bool smc_is_root(void);
int smc_set_fan_target(int fan, float rpm);
int smc_set_fan_auto(int fan);
int smc_set_all_auto(void);
bool smc_is_lid_closed(void);
bool smc_clamshell_causes_sleep(void);

// IOHID Sensors API
int sensors_init(void);
void sensors_close(void);
int sensors_get_count(void);
bool sensors_get_info(int index, char *nameBuf, int maxLen, float *tempOut);
float sensors_get_cpu_avg(void);
float sensors_get_cpu_max(void);
float smc_get_cpu_core_peak(void);
float smc_get_cpu_core_avg(void);
void smc_get_cpu_core_temps(float *avgOut, float *peakOut);
float smc_get_gpu_temp(void);
float sensors_get_battery_temp(void);
float sensors_get_storage_temp(void);

#ifdef __cplusplus
}
#endif

#endif /* CSMCBRIDGE_H */
