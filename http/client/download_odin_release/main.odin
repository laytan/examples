/*
Concurrently downloads all assets of the latest Odin GitHub release, streamed to files.
*/
package main

import "core:encoding/json"
import "core:fmt"
import "core:http"
import "core:nbio"
import "core:terminal/ansi"
import "core:time"

import os "core:os/os2"

import openssl_http "vendor:openssl/http"

// To make it simpler without dynamic memory, we know that Odin releases have a set amount of assets.
MAX_DOWNLOADS :: 6

State :: struct {
	reqs:      [MAX_DOWNLOADS]http.Outgoing_Request,
	results:   [MAX_DOWNLOADS]http.Incoming_Result,
	downloads: [MAX_DOWNLOADS]Download,
	count:     int,
	start:     time.Time,
}

Download :: struct {
	state:    ^State,
	file:     ^os.File,
	asset:    Asset,
	written:  int           `fmt:"M"`,
	duration: time.Duration,
}

main :: proc() {
	when #defined(http.native_ssl_implementation) {
		http.set_ssl_client(http.native_ssl_implementation())
	} else {
		http.set_ssl_client(openssl_http.client_implementation())
	}

	c: http.Client
	http.client_init(&c)

	release := fetch_latest_release(&c)
	free_all(context.temp_allocator)

	state: State

	state.count = len(release.assets)
	assert(state.count <= MAX_DOWNLOADS)

	for asset, i in release.assets {
		req      := &state.reqs[i]
		download := &state.downloads[i]

		_file, err := os.open(asset.name, {.Write, .Trunc, .Create})
		assert(err == nil)

		download.asset  = asset
		download.file   = _file
		download.state  = &state

		req^ = {
			allocator = context.temp_allocator,
			url       = asset.browser_download_url,
			callback  = incoming_callback(download),
		}
	}

	state.start = time.now()

	fmt.print(ansi.CSI + ansi.DECTCEM_HIDE)
	render_progress(&state, clear=false)

	// Concurrently downloads all the assets, streaming the responses to their files.
	http.request_and_wait_multiple_into_buffer(&c, state.reqs[:state.count], state.results[:state.count])

	render_progress(&state, clear=true)
	fmt.print(ansi.CSI + ansi.DECTCEM_SHOW)

	for download, i in state.downloads[:state.count] {
		os.close(download.file)
	}
}

Release :: struct {
	assets: []Asset,
	body:   string,
}

Asset :: struct {
	name:                 string,
	browser_download_url: string,
	size:                 int    `fmt:"M"`,
}

/*
Uses the GitHub API to fetch information about the latest release.
*/
fetch_latest_release :: proc(c: ^http.Client) -> (release: Release) {
	res, err := http.request_and_wait(c, "https://api.github.com/repos/odin-lang/Odin/releases/latest", allocator=context.temp_allocator)
	if err != nil {
		fmt.panicf("could not get latest release information: %v", err)
	} else if res.status != .OK {
		fmt.panicf("latest release information not OK: %v", http.status_string(res.status))
	}

	if json_err := json.unmarshal(res.body[:], &release, allocator = context.allocator); json_err != nil {
		fmt.panicf("could not unmarshal latest release information JSON %q: %v", string(res.body[:]), json_err)
	}

	return
}

/*
Callback for (full or partial) responses, writes the retrieved body to the file, updates the progress.
*/
incoming_callback :: proc(download: ^Download) -> http.Incoming_Callback {
	return {
		user_data = download,
		cb = proc (req: http.Outgoing_Request, res: ^http.Incoming_Response, err: http.Request_Error) {
			if err != nil && err != .Partial {
				return
			}

			download := (^Download)(req.user_data)

			written, write_err := os.write(download.file, res.body[:])
			assert(write_err == nil) // TODO: some way to cancel the rest of the request and error out from here.

			download.written += written
			render_progress(download.state, clear=true)

			clear(&res.body)
		},
	}
}

/*
Renders fancy download progress.
*/
render_progress :: proc(state: ^State, clear: bool) {
	if clear {
		fmt.printf(ansi.CSI + "%v" + ansi.CUU, state.count)
	}

	for &download, i in state.downloads[:state.count] {
		if clear {
			fmt.print(ansi.CSI + "2" + ansi.EL + ansi.CSI + "0" + ansi.CHA)
		}

		percentage := int(f32(download.written) / f32(download.asset.size) * 100.)

		duration: time.Duration
		if percentage == 100 {
			if download.duration == 0 {
				download.duration = time.diff(state.start, nbio.now())
			}
			duration = download.duration
		} else {
			duration = time.diff(state.start, nbio.now())
		}

		bytes_per_sec := int(f64(download.written) / time.duration_seconds(duration))

		result := state.results[i]
		if result.res.status != nil {
			fmt.printfln(
				"%36s: % 9M | %s | % 9M/s",
				download.asset.name, download.asset.size, http.status_string(result.res.status), bytes_per_sec,
			)
		} else if result.err != nil {
			fmt.printfln(
				"%36s: % 9M | %v | % 9M/s",
				download.asset.name, download.asset.size, result.err, bytes_per_sec,
			)
		} else {
			fmt.printfln(
				"%36s: % 9M/% 9M | % 3v%% | % 9M/s",
				download.asset.name, download.written, download.asset.size, percentage, bytes_per_sec,
			)
		}
	}
}

