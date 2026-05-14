

cdef inline bint is_power_of_two(uint32_t n) noexcept nogil:
    return n != 0 and (n & (n - 1)) == 0

cdef inline int buf_to_cbuf(
        object msg,
        Py_buffer* view,
        const char** data,
        size_t* size
    ) except +:

    if PyObject_GetBuffer(<PyObject*>msg, view, PyBUF_SIMPLE) != 0:
        return -1  

    data[0] = <char*>view.buf
    size[0] = <size_t>view.len

    return 0


cdef inline int str_to_cbuf(
        object msg,
        const char** data,
        size_t* size
    ) except +:
    cdef Py_ssize_t n

    data[0] = <char*>PyUnicode_AsUTF8AndSize(<PyObject*>msg, &n)
    if data[0] == NULL:
        return -1

    size[0] = <size_t>n
    return 0


cdef inline int obj_to_cbuf(
        object msg,
        PyObject** pb,
        const char** data,
        size_t* size
    ) except +:

    pb[0] = PyObject_Bytes(<PyObject*>msg)
    if pb[0] == NULL:
        return -1

    data[0] = PyBytes_AS_STRING(pb[0])
    size[0] = PyBytes_GET_SIZE(pb[0])

    return 0