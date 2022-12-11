
build:
	zig build -Drelease-fast

fmt:
	zig fmt --check .

test: fmt
	zig build test
	# Don't work on latest Zig
	# error: Unable to parse target 'i386-linux': UnknownArchitecture
	# zig build test -Dtarget=i386-linux
