#include "macos.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/ps/IOPowerSources.h>
#include <mach/mach_host.h>
#include <mach/mach_init.h>
#include <mach/vm_statistics.h>
#include <stdio.h>
#include <sys/sysctl.h>

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

int zfetch_is_dark_theme(void) {
    CFStringRef key = CFStringCreateWithCString(
        NULL,
        "AppleInterfaceStyle",
        kCFStringEncodingUTF8
    );
    if (key == NULL) {
        return 0;
    }

    CFPropertyListRef value = CFPreferencesCopyAppValue(
        key,
        kCFPreferencesAnyApplication
    );
    CFRelease(key);
    if (value == NULL) {
        return 0;
    }

    CFRelease(value);
    return 1;
}

int zfetch_get_memory(
    uint64_t *bytes_total,
    uint64_t *pages_app,
    uint64_t *pages_wired,
    uint64_t *pages_compressed
) {
    size_t bytes_total_size = sizeof(*bytes_total);
    if (sysctlbyname(
        "hw.memsize",
        bytes_total,
        &bytes_total_size,
        NULL,
        0
    ) != 0) {
        return -1;
    }

    vm_statistics64_data_t vm;
    mach_msg_type_number_t vm_count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(
        mach_host_self(),
        HOST_VM_INFO64,
        (host_info64_t)&vm,
        &vm_count
    ) != KERN_SUCCESS) {
        return 1;
    }

    const uint64_t internal_pages = (uint64_t)vm.internal_page_count;
    const uint64_t purgeable_pages = (uint64_t)vm.purgeable_count;
    *pages_app = internal_pages > purgeable_pages
        ? internal_pages - purgeable_pages
        : 0;
    *pages_wired = (uint64_t)vm.wire_count;
    *pages_compressed = (uint64_t)vm.compressor_page_count;
    return 0;
}
