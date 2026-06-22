from libc.stdint cimport uint64_t, uint32_t
from libc.stddef cimport size_t
from libc.string cimport memset
from libc.stdlib cimport free
from libcpp.atomic cimport atomic

from cykit.common cimport (
    atomic_notify_all,
    memory_order_acquire,
    memory_order_release,
    memory_order_relaxed,
    aligned_alloc_,
    aligned_free_,
    thread,
    make_thread,
)

from cykit.utils.compat cimport (
    clock_gettime_,
    CLOCK_MONOTONIC_,
    timespec_,
    usleep_,
)

from cykit.queue.queue cimport (
    QueueImpl, QueueSlot, PublishEntry,
    QueueMode, SPSC, SPMC, MPSC, MPMC,
    Q_OK, Q_ERR, Q_FULL, Q_EMPTY,
    F_BLOCK_ON_FULL,
    push_fn, pop_fn,
    spsc_push, spmc_push, mpsc_push, mpmc_push,
    spsc_try_push, spmc_try_push, mpsc_try_push, mpmc_try_push,
    spsc_push_var, spmc_push_var, mpsc_push_var, mpmc_push_var,
    spsc_try_push_var, spmc_try_push_var, mpsc_try_push_var, mpmc_try_push_var,
    spsc_pop, spmc_pop, mpsc_pop, mpmc_pop,
    spsc_try_pop, spmc_try_pop, mpsc_try_pop, mpmc_try_pop,
    spsc_pop_borrow, spmc_pop_borrow, mpsc_pop_borrow, mpmc_pop_borrow,
    spsc_pop_commit, spmc_pop_commit, mpsc_pop_commit, mpmc_pop_commit,
    spsc_pop_var, spmc_pop_var, mpsc_pop_var, mpmc_pop_var,
    spsc_try_pop_var, spmc_try_pop_var, mpsc_try_pop_var, mpmc_try_pop_var,
    register_consumer, unregister_consumer, queue_close,
    borrow_fn, commit_fn
)


cdef enum:
    N_MULTI    = 3
    PAYLOAD_SZ = 64
    CAPACITY   = 4096
    DURATION_S = 3


cdef inline double _now_sec() noexcept nogil:
    cdef timespec_ ts
    clock_gettime_(CLOCK_MONOTONIC_, &ts)
    return <double>ts.tv_sec + <double>ts.tv_nsec * 1e-9



cdef struct BenchShared:
    QueueImpl*      q
    atomic[uint64_t] start_flag
    atomic[uint64_t] stop_flag
    atomic[uint64_t] consumers_ready
    double          duration_s

cdef struct ProducerCtx:
    BenchShared* shared
    uint64_t     sent
    uint32_t     id

cdef struct ConsumerCtx:
    BenchShared* shared
    uint64_t     received
    uint32_t     id
    uint32_t     rid


cdef void* _producer_thread(void* arg) noexcept nogil:
    cdef:
        ProducerCtx* ctx = <ProducerCtx*>arg
        BenchShared* sh  = ctx.shared
        QueueImpl*   q   = sh.q
        char[PAYLOAD_SZ] buf
        double       t0
        int          rc

    memset(buf, <int>ctx.id + 1, PAYLOAD_SZ)

    while sh.start_flag.load(memory_order_acquire) == 0:
        pass

    t0 = _now_sec()

    while not sh.stop_flag.load(memory_order_acquire):
        if _now_sec() - t0 >= sh.duration_s:
            break
        rc = q.fn_push(<void*>q, buf, PAYLOAD_SZ)
        if rc == Q_OK:
            ctx.sent += 1

    return NULL


cdef void* _consumer_thread(void* arg) noexcept nogil:
    cdef:
        ConsumerCtx* ctx = <ConsumerCtx*>arg
        BenchShared* sh  = ctx.shared
        QueueImpl*   q   = sh.q
        char*        out_buf
        size_t       out_sz
        int          rc

    if q.fn_register_consumer != NULL:
        if q.fn_register_consumer(<void*>q, &ctx.rid) != Q_OK:
            return NULL
        sh.consumers_ready.fetch_add(1, memory_order_release)

    while sh.start_flag.load(memory_order_acquire) == 0:
        pass

    while True:
            rc = q.fn_pop(<void*>q, &out_buf, &out_sz)
            if rc == Q_OK:
                ctx.received += 1
            elif rc == Q_ERR:
                break

    if q.fn_unregister_consumer != NULL:
        q.fn_unregister_consumer(<void*>q, ctx.rid)

    return NULL

############################################################################################
###############################   BENCHMARK RUNNER      ####################################
############################################################################################

