# GEMINI.md

This file provides a comprehensive overview of the `zigcli` project, its structure, and how to build, run, and contribute to it.

## Project Overview

`zigcli` is a toolkit for building command-line programs in Zig. It can be used as a collection of Zig packages or as standalone command-line programs.

**Key Technologies:**

*   **Language:** Zig
*   **Build System:** Zig Build System
*   **Dependencies:**
    *   `curl` (for the `zigfetch` binary)

**Architecture:**

The project is structured into two main parts:

*   **`src/mod`:** Contains reusable Zig modules (`pretty-table`, `simargs`).
*   **`src/bin`:** Contains a collection of standalone command-line programs.

## Building and Running

The primary way to build the project is using the Zig build system. The `Makefile` provides convenient targets for common tasks.

**Key Commands:**

*   **Build all binaries:**
    ```bash
    zig build
    ```
    Or, for a release build:
    ```bash
    make build
    ```
*   **Run a specific binary:**
    ```bash
    zig build run-<binary_name>
    ```
    For example, to run the `tree` binary:
    ```bash
    zig build run-tree
    ```
*   **Run all tests:**
    ```bash
    zig build test
    ```
    Or:
    ```bash
    make test
    ```
*   **Format the code:**
    ```bash
    zig fmt .
    ```
    Or to check formatting:
    ```bash
    make fmt
    ```
*   **Clean the build artifacts:**
    ```bash
    make clean
    ```
*   **Serve the documentation:**
    ```bash
    make serve
    ```

## Development Conventions

*   **Code Style:** The project uses `zig fmt` to enforce a consistent code style. Before committing, ensure your code is formatted by running `zig fmt .`.
*   **Testing:** All modules and binaries have corresponding tests. All tests can be run with `zig build test`.
*   **Dependencies:** Dependencies are managed by the Zig build system in `build.zig`.
*   **Continuous Integration:** The project uses GitHub Actions for CI. The CI pipeline is defined in `.github/workflows/CI.yml` and it runs `make ci` which is an alias for `make fmt` and `make test`.
*   **Documentation:** The project's documentation is built with Hugo and is located in the `docs` directory.
