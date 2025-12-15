/*
Example that pipes the body from one request into the body of another.

For the example the post is done to `http://localhost:1234` on which you could locally run `httpbin`,
a server that verifies the request and returns information about it.
Via docker: `docker run -p 1234:80 kennethreitz/httpbin`
*/
package main

import "core:fmt"
import "core:http"
import "core:io"
import "core:log"

import openssl_http "vendor:openssl/http"

main :: proc() {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	when #defined(http.native_ssl_implementation) {
		http.set_ssl_client(http.native_ssl_implementation())
	} else {
		http.set_ssl_client(openssl_http.client_implementation())
	}

	c: http.Client
	http.client_init(&c)
	defer http.client_destroy_and_wait(&c)

	State :: struct {
		reqs:    [2]http.Outgoing_Request,
		results: [2]http.Incoming_Result,

		buf: ^[dynamic]byte, // Reference to the retrieved body.
		eof: bool,
	}
	state: State

	state.reqs = {
		// Retrieval request.
		{
			url       = "https://example.com",
			user_data = &state,
			cb        = proc(req: http.Outgoing_Request, res: ^http.Incoming_Response, err: http.Request_Error) {
				state := (^State)(req.user_data)
				if res != nil {
					state.buf = &res.body
				}
				if err != .Partial {
					state.eof = true
				}
			}
		},
		// Send request.
		{
			method = .Post,
			url    = "http://localhost:1234/post",
			body   = {
				content = io.Stream{
					data = &state,
					procedure = proc(state: rawptr, mode: io.Stream_Mode, buf: []byte, _: i64, _: io.Seek_From) -> (n: i64, err: io.Error) {
						state := (^State)(state)
						#partial switch mode {
						case .Query:
							return io.query_utility({.Query, .Read})
						case .Read:
							if state.buf != nil && len(state.buf) > 0 {
								n = i64(copy(buf, state.buf[:]))
								remove_range(state.buf, 0, n)
							} else if state.eof {
								err = .EOF
							}
							return
						case:
							err = .Unsupported
							return
						}
					},
				}
			}
		},
	}

	// Kick off both requests and wait on them.
	http.request_and_wait_multiple_into_buffer(&c, state.reqs[:], state.results[:])
	defer http.incoming_results_destroy(state.results[:])

	fmt.printfln("Retrieval: %s (error: %v)\nSending: %s (error: %v)", http.status_string(state.results[0].res.status), state.results[0].err, http.status_string(state.results[1].res.status), state.results[1].err)

	fmt.println(string(state.results[1].res.body[:]))
}
