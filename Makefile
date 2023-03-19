
build:
	zig build -Doptimize=ReleaseFast

fmt:
	zig fmt --check .

test:
	zig build test-loc
	zig build test-tree
	# Don't work on latest Zig
	# error: Unable to parse target 'i386-linux': UnknownArchitecture
	# zig build test -Dtarget=i386-linux

ci: fmt test
