# Testing

The unit tests use [Catch2 v3](https://github.com/catchorg/Catch2), installed by vcpkg as a plain entry in `vcpkg.json`. The CMake option `RME_BUILD_TESTS` adds the `tests/` tree to the build. It defaults to `OFF`, so a default build and the `*-release` presets produce only the editor.

## Layout

- `tests/` mirrors `source/`: the tests for a file under `source/<dir>/` live under `tests/<dir>/`.
- Each test case is named `test_<subject>_<scenario>_<expected>`.
- `catch_discover_tests` registers every test case with CTest, so `ctest` lists and runs each one by name.

## Seams

A seam is code that a test can reach without wxWidgets. That code lives in its own `.cpp` under `source/`, and both the editor target and the test target compile that file directly. There is no core library: splitting one out would widen the fork's divergence from upstream (opentibiabr).

A test source includes `main.h`, the editor's precompiled header, only when it needs wx. A wx-free seam's test includes the seam's header and Catch2 alone.

## Running the tests

With the debug presets, which turn the tests on:

```sh
cmake --preset <os>-debug
cmake --build --preset <os>-debug
ctest --preset <os>-debug
```

`<os>` is `linux`, `windows` or `macos`.

With the release build that mise drives:

```sh
RME_BUILD_TESTS=ON mise run build
mise run test
```

`mise run test` fails when the build has no tests, so a plain `mise run build` before it is an error rather than a silent pass.

## CI

The Linux, Windows and macOS build jobs configure with `RME_BUILD_TESTS=ON` and run `mise run test` between the build and the package. A failed test fails the job, and no package is uploaded.

## Shell tools

A bash script under `tools/` has its tests under `tests/tools/`, as a bash script that stubs every Windows program on `PATH`. `tests/CMakeLists.txt` registers each one with `add_test` on Linux hosts only, so the Linux job runs it under `mise run test`. Run one directly without a build:

```sh
bash tests/tools/test_windows_save_checks.sh
```

## Adding a test

Every behaviour change adds a test under `tests/`. A change to code that has no seam yet extracts the wx-free part into its own `.cpp` first, as `source/save_files.cpp` does for the file moves in `Editor::saveMap`, tested by `tests/test_save_files.cpp`.
