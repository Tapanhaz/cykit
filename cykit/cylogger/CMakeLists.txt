cmake_minimum_required(VERSION 3.15)
project(cylogger VERSION 0.0.12 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CMAKE_SKIP_BUILD_RPATH FALSE)
set(CMAKE_BUILD_WITH_INSTALL_RPATH FALSE)
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)

find_package(Python3 REQUIRED COMPONENTS Development.Module)

include(FetchContent)

FetchContent_Declare(
    spdlog
    GIT_REPOSITORY https://github.com/gabime/spdlog.git
    GIT_TAG v1.16.0
)

set(SPDLOG_HEADER_ONLY OFF CACHE BOOL "" FORCE)
set(SPDLOG_FMT_EXTERNAL OFF CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(spdlog) 

add_custom_target(cylogger_vendor_headers ALL
    COMMAND ${CMAKE_COMMAND} -E make_directory
            ${CMAKE_CURRENT_SOURCE_DIR}/include
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${spdlog_SOURCE_DIR}/include/spdlog
            ${CMAKE_CURRENT_SOURCE_DIR}/include/spdlog
)



if(MSVC)
    add_compile_options(/utf-8)
endif()

add_library(cylogger SHARED
    spdlog_logger.cpp
)

add_dependencies(cylogger cylogger_vendor_headers)

target_include_directories(cylogger
    PRIVATE
        ${Python3_INCLUDE_DIRS}
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
        $<INSTALL_INTERFACE:include/cykit/cylogger>
)

target_link_libraries(cylogger
    PRIVATE
        spdlog::spdlog
        ${Python3_LIBRARIES}
)

if(WIN32)
    set_target_properties(cylogger PROPERTIES
        WINDOWS_EXPORT_ALL_SYMBOLS ON
    )
elseif(APPLE)
    set_target_properties(cylogger PROPERTIES
        INSTALL_RPATH "@loader_path"
        BUILD_RPATH "@loader_path"
        INSTALL_NAME_DIR "@loader_path"
        MACOSX_RPATH ON 
    )
elseif(UNIX)
    set_target_properties(cylogger PROPERTIES
        INSTALL_RPATH "$ORIGIN"
        BUILD_RPATH "$ORIGIN"
    )
endif()

set_target_properties(cylogger PROPERTIES
    OUTPUT_NAME "cylogger"
    VERSION ${PROJECT_VERSION}
    SOVERSION 0
)

install(TARGETS cylogger
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)

install(FILES
    spdlog_logger.hpp
    DESTINATION include/cykit/cylogger
)
