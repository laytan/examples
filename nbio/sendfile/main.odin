/*
Example that shows the `sendfile` operation.

Dials a TCP server (localhost:1234) (use `nc -l 1234` to start a netcat server)
and sends the contents of this file to it.
*/
package main

import "core:fmt"
import "core:nbio"
import "core:net"

main :: proc() {
	err := nbio.acquire_thread_event_loop()
	assert(err == nil)
	defer nbio.release_thread_event_loop()

	nbio.dial(net.Endpoint{net.IP4_Loopback, 1234}, nil, on_dial)

	err = nbio.run()
	assert(err == nil)

	on_dial :: proc(op: ^nbio.Operation) {
		fmt.assertf(op.dial.err == nil, "dial: %v", op.dial.err)

		file, err := nbio.open_sync(#file)
		assert(err == nil)

		// Call can also take an offset, a length, a timeout.
		// By default it sends the entire file, without a timeout.
		nbio.sendfile(op.dial.socket, file, nil, on_sent)
	}

	on_sent :: proc(op: ^nbio.Operation) {
		fmt.assertf(op.sendfile.err == nil, "sendfile: %v", op.sendfile.err)
		nbio.close(op.sendfile.file)
	}
}