cdef class _BenchRunner:

    cdef:
        BenchShared  _shared
        ProducerCtx  _prod_ctx[N_MULTI]
        ConsumerCtx  _cons_ctx[N_MULTI]
        QueueImpl    _q
        int          _n_prod
        int          _n_cons
        str          _label

    def __cinit__(self):
        self._q.slots          = NULL
        self._q.slot_bufs      = NULL
        self._q.publish        = NULL
        self._shared.q          = NULL

    cdef void setup(
        self,
        str       label,
        QueueMode mode,
        int       n_prod,
        int       n_cons,
        push_fn   fn_push,
        pop_fn    fn_pop,
        pop_fn    fn_try_pop,
        double    duration_s = DURATION_S,
    ):
        cdef int i
        cdef int cap  = CAPACITY
        cdef int stsz = PAYLOAD_SZ

        self._label  = label
        self._n_prod = n_prod
        self._n_cons = n_cons

        self._q.head.store(0, memory_order_relaxed)
        self._q.tail.store(0, memory_order_relaxed)
        self._q.running.store(1, memory_order_relaxed)
        self._q.capacity_mask  = cap - 1
        self._q.slot_size      = stsz
        self._q.flags          = F_BLOCK_ON_FULL
        self._q.mode           = mode
        self._q.seq_counter    = 0
        self._q.publish        = NULL

        self._q.reader_active_mask.store(0, memory_order_relaxed)
        self._q.reader_min_pos.store(0, memory_order_relaxed)
        cdef uint32_t _ri
        for _ri in range(64):
            self._q.reader_pos[_ri].store(0, memory_order_relaxed)
        cdef int _ci
        for _ci in range(64):
            self._q.consumer_ctx[_ci].expected_seq = 0
            self._q.consumer_ctx[_ci].expected_chunk = 0
            self._q.consumer_ctx[_ci].assemble_buf = NULL
            self._q.consumer_ctx[_ci].assemble_used = 0
            self._q.consumer_ctx[_ci].assemble_cap = 0
        self._q.fn_register_consumer   = NULL
        self._q.fn_unregister_consumer = NULL

        self._q.fn_push    = fn_push
        self._q.fn_pop     = fn_pop
        self._q.fn_try_pop = fn_try_pop

        self._q.slots = <QueueSlot*>aligned_alloc_(
            64, cap * sizeof(QueueSlot)
        )
        self._q.slot_bufs = <char*>aligned_alloc_(64, cap * stsz)

        if self._q.slots == NULL or self._q.slot_bufs == NULL:
            raise MemoryError("queue slot allocation failed")

        memset(self._q.slot_bufs, 0, cap * stsz)

        for i in range(cap):
            self._q.slots[i].buf          = self._q.slot_bufs + i * stsz
            self._q.slots[i].size         = 0
            self._q.slots[i].seq_id       = 0
            self._q.slots[i].chunk_idx    = 0
            self._q.slots[i].total_chunks = 0

        if mode != SPSC:
            self._q.publish = <PublishEntry*>aligned_alloc_(
                64, cap * sizeof(PublishEntry)
            )
            if self._q.publish == NULL:
                raise MemoryError("publish array allocation failed")
            for i in range(cap):
                self._q.publish[i].seq.store(i, memory_order_relaxed)
        
        if mode == SPMC or mode == MPMC:
            self._q.fn_register_consumer   = register_consumer
            self._q.fn_unregister_consumer = unregister_consumer

        self._shared.q          = &self._q
        self._shared.duration_s = duration_s
        self._shared.start_flag.store(0, memory_order_relaxed)
        self._shared.stop_flag.store(0, memory_order_relaxed)
        self._shared.consumers_ready.store(0, memory_order_relaxed)

        for i in range(n_prod):
            self._prod_ctx[i].shared = &self._shared
            self._prod_ctx[i].sent   = 0
            self._prod_ctx[i].id     = i

        for i in range(n_cons):
            self._cons_ctx[i].shared   = &self._shared
            self._cons_ctx[i].received = 0
            self._cons_ctx[i].id       = i

    def run(self):
        cdef:
            int      i
            uint64_t total_sent     = 0
            uint64_t total_received = 0
            double   t0, t1, elapsed
            thread   prod_threads[N_MULTI]
            thread   cons_threads[N_MULTI]

        for i in range(self._n_cons):
            cons_threads[i] = make_thread(
                _consumer_thread, <void*>&self._cons_ctx[i]
            )

        for i in range(self._n_prod):
            prod_threads[i] = make_thread(
                _producer_thread, <void*>&self._prod_ctx[i]
            )
            
        if self._q.fn_register_consumer != NULL:
            while self._shared.consumers_ready.load(memory_order_acquire) < <uint64_t>self._n_cons:
                usleep_(100)

        t0 = _now_sec()
        self._shared.start_flag.store(1, memory_order_release)
        atomic_notify_all(&self._shared.start_flag)

        usleep_(<unsigned int>(DURATION_S * 1_000_000))

        self._shared.stop_flag.store(1, memory_order_release)
        

        for i in range(self._n_prod):
            if prod_threads[i].joinable():
                prod_threads[i].join()
        
        queue_close(<void*>&self._q, -1)
        
        for i in range(self._n_cons):
            if cons_threads[i].joinable():
                cons_threads[i].join()

        t1      = _now_sec()
        elapsed = t1 - t0

        for i in range(self._n_prod):
            total_sent     += self._prod_ctx[i].sent
        for i in range(self._n_cons):
            total_received += self._cons_ctx[i].received

        cdef bint is_fanout = (self._q.mode == SPMC or self._q.mode == MPMC)
        cdef bint ok = True
        cdef uint64_t expected_received

        if is_fanout:
            for i in range(self._n_cons):
                if self._cons_ctx[i].received != total_sent:
                    ok = False
                    break
        else:
            ok = (total_received <= total_sent)

        print(f"\n{'='*58}")
        print(f"  {self._label}")
        print(f"{'='*58}")
        print(f"  producers      : {self._n_prod}")
        print(f"  consumers      : {self._n_cons}")
        print(f"  duration       : {elapsed:.3f}s")
        print(f"  total sent     : {total_sent:,}")
        print(f"  total received : {total_received:,}")
        print(f"  throughput     : {total_received / elapsed:,.0f} ops/sec")
        print(f"  throughput (sent)    : {total_sent / elapsed:,.0f} msgs/sec")
        if is_fanout:
            print(f"  fan-out total  : {total_received / elapsed:,.0f} deliveries/sec")
        if is_fanout:
            print(f"  correctness    : {'OK' if ok else 'FAIL  each consumer must receive total_sent msgs'}")
        else:
            print(f"  correctness    : {'OK' if ok else 'FAIL  received > sent'}")
        for i in range(self._n_prod):
            print(f"    producer[{i}]  sent     {self._prod_ctx[i].sent:>14,}")
        for i in range(self._n_cons):
            print(f"    consumer[{i}]  received {self._cons_ctx[i].received:>14,}")
        
        return {
           "label": self._label,
           "ok": bool(ok),
           "total_sent": total_sent,
           "total_received": total_received,
           "elapsed": elapsed,
       }

    def __dealloc__(self):
        self._q.running.store(0, memory_order_relaxed)
        cdef int _ci
        for _ci in range(64):
            if self._q.consumer_ctx[_ci].assemble_buf != NULL:
                free(self._q.consumer_ctx[_ci].assemble_buf)
                self._q.consumer_ctx[_ci].assemble_buf = NULL
        if self._q.publish != NULL:
            aligned_free_(self._q.publish)
            self._q.publish = NULL
        if self._q.slot_bufs != NULL:
            aligned_free_(self._q.slot_bufs)
            self._q.slot_bufs = NULL
        if self._q.slots != NULL:
            aligned_free_(self._q.slots)
            self._q.slots = NULL


