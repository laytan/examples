// This package started out as a port of the minicoro library with the following copyright:
//
// Copyright (c) 2021-2023 Eduardo Bart (https://github.com/edubart/minicoro)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is furnished to do
// so.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

package mco

import "base:intrinsics"

import "core:fmt"
import "core:log"
import "core:mem"

when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import mco_asm "minicoro_aarch64.asm"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	foreign import mco_asm "minicoro_systemv_amd64.asm"
} else {
	#panic("unsupported target")
}

@(default_calling_convention="odin")
foreign mco_asm {
	_mco_wrap_main :: proc() ---
	_mco_switch    :: proc(from, to: ^_ctxbuf) ---
}

// Only used in parapoly.
_ :: fmt

DEFAULT_STORAGE_SIZE :: 1024

State :: enum {
	// The coroutine has finished normally or was uninitialized before finishing.
	Dead,
	// The coroutine is active but not running (that is, it has resumed another coroutine).
	Normal,
	// The coroutine is active and running.
	Running,
	// The coroutine is suspended (in a call to yield, or it has not started running yet).
	Suspended,
}

Result :: enum {
	Success,
	Generic_Error,
	Invalid_Pointer,
	Invalid_Coroutine,
	Not_Suspended,
	Not_Running,
	Make_Context_Error,
	Switch_Context_Error,
	Not_Enough_Space,
	Out_Of_Memory,
	Invalid_Arguments,
	Invalid_Operation,
	Stack_Overflow,
}

Coro :: struct {
	ctx:          ^ctx,
	state:        State,
	func:         proc(co: ^Coro),
	prev_co:      ^Coro,
	user_data:    rawptr,
	coro_size:    uint,

	stack_base:   rawptr,
	stack_size:   uint,

	storage:      [^]byte,
	bytes_stored: uint,
	storage_size: uint,

	// asan_prev_stack: rawptr,
	// tsan_prev_fiber: rawptr,
	// tsan_fiber:      rawptr,

	magic_number: uint,
}

Desc :: struct {
	func:         proc(co: ^Coro),
	user_data:    rawptr,

	storage_size: uint,
	coro_size:    uint,
	stack_size:   uint,
}

/* Minimum stack size when creating a coroutine. */
MIN_STACK_SIZE :: 32768
/* Default stack size when creating a coroutine. */
DEFAULT_STACK_SIZE :: 56 * 1024

/* Number used only to assist checking for stack overflows. */
MAGIC_NUMBER :: 0x7E3CB1A9

@(thread_local, private)
current_co: ^Coro

_prepare_jumpin :: #force_inline proc(co: ^Coro) {
	/* Set the old coroutine to normal state and update it. */
	prev_co := running_safe()
	assert(co.prev_co == nil)
	co.prev_co = prev_co
	if (prev_co != nil) {
		assert(prev_co.state == .Running)
		prev_co.state = .Normal
	}
	current_co = co
}

_prepare_jumpout :: #force_inline proc(co: ^Coro) {
	/* Switch back to the previous running coroutine. */
	prev_co := co.prev_co
	co.prev_co = nil
	if (prev_co != nil) {
		prev_co.state = .Running
	}
	current_co = prev_co
}

_main :: #force_no_inline proc(co: ^Coro) {
	co->func()
	co.state = .Dead
	_jumpout(co)
}

when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	_ctxbuf :: struct {
		x: [12]rawptr, /* x19-x30 */
		sp: rawptr,
		lr: rawptr,
		d: [8]rawptr, /* d8-d15 */
	}

	_makectx :: proc(co: ^Coro, ctx: ^_ctxbuf, stack_base: rawptr, stack_size: uint) {
		ctx.x[0] = co
		ctx.x[1] = rawptr(_main)
		ctx.x[2] = rawptr(uintptr(0xdeaddeaddeaddead))
		ctx.lr   = rawptr(_mco_wrap_main)
		ctx.sp   = rawptr(uintptr(stack_base) + uintptr(stack_size))
	}
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	_ctxbuf :: struct {
		rip, rsp, rbp, rbx, r12, r13, r14, r15: rawptr,
	}

	_makectx :: proc(co: ^Coro, ctx: ^_ctxbuf, stack_base: rawptr, stack_size: uint) {
		stack_size := stack_size
		stack_size -= 128 // red zone
		stack_high_ptr := ([^]rawptr)(uintptr(stack_base) + uintptr(stack_size) - size_of(uint))
		stack_high_ptr[0] = rawptr(uintptr(0xdeaddeaddeaddead)) // dummy return address
		ctx.rip = rawptr(_mco_wrap_main)
		ctx.rsp = stack_high_ptr
		ctx.r12 = rawptr(_main)
		ctx.r13 = co
	}
} else {
	#panic("unsupported target")
}

