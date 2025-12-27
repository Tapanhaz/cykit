

cdef inline bint is_power_of_two(uint32_t n) nogil:
    return n != 0 and (n & (n - 1)) == 0