cdef class SPSCBench:
    cdef _BenchRunner _r
    def __init__(self, double duration_s):
        self._r = _BenchRunner()
        self._r.setup(
            "SPSC  (1 producer  /  1 consumer)",
            SPSC, 1, 1,
            spsc_push, spsc_pop, spsc_try_pop, duration_s
        )
    def run(self):
        return self._r.run()


cdef class SPMCBench:
    cdef _BenchRunner _r
    def __init__(self, double duration_s):
        self._r = _BenchRunner()
        self._r.setup(
            "SPMC  (1 producer  /  3 consumers)",
            SPMC, 1, N_MULTI,
            #SPMC, 1, 1,
            spmc_push, spmc_pop, spmc_try_pop, duration_s
        )
    def run(self):
        return self._r.run()


cdef class MPSCBench:
    cdef _BenchRunner _r
    def __init__(self, double duration_s):
        self._r = _BenchRunner()
        self._r.setup(
            "MPSC  (3 producers /  1 consumer)",
            MPSC, N_MULTI, 1,
            mpsc_push, mpsc_pop, mpsc_try_pop, duration_s
        )
    def run(self):
        return self._r.run()


cdef class MPMCBench:
    cdef _BenchRunner _r
    def __init__(self, double duration_s):
        self._r = _BenchRunner()
        self._r.setup(
            "MPMC  (3 producers /  3 consumers)",
            MPMC, N_MULTI, N_MULTI,
            mpmc_push, mpmc_pop, mpmc_try_pop, duration_s
        )
    def run(self):
        return self._r.run()


cdef int _assert(bint cond, const char* msg) noexcept nogil:
    if not cond:
        with gil:
            print(f"  FAIL: {msg.decode()}")
        return 1
    return 0


cdef struct FuncShared:
    QueueImpl*       q
    atomic[uint64_t] barrier    
    atomic[uint64_t] producer_done
    uint64_t         sent
    uint64_t         received



cdef void _fill_queue(QueueImpl* q, uint64_t n) noexcept nogil:
    cdef char[PAYLOAD_SZ] buf
    cdef uint64_t i
    memset(buf, 0xAB, PAYLOAD_SZ)
    for i in range(n):
        while q.fn_push(<void*>q, buf, PAYLOAD_SZ) != Q_OK:
            pass


############################################################################################
#####################################    SPSC     #######################################
############################################################################################

cdef int _test_spsc_push_pop() noexcept nogil:
    cdef:
        QueueImpl    q
        char[PAYLOAD_SZ] buf
        char*  out
        size_t outsz
        int    rc, fail = 0

    _init_queue_spsc(&q, CAPACITY, PAYLOAD_SZ)
    memset(buf, 0x42, PAYLOAD_SZ)

    rc   = q.fn_push(<void*>&q, buf, PAYLOAD_SZ)
    fail += _assert(rc == Q_OK, b"spsc_push returned != Q_OK")

    rc   = q.fn_pop(<void*>&q, &out, &outsz)
    fail += _assert(rc == Q_OK,          b"spsc_pop returned != Q_OK")
    fail += _assert(outsz == PAYLOAD_SZ, b"spsc_pop wrong size")
    fail += _assert(out[0] == 0x42,      b"spsc_pop wrong content")

    _destroy_queue(&q)
    return fail


