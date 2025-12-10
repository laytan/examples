package main

import "core:fmt"
import "core:http"
import "core:log"

import os "core:os/os2"

import openssl_http "vendor:openssl/http"

main :: proc() {
	context.logger = log.create_console_logger(.Warning)

	when #defined(http.native_ssl_implementation) {
		http.set_ssl_client(http.native_ssl_implementation())
	} else {
		http.set_ssl_client(openssl_http.client_implementation())
	}

	c: http.Client
	http.client_init(&c)
	defer http.client_destroy_and_wait(&c)

	{
		// Get the current file as a handle, we will send the contents with the request.
		this, open_err := os.open(#file)
		assert(open_err == nil, "could not open " + #file)
		defer os.close(this)

		// Form data state for the request.
		form: http.Form_Data
		defer http.form_data_destroy(&form)

		// Add the file, and an expiry of 1 hour.
		http.form_data_append_file(&form, "file", this)
		http.form_data_append(&form, "expires", "1")

		req: http.Outgoing_Request

		// Sets the request body to the form data, and adds the appropriate content type.
		// This allocates the content type string, which is deleted with the deferred call later.
		http.form_data_add_to_request(&form, &req)
		defer http.form_data_remove_from_request(&form, &req)

		// Actually makes the request and waits on it.
		res, err := http.request_and_wait(&c, "https://0x0.st", req)
		defer http.incoming_response_destroy(res)

		if err != nil {
			fmt.panicf("could not POST: %v", err)
		} else if res.status != .OK {
			fmt.panicf("not OK: %v", http.status_string(res.status))
		}

		fmt.printf("Posted at %v", string(res.body[:]))
	}
}