ctx :: struct {
	ctx:      _ctxbuf,
	back_ctx: _ctxbuf,
}

_jumpin :: proc(co: ^Coro) {
	ctx := (^ctx)(co.ctx)
	_prepare_jumpin(co)
	_mco_switch(&ctx.back_ctx, &ctx.ctx)
}

_jumpout :: proc(co: ^Coro) {
	ctx := (^ctx)(co.ctx)
	_prepare_jumpout(co)
	_mco_switch(&ctx.ctx, &ctx.back_ctx)
}

create_ctx :: proc(co: ^Coro, desc: ^Desc) {
	co_addr      := uintptr(co)
	ctx_addr     := mem.align_forward_uintptr(co_addr + size_of(Coro), 16)
	storage_addr := mem.align_forward_uintptr(ctx_addr + size_of(ctx), 16)
	stack_addr   := mem.align_forward_uintptr(storage_addr + uintptr(desc.storage_size), 16)

	ctx := (^ctx)(ctx_addr)
	mem.zero_item(ctx)

	storage := ([^]byte)(storage_addr)

	stack_base := rawptr(stack_addr)
	stack_size := desc.stack_size

	_makectx(co, &ctx.ctx, stack_base, stack_size)

	co.ctx          = ctx
	co.stack_base   = stack_base
	co.stack_size   = stack_size
	co.storage      = storage
	co.storage_size = desc.storage_size
}

_init_desc_sizes :: #force_inline proc(desc: ^Desc, stack_size: uint) {
	desc.coro_size = (
		mem.align_forward_uint(size_of(Coro), 16) +
		mem.align_forward_uint(size_of(ctx), 16) +
		mem.align_forward_uint(desc.storage_size, 16) +
		stack_size + 16 \
	)
	desc.stack_size = stack_size
}

desc_init :: proc(func: proc(co: ^Coro), stack_size: uint = 0) -> Desc {
	stack_size := stack_size
	if stack_size != 0 {
		if stack_size < MIN_STACK_SIZE {
			stack_size = MIN_STACK_SIZE
		}
	} else {
		stack_size = DEFAULT_STACK_SIZE
	}
	stack_size = mem.align_forward_uint(stack_size, 16)

	desc: Desc
	desc.func = func
	desc.storage_size = DEFAULT_STORAGE_SIZE
	_init_desc_sizes(&desc, stack_size)
	return desc
}

_validate_desc :: proc(desc: ^Desc) -> Result {
	if desc == nil {
		log.error("coroutine description is nil")
		return .Invalid_Arguments
	}
	if desc.func == nil {
		log.error("coroutine function is invalid")
		return .Invalid_Arguments
	}
	if desc.stack_size < MIN_STACK_SIZE {
		log.error("coroutine stack size is too small")
		return .Invalid_Arguments
	}
	if desc.coro_size < size_of(Coro) {
		log.error("coroutine size is invalid")
		return .Invalid_Arguments
	}
	return .Success
}

init :: proc(co: ^Coro, desc: ^Desc) -> Result {
	if co == nil {
		log.error("attempt to initialize an invalid coroutine")
		return .Invalid_Coroutine
	}
	mem.zero_item(co) // NOTE: Not sure if needed.

	_validate_desc(desc) or_return
	create_ctx(co, desc)

	co.state = .Suspended
	co.coro_size = desc.coro_size
	co.func = desc.func
	co.user_data = desc.user_data
	co.magic_number = MAGIC_NUMBER
	return .Success
}

uninit :: proc(co: ^Coro) -> Result {
	if co == nil {
		log.error("attempt to uninitialize an invalid coroutine")
		return .Invalid_Coroutine
	}
	if co.state != .Suspended && co.state != .Dead {
		log.error("attempt to uninitialize a coroutine that is not dead or suspended")
		return .Invalid_Operation
	}
	co.state = .Dead
	return .Success
}

create :: proc(desc: ^Desc, allocator := context.allocator) -> (co: ^Coro, res: Result) {
	if desc == nil {
		log.error("coroutine description is not set")
		return nil, .Invalid_Arguments
	}
	ptr, aerr := mem.alloc(int(desc.coro_size), allocator=allocator)
	if aerr != nil {
		log.error("coroutine allocation failed: %v", aerr)
		return nil, .Out_Of_Memory
	}
	co = (^Coro)(ptr)
	defer if res != .Success do mem.free_with_size(ptr, int(desc.coro_size), allocator)

	init(co, desc) or_return
	return
}

