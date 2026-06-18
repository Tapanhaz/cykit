cmake_minimum_required(VERSION 3.18)
project(install_openssl)

set(OPENSSL_PATHS_FILE "${CMAKE_CURRENT_BINARY_DIR}/openssl_paths.txt")

if(DEFINED ENV{OPENSSL_ROOT_DIR} AND NOT OPENSSL_ROOT_DIR)
    set(OPENSSL_ROOT_DIR "$ENV{OPENSSL_ROOT_DIR}")
endif()

if(NOT OPENSSL_ROOT_DIR)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        foreach(_pm apt-get dnf yum)
            find_program(_PM_BIN ${_pm})
            if(_PM_BIN)
                if(_pm STREQUAL "apt-get")
                    set(_pm_args install -y libssl-dev)
                else()
                    set(_pm_args install -y openssl-devel)
                endif()
                execute_process(COMMAND ${_PM_BIN} ${_pm_args}
                    RESULT_VARIABLE _pm_rc OUTPUT_QUIET ERROR_QUIET)
                if(_pm_rc EQUAL 0)
                    message(STATUS "[OpenSSL] ${_pm} install succeeded.")
                endif()
                break()
            endif()
        endforeach()

    elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        foreach(_p
            "/opt/homebrew/opt/openssl@3"
            "/opt/homebrew/opt/openssl"
            "/usr/local/opt/openssl@3"
            "/usr/local/opt/openssl")
            if(EXISTS "${_p}/include/openssl/ssl.h")
                set(OPENSSL_ROOT_DIR "${_p}")
                message(STATUS "[OpenSSL] Homebrew at ${_p}")
                break()
            endif()
        endforeach()
        if(NOT OPENSSL_ROOT_DIR)
            find_program(_BREW brew)
            if(_BREW)
                execute_process(COMMAND "${_BREW}" install openssl@3
                    RESULT_VARIABLE _br OUTPUT_QUIET ERROR_QUIET)
                if(_br EQUAL 0)
                    execute_process(COMMAND "${_BREW}" --prefix openssl@3
                        OUTPUT_VARIABLE _bp OUTPUT_STRIP_TRAILING_WHITESPACE)
                    if(EXISTS "${_bp}/include/openssl/ssl.h")
                        set(OPENSSL_ROOT_DIR "${_bp}")
                    endif()
                endif()
            endif()
        endif()

    elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
        foreach(_p
            "$ENV{OPENSSL_ROOT_DIR}"
            "C:/Program Files/OpenSSL-Win64"
            "C:/Program Files/OpenSSL"
            "C:/OpenSSL-Win64"
            "C:/OpenSSL"
            "$ENV{ProgramFiles}/OpenSSL-Win64")
            if(EXISTS "${_p}/include/openssl/ssl.h")
                set(OPENSSL_ROOT_DIR "${_p}")
                message(STATUS "[OpenSSL] Found at ${_p}")
                break()
            endif()
        endforeach()

        if(NOT OPENSSL_ROOT_DIR)
            find_program(_WINGET winget)
            if(_WINGET)
                message(STATUS "[OpenSSL] Trying winget install ShiningLight.OpenSSL.Dev")
                execute_process(
                    COMMAND "${_WINGET}" install -e --id ShiningLight.OpenSSL.Dev
                            --accept-source-agreements --accept-package-agreements
                            --silent
                    RESULT_VARIABLE _wg OUTPUT_QUIET ERROR_QUIET)
                if(_wg EQUAL 0)
                    foreach(_p "C:/Program Files/OpenSSL-Win64" "C:/Program Files/OpenSSL")
                        if(EXISTS "${_p}/include/openssl/ssl.h")
                            set(OPENSSL_ROOT_DIR "${_p}")
                            break()
                        endif()
                    endforeach()
                else()
                    message(STATUS "[OpenSSL] winget failed (rc=${_wg}), trying choco.")
                    find_program(_CHOCO choco)
                    if(_CHOCO)
                        execute_process(
                            COMMAND "${_CHOCO}" install openssl -y --no-progress
                            RESULT_VARIABLE _ch OUTPUT_QUIET ERROR_QUIET)
                        foreach(_p "C:/Program Files/OpenSSL-Win64" "C:/Program Files/OpenSSL")
                            if(EXISTS "${_p}/include/openssl/ssl.h")
                                set(OPENSSL_ROOT_DIR "${_p}")
                                break()
                            endif()
                        endforeach()
                    endif()
                endif()
            endif()
        endif()
    endif()
endif()

find_package(OpenSSL QUIET)

if(OpenSSL_FOUND)
    message(STATUS "[OpenSSL] System: ${OPENSSL_VERSION}")
    message(STATUS "  inc: ${OPENSSL_INCLUDE_DIR}")
    message(STATUS "  ssl: ${OPENSSL_SSL_LIBRARY}")
    message(STATUS "  cry: ${OPENSSL_CRYPTO_LIBRARY}")
endif()

if(NOT OpenSSL_FOUND)
    message(STATUS "[OpenSSL] Not found — building from source via FetchContent.")
    include(FetchContent)
    FetchContent_Declare(openssl_cmake
        GIT_REPOSITORY https://github.com/janbar/openssl-cmake.git
        GIT_TAG        master
        GIT_SHALLOW    TRUE)
    set(BUILD_SHARED_LIBS    OFF CACHE BOOL "" FORCE)
    set(OPENSSL_BUILD_TESTS  OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(openssl_cmake)

    if(NOT (TARGET ssl AND TARGET crypto))
        message(FATAL_ERROR "[OpenSSL] FetchContent build did not produce ssl/crypto targets.")
    endif()
    set(OPENSSL_INCLUDE_DIR
        "${openssl_cmake_SOURCE_DIR}/include"
        "${openssl_cmake_BINARY_DIR}/include")
    set(OPENSSL_SSL_LIBRARY    "$<TARGET_FILE:ssl>")
    set(OPENSSL_CRYPTO_LIBRARY "$<TARGET_FILE:crypto>")
    set(_OSSL_FC TRUE)
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Windows" AND NOT _OSSL_FC AND OpenSSL_FOUND)
    get_filename_component(_ssl_dir "${OPENSSL_SSL_LIBRARY}" DIRECTORY)
    file(GLOB _dlls
        "${_ssl_dir}/../bin/libssl*.dll"
        "${_ssl_dir}/../bin/libcrypto*.dll")
    foreach(_dll ${_dlls})
        configure_file("${_dll}"
            "${CMAKE_CURRENT_BINARY_DIR}/Release/" COPYONLY)
    endforeach()
endif()

if(_OSSL_FC)
    file(GENERATE OUTPUT "${OPENSSL_PATHS_FILE}" CONTENT
"OPENSSL_INCLUDE_DIR=${OPENSSL_INCLUDE_DIR}
OPENSSL_SSL_LIBRARY=$<TARGET_FILE:ssl>
OPENSSL_CRYPTO_LIBRARY=$<TARGET_FILE:crypto>
OPENSSL_FROM_FETCHCONTENT=1
")
else()
    file(WRITE "${OPENSSL_PATHS_FILE}"
"OPENSSL_INCLUDE_DIR=${OPENSSL_INCLUDE_DIR}
OPENSSL_SSL_LIBRARY=${OPENSSL_SSL_LIBRARY}
OPENSSL_CRYPTO_LIBRARY=${OPENSSL_CRYPTO_LIBRARY}
OPENSSL_FROM_FETCHCONTENT=0
")
endif()
message(STATUS "[OpenSSL] Paths written → ${OPENSSL_PATHS_FILE}")