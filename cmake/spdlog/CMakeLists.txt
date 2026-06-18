cmake_minimum_required(VERSION 3.15)
project(vendor_spdlog LANGUAGES CXX)

if(NOT DEFINED VENDOR_INCLUDE_DIR OR VENDOR_INCLUDE_DIR STREQUAL "")
    get_filename_component(VENDOR_INCLUDE_DIR
        "${CMAKE_CURRENT_SOURCE_DIR}/../../cykit/_vendor/include" ABSOLUTE)
endif()

set(SPDLOG_VENDOR_DST "${VENDOR_INCLUDE_DIR}/spdlog")

if(EXISTS "${SPDLOG_VENDOR_DST}")
    file(GLOB _existing "${SPDLOG_VENDOR_DST}/*.h")
    if(_existing)
        message(STATUS "[spdlog] Headers already vendored at ${SPDLOG_VENDOR_DST} — skipping.")
        add_custom_target(vendor_spdlog_headers ALL
            COMMENT "[spdlog] Headers already present, nothing to do."
        )
        return()
    endif()
endif()

message(STATUS "[spdlog] Fetching headers ...")
include(FetchContent)

FetchContent_Declare(
    spdlog
    GIT_REPOSITORY https://github.com/gabime/spdlog.git
    GIT_TAG        v1.16.0
    GIT_SHALLOW    TRUE
)
set(SPDLOG_HEADER_ONLY    ON  CACHE BOOL "" FORCE)
set(SPDLOG_FMT_EXTERNAL   OFF CACHE BOOL "" FORCE)
set(SPDLOG_BUILD_EXAMPLE  OFF CACHE BOOL "" FORCE)
set(SPDLOG_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(SPDLOG_INSTALL        OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(spdlog)

add_custom_target(vendor_spdlog_headers ALL
    COMMAND ${CMAKE_COMMAND} -E make_directory "${SPDLOG_VENDOR_DST}"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "${spdlog_SOURCE_DIR}/include/spdlog"
            "${SPDLOG_VENDOR_DST}"
    COMMENT "[spdlog] Vendoring headers → ${SPDLOG_VENDOR_DST}"
)