destroy :: proc(co: ^Coro, allocator := context.allocator) -> Result {
	if co == nil {
		log.error("attempt to destroy an invalid coroutine")
		return .Invalid_Coroutine
	}
	uninit(co) or_return

	if err := mem.free_with_size(co, int(co.coro_size), allocator); err != nil {
		log.error("free coroutine error: %v", err)
		return .Invalid_Operation
	}

	return .Success
}

resume :: proc(co: ^Coro) -> Result {
	if co == nil {
		log.error("attempt to resume a nil coroutine")
		return .Invalid_Coroutine
	}
	if co.state != .Suspended {
		log.error("attempt to resume a coroutine that is not suspended")
		return .Not_Suspended
	}
	co.state = .Running
	_jumpin(co)
	return .Success
}

yield :: proc(co_: ^Coro = nil) -> Result {
	co := co_or_running(co_) or_return

	// Check stack overflow, happens after the fact, but better late then never.
	dummy: uintptr
	stack_addr := uintptr(&dummy)
	stack_min := uintptr(co.stack_base)
	stack_max := stack_min + uintptr(co.stack_size)
	if co.magic_number != MAGIC_NUMBER || stack_addr < stack_min || stack_addr > stack_max {
		log.error("coroutine stack overflow, try increasing te stack size")
		return .Stack_Overflow
	}

	if co.state != .Running {
		log.error("attempt to yield a coroutine that is not running")
		return .Not_Running
	}

	co.state = .Suspended
	_jumpout(co)
	return .Success
}

status :: proc(co_: ^Coro = nil) -> State {
	co, _ := co_or_running(co_)
	if co == nil {
		return .Dead
	}
	return co.state
}

user_data :: proc($T: typeid, co_: ^Coro = nil) -> T where intrinsics.type_is_pointer(T) || intrinsics.type_is_proc(T) {
	co, _ := co_or_running(co_)
	if co == nil {
		return nil
	}
	return (T)(co.user_data)
}

push :: proc(val: $T, co_: ^Coro = nil) -> Result {
	len :: size_of(T)
	tid := typeid_of(T)
	tot :: len + size_of(typeid)

	co := co_or_running(co_) or_return

	bytes_stored := co.bytes_stored + tot
	if bytes_stored > co.storage_size {
		log.error("attempt to push too many bytes into the coroutine storage")
		return .Not_Enough_Space
	}

	val := val
	mem.copy(&co.storage[co.bytes_stored], &val, len)
	mem.copy(&co.storage[co.bytes_stored+len], &tid, size_of(tid))
	co.bytes_stored = bytes_stored

	return .Success
}

pop :: proc(dest: $P/^$T, co_: ^Coro = nil, loc := #caller_location) {
	len :: size_of(T)
	tid := typeid_of(T)
	tot :: len + size_of(typeid)

	co := co_or_running_or_panic(co_, loc)

	if tot > co.bytes_stored {
		fmt.panicf("attempt to pop type %v from coroutine stack, but there are only %v bytes stored", tid, co.bytes_stored, loc=loc)
	}

	co.bytes_stored -= size_of(typeid)
	stid: typeid
	mem.copy(&stid, &co.storage[co.bytes_stored], size_of(typeid))

	if tid != stid {
		fmt.panicf("attempt to pop type %v from coroutine stack, but type %v is stored on the top", tid, stid, loc=loc)
	}

	co.bytes_stored -= len
	mem.copy(dest, &co.storage[co.bytes_stored], len)

	return
}

bytes_stored :: proc(co_: ^Coro = nil) -> uint {
	co, _ := co_or_running(co_)
	if co == nil {
		return 0
	}
	return co.bytes_stored
}

storage_size :: proc(co_: ^Coro = nil) -> uint {
	co, _ := co_or_running(co_)
	if co == nil {
		return 0
	}
	return co.storage_size
}

running_safe :: #force_no_inline proc() -> ^Coro {
	return current_co
}

running_or_panic :: proc(msg := "attempt to use running coroutine, but no coroutine is running", loc := #caller_location) -> ^Coro {
	if current_co == nil {
		panic(msg, loc)
	}
	return current_co
}

co_or_running :: #force_inline proc(co: ^Coro) -> (out: ^Coro, err: Result) {
	out = co if co != nil else running_safe()
	if out == nil {
		log.warn("attempt to use an invalid coroutine")
		err = .Invalid_Coroutine
	}
	return
}

co_or_running_or_panic :: #force_inline proc(co: ^Coro, loc := #caller_location) -> ^Coro {
	return co if co != nil else running_or_panic(loc=loc)
}

