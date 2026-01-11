package main

import "core:fmt"
import "core:nbio"

import mco "minicoro"

await :: proc(op: ^nbio.Operation, result: ^nbio.Specifics) {
	op.cb = proc(op: ^nbio.Operation) {
		result := (^nbio.Specifics)(op.user_data[0])
		co     := (^mco.Coro)(op.user_data[1])
		result^ = op._specifics
		mco.resume(co)
	}
	op.user_data[0] = result
	op.user_data[1] = mco.running_or_panic()
	mco.yield()
}

panic_cb :: proc(op: ^nbio.Operation) {
	panic("panic_cb called")
}

Stat :: distinct nbio.FS_Error
Open :: distinct nbio.FS_Error
Read :: distinct nbio.FS_Error

Read_Entire_File_Error :: union #shared_nil {
	Stat,
	Open,
	Read,
}

read_entire_file :: proc(path: string, allocator := context.allocator) -> ([]byte, Read_Entire_File_Error) {
	result: nbio.Specifics
	await(nbio.open(path, panic_cb), &result)
	if result.open.err != nil {
		return nil, Open(result.open.err)
	}

	await(nbio.stat(result.open.handle, panic_cb), &result)
	if result.stat.err != nil {
		return nil, Stat(result.stat.err)
	}

	buf, err := make([]byte, result.stat.size, allocator)
	if err != nil {
		return nil, Read(.Allocation_Failed)
	}

	await(nbio.read(result.stat.handle, 0, buf, panic_cb, all=true), &result)
	if result.read.err != nil {
		delete(buf, allocator)
		return nil, Read(result.read.err)
	}

	return buf, nil
}

Read_Entire_File_Callback :: proc(buf: []byte, err: Read_Entire_File_Error)

read_entire_file2 :: proc(path: string, allocator := context.allocator, cb: Read_Entire_File_Callback) {
	context.allocator = allocator

	nbio.open_poly(path, cb, on_open)

	on_open :: proc(op: ^nbio.Operation, cb: Read_Entire_File_Callback) {
		if op.open.err != nil {
			cb(nil, Open(op.open.err))
			return
		}

		nbio.stat_poly(op.open.handle, cb, on_stat)
	}

	on_stat :: proc(op: ^nbio.Operation, cb: Read_Entire_File_Callback) {
		if op.stat.err != nil {
			cb(nil, Stat(op.stat.err))
			return
		}

		buf, err := make([]byte, op.stat.size)
		if err != nil {
			cb(nil, Read(.Allocation_Failed))
			return
		}

		nbio.read_poly(op.stat.handle, 0, buf, cb, on_read)
	}

	on_read :: proc(op: ^nbio.Operation, cb: Read_Entire_File_Callback) {
		if op.read.err != nil {
			delete(op.read.buf)
			cb(nil, Read(op.read.err))
			return
		}

		cb(op.read.buf, nil)
	}
}

coro_entry :: proc(co: ^mco.Coro) {
	data, uerr := read_entire_file(#file)
	switch err in uerr {
	case Open: fmt.eprintfln("read_entire_file(%q): open: %v", #file, err)
	case Stat: fmt.eprintfln("read_entire_file(%q): stat: %v", #file, err)
	case Read: fmt.eprintfln("read_entire_file(%q): read: %v", #file, err)
	case nil:  fmt.print(string(data))
	}
}

main :: proc() {
	desc := mco.desc_init(coro_entry)

	co, res := mco.create(&desc, context.allocator)
	assert(res == .Success)
	assert(mco.status(co) == .Suspended)
	defer mco.destroy(co, context.allocator)

	nbio.acquire_thread_event_loop()
	defer nbio.release_thread_event_loop()

	res = mco.resume(co)
	assert(res == .Success)
	assert(mco.status(co) == .Suspended)

	err := nbio.run()
	assert(err == nil)
}