cdef int _test_spsc_try_push_full() noexcept nogil:
    cdef:
        QueueImpl q
        char[PAYLOAD_SZ] buf
        int rc, fail = 0

    _init_queue_spsc(&q, CAPACITY, PAYLOAD_SZ)
    memset(buf, 1, PAYLOAD_SZ)

    _fill_queue(&q, CAPACITY)  

    rc   = q.fn_try_push(<void*>&q, buf, PAYLOAD_SZ)
    fail += _assert(rc == Q_FULL, b"spsc_try_push on full queue != Q_FULL")

    _destroy_queue(&q)
    return fail


cdef int _test_spsc_try_pop_empty() noexcept nogil:
    cdef:
        QueueImpl q
        char*  out
        size_t outsz
        int    rc, fail = 0

    _init_queue_spsc(&q, CAPACITY, PAYLOAD_SZ)

    rc   = q.fn_try_pop(<void*>&q, &out, &outsz)
    fail += _assert(rc == Q_EMPTY, b"spsc_try_pop on empty queue != Q_EMPTY")

    _destroy_queue(&q)
    return fail


cdef int _test_spsc_borrow_commit() noexcept nogil:
    cdef:
        QueueImpl q
        char[PAYLOAD_SZ] buf
        char*  out
        size_t outsz
        uint64_t head_before, head_after
        int rc, fail = 0

    _init_queue_spsc(&q, CAPACITY, PAYLOAD_SZ)
    memset(buf, 0x77, PAYLOAD_SZ)
    q.fn_push(<void*>&q, buf, PAYLOAD_SZ)

    head_before = q.head.load(memory_order_relaxed)
    rc = q.fn_pop_borrow(<void*>&q, &out, &outsz)
    fail += _assert(rc == Q_OK, b"spsc_pop_borrow != Q_OK")
    fail += _assert(
        q.head.load(memory_order_relaxed) == head_before,
        b"spsc: head advanced before commit"
    )
    fail += _assert(out[0] == 0x77, b"spsc_pop_borrow wrong content")

    q.fn_pop_commit(<void*>&q)
    fail += _assert(
        q.head.load(memory_order_relaxed) == head_before + 1,
        b"spsc: head did not advance after commit"
    )

    _destroy_queue(&q)
    return fail


############################################################################################
#####################################    SPMC      #########################################
############################################################################################

cdef struct _SPMCFanoutCtx:
    QueueImpl*       q
    atomic[uint64_t]* barrier
    uint64_t         received
    uint32_t         rid

cdef void* _spmc_consumer(void* arg) noexcept nogil:
    cdef _SPMCFanoutCtx* ctx = <_SPMCFanoutCtx*>arg
    cdef QueueImpl* q = ctx.q
    cdef char* out
    cdef size_t outsz

    register_consumer(<void*>q, &ctx.rid)

    ctx.barrier[0].fetch_add(1, memory_order_release)
    while ctx.barrier[0].load(memory_order_acquire) < 3:
        pass

    while True:
        rc = q.fn_pop(<void*>q, &out, &outsz)
        if rc == Q_ERR:
            break
        if rc == Q_OK:
            ctx.received += 1

    unregister_consumer(<void*>q, ctx.rid)
    return NULL


cdef int _test_spmc_fanout() noexcept nogil:
    cdef:
        QueueImpl           q
        _SPMCFanoutCtx      ctx[3]
        thread              threads[3]
        char[PAYLOAD_SZ]    buf
        uint64_t            N = 10000
        int                 i, fail = 0

    _init_queue_spmc(&q, CAPACITY, PAYLOAD_SZ)
    q.flags = F_BLOCK_ON_FULL
    memset(buf, 0xCC, PAYLOAD_SZ)

    cdef atomic[uint64_t] barrier
    barrier.store(0, memory_order_relaxed)

    for i in range(3):
        ctx[i].q        = &q
        ctx[i].barrier  = &barrier  
        ctx[i].received = 0
        ctx[i].rid      = 0
        threads[i] = make_thread(_spmc_consumer, <void*>&ctx[i])

    while barrier.load(memory_order_acquire) < 3:
        pass

    for i in range(<int>N):
        while q.fn_push(<void*>&q, buf, PAYLOAD_SZ) != Q_OK:
            pass

    queue_close(<void*>&q, -1)

    for i in range(3):
        threads[i].join()

    for i in range(3):
        fail += _assert(
            ctx[i].received == N,
            b"spmc_fanout: consumer did not receive all messages"
        )

    _destroy_queue(&q)
    return fail


cdef int _test_spmc_try_pop_empty() noexcept nogil:
    cdef:
        QueueImpl q
        char*  out
        size_t outsz
        uint32_t rid
        int rc, fail = 0

    _init_queue_spmc(&q, CAPACITY, PAYLOAD_SZ)
    register_consumer(<void*>&q, &rid)

    rc   = q.fn_try_pop(<void*>&q, &out, &outsz)
    fail += _assert(rc == Q_EMPTY, b"spmc_try_pop on empty != Q_EMPTY")

    unregister_consumer(<void*>&q, rid)
    _destroy_queue(&q)
    return fail


