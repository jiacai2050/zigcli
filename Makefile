
build:
	zig build -Doptimize=ReleaseFast

fmt:
	zig fmt --check .

test:
	zig build test-all -Dtarget=x86-linux
	zig build test-all -Dtarget=arm-linux
	zig build test-all -Dtarget=x86_64-linux
	zig build test-all -Dtarget=aarch64-linux
	zig build test-all -Dtarget=x86_64-macos
	zig build test-all -Dtarget=aarch64-macos

ci: fmt test
