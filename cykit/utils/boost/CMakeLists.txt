cmake_minimum_required(VERSION 3.15)
project(vendor_boost VERSION 1.0 LANGUAGES CXX)

cmake_policy(SET CMP0169 OLD)

include(FetchContent)

set(BOOST_VERSION "boost-1.87.0")


function(fetch_boost_headers module git_url)
    FetchContent_Declare(
        ${module}
        GIT_REPOSITORY ${git_url}
        GIT_TAG ${BOOST_VERSION}
    )
    
    FetchContent_GetProperties(${module})
    if(NOT ${module}_POPULATED)
        FetchContent_Populate(${module})
    endif()
    
    add_custom_target(${module}_headers ALL
        COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_CURRENT_SOURCE_DIR}/include/boost
        COMMAND ${CMAKE_COMMAND} -E copy_directory
                ${${module}_SOURCE_DIR}/include/boost
                ${CMAKE_CURRENT_SOURCE_DIR}/include/boost
        COMMENT "Vendoring ${module} headers"
    )
endfunction()

fetch_boost_headers(core https://github.com/boostorg/core.git)
fetch_boost_headers(config https://github.com/boostorg/config.git)
fetch_boost_headers(assert https://github.com/boostorg/assert.git)
fetch_boost_headers(static_assert https://github.com/boostorg/static_assert.git)
fetch_boost_headers(mp11 https://github.com/boostorg/mp11.git)
fetch_boost_headers(move https://github.com/boostorg/move.git)

fetch_boost_headers(asio https://github.com/boostorg/asio.git)
fetch_boost_headers(beast https://github.com/boostorg/beast.git)
fetch_boost_headers(interprocess https://github.com/boostorg/interprocess.git)

fetch_boost_headers(system https://github.com/boostorg/system.git)
fetch_boost_headers(filesystem https://github.com/boostorg/filesystem.git)

add_custom_target(boost_vendor ALL
    DEPENDS 
        core_headers 
        config_headers 
        assert_headers 
        static_assert_headers
        mp11_headers 
        move_headers
        asio_headers 
        beast_headers 
        interprocess_headers
        system_headers 
        filesystem_headers
    COMMENT "All Boost headers vendored"
)