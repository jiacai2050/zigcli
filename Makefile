
build:
	zig build -Doptimize=ReleaseFast -Dbuild_date=$(shell date +"%Y-%m-%dT%H:%M:%S%z") \
	-Dgit_commit=$(shell git rev-parse --short HEAD)

fmt:
	zig fmt --check .

test:
	zig build test

ci: fmt test
