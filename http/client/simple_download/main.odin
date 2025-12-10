/*
An example of a really simple file downloader.

Expects an output path as the first argument and the URL to download as the second.

Streams the download into the file.
*/
package main

import "core:fmt"
import "core:http"

import os "core:os/os2"

import openssl_http "vendor:openssl/http"

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintfln("Usage: %s <output> <url>", os.args[0])
		os.exit(1)
	}

	output_file  := os.args[1]
	download_url := os.args[2]

	when #defined(http.native_ssl_implementation) {
		http.set_ssl_client(http.native_ssl_implementation())
	} else {
		http.set_ssl_client(openssl_http.client_implementation())
	}

	c: http.Client
	http.client_init(&c)
	defer http.client_destroy(&c)

	output, open_err := os.open(output_file, {.Write, .Create, .Excl})
	if open_err != nil {
		fmt.printfln("failed to open %q: %v", output_file, os.error_string(open_err))
		os.exit(1)
	}
	defer os.close(output)
	output_writer := os.to_writer(output)

	res, err := http.request_and_wait(&c, download_url, {
		// NOTE: one can write their own implementation that prints a progress bar (for an example, see "download_odin_release").
		callback = http.incoming_body_to_stream(&output_writer),
	})
	defer http.incoming_response_destroy(res)

	if err != nil {
		fmt.printfln("could not download %q: %v", download_url, err)
		os.exit(1)
	} else if !http.status_is_success(res.status) {
		fmt.printfln("not OK: %v", http.status_string(res.status))
		os.exit(1)
	}
}
