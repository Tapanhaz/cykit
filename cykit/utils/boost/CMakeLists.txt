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

fetch_boost_headers(throw_exception https://github.com/boostorg/throw_exception.git)
fetch_boost_headers(smart_ptr https://github.com/boostorg/smart_ptr.git)
fetch_boost_headers(winapi https://github.com/boostorg/winapi.git)
fetch_boost_headers(optional https://github.com/boostorg/optional.git)
fetch_boost_headers(intrusive https://github.com/boostorg/intrusive.git)
fetch_boost_headers(type_traits https://github.com/boostorg/type_traits.git)
fetch_boost_headers(endian https://github.com/boostorg/endian.git)
fetch_boost_headers(logic https://github.com/boostorg/logic.git)
fetch_boost_headers(type_index https://github.com/boostorg/type_index.git)
fetch_boost_headers(functional https://github.com/boostorg/functional.git)
fetch_boost_headers(static_string https://github.com/boostorg/static_string.git)
fetch_boost_headers(preprocessor https://github.com/boostorg/preprocessor.git)
fetch_boost_headers(container https://github.com/boostorg/container.git)
fetch_boost_headers(bind https://github.com/boostorg/bind.git)
fetch_boost_headers(iterator https://github.com/boostorg/iterator.git)
fetch_boost_headers(io https://github.com/boostorg/io.git)
fetch_boost_headers(context https://github.com/boostorg/context.git)
fetch_boost_headers(date_time https://github.com/boostorg/date_time.git)
fetch_boost_headers(align https://github.com/boostorg/align.git)
fetch_boost_headers(variant2 https://github.com/boostorg/variant2.git)

fetch_boost_headers(mpl https://github.com/boostorg/mpl.git)
fetch_boost_headers(concept_check https://github.com/boostorg/concept_check.git)
fetch_boost_headers(function_types https://github.com/boostorg/function_types.git)
fetch_boost_headers(utility https://github.com/boostorg/utility.git)
fetch_boost_headers(fusion https://github.com/boostorg/fusion.git)
fetch_boost_headers(container_hash https://github.com/boostorg/container_hash.git)
fetch_boost_headers(predef https://github.com/boostorg/predef.git)
fetch_boost_headers(tokenizer https://github.com/boostorg/tokenizer.git)
fetch_boost_headers(algorithm https://github.com/boostorg/algorithm.git)
fetch_boost_headers(lexical_cast https://github.com/boostorg/lexical_cast.git)
fetch_boost_headers(range https://github.com/boostorg/range.git)
fetch_boost_headers(numeric_conversion https://github.com/boostorg/numeric_conversion.git)
fetch_boost_headers(pool https://github.com/boostorg/pool.git)
fetch_boost_headers(function https://github.com/boostorg/function.git)
fetch_boost_headers(typeof https://github.com/boostorg/typeof.git)

fetch_boost_headers(detail https://github.com/boostorg/detail.git)
fetch_boost_headers(integer https://github.com/boostorg/integer.git)
fetch_boost_headers(regex https://github.com/boostorg/regex.git)
fetch_boost_headers(array https://github.com/boostorg/array.git)
fetch_boost_headers(unordered https://github.com/boostorg/unordered.git)
fetch_boost_headers(tuple https://github.com/boostorg/tuple.git)
fetch_boost_headers(exception https://github.com/boostorg/exception.git)
fetch_boost_headers(conversion https://github.com/boostorg/conversion.git)
fetch_boost_headers(describe https://github.com/boostorg/describe.git)

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
        throw_exception_headers
        smart_ptr_headers
        winapi_headers
        optional_headers
        intrusive_headers
        type_traits_headers
        endian_headers
        logic_headers
        type_index_headers
        functional_headers
        static_string_headers
        preprocessor_headers
        container_headers
        bind_headers
        iterator_headers
        io_headers
        context_headers
        date_time_headers
        align_headers
        variant2_headers
        mpl_headers
        concept_check_headers
        function_types_headers
        utility_headers
        fusion_headers
        container_hash_headers
        predef_headers
        tokenizer_headers
        algorithm_headers
        lexical_cast_headers
        range_headers
        numeric_conversion_headers
        pool_headers
        function_headers
        typeof_headers
        detail_headers
        integer_headers
        regex_headers
        array_headers
        unordered_headers
        tuple_headers
        exception_headers
        conversion_headers
        describe_headers
        asio_headers 
        beast_headers 
        interprocess_headers
        system_headers 
        filesystem_headers
    COMMENT "All Boost headers vendored"
)