cdef int _test_spmc_borrow_commit() noexcept nogil:
    cdef:
        QueueImpl        q
        char[PAYLOAD_SZ] buf
        char*   out
        size_t  outsz
        uint32_t rid
        uint64_t pos_before
        int rc, fail = 0

    _init_queue_spmc(&q, CAPACITY, PAYLOAD_SZ)
    memset(buf, 0x55, PAYLOAD_SZ)
    register_consumer(<void*>&q, &rid)

    q.fn_push(<void*>&q, buf, PAYLOAD_SZ)

    pos_before = q.reader_pos[rid].load(memory_order_relaxed)
    rc = q.fn_pop_borrow(<void*>&q, &out, &outsz)
    fail += _assert(rc == Q_OK, b"spmc_pop_borrow != Q_OK")
    fail += _assert(
        q.reader_pos[rid].load(memory_order_relaxed) == pos_before,
        b"spmc: reader_pos advanced before commit"
    )

    q.fn_pop_commit(<void*>&q)
    fail += _assert(
        q.reader_pos[rid].load(memory_order_relaxed) == pos_before + 1,
        b"spmc: reader_pos did not advance after commit"
    )

    unregister_consumer(<void*>&q, rid)
    _destroy_queue(&q)
    return fail


############################################################################################
#####################################    MPSC     #######################################
############################################################################################

cdef struct _MPSCProdCtx:
    QueueImpl*        q
    atomic[uint64_t]* barrier
    atomic[uint64_t]* start
    uint64_t          sent
    uint64_t          n

cdef struct _MPSCConsCtx:
    QueueImpl*        q
    atomic[uint64_t]* prod_done
    uint64_t          received

cdef void* _mpsc_consumer(void* arg) noexcept nogil:
    cdef _MPSCConsCtx* ctx = <_MPSCConsCtx*>arg
    cdef char*   out
    cdef size_t  outsz
    cdef int rc 
    while True:
        rc = ctx.q.fn_pop(<void*>ctx.q, &out, &outsz)
        if rc == Q_OK:
            ctx.received += 1
        elif rc == Q_ERR:
            break

cdef void* _mpsc_producer(void* arg) noexcept nogil:
    cdef _MPSCProdCtx* ctx = <_MPSCProdCtx*>arg
    cdef char[PAYLOAD_SZ] buf
    cdef uint64_t i
    memset(buf, 1, PAYLOAD_SZ)
    ctx.barrier[0].fetch_add(1, memory_order_release)
    while ctx.start[0].load(memory_order_acquire) == 0:
        pass
    for i in range(ctx.n):
        while ctx.q.fn_push(<void*>ctx.q, buf, PAYLOAD_SZ) != Q_OK:
            pass
        ctx.sent += 1
    return NULL


cdef int _test_mpsc_push_pop() noexcept nogil:
    cdef:
        QueueImpl        q
        _MPSCProdCtx     pctx[3]
        _MPSCConsCtx     cctx
        thread           pthreads[3]
        thread           cthread
        atomic[uint64_t] barrier
        atomic[uint64_t] start
        uint64_t total_sent = 0
        uint64_t N = 5000
        int i, fail = 0

    _init_queue_mpsc(&q, CAPACITY, PAYLOAD_SZ)
    q.flags = F_BLOCK_ON_FULL
    barrier.store(0, memory_order_relaxed)
    start.store(0, memory_order_relaxed)

    cctx.q        = &q
    cctx.received = 0
    cthread = make_thread(_mpsc_consumer, <void*>&cctx)

    for i in range(3):
        pctx[i].q       = &q
        pctx[i].barrier = &barrier
        pctx[i].start   = &start
        pctx[i].sent    = 0
        pctx[i].n       = N
        pthreads[i] = make_thread(_mpsc_producer, <void*>&pctx[i])

    while barrier.load(memory_order_acquire) < 3:
        pass
    start.store(1, memory_order_release)

    for i in range(3):
        pthreads[i].join()
        total_sent += pctx[i].sent

    queue_close(<void*>&q, -1)
    cthread.join()

    fail += _assert(cctx.received == total_sent, b"mpsc: received != sent")
    _destroy_queue(&q)
    return fail


cdef int _test_mpsc_try_push_full() noexcept nogil:
    cdef:
        QueueImpl        q
        char[PAYLOAD_SZ] buf
        int rc, fail = 0

    _init_queue_mpsc(&q, CAPACITY, PAYLOAD_SZ)
    memset(buf, 2, PAYLOAD_SZ)
    _fill_queue(&q, CAPACITY)

    rc   = q.fn_try_push(<void*>&q, buf, PAYLOAD_SZ)
    fail += _assert(rc == Q_FULL, b"mpsc_try_push on full != Q_FULL")

    _destroy_queue(&q)
    return fail


