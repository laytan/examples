/*
Example of a static file server.
*/
package main

import "core:mem/virtual"
import "core:bytes"
import "core:nbio"
import "core:strings"
import "core:log"
import "core:net"
import "core:fmt"
import os "core:os/os2"
import "core:http"

// TODO: make it much easier to just tell `http` to send the start of the request, and take over the socket until we
// are done sending body.

// The root of the examples repo.
TARGET :: #directory + "../../.."
target_path: string
target: nbio.Handle

main :: proc() {
	context.logger = log.create_console_logger()

	nbio.acquire_thread_event_loop()
	defer nbio.release_thread_event_loop()

	{
		err: os.Error
		target_path, err = os.get_absolute_path(TARGET, context.allocator)
		assert(err == nil)

		nbio.open(target_path, nil, proc(op: ^nbio.Operation) {
			assert(op.open.err == nil)
			target = op.open.handle
		})
		nbio.run()
	}

	ep, _ := net.parse_endpoint("127.0.0.1:1111")

	s: http.Server
	err := http.listen_and_serve(&s, http.handler(handler), ep)
	fmt.assertf(err == nil, "listen_and_serve: %v", err)
}

handler :: proc(using ctx: ^http.Context) {
	if req.line.(http.Requestline).method != .Get {
		http.respond_with_status(res, .Not_Found)
		return
	}

	full_request, err := os.join_path({target_path, req.url.path}, context.temp_allocator)
	if err != nil {
		log.warnf("join_path(%q, %q): %v", target_path, req.url.path, err)
		http.respond_with_status(res, .Not_Found)
		return
	}

	if !strings.has_prefix(full_request, target_path) {
		log.warnf("path traversal %q %q", full_request, target_path)
		http.respond_with_status(res, .Not_Found)
		return
	}

	rel_path, rel_err := os.get_relative_path(target_path, full_request, context.temp_allocator)
	if rel_err != nil {
		log.warnf("get_relative_path(%q, %q)", target_path, full_request, rel_err)
		http.respond_with_status(res, .Not_Found)
	}

	http.headers_set_content_type_mime(&res.headers, http.mime_from_extension(rel_path))

	nbio.open_poly(rel_path, ctx, on_open, dir=target)

	on_open :: proc(op: ^nbio.Operation, using ctx: ^http.Context) {
		if op.open.err != nil {
			if op.open.err != .Not_Exist {
				log.warnf("open(%q): %v", op.open.path, op.open.err)
			}

			http.respond_with_status(res, .Not_Found)
			return
		}

		nbio.stat_poly(op.open.handle, ctx, on_stat)
	}

	on_stat :: proc(op: ^nbio.Operation, using ctx: ^http.Context) {
		if op.stat.err != nil {
			log.warnf("stat: %v", op.stat.err)

			http.respond_with_status(res, .Not_Found)
			return
		}

		if op.stat.type != .Regular {
			log.warn("not a regular file")

			http.respond_with_status(res, .Not_Found)
			return
		}

		if op.stat.size > i64(max(int)) {
			log.warn("massive file")

			http.respond_with_status(res, .Not_Found)
			return
		}
		size := int(op.stat.size)

		http.response_status(res, .OK)

		http._response_write_heading(res, size)
		loop := http.res_loop(res)
		conn := http.loop_conn(loop)
		buf  := bytes.buffer_to_bytes(&res._buf)

		nbio.send_poly3(conn.socket, buf, ctx, op.stat.handle, size, on_sent_headers)
	}

	on_sent_headers :: proc(op: ^nbio.Operation, using ctx: ^http.Context, file: nbio.Handle, size: int) {
		loop := http.res_loop(res)
		conn := http.loop_conn(loop)

		if op.send.err != nil {
			log.warnf("send (headers): %v", op.send.err)

			http.connection_set_state(conn, .Will_Close)
			http._connection_close(conn)
			return
		}

		log.info("send file")
		nbio.sendfile_poly(conn.socket, file, ctx, on_sent_file, nbytes=size)
	}

	on_sent_file :: proc(op: ^nbio.Operation, using ctx: ^http.Context) {
		loop := http.res_loop(res)
		conn := http.loop_conn(loop)

		if op.sendfile.err != nil {
			log.warnf("send: %v", op.sendfile.err)

			http.connection_set_state(conn, .Will_Close)
			http._connection_close(conn)
			return
		}

		context.temp_allocator = virtual.arena_allocator(&conn.temp_allocator)
		http.clean_request_loop(conn)
		nbio.close(op.sendfile.file)
	}
}
