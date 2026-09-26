#include "macos_battery.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/ps/IOPowerSources.h>
#include <stdio.h>

int zfetch_get_battery(char *buffer, size_t buffer_size) {
    if (buffer == NULL || buffer_size == 0) {
        return -1;
    }

    CFTypeRef power_sources_info = IOPSCopyPowerSourcesInfo();
    if (power_sources_info == NULL) {
        return snprintf(buffer, buffer_size, "No Battery");
    }

    CFArrayRef power_sources = IOPSCopyPowerSourcesList(power_sources_info);
    if (power_sources == NULL || CFArrayGetCount(power_sources) == 0) {
        if (power_sources != NULL) {
            CFRelease(power_sources);
        }
        CFRelease(power_sources_info);
        return snprintf(buffer, buffer_size, "No Battery");
    }

    CFTypeRef source = CFArrayGetValueAtIndex(power_sources, 0);
    CFDictionaryRef description =
        IOPSGetPowerSourceDescription(power_sources_info, source);
    if (description == NULL) {
        CFRelease(power_sources);
        CFRelease(power_sources_info);
        return snprintf(buffer, buffer_size, "No Battery");
    }

    int capacity = 0;
    CFTypeRef capacity_value = CFDictionaryGetValue(
        description,
        CFSTR("Current Capacity")
    );
    if (capacity_value != NULL) {
        CFNumberGetValue(
            (CFNumberRef)capacity_value,
            kCFNumberIntType,
            &capacity
        );
    }

    int is_charging = 0;
    CFTypeRef charging_value = CFDictionaryGetValue(
        description,
        CFSTR("Is Charging")
    );
    if (charging_value != NULL) {
        is_charging = CFBooleanGetValue((CFBooleanRef)charging_value);
    }

    const char *status = is_charging ? "Charging" : "Discharging";
    const int result = snprintf(
        buffer,
        buffer_size,
        "%d%% [%s]",
        capacity,
        status
    );
    CFRelease(power_sources);
    CFRelease(power_sources_info);
    return result;
}