cdef int _test_mpsc_borrow_commit() noexcept nogil:
    cdef:
        QueueImpl        q
        char[PAYLOAD_SZ] buf
        char*   out
        size_t  outsz
        uint64_t head_before
        int rc, fail = 0

    _init_queue_mpsc(&q, CAPACITY, PAYLOAD_SZ)
    memset(buf, 0x33, PAYLOAD_SZ)
    q.fn_push(<void*>&q, buf, PAYLOAD_SZ)

    head_before = q.head.load(memory_order_relaxed)
    rc = q.fn_pop_borrow(<void*>&q, &out, &outsz)
    fail += _assert(rc == Q_OK, b"mpsc_pop_borrow != Q_OK")
    fail += _assert(
        q.head.load(memory_order_relaxed) == head_before,
        b"mpsc: head advanced before commit"
    )

    q.fn_pop_commit(<void*>&q)
    fail += _assert(
        q.head.load(memory_order_relaxed) == head_before + 1,
        b"mpsc: head did not advance after commit"
    )

    _destroy_queue(&q)
    return fail


############################################################################################
#####################################    MPMC      #######################################
############################################################################################

cdef int _test_mpmc_fanout() noexcept nogil:
    cdef:
        QueueImpl           q
        _SPMCFanoutCtx      cctx[3]
        _MPSCProdCtx        pctx[3]
        thread              cthreads[3]
        thread              pthreads[3]
        atomic[uint64_t]    cons_barrier
        atomic[uint64_t]    prod_barrier
        atomic[uint64_t]    prod_start
        char[PAYLOAD_SZ]    buf
        uint64_t            N = 5000, total_sent = 0
        int                 i, fail = 0

    _init_queue_mpmc(&q, CAPACITY, PAYLOAD_SZ)
    q.flags = F_BLOCK_ON_FULL
    memset(buf, 0xDD, PAYLOAD_SZ)
    cons_barrier.store(0, memory_order_relaxed)
    prod_barrier.store(0, memory_order_relaxed)
    prod_start.store(0, memory_order_relaxed)

    for i in range(3):
        cctx[i].q        = &q
        cctx[i].barrier  = &cons_barrier
        cctx[i].received = 0
        cctx[i].rid      = 0
        cthreads[i] = make_thread(_spmc_consumer, <void*>&cctx[i])

    while cons_barrier.load(memory_order_acquire) < 3:
        pass

    for i in range(3):
        pctx[i].q       = &q
        pctx[i].barrier = &prod_barrier
        pctx[i].start   = &prod_start
        pctx[i].sent    = 0
        pctx[i].n       = N
        pthreads[i] = make_thread(_mpsc_producer, <void*>&pctx[i])

    while prod_barrier.load(memory_order_acquire) < 3:
        pass
    prod_start.store(1, memory_order_release)

    for i in range(3):
        pthreads[i].join()
        total_sent += pctx[i].sent

    queue_close(<void*>&q, -1)

    for i in range(3):
        cthreads[i].join()

    for i in range(3):
        fail += _assert(
            cctx[i].received == total_sent,
            b"mpmc_fanout: consumer did not receive all messages"
        )

    _destroy_queue(&q)
    return fail

############################################################################################
#############################    _VAR FUNC TESTS        ####################################
############################################################################################

cdef int _test_spsc_push_pop_var() noexcept nogil:
    cdef:
        QueueImpl        q
        char[512]        big_buf       
        char*  out
        size_t outsz
        int    rc, fail = 0
        size_t j

    _init_queue_spsc(&q, CAPACITY, PAYLOAD_SZ)
    q.fn_push_var   = spsc_push_var
    q.fn_try_push_var = spsc_try_push_var
    q.fn_pop_var    = spsc_pop_var
    q.fn_try_pop_var = spsc_try_pop_var

    memset(big_buf, 0xBB, 512)

    rc = q.fn_push_var(<void*>&q, big_buf, 512)
    fail += _assert(rc == Q_OK, b"spsc_push_var != Q_OK")

    rc = q.fn_pop_var(<void*>&q, &out, &outsz)
    fail += _assert(rc == Q_OK,   b"spsc_pop_var != Q_OK")
    fail += _assert(outsz == 512, b"spsc_pop_var wrong size")
    fail += _assert(out[0] == <char>0xBB, b"spsc_pop_var wrong content")

    _destroy_queue(&q)
    return fail


cdef int _test_spsc_try_push_var_full() noexcept nogil:
    cdef:
        QueueImpl        q
        char[PAYLOAD_SZ] buf
        char[512]        big_buf
        int rc, fail = 0

    _init_queue_spsc(&q, CAPACITY, PAYLOAD_SZ)
    q.fn_push_var    = spsc_push_var
    q.fn_try_push_var = spsc_try_push_var
    q.fn_pop_var     = spsc_pop_var
    q.fn_try_pop_var  = spsc_try_pop_var

    memset(big_buf, 1, 512)
    _fill_queue(&q, CAPACITY - 7)

    rc = q.fn_try_push_var(<void*>&q, big_buf, 512)
    fail += _assert(rc == Q_FULL, b"spsc_try_push_var on full != Q_FULL")

    _destroy_queue(&q)
    return fail


cdef int _test_spsc_try_pop_var_empty() noexcept nogil:
    cdef:
        QueueImpl q
        char* out
        size_t outsz
        int rc, fail = 0

    _init_queue_spsc(&q, CAPACITY, PAYLOAD_SZ)
    q.fn_pop_var     = spsc_pop_var
    q.fn_try_pop_var  = spsc_try_pop_var

    rc = q.fn_try_pop_var(<void*>&q, &out, &outsz)
    fail += _assert(rc == Q_EMPTY, b"spsc_try_pop_var on empty != Q_EMPTY")

    _destroy_queue(&q)
    return fail


