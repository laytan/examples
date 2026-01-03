package main

import    "core:fmt"
import    "core:time"
import os "core:os/os2"
import tz "core:time/timezone"

main :: proc() {
	local_region, local_region_ok := tz.region_load("local", context.allocator)
	if !local_region_ok {
		fmt.eprintln("Could not find determine local timezone.")
		os.exit(1)
	}
	defer tz.region_destroy(local_region, context.allocator)

	utc, utc_ok := time.time_to_datetime(time.now())
	assert(utc_ok)

	local, local_ok := tz.datetime_to_tz(utc, local_region)
	assert(local_ok)

	fmt.printfln("%04d-%02d-%02d @ %02d:%02d:%02d", local.year, local.month, local.day, local.hour, local.minute, local.second)
	fmt.printfln("%s || %s", local_region.name, tz.shortname_unsafe(local))
	fmt.printfln("%sDST", "" if tz.dst_unsafe(local) else "Not ")
}
