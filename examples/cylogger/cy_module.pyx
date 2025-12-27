from cykit.cylogger cimport TRACE, DEBUG_C, INFO_FX
from cykit.cylogger.color cimport AnsiColor, TextEffect

cpdef void cy_func():
    cdef:
        int request_id = 1024
        double latency_ms = 18.42
        const char* component = "network" 

    with nogil:

        TRACE(
            "Entering component=%s (request_id=%d)",
            component,
            request_id
        )

        DEBUG_C(
            AnsiColor.SEAGREEN1_A,
            "Request %d processed in %.2f ms",
            request_id,
            latency_ms
        )

        INFO_FX(
            AnsiColor.BLUE,
            AnsiColor.LIGHTGOLDENROD1, 
            TextEffect.ITALIC,
            "Request %d completed successfully",
            request_id
        )
