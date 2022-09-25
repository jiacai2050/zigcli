
build:
	zig build -Drelease-fast

fmt:
	zig fmt --check .

test: fmt
	zig build test
