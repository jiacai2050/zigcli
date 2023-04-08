
build:
	zig build -Doptimize=ReleaseFast

fmt:
	zig fmt --check .

test:
	zig build test

ci: fmt test