cdef int _test_spmc_push_pop_var() noexcept nogil:
    cdef:
        QueueImpl        q
        char[512]        big_buf
        char*  out
        size_t outsz
        uint32_t rid
        int rc, fail = 0

    _init_queue_spmc(&q, CAPACITY, PAYLOAD_SZ)
    q.fn_push_var    = spmc_push_var
    q.fn_try_push_var = spmc_try_push_var
    q.fn_pop_var     = spmc_pop_var
    q.fn_try_pop_var  = spmc_try_pop_var

    memset(big_buf, 0xAA, 512)
    register_consumer(<void*>&q, &rid)

    rc = q.fn_push_var(<void*>&q, big_buf, 512)
    fail += _assert(rc == Q_OK, b"spmc_push_var != Q_OK")

    rc = q.fn_pop_var(<void*>&q, &out, &outsz)
    fail += _assert(rc == Q_OK,   b"spmc_pop_var != Q_OK")
    fail += _assert(outsz == 512, b"spmc_pop_var wrong size")
    fail += _assert(out[0] == <char>0xAA, b"spmc_pop_var wrong content")

    unregister_consumer(<void*>&q, rid)
    _destroy_queue(&q)
    return fail


cdef int _test_mpsc_push_pop_var() noexcept nogil:
    cdef:
        QueueImpl        q
        char[512]        big_buf
        char*  out
        size_t outsz
        int rc, fail = 0

    _init_queue_mpsc(&q, CAPACITY, PAYLOAD_SZ)
    q.fn_push_var    = mpsc_push_var
    q.fn_try_push_var = mpsc_try_push_var
    q.fn_pop_var     = mpsc_pop_var
    q.fn_try_pop_var  = mpsc_try_pop_var

    memset(big_buf, 0x99, 512)

    rc = q.fn_push_var(<void*>&q, big_buf, 512)
    fail += _assert(rc == Q_OK, b"mpsc_push_var != Q_OK")

    rc = q.fn_pop_var(<void*>&q, &out, &outsz)
    fail += _assert(rc == Q_OK,   b"mpsc_pop_var != Q_OK")
    fail += _assert(outsz == 512, b"mpsc_pop_var wrong size")
    fail += _assert(out[0] == <char>0x99, b"mpsc_pop_var wrong content")

    _destroy_queue(&q)
    return fail


cdef int _test_mpmc_push_pop_var() noexcept nogil:
    cdef:
        QueueImpl        q
        char[512]        big_buf
        char*  out
        size_t outsz
        uint32_t rid
        int rc, fail = 0

    _init_queue_mpmc(&q, CAPACITY, PAYLOAD_SZ)
    q.fn_push_var    = mpmc_push_var
    q.fn_try_push_var = mpmc_try_push_var
    q.fn_pop_var     = mpmc_pop_var
    q.fn_try_pop_var  = mpmc_try_pop_var

    memset(big_buf, 0x77, 512)
    register_consumer(<void*>&q, &rid)

    rc = q.fn_push_var(<void*>&q, big_buf, 512)
    fail += _assert(rc == Q_OK, b"mpmc_push_var != Q_OK")

    rc = q.fn_pop_var(<void*>&q, &out, &outsz)
    fail += _assert(rc == Q_OK,   b"mpmc_pop_var != Q_OK")
    fail += _assert(outsz == 512, b"mpmc_pop_var wrong size")
    fail += _assert(out[0] == <char>0x77, b"mpmc_pop_var wrong content")

    unregister_consumer(<void*>&q, rid)
    _destroy_queue(&q)
    return fail

############################################################################################
#####################################    HELPERS     #######################################
############################################################################################

cdef void _init_queue_base(
    QueueImpl* q, size_t cap, size_t stsz, QueueMode mode,
    push_fn fn_push, push_fn fn_try_push,
    pop_fn  fn_pop,  pop_fn  fn_try_pop,
    borrow_fn fn_borrow, commit_fn fn_commit,
) noexcept nogil:
    cdef size_t i
    q.head.store(0, memory_order_relaxed)
    q.tail.store(0, memory_order_relaxed)
    q.running.store(1, memory_order_relaxed)
    q.capacity_mask = cap - 1
    q.slot_size     = stsz
    q.flags         = 0        
    q.mode          = mode
    q.seq_counter   = 0
    q.publish       = NULL
    q.reader_active_mask.store(0, memory_order_relaxed)
    q.reader_min_pos.store(0, memory_order_relaxed)
    for i in range(64):
        q.reader_pos[i].store(0, memory_order_relaxed)
    for i in range(64):
        q.consumer_ctx[i].expected_seq   = 0
        q.consumer_ctx[i].expected_chunk  = 0
        q.consumer_ctx[i].assemble_buf   = NULL
        q.consumer_ctx[i].assemble_used  = 0
        q.consumer_ctx[i].assemble_cap   = 0
    q.fn_register_consumer   = NULL
    q.fn_unregister_consumer = NULL
    q.fn_push        = fn_push
    q.fn_try_push    = fn_try_push
    q.fn_pop         = fn_pop
    q.fn_try_pop     = fn_try_pop
    q.fn_pop_borrow  = fn_borrow
    q.fn_pop_commit  = fn_commit
    q.fn_push_var    = NULL
    q.fn_try_push_var= NULL
    q.fn_pop_var     = NULL
    q.fn_try_pop_var = NULL

    q.slots     = <QueueSlot*>aligned_alloc_(64, cap * sizeof(QueueSlot))
    q.slot_bufs = <char*>aligned_alloc_(64, cap * stsz)
    memset(q.slot_bufs, 0, cap * stsz)
    for i in range(cap):
        q.slots[i].buf          = q.slot_bufs + i * stsz
        q.slots[i].size         = 0
        q.slots[i].seq_id       = 0
        q.slots[i].chunk_idx    = 0
        q.slots[i].total_chunks = 0

    if mode != SPSC:
        q.publish = <PublishEntry*>aligned_alloc_(64, cap * sizeof(PublishEntry))
        for i in range(cap):
            q.publish[i].seq.store(i, memory_order_relaxed)

    if mode == SPMC or mode == MPMC:
        q.fn_register_consumer   = register_consumer
        q.fn_unregister_consumer = unregister_consumer


