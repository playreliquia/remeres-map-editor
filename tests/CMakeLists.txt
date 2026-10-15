find_package(Catch2 3 CONFIG REQUIRED)
include(Catch)

# Each wx-free seam's .cpp compiles straight into the tests, beside its tests,
# rather than through a core library shared with the editor.
add_executable(rme-tests test_save_files.cpp
                         ${CMAKE_SOURCE_DIR}/source/save_files.cpp)

target_include_directories(rme-tests PRIVATE ${CMAKE_SOURCE_DIR}/source)
target_link_libraries(rme-tests PRIVATE Catch2::Catch2WithMain)

# The static triplet's Catch2 links the static CRT, as the editor does.
if(MSVC AND BUILD_STATIC_LIBRARY)
  set_property(TARGET rme-tests PROPERTY MSVC_RUNTIME_LIBRARY
                                         "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# PRE_TEST lists the cases when ctest runs, so a test binary that cannot start
# fails the test run rather than the build.
catch_discover_tests(rme-tests DISCOVERY_MODE PRE_TEST)

# tools/windows-save-checks.sh runs under WSL. Its tests stub WSL interop and powershell.exe,
# so any Linux host runs them with bash alone; the macOS and Windows jobs skip them.
if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
  find_program(BASH_PROGRAM bash REQUIRED)
  add_test(NAME test_windows_save_checks
           COMMAND ${BASH_PROGRAM}
                   ${CMAKE_CURRENT_SOURCE_DIR}/tools/test_windows_save_checks.sh)
endif()
