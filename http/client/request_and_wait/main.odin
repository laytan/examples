package main

import "core:fmt"
import "core:http"
import "core:log"
import "core:nbio"

import openssl_http "vendor:openssl/http"

main :: proc() {
	context.logger = log.create_console_logger()

	when #defined(http.native_ssl_implementation) {
		http.set_ssl_client(http.native_ssl_implementation())
	} else {
		http.set_ssl_client(openssl_http.client_implementation())
	}

	c: http.Client
	http.client_init(&c)
	defer http.client_destroy(&c)

	file, oerr := nbio.open_sync("microui")
	assert(oerr == nil)

	res, err := http.request_and_wait(&c, "https://httpbin.org/post", {
		method = .Post,
		body = { content = file },
	})
	if err != nil {
		fmt.panicf("could not POST: %v", err)
	}
	defer http.incoming_response_destroy(res)

	fmt.printfln(
		"%s\n\n%s\n%s",
		http.status_string(res.status),
		http.headers_to_string(&res.headers),
		string(res.body[:]),
	)
}