cdef void _destroy_queue(QueueImpl* q) noexcept nogil:
    q.running.store(0, memory_order_relaxed)
    if q.publish   != NULL: aligned_free_(q.publish);   q.publish   = NULL
    if q.slot_bufs != NULL: aligned_free_(q.slot_bufs); q.slot_bufs = NULL
    if q.slots     != NULL: aligned_free_(q.slots);     q.slots     = NULL


cdef void _init_queue_spsc(QueueImpl* q, size_t cap, size_t stsz) noexcept nogil:
    _init_queue_base(q, cap, stsz, SPSC,
        spsc_push, spsc_try_push, spsc_pop, spsc_try_pop,
        spsc_pop_borrow, spsc_pop_commit)

cdef void _init_queue_spmc(QueueImpl* q, size_t cap, size_t stsz) noexcept nogil:
    _init_queue_base(q, cap, stsz, SPMC,
        spmc_push, spmc_try_push, spmc_pop, spmc_try_pop,
        spmc_pop_borrow, spmc_pop_commit)

cdef void _init_queue_mpsc(QueueImpl* q, size_t cap, size_t stsz) noexcept nogil:
    _init_queue_base(q, cap, stsz, MPSC,
        mpsc_push, mpsc_try_push, mpsc_pop, mpsc_try_pop,
        mpsc_pop_borrow, mpsc_pop_commit)

cdef void _init_queue_mpmc(QueueImpl* q, size_t cap, size_t stsz) noexcept nogil:
    _init_queue_base(q, cap, stsz, MPMC,
        mpmc_push, mpmc_try_push, mpmc_pop, mpmc_try_pop,
        mpmc_pop_borrow, mpmc_pop_commit)

############################################################################################
#####################################    RUNNER      #######################################
############################################################################################

cdef struct _FuncTest:
    const char* name
    int (*fn)() noexcept nogil


def run_func_tests_collect():
    cdef _FuncTest[48] tests
    tests[0]  = _FuncTest(b"spsc  push/pop",             _test_spsc_push_pop)
    tests[1]  = _FuncTest(b"spsc  try_push full",         _test_spsc_try_push_full)
    tests[2]  = _FuncTest(b"spsc  try_pop empty",         _test_spsc_try_pop_empty)
    tests[3]  = _FuncTest(b"spsc  borrow/commit",         _test_spsc_borrow_commit)
    tests[4]  = _FuncTest(b"spsc  push_var/pop_var",      _test_spsc_push_pop_var)
    tests[5]  = _FuncTest(b"spsc  try_push_var full",     _test_spsc_try_push_var_full)
    tests[6]  = _FuncTest(b"spsc  try_pop_var empty",     _test_spsc_try_pop_var_empty)
    tests[7]  = _FuncTest(b"spmc  fanout 1p3c",           _test_spmc_fanout)
    tests[8]  = _FuncTest(b"spmc  try_pop empty",         _test_spmc_try_pop_empty)
    tests[9]  = _FuncTest(b"spmc  borrow/commit",         _test_spmc_borrow_commit)
    tests[10] = _FuncTest(b"spmc  push_var/pop_var",      _test_spmc_push_pop_var)
    tests[11] = _FuncTest(b"mpsc  3p1c total",            _test_mpsc_push_pop)
    tests[12] = _FuncTest(b"mpsc  try_push full",         _test_mpsc_try_push_full)
    tests[13] = _FuncTest(b"mpsc  borrow/commit",         _test_mpsc_borrow_commit)
    tests[14] = _FuncTest(b"mpsc  push_var/pop_var",      _test_mpsc_push_pop_var)
    tests[15] = _FuncTest(b"mpmc  fanout 3p3c",           _test_mpmc_fanout)
    tests[16] = _FuncTest(b"mpmc  try_pop empty",         _test_spmc_try_pop_empty)
    tests[17] = _FuncTest(b"mpmc  push_var/pop_var",      _test_mpmc_push_pop_var)

    results = []
    cdef int i, result
    for i in range(18):
        with nogil:
            result = tests[i].fn()
        results.append((tests[i].name.decode(), result))
    return results

